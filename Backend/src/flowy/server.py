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


@app.post("/transcribe")
async def transcribe_endpoint(request: Request) -> JSONResponse:
    audio_bytes = await request.body()
    if not audio_bytes:
        return JSONResponse(status_code=400, content={"error": "Empty request body"})
    try:
        # Offload the blocking model call so the event loop stays responsive.
        text = await run_in_threadpool(transcribe, audio_bytes)
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
