"""The provider contract and the HTTP helpers every cloud provider shares.

The caller supplies provider, model and API key per request; nothing is read
from the environment and nothing is stored server-side.
"""

from __future__ import annotations

import json
from collections.abc import AsyncIterator
from dataclasses import dataclass
from typing import Any, Protocol

import httpx

from flowy.util import truncate

# HTTP timeout for a single completion. Generous because some providers/models
# are slow to first byte; the endpoint is not on a latency-critical path.
TIMEOUT_SECONDS = 60.0


@dataclass(frozen=True)
class ChatInput:
    """One assistant turn. An image is ``{"media_type": "image/png", "data":
    "<base64, no prefix>"}``; a history turn is ``{"role": "user"|"assistant",
    "content": str}`` (text only)."""

    text: str
    model: str
    api_key: str
    base_url: str | None = None
    system_prompt: str | None = None
    max_tokens: int = 1024
    images: list[dict[str, str]] | None = None
    history: list[dict[str, str]] | None = None
    # Local-provider knobs (ignored for cloud providers): int8 weight-only
    # quantization and the resident-memory ceiling in GB.
    local_quantized: bool = True
    local_mem_gb: float | None = None


@dataclass(frozen=True)
class AudioInput:
    """One ground-truth transcription of a captured dictation."""

    model: str
    api_key: str
    audio_b64: str
    media_type: str = "audio/wav"
    base_url: str | None = None
    local_quantized: bool = True
    local_mem_gb: float | None = None
    #: The user's Vocabulary, appended to the instruction.
    vocab_hint: str | None = None
    #: The user's edited base instruction (empty/None = the shipped default).
    prompt_override: str | None = None


class Provider(Protocol):
    #: The id the app sends (``"openai_compatible"``).
    name: str
    #: False only for on-device models; the gateway rejects a missing key first.
    requires_key: bool

    def label(self, base_url: str | None) -> str:
        """Who to blame in a user-facing message ("OpenRouter returned …")."""
        ...

    async def chat(self, req: ChatInput) -> str:
        """The whole reply, stripped. ValueError on a non-2xx or odd shape."""
        ...

    def stream(self, req: ChatInput) -> AsyncIterator[str]:
        """Text deltas. ValueError on an error event; the gateway handles the
        stream that ends with no text."""
        ...

    async def list_models(self, api_key: str, base_url: str | None) -> list[str]:
        """The provider's live model ids, chat-capable ones, sorted."""
        ...

    async def transcribe_audio(self, req: AudioInput) -> tuple[str, str]:
        """``(text, prompt_used)`` — ValueError when this provider can't hear."""
        ...


def http_client() -> httpx.AsyncClient:
    # Looked up at call time so tests can swap httpx.AsyncClient.
    return httpx.AsyncClient(timeout=TIMEOUT_SECONDS)


def raise_for_status(provider: str, response: httpx.Response) -> None:
    """Raise ValueError on a non-2xx response, including the provider's body."""
    if response.is_success:
        return
    body = truncate(response.text)
    raise ValueError(
        f"{provider} request failed ({response.status_code}): {body}"
    )


async def raise_for_stream_status(provider: str, r: httpx.Response) -> None:
    """Read the body of a failed streamed response, then raise ValueError."""
    if r.is_success:
        return
    await r.aread()
    raise_for_status(provider, r)


def sse_data(line: str) -> str | None:
    """Return the payload of an SSE ``data:`` line, or None for other lines."""
    if line.startswith("data:"):
        return line[len("data:"):].strip()
    return None


async def sse_events(r: httpx.Response) -> AsyncIterator[Any]:
    """Decoded JSON events of an SSE response; blank and unparseable lines
    (OpenAI's ``[DONE]`` sentinel included) are skipped."""
    async for line in r.aiter_lines():
        data = sse_data(line)
        if not data:
            continue
        try:
            yield json.loads(data)
        except json.JSONDecodeError:
            continue


def stream_error_message(label: str, err: Any) -> str:
    """Readable text for an error event a provider sent mid-stream (Anthropic
    ``type: error``, OpenAI/OpenRouter/Gemini ``{"error": ...}``)."""
    if isinstance(err, dict):
        kind = str(err.get("type") or err.get("status") or err.get("code") or "")
        message = str(err.get("message") or kind or "unknown error")
    else:
        kind, message = "", str(err)
    lowered = f"{kind} {message}".lower()
    if any(k in lowered for k in ("overloaded", "unavailable", "503", "529")):
        return f"{label} is overloaded — try again in a moment."
    if any(k in lowered for k in ("rate_limit", "rate limit", "429", "resource_exhausted")):
        return f"{label} rate limit hit — wait a moment and try again."
    return f"{label} error: {truncate(message, 300)}"
