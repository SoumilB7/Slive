"""What the routes call: request-level checks shared by every provider, then
one ``registry.resolve(name)`` instead of a per-operation ``if provider ==``
ladder."""

from __future__ import annotations

import logging
from collections.abc import AsyncIterator

from flowy.providers.base import AudioInput, ChatInput
from flowy.providers.registry import ProviderRegistry
from flowy.providers.transcription import validate_audio_payload

logger = logging.getLogger("flowy.assistant")


class Gateway:
    def __init__(self, registry: ProviderRegistry) -> None:
        self.registry = registry

    async def answer(self, provider: str, req: ChatInput) -> str:
        """The assistant's whole reply, stripped. ValueError on missing
        key/text, a non-2xx (with the provider's body), an unknown provider,
        or an unexpected response shape."""
        if not req.text or not req.text.strip():
            raise ValueError("Empty prompt text")
        return await self.registry.resolve(provider, req.api_key).chat(req)

    async def answer_stream(self, provider: str, req: ChatInput) -> AsyncIterator[str]:
        """Like ``answer`` but yields text deltas. Also raises on an error
        event the provider sends mid-stream (overloaded, safety block, ...)
        and when the stream ends with no text at all; partial output already
        yielded stays yielded."""
        if not req.text or not req.text.strip():
            raise ValueError("Empty prompt text")
        impl = self.registry.resolve(provider, req.api_key)
        got_text = False
        async for delta in impl.stream(req):
            got_text = True
            yield delta
        # A stream that ends without a single token would make the overlay
        # vanish with no answer — say so instead.
        if not got_text:
            raise ValueError(f"{impl.label(req.base_url)} returned an empty answer — try again.")

    async def list_models(self, provider: str, api_key: str,
                          base_url: str | None = None) -> list[str]:
        """The provider's LIVE list of model ids, lightly filtered to
        chat-capable models and sorted."""
        if not api_key:
            raise ValueError("Missing api_key")
        return await self.registry.resolve(provider, api_key).list_models(api_key, base_url)

    async def transcribe_audio(self, provider: str, req: AudioInput) -> tuple[str, str]:
        """A verbatim transcription from an audio-capable model, plus the exact
        instruction it saw (the UI shows it, vocabulary hint included)."""
        if not req.audio_b64:
            raise ValueError("Missing audio")
        # Proof the audio actually went in — validated on arrival, size logged on
        # every request. An empty/truncated payload fails HERE with a clear
        # message instead of confusing a provider into "please provide the audio".
        audio_bytes_len = validate_audio_payload(req.audio_b64)
        logger.info("transcribe_llm: %.0f KB audio in → %s / %s",
                    audio_bytes_len / 1024, provider, req.model)
        return await self.registry.resolve(provider, req.api_key).transcribe_audio(req)
