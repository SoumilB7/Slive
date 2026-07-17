"""Local HTTP server for speech-to-text transcription.

Run with:

    cd Backend && uv run python -m flowy.server

Contract:
    POST /transcribe
      Request body: raw bytes of an audio file (MP3, 16 kHz mono),
                    Content-Type: audio/mpeg
      Success: 200, JSON {"text": "<transcribed text>"}
      Error:   non-200, JSON {"error": "<message>"}
"""

from __future__ import annotations

import base64
import binascii
import json
import logging

from fastapi import FastAPI, Request
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import JSONResponse, StreamingResponse
from pydantic import BaseModel, field_validator

from flowy.assistant import answer as assistant_answer
from flowy.assistant import answer_stream as assistant_answer_stream
from flowy.assistant import list_models as assistant_list_models
from flowy.assistant import transcribe_audio as assistant_transcribe_audio
from flowy.transcribe import transcribe

HOST = "127.0.0.1"
PORT = 50711

logger = logging.getLogger("flowy.server")

app = FastAPI(title="Flowy STT", version="0.1.0")


# NOTE: no model loading at startup. Dictation STT runs on-device (WhisperKit)
# in the app; this server exists for the assistant proxy, which needs no local
# model. The legacy /transcribe endpoint still works — its model loads lazily
# (and stays loaded) on the first call — so an idle backend costs a few tens of
# MB instead of holding a warmed STT model in RAM for nothing.


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


def _decode_header(value: str | None) -> str | None:
    """Base64-decode a header into a UTF-8 string, defensively.

    Missing, empty, or malformed values all collapse to None so a bad header
    never turns into a 500 — recognition just proceeds without the hint.
    """
    if not value:
        return None
    try:
        decoded = base64.b64decode(value, validate=True).decode("utf-8").strip()
    except (binascii.Error, ValueError, UnicodeDecodeError):
        return None
    return decoded or None


@app.post("/transcribe")
async def transcribe_endpoint(request: Request) -> JSONResponse:
    audio_bytes = await request.body()
    if not audio_bytes:
        return JSONResponse(status_code=400, content={"error": "Empty request body"})
    hotwords = _decode_header(request.headers.get("X-Slive-Hotwords"))
    initial_prompt = _decode_header(request.headers.get("X-Slive-Prompt"))
    try:
        # Offload the blocking model call so the event loop stays responsive.
        text = await run_in_threadpool(
            transcribe, audio_bytes, hotwords, initial_prompt
        )
    except Exception as exc:  # noqa: BLE001 - surface any engine error as JSON
        logger.exception("Transcription failed")
        return JSONResponse(status_code=500, content={"error": str(exc)})
    return JSONResponse(status_code=200, content={"text": text})


class ImageItem(BaseModel):
    media_type: str
    data: str


class HistoryItem(BaseModel):
    role: str
    content: str


def _clean_api_key(value: str) -> str:
    """Strip surrounding whitespace/newlines from an API key and reject any that
    still contains control characters.

    A key pasted with a trailing newline (or otherwise malformed) would reach the
    HTTP layer as an illegal ``Authorization`` header value and raise a cryptic
    httpx error mid-request. Sanitising at the request boundary turns that into a
    clean, explainable 4xx instead.
    """
    cleaned = value.strip()
    if any(ord(ch) < 0x20 or ord(ch) == 0x7F for ch in cleaned):
        raise ValueError("API key contains invalid (control) characters")
    return cleaned


class AssistantRequest(BaseModel):
    text: str
    provider: str
    model: str
    api_key: str
    base_url: str | None = None
    system_prompt: str | None = None
    max_tokens: int = 1024
    images: list[ImageItem] | None = None
    history: list[HistoryItem] | None = None

    _clean_key = field_validator("api_key")(_clean_api_key)


