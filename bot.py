"""Pipecat bot for Pantheon voice-agent validation.

Run locally on Prometheus with:
    uv run bot.py -t webrtc --host 0.0.0.0 --port 7860
"""

from __future__ import annotations

import asyncio
import json
import os
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

from loguru import logger
from pipecat.audio.vad.silero import SileroVADAnalyzer
from pipecat.audio.vad.vad_analyzer import VADParams
from pipecat.frames.frames import (
    LLMRunFrame,
    LLMSettings,
    LLMUpdateSettingsFrame,
    TTSSettings,
    TTSUpdateSettingsFrame,
)
from pipecat.pipeline.pipeline import Pipeline
from pipecat.pipeline.runner import PipelineRunner
from pipecat.pipeline.task import PipelineParams, PipelineTask
from pipecat.processors.aggregators.llm_context import LLMContext
from pipecat.processors.aggregators.llm_response_universal import (
    LLMContextAggregatorPair,
    LLMUserAggregatorParams,
)
from pipecat.turns.user_start import MinWordsUserTurnStartStrategy
from pipecat.turns.user_turn_strategies import (
    UserTurnStrategies,
    default_user_turn_start_strategies,
)
from pipecat.runner.types import DailyRunnerArguments, RunnerArguments, SmallWebRTCRunnerArguments
from pipecat.services.openai.llm import OpenAILLMService
from pipecat.services.openai.stt import OpenAISTTService
from pipecat.services.openai.tts import OpenAITTSService
from pipecat.services.openai import tts as _openai_tts
from pipecat.transports.base_transport import BaseTransport, TransportParams

try:
    from pipecat.transports.network.small_webrtc import SmallWebRTCTransport
except ImportError:  # Pipecat 1.2.1 compatibility on the installed host.
    from pipecat.transports.smallwebrtc.transport import SmallWebRTCTransport


LOCAL_VOICE_API = os.getenv("LOCAL_VOICE_API", "http://127.0.0.1:8002")
# STT and TTS are separate CrispASR servers: one process serves one model.
# Both default to LOCAL_VOICE_API so the legacy single-server layout still works.
STT_API = os.getenv("VOICE_AGENT_STT_API", LOCAL_VOICE_API)
TTS_API = os.getenv("VOICE_AGENT_TTS_API", LOCAL_VOICE_API)
LLAMA_SWAP_URL = os.getenv("LLAMA_SWAP_URL", "http://172.17.0.1:8085/v1")
LLAMA_SWAP_KEY = os.getenv("LLAMA_SWAP_KEY", "LOCAL")
LLM_MODEL = os.getenv("VOICE_AGENT_LLM_MODEL", "gemma-4-e4b-it")
TTS_VOICE = os.getenv("VOICE_AGENT_TTS_VOICE", "alloy")
TTS_SPEED = float(os.getenv("VOICE_AGENT_TTS_SPEED", "1.5"))
VOICE_AGENT_SYSTEM_PROMPT = os.getenv(
    "VOICE_AGENT_SYSTEM_PROMPT",
    (
        "You are a helpful spoken assistant for a homelab AI stack. "
        "Answer with the final answer only. Use one or two concise sentences with enough detail to be useful. "
        "Do not mention reasoning, plans, markdown, or hidden thoughts."
    ),
)
VOICE_AGENT_MIN_INTERRUPT_WORDS = int(os.getenv("VOICE_AGENT_MIN_INTERRUPT_WORDS", "3"))
# CrispASR requires a consent attestation on every /v1/audio/speech request that
# uses a cloned voice, regardless of server-side --i-have-rights. Pipecat's
# OpenAITTSService has no extra-body hook, so it is injected below. Leave unset
# for built-in voices, which need no attestation.
VOICE_AGENT_TTS_CONSENT = os.getenv("VOICE_AGENT_TTS_CONSENT", "").strip()
# Control server port. Set to 0 to disable. Bound to localhost only: this
# endpoint changes what the agent says and in whose voice, so it must not be
# reachable off the machine.
VOICE_AGENT_CONTROL_PORT = int(os.getenv("VOICE_AGENT_CONTROL_PORT", "7861"))
VOICE_AGENT_START_PROMPT = os.getenv("VOICE_AGENT_START_PROMPT", "Greet me in six words.")
VOICE_AGENT_MAX_TOKENS = int(os.getenv("VOICE_AGENT_MAX_TOKENS", "80"))
VOICE_AGENT_TEMPERATURE = float(os.getenv("VOICE_AGENT_TEMPERATURE", "0.35"))
VOICE_AGENT_LLM_EXTRA_JSON = os.getenv(
    "VOICE_AGENT_LLM_EXTRA_JSON",
    '{"extra_body":{"chat_template_kwargs":{"enable_thinking":false}}}',
).strip()




