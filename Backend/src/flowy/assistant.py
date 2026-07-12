"""LLM assistant backend.

This module hides several LLM providers behind a single async ``answer``
function so the HTTP server can talk to any of them without caring about the
concrete request/response shape. The caller supplies the provider, model, and
API key per request; nothing is read from the environment here.

Supported providers: "anthropic", "openai", "gemini", and "openai_compatible"
(the last covers OpenRouter/Groq/Ollama/LM Studio via a base_url).
"""

from __future__ import annotations

import logging
from typing import Any

import httpx

logger = logging.getLogger("flowy.assistant")

# HTTP timeout for a single completion. Generous because some providers/models
# are slow to first byte; the endpoint is not on a latency-critical path.
TIMEOUT_SECONDS = 60.0

# Reference/fallback models per provider. The caller passes the model it wants,
# so this is documentation more than configuration.
DEFAULT_MODELS = {
    "anthropic": "claude-sonnet-5",
    "openai": "gpt-4o",
    "gemini": "gemini-2.5-flash",
    "openai_compatible": "",
}


def _truncate(text: str, limit: int = 500) -> str:
    """Clip a response body for error messages so logs stay readable."""
    if len(text) <= limit:
        return text
    return text[:limit] + "..."


def _raise_for_status(provider: str, response: httpx.Response) -> None:
    """Raise ValueError on a non-2xx response, including the provider's body."""
    if response.is_success:
        return
    body = _truncate(response.text)
    raise ValueError(
        f"{provider} request failed ({response.status_code}): {body}"
    )


async def answer(
    text: str,
    provider: str,
    model: str,
    api_key: str,
    base_url: str | None = None,
    system_prompt: str | None = None,
    max_tokens: int = 1024,
) -> str:
    """Send ``text`` to an LLM provider and return the assistant's reply.

    ``provider`` selects the concrete HTTP API ("anthropic", "openai",
    "gemini", or "openai_compatible"). ``base_url`` is required for
    "openai_compatible" and ignored otherwise. ``system_prompt`` is optional and
    forwarded only when non-empty.

    Returns the reply text, stripped. Raises ValueError on missing api_key/text,
    on a non-2xx response (with the provider's error body), on an unknown
    provider, or when the expected keys are absent from the JSON response.
    """
    if not text or not text.strip():
        raise ValueError("Empty prompt text")
    if not api_key:
        raise ValueError("Missing api_key")

    async with httpx.AsyncClient(timeout=TIMEOUT_SECONDS) as client:
        if provider == "anthropic":
            return await _answer_anthropic(
                client, text, model, api_key, system_prompt, max_tokens
            )
        if provider == "openai":
            return await _answer_openai(
                client, text, model, api_key, system_prompt, max_tokens
            )
        if provider == "gemini":
            return await _answer_gemini(
                client, text, model, api_key, system_prompt, max_tokens
            )
        if provider == "openai_compatible":
            if not base_url:
                raise ValueError("base_url is required for openai_compatible")
            return await _answer_openai(
                client,
                text,
                model,
                api_key,
                system_prompt,
                max_tokens,
                url=f"{base_url.rstrip('/')}/chat/completions",
            )
        raise ValueError(f"Unknown provider: {provider}")


