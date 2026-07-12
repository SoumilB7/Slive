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
import logging

from fastapi import FastAPI, Request
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import JSONResponse

from flowy.transcribe import load_model, transcribe

HOST = "127.0.0.1"
PORT = 50711

logger = logging.getLogger("flowy.server")

app = FastAPI(title="Flowy STT", version="0.1.0")


@app.on_event("startup")
def _startup() -> None:
    # Load the STT model ONCE at startup, not per request.
    logger.info("Loading STT model...")
    load_model()
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


def main() -> None:
    import uvicorn

    logging.basicConfig(level=logging.INFO)
    uvicorn.run(app, host=HOST, port=PORT, log_level="info")


if __name__ == "__main__":
    main()