# Live state, published for the control server. llama-swap selects the model per
# request, so switching is a matter of changing the field the bot sends; the
# speech servers are untouched and the WebRTC session survives.
_control = {"task": None, "loop": None, "llm": None, "tts": None,
            "model": None, "voice": None}


def _push(frame) -> bool:
    """Queues a frame onto the pipeline from the control server's thread."""
    task, loop = _control["task"], _control["loop"]
    if task is None or loop is None:
        return False
    asyncio.run_coroutine_threadsafe(task.queue_frames([frame]), loop)
    return True


class _ControlHandler(BaseHTTPRequestHandler):
    def _reply(self, code: int, payload: dict) -> None:
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):  # noqa: N802 - BaseHTTPRequestHandler's naming
        if self.path.rstrip("/") in ("/state", "/control/state"):
            self._reply(200, {
                "model": _control["model"],
                "voice": _control["voice"],
                "connected": _control["task"] is not None,
            })
        else:
            self._reply(404, {"error": "use GET /state, POST /model, POST /voice"})

    def do_POST(self):  # noqa: N802
        length = int(self.headers.get("Content-Length") or 0)
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            return self._reply(400, {"error": "invalid JSON"})

        path = self.path.rstrip("/")
        if path in ("/model", "/control/model"):
            model = (body.get("model") or "").strip()
            if not model:
                return self._reply(400, {"error": "model is required"})
            llm = _control["llm"]
            if llm is None:
                return self._reply(409, {"error": "no active session; connect a client first"})
            # base_llm.py builds the request as {"model": self._settings.model},
            # so that is the field that has to change. set_full_model_name writes
            # a different attribute and had no effect on the request; the delta
            # frame alone applied for one turn and then lost to the constructor.
            llm._settings.model = model
            llm.set_full_model_name(model)
            _push(LLMUpdateSettingsFrame(delta=LLMSettings(model=model)))
            _control["model"] = model
            logger.info("control: model -> {}", model)
            return self._reply(200, {"model": model})

        if path in ("/voice", "/control/voice"):
            voice = (body.get("voice") or "").strip()
            if not voice:
                return self._reply(400, {"error": "voice is required"})
            # Pipecat validates `voice` against OpenAI's enum, so a local
            # reference name has to be registered before it will pass.
            if voice not in _openai_tts.VALID_VOICES:
                _openai_tts.VALID_VOICES[voice] = voice
            tts = _control["tts"]
            if tts is None:
                return self._reply(409, {"error": "no active session; connect a client first"})
            _push(TTSUpdateSettingsFrame(delta=TTSSettings(voice=voice)))
            _control["voice"] = voice
            logger.info("control: voice -> {}", voice)
            return self._reply(200, {"voice": voice})

        self._reply(404, {"error": "use POST /model or POST /voice"})

    def log_message(self, *args):  # silence per-request stderr logging
        pass