async def list_models(
    provider: str,
    api_key: str,
    base_url: str | None = None,
) -> list[str]:
    """Fetch the provider's LIVE list of available model ids.

    Hits each provider's "list models" endpoint with the given key and returns
    the model ids, lightly filtered to chat-capable models and sorted. Raises
    ValueError on missing key, unknown provider, or a non-2xx response.
    """
    if not api_key:
        raise ValueError("Missing api_key")

    async with httpx.AsyncClient(timeout=TIMEOUT_SECONDS) as client:
        if provider == "anthropic":
            response = await client.get(
                "https://api.anthropic.com/v1/models",
                headers={"x-api-key": api_key, "anthropic-version": "2023-06-01"},
                params={"limit": 1000},
            )
            _raise_for_status("anthropic", response)
            ids = [m["id"] for m in response.json().get("data", [])]
            return sorted(ids, reverse=True)

        if provider in ("openai", "openai_compatible"):
            if provider == "openai_compatible" and not base_url:
                raise ValueError("base_url is required for openai_compatible")
            url = (
                "https://api.openai.com/v1/models"
                if provider == "openai"
                else f"{base_url.rstrip('/')}/models"
            )
            response = await client.get(
                url, headers={"Authorization": f"Bearer {api_key}"}
            )
            _raise_for_status(provider, response)
            ids = [m["id"] for m in response.json().get("data", [])]
            # OpenAI's list mixes in embeddings/tts/whisper/image models; keep the
            # chat-capable ones. For a custom base_url, keep everything (can't guess).
            if provider == "openai":
                keep = ("gpt", "o1", "o3", "o4", "chatgpt")
                chat = [i for i in ids if i.startswith(keep)]
                ids = chat or ids
            return sorted(ids, reverse=True)

        if provider == "gemini":
            response = await client.get(
                "https://generativelanguage.googleapis.com/v1beta/models",
                params={"key": api_key, "pageSize": 1000},
            )
            _raise_for_status("gemini", response)
            out: list[str] = []
            for m in response.json().get("models", []):
                methods = m.get("supportedGenerationMethods", [])
                if "generateContent" not in methods:
                    continue
                # Names look like "models/gemini-2.5-flash" → strip the prefix.
                out.append(m.get("name", "").removeprefix("models/"))
            return sorted(x for x in out if x)

        raise ValueError(f"Unknown provider: {provider}")


async def _answer_anthropic(
    client: httpx.AsyncClient,
    text: str,
    model: str,
    api_key: str,
    system_prompt: str | None,
    max_tokens: int,
) -> str:
    """Call the Anthropic Messages API and return the reply text."""
    body: dict[str, Any] = {
        "model": model,
        "max_tokens": max_tokens,
        "messages": [{"role": "user", "content": text}],
    }
    if system_prompt:
        body["system"] = system_prompt
    response = await client.post(
        "https://api.anthropic.com/v1/messages",
        headers={
            "x-api-key": api_key,
            "anthropic-version": "2023-06-01",
            "content-type": "application/json",
        },
        json=body,
    )
    _raise_for_status("anthropic", response)
    try:
        return response.json()["content"][0]["text"].strip()
    except (KeyError, IndexError, TypeError) as exc:
        raise ValueError(
            f"Unexpected anthropic response: {_truncate(response.text)}"
        ) from exc


async def _answer_openai(
    client: httpx.AsyncClient,
    text: str,
    model: str,
    api_key: str,
    system_prompt: str | None,
    max_tokens: int,
    url: str = "https://api.openai.com/v1/chat/completions",
) -> str:
    """Call an OpenAI-style chat completions API and return the reply text.

    Shared by the "openai" and "openai_compatible" providers; the latter only
    differs by ``url``.
    """
    messages: list[dict[str, str]] = []
    if system_prompt:
        messages.append({"role": "system", "content": system_prompt})
    messages.append({"role": "user", "content": text})
    body: dict[str, Any] = {
        "model": model,
        "max_tokens": max_tokens,
        "messages": messages,
    }
    response = await client.post(
        url,
        headers={"Authorization": f"Bearer {api_key}"},
        json=body,
    )
    _raise_for_status("openai", response)
    try:
        return response.json()["choices"][0]["message"]["content"].strip()
    except (KeyError, IndexError, TypeError) as exc:
        raise ValueError(
            f"Unexpected openai response: {_truncate(response.text)}"
        ) from exc


async def _answer_gemini(
    client: httpx.AsyncClient,
    text: str,
    model: str,
    api_key: str,
    system_prompt: str | None,
    max_tokens: int,
) -> str:
    """Call the Gemini generateContent API and return the reply text."""
    body: dict[str, Any] = {
        "contents": [{"role": "user", "parts": [{"text": text}]}],
        "generationConfig": {"maxOutputTokens": max_tokens},
    }
    if system_prompt:
        body["systemInstruction"] = {"parts": [{"text": system_prompt}]}
    url = (
        "https://generativelanguage.googleapis.com/v1beta/models/"
        f"{model}:generateContent?key={api_key}"
    )
    response = await client.post(url, json=body)
    _raise_for_status("gemini", response)
    try:
        return response.json()["candidates"][0]["content"]["parts"][0]["text"].strip()
    except (KeyError, IndexError, TypeError) as exc:
        raise ValueError(
            f"Unexpected gemini response: {_truncate(response.text)}"
        ) from exc
