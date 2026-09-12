<#
.SYNOPSIS
  Runs the voice-agent speech legs locally on a Windows machine, with the LLM
  served remotely by llama-swap.

.DESCRIPTION
  Edge half of the split described in
  systems/prometheus/opt/stacks/ai/voice-agent/procedures/voice-agent-edge-split.md

      this machine : STT + TTS          (CrispASR, CUDA)
      Prometheus   : /v1/chat/completions (llama-swap)

  No build step. Upstream ships prebuilt Windows CUDA binaries, so -Bootstrap
  downloads the release and the models and nothing needs compiling.

  Two CrispASR quirks this script exists to encapsulate:

    * The OpenAI `voice` field is resolved as a filename relative to the TTS
      server's *working directory*, not to --voice-dir. The server is therefore
      started from inside the voice directory.
    * Passing only the Chatterbox *turbo* T3 auto-resolves the *base* S3Gen,
      which runs 10 CFM steps instead of the turbo meanflow 2-step path. That
      alone measured RTF 1.34 versus 0.68 on the same hardware. --codec-model is
      always passed explicitly, and Verify checks for "meanflow mode" in the log.

.PARAMETER Bootstrap
  Download the CrispASR Windows CUDA release and the model set, then exit.

.PARAMETER Verify
  Start the servers, run a warm synthesis and transcription, report RTF, stop.

.PARAMETER Stop
  Stop any running CrispASR servers started by this script.

.PARAMETER Voice
  Reference voice name. Must match a file in voices\chatterbox\ with NO
  extension. Default: tester

.EXAMPLE
  .\nomad-voice-stack.ps1 -Bootstrap
  .\nomad-voice-stack.ps1 -Verify
  .\nomad-voice-stack.ps1 -Voice salesman
#>
[CmdletBinding()]
param(
    [switch]$Bootstrap,
    [switch]$Verify,
    [switch]$Stop,
    [switch]$SpeechOnly,
    [string]$Voice = 'tester',
    [string]$Model = 'gemma-4-26b-a4b-it-qat-co',
    [string]$LlamaSwapUrl = $(if ($env:LLAMA_SWAP_URL) { $env:LLAMA_SWAP_URL } else { 'http://localhost:8085/v1' }),
    [string]$LlamaSwapKey = 'LOCAL',
    [int]$BotPort = 7860,
    [double]$Speed = 0.92,
    # bot.py's built-in default is the old terse prompt that produced clipped
    # replies. Passing it here keeps NOMAD in step with the Prometheus launcher.
    [string]$SystemPrompt = 'You are a spoken assistant for a homelab AI stack. Your replies are read aloud, so write how a person talks, not how a page reads. Match the length of your answer to the question. A factual or yes/no question gets one or two sentences. A how-to, recipe, comparison, or explanation gets full detail, including specific quantities, times, temperatures, and names, walked through in spoken order. Never use markdown, bullet characters, numbered lists, headings, or emoji, and never say the word asterisk. Say first, then, after that instead. Give the answer directly, with no preamble about what you are about to do and no offer to help further. Do not mention reasoning, plans, or hidden thoughts.',
    # Reasoning models spend a small budget entirely on reasoning and return
    # empty content. 400 covers qwen3.8-flash-next and the -think profiles.
    [int]$MaxTokens = 400,
    [string]$Base = "$env:USERPROFILE\stacks\voice-edge",
    [int]$SttPort = 8002,
    [int]$TtsPort = 8003,
    [string]$Release = 'v0.8.32',
    # Cloned voices require an attestation on every synthesis request;
    # server-side --i-have-rights does not satisfy it.
    [string]$Consent = 'The reference voice is my own, or synthetic audio, or material I am licensed to use.'
)

$ErrorActionPreference = 'Stop'
$Bin      = Join-Path $Base 'bin'
$Models   = Join-Path $Base 'models'
$VoiceDir = Join-Path $Base 'voices\chatterbox'
$Logs     = Join-Path $Base 'logs'
$Pipecat  = Join-Path $Base 'pipecat'
$Exe      = Join-Path $Bin 'crispasr.exe'

$T3    = Join-Path $Models 'chatterbox-turbo-t3-q8_0.gguf'
$S3Gen = Join-Path $Models 'chatterbox-turbo-s3gen-q8_0.gguf'
$Stt   = Join-Path $Models 'parakeet-tdt-0.6b-v3-q4_k.gguf'

