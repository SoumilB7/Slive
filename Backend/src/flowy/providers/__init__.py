"""LLM providers behind one gateway: the assistant (chat + streaming), live
model lists, and ground-truth transcription from audio-capable models.

Supported: "anthropic", "openai", "openai_compatible" (OpenAI's API at a
``base_url`` — OpenRouter/Groq/Ollama/LM Studio), "gemini", and "local"
(on-device Hugging Face models). See ``registry.py`` to add one.

The module-level functions use the default registry and keep the keyword
signatures scripts and tests call.
"""

from __future__ import annotations

from collections.abc import AsyncIterator

from flowy.providers.base import TIMEOUT_SECONDS, AudioInput, ChatInput, Provider
from flowy.providers.gateway import Gateway
from flowy.providers.registry import ProviderRegistry, default_registry
from flowy.providers.transcription import TRANSCRIBE_PROMPT

__all__ = [
    "TIMEOUT_SECONDS", "TRANSCRIBE_PROMPT", "AudioInput", "ChatInput", "Gateway", "Provider",
    "ProviderRegistry", "answer", "answer_stream", "default_gateway", "default_registry",
    "list_models", "transcribe_audio",
]

default_gateway = Gateway(default_registry())


async def answer(text: str, provider: str, model: str, api_key: str, **options) -> str:
    return await default_gateway.answer(provider, ChatInput(text, model, api_key, **options))


def answer_stream(text: str, provider: str, model: str, api_key: str,
                  **options) -> AsyncIterator[str]:
    return default_gateway.answer_stream(provider, ChatInput(text, model, api_key, **options))


async def list_models(provider: str, api_key: str, base_url: str | None = None) -> list[str]:
    return await default_gateway.list_models(provider, api_key, base_url)


async def transcribe_audio(provider: str, model: str, api_key: str, audio_b64: str,
                           **options) -> tuple[str, str]:
    return await default_gateway.transcribe_audio(
        provider, AudioInput(model, api_key, audio_b64, **options))
