"""On-device Hugging Face models (``local_infer``), run off the event loop.

The "key" is an optional HF token. The app lists local models through
``/local/cache``, not ``/models``.
"""

from __future__ import annotations

from collections.abc import AsyncIterator

from fastapi.concurrency import run_in_threadpool

from flowy.providers.base import AudioInput, ChatInput
from flowy.providers.transcription import full_prompt, guard_transcription


class LocalProvider:
    name = "local"
    requires_key = False

    def label(self, base_url: str | None) -> str:
        return "The local model"

    async def chat(self, req: ChatInput) -> str:
        from flowy import local_infer

        return await run_in_threadpool(
            local_infer.chat, req.model, req.api_key or None, req.system_prompt or "",
            req.history or [], req.text, [img.get("data", "") for img in (req.images or [])],
            req.max_tokens, req.local_quantized, req.local_mem_gb or local_infer.DEFAULT_MEM_GB,
        )

    async def stream(self, req: ChatInput) -> AsyncIterator[str]:
        # One piece: local generation isn't incremental. An empty reply yields
        # nothing, and the gateway reports "The local model returned an empty
        # answer".
        reply = await self.chat(req)
        if reply:
            yield reply

    async def list_models(self, api_key: str, base_url: str | None) -> list[str]:
        raise ValueError(f"Unknown provider: {self.name}")

    async def transcribe_audio(self, req: AudioInput) -> tuple[str, str]:
        from flowy import local_infer

        prompt = full_prompt(req)
        text = guard_transcription(await run_in_threadpool(
            local_infer.transcribe, req.model, req.api_key or None, req.audio_b64,
            req.media_type, 448, req.local_quantized,
            req.local_mem_gb or local_infer.DEFAULT_MEM_GB, prompt,
        ))
        return text, prompt