def _start_control_server() -> None:
    if VOICE_AGENT_CONTROL_PORT <= 0:
        return
    server = HTTPServer(("127.0.0.1", VOICE_AGENT_CONTROL_PORT), _ControlHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    logger.info("control server on 127.0.0.1:{}", VOICE_AGENT_CONTROL_PORT)


_start_control_server()


async def run_bot(transport: BaseTransport) -> None:
    logger.info("starting voice-agent bot")
    logger.info("voice_api={} llama_swap={} model={}", LOCAL_VOICE_API, LLAMA_SWAP_URL, LLM_MODEL)

    stt = OpenAISTTService(
        base_url=STT_API,
        api_key="not-needed",
        model="whisper-1",
    )

    llm = OpenAILLMService(
        model=LLM_MODEL,
        base_url=LLAMA_SWAP_URL,
        api_key=LLAMA_SWAP_KEY,
        settings=OpenAILLMService.Settings(
            model=LLM_MODEL,
            extra=json.loads(VOICE_AGENT_LLM_EXTRA_JSON) if VOICE_AGENT_LLM_EXTRA_JSON else {},
            max_tokens=VOICE_AGENT_MAX_TOKENS,
            temperature=VOICE_AGENT_TEMPERATURE,
        ),
    )

    # Pipecat validates `voice` against OpenAI's own enum, which is meaningless
    # for a local backend serving named reference voices. Register whatever name
    # is configured so custom voices work: the local server resolves it, not
    # OpenAI. Harmless for real OpenAI voices, which are already in the map.
    if TTS_VOICE not in _openai_tts.VALID_VOICES:
        _openai_tts.VALID_VOICES[TTS_VOICE] = TTS_VOICE
        logger.info("registered custom TTS voice name: {}", TTS_VOICE)

    tts = OpenAITTSService(
        base_url=TTS_API,
        api_key="not-needed",
        voice=TTS_VOICE,
        model="tts-1",
        speed=TTS_SPEED,
    )

    # VAD gates when a user turn *starts*. Smart Turn decides when it ends, so
    # stop_secs should stay at Pipecat's recommended 0.2. Raise min_volume and
    # confidence to stop background noise opening a turn and interrupting the bot.
    vad = SileroVADAnalyzer(
        params=VADParams(
            confidence=float(os.getenv("VOICE_AGENT_VAD_CONFIDENCE", "0.7")),
            start_secs=float(os.getenv("VOICE_AGENT_VAD_START_SECS", "0.2")),
            stop_secs=float(os.getenv("VOICE_AGENT_VAD_STOP_SECS", "0.2")),
            min_volume=float(os.getenv("VOICE_AGENT_VAD_MIN_VOLUME", "0.6")),
        )
    )

    if VOICE_AGENT_TTS_CONSENT:
        # OpenAI SDK: `with_streaming_response` is a cached_property, so the object
        # is stable, but `create` is bound per-instance in __init__ (not on the
        # class). Patch the instance attribute, not the class.
        _speech = tts._client.audio.speech.with_streaming_response
        _orig_create = _speech.create

        def _create_with_consent(*args, **kwargs):
            body = dict(kwargs.get("extra_body") or {})
            body["consent_attestation"] = VOICE_AGENT_TTS_CONSENT
            kwargs["extra_body"] = body
            return _orig_create(*args, **kwargs)

        _speech.create = _create_with_consent
        logger.info("tts consent attestation enabled for cloned voice")

    context = LLMContext(messages=[{"role": "system", "content": VOICE_AGENT_SYSTEM_PROMPT}])
    user_aggregator, assistant_aggregator = LLMContextAggregatorPair(
        context,
        user_params=LLMUserAggregatorParams(
            vad_analyzer=vad,
            # Side chatter (TV, other people) is real speech, so VAD gating alone
            # cannot stop it interrupting the bot. MinWords requires N words before
            # a turn starts *while the bot is speaking*; when the bot is silent it
            # falls back to 1 word, so normal turn-taking is unaffected.
            #
            # This must EXTEND the defaults, not replace them. Dropping
            # VADUserTurnStartStrategy / TranscriptionUserTurnStartStrategy breaks
            # the turn lifecycle so assistant replies are never committed to the
            # context, and every turn starts from the system prompt alone.
            # Set VOICE_AGENT_MIN_INTERRUPT_WORDS=0 to use the stock defaults.
            user_turn_strategies=UserTurnStrategies(
                start=[
                    MinWordsUserTurnStartStrategy(
                        min_words=VOICE_AGENT_MIN_INTERRUPT_WORDS
                    ),
                    *default_user_turn_start_strategies(),
                ]
            )
            if VOICE_AGENT_MIN_INTERRUPT_WORDS > 0
            else None,
            audio_idle_timeout=1.5,
            user_turn_stop_timeout=6.0,
        ),
    )

    pipeline = Pipeline(
        [
            transport.input(),
            stt,
            user_aggregator,
            llm,
            tts,
            transport.output(),
            assistant_aggregator,
        ]
    )

    task = PipelineTask(
        pipeline,
        params=PipelineParams(enable_metrics=True, enable_usage_metrics=True),
    )

    _control.update({
        "task": task,
        "loop": asyncio.get_running_loop(),
        "llm": llm,
        "tts": tts,
        "model": LLM_MODEL,
        "voice": TTS_VOICE,
    })

    @task.rtvi.event_handler("on_client_ready")
    async def on_client_ready(rtvi):
        logger.info("client ready")
        context.add_message({"role": "user", "content": VOICE_AGENT_START_PROMPT})
        await task.queue_frames([LLMRunFrame()])

    @transport.event_handler("on_client_connected")
    async def on_client_connected(transport, client):
        logger.info("client connected")

    @transport.event_handler("on_client_disconnected")
    async def on_client_disconnected(transport, client):
        logger.info("client disconnected")
        await task.cancel()

    runner = PipelineRunner(handle_sigint=False)
    await runner.run(task)


async def bot(runner_args: RunnerArguments) -> None:
    if isinstance(runner_args, DailyRunnerArguments):
        from pipecat.transports.daily.transport import DailyParams, DailyTransport

        transport = DailyTransport(
            runner_args.room_url,
            runner_args.token,
            "Pantheon Voice Agent",
            params=DailyParams(audio_in_enabled=True, audio_out_enabled=True),
        )
    elif isinstance(runner_args, SmallWebRTCRunnerArguments):
        transport = SmallWebRTCTransport(
            params=TransportParams(audio_in_enabled=True, audio_out_enabled=True),
            webrtc_connection=runner_args.webrtc_connection,
        )
    else:
        logger.error("unsupported runner arguments type: {}", type(runner_args))
        return

    await run_bot(transport)


if __name__ == "__main__":
    from pipecat.runner.run import main

    main()
