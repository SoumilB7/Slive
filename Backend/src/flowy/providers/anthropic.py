"""Anthropic Messages API."""

from __future__ import annotations

from collections.abc import AsyncIterator
from typing import Any

from flowy.providers.base import (
    AudioInput,
    ChatInput,
    http_client,
    raise_for_status,
    raise_for_stream_status,
    sse_events,
    stream_error_message,
)
from flowy.util import truncate

API = "https://api.anthropic.com/v1"
HEADERS = {"anthropic-version": "2023-06-01"}


def _content(text: str, images: list[dict[str, str]] | None) -> list[dict[str, Any]]:
    """Anthropic user content: image blocks first, then the text block."""
    content: list[dict[str, Any]] = []
    for img in images or []:
        content.append({
            "type": "image",
            "source": {
                "type": "base64",
                "media_type": img["media_type"],
                "data": img["data"],
            },
        })
    content.append({"type": "text", "text": text})
    return content


def _messages(req: ChatInput) -> list[dict[str, Any]]:
    """Prior turns, then the current user message (with any images)."""
    messages: list[dict[str, Any]] = []
    for h in req.history or []:
        messages.append({"role": h["role"], "content": h["content"]})
    messages.append({"role": "user", "content": _content(req.text, req.images)})
    return messages


def _body(req: ChatInput, **extra: Any) -> dict[str, Any]:
    body: dict[str, Any] = {
        "model": req.model,
        "max_tokens": req.max_tokens,
        **extra,
        "messages": _messages(req),
    }
    if req.system_prompt:
        body["system"] = req.system_prompt
    return body


def _headers(api_key: str) -> dict[str, str]:
    return {"x-api-key": api_key, **HEADERS, "content-type": "application/json"}


class AnthropicProvider:
    name = "anthropic"
    requires_key = True
    #: Reference model — the app always sends the one it wants.
    default_model = "claude-sonnet-5"

    def label(self, base_url: str | None) -> str:
        return "Anthropic"

    async def chat(self, req: ChatInput) -> str:
        """Call the Anthropic Messages API and return the reply text."""
        async with http_client() as client:
            response = await client.post(
                f"{API}/messages", headers=_headers(req.api_key), json=_body(req)
            )
        raise_for_status("anthropic", response)
        try:
            return response.json()["content"][0]["text"].strip()
        except (KeyError, IndexError, TypeError) as exc:
            raise ValueError(
                f"Unexpected anthropic response: {truncate(response.text)}"
            ) from exc

    async def stream(self, req: ChatInput) -> AsyncIterator[str]:
        async with http_client() as client, client.stream(
            "POST", f"{API}/messages", headers=_headers(req.api_key),
            json=_body(req, stream=True),
        ) as r:
            await raise_for_stream_status("anthropic", r)
            async for evt in sse_events(r):
                if evt.get("type") == "content_block_delta":
                    piece = evt.get("delta", {}).get("text")
                    if piece:
                        yield piece
                elif evt.get("type") == "error":
                    raise ValueError(stream_error_message("Anthropic", evt.get("error")))

    async def list_models(self, api_key: str, base_url: str | None) -> list[str]:
        async with http_client() as client:
            response = await client.get(
                f"{API}/models",
                headers={"x-api-key": api_key, **HEADERS},
                params={"limit": 1000},
            )
        raise_for_status("anthropic", response)
        ids = [m["id"] for m in response.json().get("data", [])]
        return sorted(ids, reverse=True)

    async def transcribe_audio(self, req: AudioInput) -> tuple[str, str]:
        # Rejected explicitly rather than failing confusingly upstream.
        raise ValueError(
            "Anthropic models do not accept audio input — pick Gemini or an "
            "OpenAI audio model for ground-truth transcription."
        )
