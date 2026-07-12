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
from pydantic import BaseModel

from flowy.assistant import answer as assistant_answer
from flowy.assistant import answer_stream as assistant_answer_stream
from flowy.assistant import list_models as assistant_list_models
from flowy.transcribe import load_model, transcribe, warm_up

HOST = "127.0.0.1"
PORT = 50711

logger = logging.getLogger("flowy.server")

app = FastAPI(title="Flowy STT", version="0.1.0")


@app.on_event("startup")
def _startup() -> None:
    # Load the STT model ONCE at startup, not per request.
    logger.info("Loading STT model...")
    load_model()
    # Prime the compute kernels so the user's first dictation is instant.
    logger.info("Warming up...")
    warm_up()
    logger.info("STT model ready.")


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
    hotwords = _decode_header(request.headers.get("X-Flowy-Hotwords"))
    initial_prompt = _decode_header(request.headers.get("X-Flowy-Prompt"))
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


class ModelsRequest(BaseModel):
    provider: str
    api_key: str
    base_url: str | None = None


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