@app.post("/assistant")
async def assistant_endpoint(req: AssistantRequest) -> JSONResponse:
    try:
        # Already async — awaited directly so the event loop stays responsive.
        reply = await assistant_answer(
            text=req.text,
            provider=req.provider,
            model=req.model,
            api_key=req.api_key,
            base_url=req.base_url,
            system_prompt=req.system_prompt,
            max_tokens=req.max_tokens,
            images=[img.model_dump() for img in req.images] if req.images else None,
            history=[h.model_dump() for h in req.history] if req.history else None,
        )
    except ValueError as exc:
        # Bad input or a provider error we could parse — client's problem.
        return JSONResponse(status_code=400, content={"error": str(exc)})
    except Exception as exc:  # noqa: BLE001 - surface any upstream error as JSON
        logger.exception("Assistant request failed")
        return JSONResponse(status_code=502, content={"error": str(exc)})
    return JSONResponse(status_code=200, content={"text": reply})


@app.post("/assistant/stream")
async def assistant_stream_endpoint(req: AssistantRequest) -> StreamingResponse:
    """Stream the assistant's reply as newline-delimited JSON.

    Each line is one JSON object: {"delta": "..."} for a text chunk,
    {"error": "..."} if the provider call fails, and a final {"done": true}.
    """
    async def gen():
        try:
            async for delta in assistant_answer_stream(
                text=req.text,
                provider=req.provider,
                model=req.model,
                api_key=req.api_key,
                base_url=req.base_url,
                system_prompt=req.system_prompt,
                max_tokens=req.max_tokens,
                images=(
                    [img.model_dump() for img in req.images] if req.images else None
                ),
                history=(
                    [h.model_dump() for h in req.history] if req.history else None
                ),
            ):
                yield json.dumps({"delta": delta}) + "\n"
        except Exception as exc:  # noqa: BLE001 - report any failure inline
            logger.exception("Assistant stream failed")
            yield json.dumps({"error": str(exc)}) + "\n"
        else:
            yield json.dumps({"done": True}) + "\n"

    return StreamingResponse(gen(), media_type="application/x-ndjson")


class TranscribeLLMRequest(BaseModel):
    """Ground-truth transcription of a captured dictation via an audio-capable
    multimodal model (Gemini / OpenAI audio). Same per-request key model as
    /assistant — nothing stored server-side."""

    provider: str
    model: str
    api_key: str
    audio_b64: str
    media_type: str = "audio/wav"
    base_url: str | None = None

    _clean_key = field_validator("api_key")(_clean_api_key)


@app.post("/transcribe_llm")
async def transcribe_llm_endpoint(req: TranscribeLLMRequest) -> JSONResponse:
    try:
        text = await assistant_transcribe_audio(
            provider=req.provider,
            model=req.model,
            api_key=req.api_key,
            audio_b64=req.audio_b64,
            media_type=req.media_type,
            base_url=req.base_url,
        )
    except ValueError as exc:
        return JSONResponse(status_code=400, content={"error": str(exc)})
    except Exception as exc:  # noqa: BLE001 - surface any upstream error as JSON
        logger.exception("LLM transcription failed")
        return JSONResponse(status_code=502, content={"error": str(exc)})
    return JSONResponse(status_code=200, content={"text": text})


class ModelsRequest(BaseModel):
    provider: str
    api_key: str
    base_url: str | None = None

    _clean_key = field_validator("api_key")(_clean_api_key)


@app.post("/models")
async def models_endpoint(req: ModelsRequest) -> JSONResponse:
    try:
        models = await assistant_list_models(
            provider=req.provider, api_key=req.api_key, base_url=req.base_url
        )
    except ValueError as exc:
        return JSONResponse(status_code=400, content={"error": str(exc)})
    except Exception as exc:  # noqa: BLE001 - surface any upstream error as JSON
        logger.exception("Model list request failed")
        return JSONResponse(status_code=502, content={"error": str(exc)})
    return JSONResponse(status_code=200, content={"models": models})


def main() -> None:
    import uvicorn

    logging.basicConfig(level=logging.INFO)
    uvicorn.run(app, host=HOST, port=PORT, log_level="info")


if __name__ == "__main__":
    main()
