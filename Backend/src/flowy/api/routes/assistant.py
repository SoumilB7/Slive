"""The assistant proxy: one reply, a streamed reply, and live model lists."""

from __future__ import annotations

import json
import logging

from fastapi import APIRouter
from fastapi.responses import StreamingResponse

from flowy.api.routes import ServicesDep
from flowy.api.schemas import ChatRequest, ModelsRequest
from flowy.errors import upstream_errors
from flowy.util import error_text

logger = logging.getLogger("flowy.server")

router = APIRouter()


@router.post("/assistant")
async def assistant(req: ChatRequest, services: ServicesDep):
    with upstream_errors("Assistant request failed"):
        # Already async — awaited directly so the event loop stays responsive.
        reply = await services.ai.answer(req.provider, req.chat_input())
    return {"text": reply}


@router.post("/assistant/stream")
async def assistant_stream(req: ChatRequest, services: ServicesDep) -> StreamingResponse:
    """Stream the assistant's reply as newline-delimited JSON.

    Each line is one JSON object: {"delta": "..."} for a text chunk,
    {"error": "..."} if the provider call fails, and a final {"done": true}.
    The status is always 200 — failures ride in the stream.
    """
    async def gen():
        try:
            async for delta in services.ai.answer_stream(req.provider, req.chat_input()):
                yield json.dumps({"delta": delta}) + "\n"
        except Exception as exc:  # noqa: BLE001 - report any failure inline
            logger.exception("Assistant stream failed")
            yield json.dumps({"error": error_text(exc)}) + "\n"
        else:
            yield json.dumps({"done": True}) + "\n"

    return StreamingResponse(gen(), media_type="application/x-ndjson")


@router.post("/models")
async def models(req: ModelsRequest, services: ServicesDep):
    with upstream_errors("Model list request failed"):
        ids = await services.ai.list_models(req.provider, req.api_key, req.base_url)
    return {"models": ids}
