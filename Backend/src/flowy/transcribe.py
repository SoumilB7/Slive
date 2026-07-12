"""Speech-to-text transcription.

This module hides the concrete STT engine behind a single ``transcribe`` function
so it can be swapped out later without touching the HTTP server.

Right now it uses a casual, local, CPU-friendly model (faster-whisper). The model
is loaded exactly once and reused across calls.

# TODO: replace with Gemma 4 E2B
"""

from __future__ import annotations

import os
import tempfile
from threading import Lock
from typing import Any

# Model for faster-whisper. "tiny.en" is the fast default (~1.8s for a 7s clip
# on an M4, accurate for clear English dictation). Override with
# FLOWY_WHISPER_MODEL: "base.en" for more accuracy, "base" for multilingual.
MODEL_SIZE = os.environ.get("FLOWY_WHISPER_MODEL", "tiny.en")

_model: Any = None
_model_lock = Lock()


def _get_model() -> Any:
    """Load the STT model once and cache it (thread-safe)."""
    global _model
    if _model is not None:
        return _model
    with _model_lock:
        if _model is None:
            # Imported lazily so importing this module is cheap.
            from faster_whisper import WhisperModel

            # int8 on CPU keeps memory + latency low and works everywhere;
            # more threads on Apple Silicon shortens transcription time.
            _model = WhisperModel(
                MODEL_SIZE, device="cpu", compute_type="int8", cpu_threads=8
            )
    return _model


def load_model() -> None:
    """Eagerly load the model at server startup (not per request)."""
    _get_model()


def transcribe(
    audio_bytes: bytes,
    hotwords: str | None = None,
    initial_prompt: str | None = None,
) -> str:
    """Transcribe raw audio bytes (MP3, 16 kHz mono) into text.

    The incoming bytes are written to a temp file and decoded by faster-whisper's
    bundled backend (PyAV/ffmpeg). Returns the transcribed text (may be empty for
    silence).

    ``hotwords`` biases recognition toward a space-separated list of custom words,
    and ``initial_prompt`` seeds the decoder with a context sentence. Each is only
    forwarded to faster-whisper when it's a non-empty string.

    # TODO: replace with Gemma 4 E2B
    """
    if not audio_bytes:
        raise ValueError("Empty audio payload")

    model = _get_model()

    tmp_path = None
    try:
        with tempfile.NamedTemporaryFile(suffix=".mp3", delete=False) as tmp:
            tmp.write(audio_bytes)
            tmp_path = tmp.name

        # Speed: greedy decoding (beam_size=1) instead of a 5-wide beam, VAD to
        # skip silence, no cross-segment conditioning, and skip language
        # detection for English-only models. Much faster, negligible quality loss
        # for short dictation.
        lang = "en" if MODEL_SIZE.endswith(".en") else None
        extra: dict[str, Any] = {}
        if hotwords:
            extra["hotwords"] = hotwords
        if initial_prompt:
            extra["initial_prompt"] = initial_prompt
        segments, _info = model.transcribe(
            tmp_path,
            beam_size=1,
            language=lang,
            vad_filter=True,
            condition_on_previous_text=False,
            **extra,
        )
        text = "".join(segment.text for segment in segments)
        return text.strip()
    finally:
        if tmp_path is not None:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass
