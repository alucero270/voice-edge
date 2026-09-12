<#
  Measures llama-swap LLM profiles from NOMAD, as the voice agent calls them.

  Reports cold load, warm turn latency, throughput, and whether the model
  emits hidden reasoning. Reasoning matters here for two reasons a raw
  tok/s figure hides: it is latency the speaker waits through, and if the
  token budget is too small the reasoning consumes all of it and the reply
  comes back empty.
#>
param(
    [string[]]$Models = @('laguna-s-2.1-ud-iq4-nl','qwen3.8-27b-mtp','qwen3.8-27b-dflash'),
    [string]$Url = $(if ($env:LLAMA_SWAP_URL) { $env:LLAMA_SWAP_URL } else { 'http://localhost:8085/v1' }),
    [string]$Key = 'LOCAL',
    [int]$MaxTokens = 400
)

$hdr = @{ Authorization = "Bearer $Key" }
$sys = 'You are a spoken assistant for a homelab. Reply in one or two short sentences.'
$q   = 'Why does moving speech processing off a shared GPU help?'

"{0,-28} {1,9} {2,9} {3,8} {4,7} {5,10}" -f 'model','cold','warm','tok/s','tokens','reasoning'
'-' * 78

foreach ($m in $Models) {
    # Evict first so "cold" means cold.
    try { Invoke-RestMethod -Uri "$($Url -replace '/v1$','')/unload" -Headers $hdr -TimeoutSec 60 | Out-Null } catch {}
    Start-Sleep -Seconds 6

    $body = @{
        model = $m
        messages = @(@{ role='system'; content=$sys }, @{ role='user'; content=$q })
        max_tokens = $MaxTokens
        extra_body = @{ chat_template_kwargs = @{ enable_thinking = $false; reasoning_effort = 'low' } }
    } | ConvertTo-Json -Compress -Depth 6

    $cold = $null; $warm = $null; $r = $null
    foreach ($pass in 'cold','warm') {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        try {
            $r = Invoke-RestMethod -Uri "$Url/chat/completions" -Method POST -Body $body `
                    -ContentType 'application/json' -Headers $hdr -TimeoutSec 1800
            $sw.Stop()
            if ($pass -eq 'cold') { $cold = $sw.Elapsed.TotalSeconds } else { $warm = $sw.Elapsed.TotalSeconds }
        } catch {
            $sw.Stop()
            "{0,-28} FAILED after {1:N0}s: {2}" -f $m, $sw.Elapsed.TotalSeconds, $_.Exception.Message
            $r = $null; break
        }
    }
    if (-not $r) { continue }

    $rc = if ($r.choices[0].message.PSObject.Properties.Name -contains 'reasoning_content' -and $r.choices[0].message.reasoning_content) {
              "$($r.choices[0].message.reasoning_content.Length) ch" } else { 'none' }
    $content = ($r.choices[0].message.content | Out-String).Trim()

    "{0,-28} {1,7:N1}s {2,7:N2}s {3,8:N1} {4,7} {5,10}" -f `
        $m, $cold, $warm, $r.timings.predicted_per_second, $r.timings.predicted_n, $rc
    if ($content) { "    -> " + ($content -replace '\s+',' ').Substring(0, [Math]::Min(110, $content.Length)) }
    else { "    -> EMPTY CONTENT (reasoning consumed the token budget)" }
}

try { Invoke-RestMethod -Uri "$($Url -replace '/v1$','')/unload" -Headers $hdr -TimeoutSec 60 | Out-Null } catch {}