function Stop-Servers {
    Get-Process crispasr -ErrorAction SilentlyContinue | Stop-Process -Force
    # Match on path: a bare 'python' kill would take unrelated interpreters.
    Get-Process python -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path -like "*voice-edge*" } | Stop-Process -Force
    Start-Sleep -Seconds 2
}

function Wait-Healthy([int]$Port, [int]$TimeoutSec = 180) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        try {
            Invoke-WebRequest -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 2 -UseBasicParsing | Out-Null
            return $true
        } catch { Start-Sleep -Seconds 2 }
    }
    return $false
}

function Invoke-SttTranscription {
    <#
      Posts a WAV to the OpenAI-compatible transcription endpoint.
      The multipart body is assembled by hand because Invoke-RestMethod -Form
      requires PowerShell 7, and this script targets the Windows PowerShell 5.1
      that ships with the OS.
    #>
    param([int]$Port, [string]$Path)

    $boundary = [Guid]::NewGuid().ToString()
    $LF = "`r`n"
    $fileBytes = [IO.File]::ReadAllBytes($Path)
    $enc = [Text.Encoding]::GetEncoding('iso-8859-1')

    $head = (
        "--$boundary", "Content-Disposition: form-data; name=`"model`"", '', 'whisper-1',
        "--$boundary",
        "Content-Disposition: form-data; name=`"file`"; filename=`"$(Split-Path $Path -Leaf)`"",
        'Content-Type: audio/wav', ''
    ) -join $LF
    $body = $head + $LF + $enc.GetString($fileBytes) + $LF + "--$boundary--" + $LF

    $r = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/v1/audio/transcriptions" -Method POST `
            -ContentType "multipart/form-data; boundary=$boundary" `
            -Body $enc.GetBytes($body) -TimeoutSec 600
    return $r.text
}

function Invoke-Bootstrap {
    New-Item -ItemType Directory -Force -Path $Bin, $Models, $VoiceDir, $Logs | Out-Null

    if (-not (Test-Path $Exe)) {
        Write-Host "Downloading CrispASR $Release (Windows CUDA)..."
        $zip = Join-Path $env:TEMP 'crispasr-windows-x86_64-cuda.zip'
        gh release download $Release --repo CrispStrobe/CrispASR `
            --pattern 'crispasr-windows-x86_64-cuda.zip' --output $zip --clobber
        $tmp = Join-Path $env:TEMP 'crispasr-extract'
        Expand-Archive -Path $zip -DestinationPath $tmp -Force
        $srcDir = (Get-ChildItem $tmp -Recurse -Filter 'crispasr.exe' | Select-Object -First 1).DirectoryName
        Copy-Item "$srcDir\*" -Destination $Bin -Recurse -Force
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Fetched by direct URL rather than --hf-repo: auto-resolution pulls the
    # BASE s3gen for a turbo T3, which is the 10-step slow path.
    $files = @{
        'chatterbox-turbo-t3-q8_0.gguf'    = 'https://huggingface.co/cstr/chatterbox-turbo-GGUF/resolve/main/chatterbox-turbo-t3-q8_0.gguf'
        'chatterbox-turbo-s3gen-q8_0.gguf' = 'https://huggingface.co/cstr/chatterbox-turbo-GGUF/resolve/main/chatterbox-turbo-s3gen-q8_0.gguf'
        'parakeet-tdt-0.6b-v3-q4_k.gguf'   = 'https://huggingface.co/cstr/parakeet-tdt-0.6b-v3-GGUF/resolve/main/parakeet-tdt-0.6b-v3-q4_k.gguf'
    }
    foreach ($name in $files.Keys) {
        $dest = Join-Path $Models $name
        if (Test-Path $dest) { Write-Host "have $name"; continue }
        Write-Host "Downloading $name ..."
        Invoke-WebRequest -Uri $files[$name] -OutFile $dest -UseBasicParsing
    }

    # Pipecat 1.10 renamed the prebuilt frontend package and no longer pulls
    # fastapi/uvicorn transitively, so both are requested explicitly.
    if (-not (Test-Path (Join-Path $Pipecat '.venv\Scripts\python.exe'))) {
        Write-Host 'Creating Pipecat venv (Python 3.12) ...'
        New-Item -ItemType Directory -Force -Path $Pipecat | Out-Null
        Push-Location $Pipecat
        try {
            & uv venv --python 3.12 .venv
            & uv pip install --python .venv\Scripts\python.exe `
                'pipecat-ai[silero,webrtc,openai]' fastapi uvicorn pipecat-ai-prebuilt
        } finally { Pop-Location }
    }

    Write-Host ""
    Write-Host "Bootstrap complete. Copy a reference voice into:"
    Write-Host "  $VoiceDir"
    Write-Host "named exactly as the voice (NO extension), e.g. 'tester'."
    & $Exe --version 2>&1 | Select-String 'version|backends|cuda archs'
}

function Start-Servers {
    if (-not (Test-Path $Exe))   { throw "CrispASR not installed. Run with -Bootstrap first." }
    if (-not (Test-Path $S3Gen)) { throw "Turbo S3Gen missing. Run with -Bootstrap first." }
    $ref = Join-Path $VoiceDir $Voice
    if (-not (Test-Path $ref)) {
        throw "Voice '$Voice' not found at $ref. The file must have NO extension."
    }

    Stop-Servers
    New-Item -ItemType Directory -Force -Path $Logs | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

    Write-Host "Starting STT (parakeet) on $SttPort ..."
    Start-Process -FilePath $Exe -NoNewWindow `
        -ArgumentList @('--server','--host','127.0.0.1','--port',"$SttPort",
                        '--cache-dir',"`"$Models`"",'-m',"`"$Stt`"") `
        -RedirectStandardOutput "$Logs\stt_$stamp.log" -RedirectStandardError "$Logs\stt_$stamp.err" | Out-Null

    # Started from inside the voice directory: CrispASR resolves `voice` as a
    # path relative to cwd, not to --voice-dir.
    Write-Host "Starting TTS (chatterbox, voice=$Voice) on $TtsPort ..."
    Push-Location $VoiceDir
    try {
        Start-Process -FilePath $Exe -NoNewWindow `
            -ArgumentList @('--server','--host','127.0.0.1','--port',"$TtsPort",
                            '--cache-dir',"`"$Models`"",'--voice-dir',"`"$VoiceDir`"",
                            '--i-have-rights','--no-spoken-disclaimer','--accept-marking-responsibility',
                            '-m',"`"$T3`"",'--codec-model',"`"$S3Gen`"") `
            -RedirectStandardOutput "$Logs\tts_$stamp.log" -RedirectStandardError "$Logs\tts_$stamp.err" | Out-Null
    } finally { Pop-Location }

    foreach ($p in @($SttPort, $TtsPort)) {
        if (Wait-Healthy $p) { Write-Host "  :$p ready" }
        else { throw "Port $p did not become healthy. See $Logs\*_$stamp.err" }
    }
    return $stamp
}

if ($Stop)      { Stop-Servers; Write-Host 'stopped'; return }
if ($Bootstrap) { Invoke-Bootstrap; return }

$stamp = Start-Servers

if ($Verify) {
    $body = @{ model='tts-1'; voice=$Voice; consent_attestation=$Consent
               input='The voice agent speech services are running locally.' } | ConvertTo-Json -Compress
    # warm first: a cold measurement charges model load to the synthesis
    foreach ($pass in 'warmup','measure') {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:$TtsPort/v1/audio/speech" -Method POST `
                -Body $body -ContentType 'application/json' -TimeoutSec 600 -UseBasicParsing
        if ($pass -eq 'measure') {
            $wav = Join-Path $Logs 'verify.wav'
            [IO.File]::WriteAllBytes($wav, $r.Content)
            Write-Host ("TTS ok: {0} bytes -> {1}" -f $r.Content.Length, $wav)
        }
    }

    $meanflow = Select-String -Path "$Logs\tts_$stamp.err" -Pattern 'meanflow mode' -ErrorAction SilentlyContinue
    if ($meanflow) { Write-Host 'codec: turbo meanflow (2 steps) - correct' }
    else { Write-Warning 'codec is NOT meanflow - the base S3Gen resolved, expect roughly half speed' }
    Select-String -Path "$Logs\tts_$stamp.err" -Pattern 'synthesized .*RTF' -ErrorAction SilentlyContinue |
        Select-Object -Last 1 -ExpandProperty Line

    # Built by hand: Invoke-RestMethod -Form is PowerShell 7+, and this script
    # must run on the Windows PowerShell 5.1 that ships with the OS.
    $wavPath = Join-Path $Logs 'verify.wav'
    $t = Invoke-SttTranscription -Port $SttPort -Path $wavPath
    Write-Host ("STT ok: {0}" -f $t)

    Stop-Servers
    Write-Host 'verify complete, servers stopped'
    return
}

if ($SpeechOnly) {
    Write-Host ''
    Write-Host "Speech services up. Point a Pipecat bot at:"
    Write-Host "  VOICE_AGENT_STT_API = http://127.0.0.1:$SttPort/v1"
    Write-Host "  VOICE_AGENT_TTS_API = http://127.0.0.1:$TtsPort/v1"
    Write-Host "  LLAMA_SWAP_URL      = $LlamaSwapUrl"
    Write-Host ''
    Write-Host "Stop with: .\nomad-voice-stack.ps1 -Stop"
    return
}

# Pipecat holds the WebRTC session and the conversation context. It runs on
# Windows directly so it can reach the microphone; WSL has no audio device.
$py = Join-Path $Pipecat '.venv\Scripts\python.exe'
if (-not (Test-Path $py)) { throw "Pipecat venv missing at $py. Run with -Bootstrap." }

$env:VOICE_AGENT_STT_API     = "http://127.0.0.1:$SttPort/v1"
$env:VOICE_AGENT_TTS_API     = "http://127.0.0.1:$TtsPort/v1"
$env:LLAMA_SWAP_URL          = $LlamaSwapUrl
$env:LLAMA_SWAP_KEY          = $LlamaSwapKey
$env:VOICE_AGENT_LLM_MODEL   = $Model
$env:VOICE_AGENT_TTS_VOICE   = $Voice
$env:VOICE_AGENT_TTS_CONSENT = $Consent
$env:VOICE_AGENT_TTS_SPEED   = "$Speed"
$env:VOICE_AGENT_SYSTEM_PROMPT = $SystemPrompt
$env:VOICE_AGENT_MAX_TOKENS    = "$MaxTokens"

Write-Host "Warming $Model on llama-swap (cold load takes ~20s) ..."
$warm = @{ model=$Model; messages=@(@{ role='user'; content='ping' }); max_tokens=8 } | ConvertTo-Json -Compress -Depth 4
try {
    Invoke-RestMethod -Uri "$LlamaSwapUrl/chat/completions" -Method POST -Body $warm `
        -ContentType 'application/json' -Headers @{ Authorization = "Bearer $LlamaSwapKey" } -TimeoutSec 600 | Out-Null
    Write-Host '  llm ready'
} catch { Write-Warning "LLM warm failed: $($_.Exception.Message). The first spoken turn will be slow." }

Write-Host "Starting Pipecat on $BotPort ..."
Push-Location $Pipecat
try {
    Start-Process -FilePath $py -NoNewWindow `
        -ArgumentList @('bot.py','-t','webrtc','--host','0.0.0.0','--port',"$BotPort") `
        -RedirectStandardOutput "$Logs\bot_$stamp.log" -RedirectStandardError "$Logs\bot_$stamp.err" | Out-Null
} finally { Pop-Location }

$deadline = (Get-Date).AddSeconds(120)
$up = $false
while ((Get-Date) -lt $deadline) {
    try { Invoke-WebRequest -Uri "http://127.0.0.1:$BotPort/client/" -TimeoutSec 2 -UseBasicParsing | Out-Null; $up = $true; break }
    catch { Start-Sleep -Seconds 2 }
}
if (-not $up) { throw "Pipecat did not serve /client/. See $Logs\bot_$stamp.err" }

Write-Host ''
Write-Host "Voice agent up on this machine."
Write-Host "  open   http://localhost:$BotPort/client/"
Write-Host "  speech local, LLM on $LlamaSwapUrl ($Model)"
Write-Host "  logs   $Logs\*_$stamp.*"
Write-Host ''
Write-Host "Stop with: .\nomad-voice-stack.ps1 -Stop"
