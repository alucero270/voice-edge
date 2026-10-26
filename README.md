# voice-edge

A local voice agent for Windows. Speech runs on your machine; the language model runs wherever your [llama-swap](https://github.com/mostlygeek/llama-swap) lives.

You talk to the laptop. The laptop talks back. Something else does the thinking.

```
your machine                              llama-swap host
  microphone
  -> Silero VAD + Smart Turn (CPU)
  -> Pipecat
  -> STT   Parakeet TDT v3    (CUDA)
  -> LLM   ------------------------------> /v1/chat/completions
  -> TTS   Chatterbox Turbo   (CUDA)
  -> speaker
```

There is no build step. [CrispASR](https://github.com/CrispStrobe/CrispASR) ships prebuilt Windows CUDA binaries, so `-Bootstrap` downloads a release and the models and nothing needs compiling.

## Why split it this way

A 20 GB card running a 27B model has no room left for speech. Moving STT and TTS onto the machine with the microphone returns that memory to the model, and it puts turn detection next to the person talking, which is where latency hurts most.

Measured on an **NVIDIA T500**, a 4 GB mobile GPU with 896 CUDA cores, which is about the weakest card worth trying:

| | |
|---|---|
| TTS (Chatterbox Turbo Q8, cloned voice) | RTF 0.57-0.61 |
| STT (Parakeet TDT v3 Q4_K) | well under realtime |
| Speech stack resident | 1,695 MiB |

RTF is synthesis time divided by audio duration, so under 1.0 is faster than realtime. A stronger GPU does proportionally better; the RTX 4000 Ada this was developed against runs the same model near 0.15.

**TTS is the part that needs a GPU.** On CPU, Kokoro measured RTF 2.49 at 4 threads and 1.72 at 8. Doubling the threads bought 30%, so the workload does not scale with core count and a bigger CPU will not rescue it. STT is fine on CPU at 3.7x realtime.

## Requirements

- Windows 10 or 11, PowerShell 5.1 (the one that ships with the OS)
- An NVIDIA GPU with 2 GB free or more
- Python 3.12 and [uv](https://github.com/astral-sh/uv)
- [`gh`](https://cli.github.com/) for the bootstrap download
- A reachable llama-swap

## Setup

```powershell
git clone https://github.com/<you>/voice-edge
cd voice-edge

# downloads the CrispASR release, ~1.6 GB of models, and builds the Pipecat venv
.\voice-edge.ps1 -Bootstrap

# tell it where your llama-swap is
$env:LLAMA_SWAP_URL = 'http://your-llama-swap-host:8085/v1'
```

Then put a reference voice in `%USERPROFILE%\stacks\voice-edge\voices\chatterbox\`, named exactly as the voice **with no extension**. A file called `tester` gives you a voice called `tester`. 5 to 15 seconds of clean 24 kHz mono PCM16 is what Chatterbox wants.

```powershell
.\voice-edge.ps1 -Verify                 # round-trip test, reports RTF
.\voice-edge.ps1 -Voice tester -Model your-model-id
```

Open **http://localhost:7860/client/** and press Connect.

## Dashboard

```powershell
.\voice-edge.ps1 -Shortcut     # puts "Voice Edge" on the desktop
```

The shortcut runs `supervisor.py`, which opens a console window and a dashboard at **http://127.0.0.1:7870/**. Pick a profile, optionally paste or load session material, and press Start. The dashboard shows every process, its PID, which PID actually holds each port, health, uptime, logs, and whether llama-swap is reachable and offers the model.

**The console window is the instance.** The supervisor puts itself in a Windows Job Object that kills its members when it exits, and every process it starts inherits that. Closing the window, Ctrl+C, the Shut down button, or a crash all take STT, TTS and the bot down with it. Clicking the shortcut again while it is running just reopens the dashboard.

Anything holding a voice-edge port that the supervisor did not start shows up under **Strays**, typically a leftover from a launcher run, and can be stopped from there.

### Profiles and session material

A **profile** is who the agent is: a TOML file in `profiles/` with a system prompt, an opening line, and optionally its own voice, model and token budget. A new use case is a new file, not a new script. `profiles/_spoken.txt` is prepended to every profile; it holds the rules that come from speaking aloud rather than from the role.

**Session material** is what you are working on today, such as a resume or an assignment. It is pasted into the dashboard per session, appended to the prompt as reference text, and capped at 60,000 characters. The composed prompt is written to `logs\prompt_<time>.txt` so you can read exactly what the model got.

Changing profile restarts only the bot. The speech servers stay loaded, so it takes seconds; reconnect the voice client afterwards.

Machine settings such as the llama-swap URL, ports and default voice go in `stack.toml`; see `stack.example.toml`.

## Usage

```powershell
.\voice-edge.ps1 -Voice tester -Model gemma-3-27b    # start
.\voice-edge.ps1 -SpeechOnly                        # STT and TTS, no bot
.\voice-edge.ps1 -Verify                            # check it works
.\voice-edge.ps1 -Stop                              # stop everything
```

| Flag | Default | |
|---|---|---|
| `-Voice` | `tester` | reference voice name |
| `-Model` | `gemma-4-26b-a4b-it-qat-co` | llama-swap model id |
| `-Speed` | `0.92` | Chatterbox reads slightly fast at 1.0 |
| `-MaxTokens` | `400` | see the reasoning-model note below |
| `-LlamaSwapUrl` | `$env:LLAMA_SWAP_URL` or localhost | |
| `-BotPort` | `7860` | |

There is also a control server on `127.0.0.1:7861`, localhost-only because it changes what the agent says and in whose voice:

```powershell
irm http://127.0.0.1:7861/state
irm http://127.0.0.1:7861/voice -Method POST -Body '{"voice":"other"}' -ContentType 'application/json'
```

Voice switching works. **Model switching does not** and is unresolved, see below. Relaunch with `-Model` instead.

## Things that cost me a day, so they need not cost you one

**Pass the codec explicitly.** Giving CrispASR only the Chatterbox *turbo* T3 makes it auto-resolve the *base* S3Gen, which runs 10 CFM steps instead of the turbo 2-step meanflow path. That alone is RTF 1.34 versus 0.68 on identical hardware. `-Verify` asserts `meanflow mode` appears in the log so this cannot happen quietly.

**Voice files have no extension.** CrispASR resolves the OpenAI `voice` field as a filename relative to the **process working directory**, not to `--voice-dir`. `alloy.wav` is invisible to a request for `alloy`. The launcher starts the TTS server from inside the voice directory for this reason.

**Reasoning models return empty replies on a small token budget.** They spend the whole budget reasoning and hand back nothing in `content`. I watched one generate 120 tokens and produce an empty string. Hence `-MaxTokens 400`. Note also that `enable_thinking:false` alone often does not stop it; `reasoning_effort:low` is what works.

**Throughput does not predict turn latency, token count does.** One model at 17.4 tok/s answered in 3.02s while another at 28.2 tok/s took 4.85s, because the faster one generated 119 tokens instead of 43. Reasoning models pay twice: hidden tokens are latency you wait through, and they inflate the visible reply too.

**Benchmark against a warm server.** CrispASR in CLI mode reloads the model on every invocation. Measuring that way charges each request a full model load and makes any backend look unusable.

**Pipecat ignores SIGTERM.** A stale bot holds its port while new instances silently fail to bind, and the browser keeps talking to the old process with old settings. `-Stop` escalates to SIGKILL.

## Known defect: model switching

`POST /model` reports success and `/state` reflects the change, but the agent reverts to the model it launched with on the following turn. Verified against llama-swap's own log rather than the bot's report.

Ruled out so far:

| Approach | Result |
|---|---|
| `LLMUpdateSettingsFrame(settings=...)` | deprecated since 0.0.104, silently ignored |
| `LLMUpdateSettingsFrame(delta=...)` | applies for one turn, then reverts |
| `set_full_model_name()` | writes a different attribute, no effect on the request |
| `llm._settings.model = model` | the field `base_llm.py` actually sends; verified in isolation, still reverts live |

Leading hypothesis, untested: `run_bot` runs per WebRTC session and constructs fresh service objects, so a reconnect leaves the control server holding a stale instance while a new one starts from the constructor value. Logs showing `OpenAILLMService#1` suggest more than one instance exists.

Patches welcome.

## Credits

[CrispASR](https://github.com/CrispStrobe/CrispASR) for the ggml speech runtime and the Windows CUDA builds. [Pipecat](https://github.com/pipecat-ai/pipecat) for orchestration, VAD and Smart Turn. [llama-swap](https://github.com/mostlygeek/llama-swap) for model serving. Chatterbox is from [ResembleAI](https://github.com/resemble-ai/chatterbox), Parakeet from NVIDIA.

## A note on voices

Chatterbox clones from reference audio. Use your own voice, something you have licensed, or synthetic audio. Cloning an identifiable person without their consent is not something this tool should be used for, and CrispASR requires a per-request consent attestation for cloned voices, which the launcher supplies via `-Consent`.

## License

MIT
