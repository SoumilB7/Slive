"""LLM assistant backend.

This module hides several LLM providers behind a single async ``answer``
function so the HTTP server can talk to any of them without caring about the
concrete request/response shape. The caller supplies the provider, model, and
API key per request; nothing is read from the environment here.

Supported providers: "anthropic", "openai", "gemini", and "openai_compatible"
(the last covers OpenRouter/Groq/Ollama/LM Studio via a base_url).
"""

from __future__ import annotations

import json
import logging
from collections.abc import AsyncIterator
from typing import Any

import httpx
from fastapi.concurrency import run_in_threadpool

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


# --- Multimodal content builders --------------------------------------------
# An image is a dict {"media_type": "image/png", "data": "<base64, no prefix>"}.

def _anthropic_content(
    text: str, images: list[dict[str, str]] | None
) -> list[dict[str, Any]]:
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


def _openai_content(text: str, images: list[dict[str, str]] | None) -> Any:
    """OpenAI user content: a plain string when no images, else a parts list."""
    if not images:
        return text
    parts: list[dict[str, Any]] = [{"type": "text", "text": text}]
    for img in images:
        parts.append({
            "type": "image_url",
            "image_url": {"url": f"data:{img['media_type']};base64,{img['data']}"},
        })
    return parts


def _gemini_parts(
    text: str, images: list[dict[str, str]] | None
) -> list[dict[str, Any]]:
    """Gemini user parts: the text part, then inlineData parts for each image."""
    parts: list[dict[str, Any]] = [{"text": text}]
    for img in images or []:
        parts.append({
            "inlineData": {"mimeType": img["media_type"], "data": img["data"]}
        })
    return parts


# A history turn is {"role": "user"|"assistant", "content": str} (text only).

def _anthropic_messages(
    text: str,
    images: list[dict[str, str]] | None,
    history: list[dict[str, str]] | None,
) -> list[dict[str, Any]]:
    """Prior turns, then the current user message (with any images)."""
    messages: list[dict[str, Any]] = []
    for h in history or []:
        messages.append({"role": h["role"], "content": h["content"]})
    messages.append({"role": "user", "content": _anthropic_content(text, images)})
    return messages


def _openai_messages(
    text: str,
    system_prompt: str | None,
    images: list[dict[str, str]] | None,
    history: list[dict[str, str]] | None,
) -> list[dict[str, Any]]:
    """System (optional), prior turns, then the current user message."""
    messages: list[dict[str, Any]] = []
    if system_prompt:
        messages.append({"role": "system", "content": system_prompt})
    for h in history or []:
        messages.append({"role": h["role"], "content": h["content"]})
    messages.append({"role": "user", "content": _openai_content(text, images)})
    return messages


def _gemini_contents(
    text: str,
    images: list[dict[str, str]] | None,
    history: list[dict[str, str]] | None,
) -> list[dict[str, Any]]:
    """Prior turns (assistant → 'model'), then the current user content."""
    contents: list[dict[str, Any]] = []
    for h in history or []:
        role = "model" if h["role"] == "assistant" else "user"
        contents.append({"role": role, "parts": [{"text": h["content"]}]})
    contents.append({"role": "user", "parts": _gemini_parts(text, images)})
    return contents


async def answer(
    text: str,
    provider: str,
    model: str,
    api_key: str,
    base_url: str | None = None,
    system_prompt: str | None = None,
    max_tokens: int = 1024,
    images: list[dict[str, str]] | None = None,
    history: list[dict[str, str]] | None = None,
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
    if provider == "local":
        from flowy import local_infer
        return await run_in_threadpool(
            local_infer.chat, model, api_key or None, system_prompt or "",
            history or [], text, [img.get("data", "") for img in (images or [])],
            max_tokens,
        )
    if not api_key:
        raise ValueError("Missing api_key")

    async with httpx.AsyncClient(timeout=TIMEOUT_SECONDS) as client:
        if provider == "anthropic":
            return await _answer_anthropic(
                client, text, model, api_key, system_prompt, max_tokens,
                images=images, history=history,
            )
        if provider == "openai":
            return await _answer_openai(
                client, text, model, api_key, system_prompt, max_tokens,
                token_field="max_completion_tokens", images=images, history=history,
            )
        if provider == "gemini":
            return await _answer_gemini(
                client, text, model, api_key, system_prompt, max_tokens,
                images=images, history=history,
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
                token_field="max_tokens",
                images=images,
                history=history,
            )
        raise ValueError(f"Unknown provider: {provider}")


async def answer_stream(
    text: str,
    provider: str,
    model: str,
    api_key: str,
    base_url: str | None = None,
    system_prompt: str | None = None,
    max_tokens: int = 1024,
    images: list[dict[str, str]] | None = None,
    history: list[dict[str, str]] | None = None,
) -> AsyncIterator[str]:
    """Like ``answer`` but yields the reply incrementally as text deltas.

    Uses each provider's server-sent-events streaming API. Raises ValueError on
    the same conditions as ``answer`` (missing key/text, bad status, unknown
    provider); partial output already yielded stays yielded.
    """
    if not text or not text.strip():
        raise ValueError("Empty prompt text")
    if provider == "local":
        from flowy import local_infer
        reply = await run_in_threadpool(
            local_infer.chat, model, api_key or None, system_prompt or "",
            history or [], text, [img.get("data", "") for img in (images or [])],
            max_tokens,
        )
        if reply:
            yield reply
        return
    if not api_key:
        raise ValueError("Missing api_key")

    async with httpx.AsyncClient(timeout=TIMEOUT_SECONDS) as client:
        if provider == "anthropic":
            async for d in _stream_anthropic(
                client, text, model, api_key, system_prompt, max_tokens,
                images=images, history=history,
            ):
                yield d
        elif provider in ("openai", "openai_compatible"):
            if provider == "openai_compatible" and not base_url:
                raise ValueError("base_url is required for openai_compatible")
            if provider == "openai":
                url = "https://api.openai.com/v1/chat/completions"
                token_field = "max_completion_tokens"
            else:
                url = f"{base_url.rstrip('/')}/chat/completions"
                token_field = "max_tokens"
            async for d in _stream_openai(
                client, text, model, api_key, system_prompt, max_tokens, url,
                token_field=token_field, images=images, history=history,
            ):
                yield d
        elif provider == "gemini":
            async for d in _stream_gemini(
                client, text, model, api_key, system_prompt, max_tokens,
                images=images, history=history,
            ):
                yield d
        else:
            raise ValueError(f"Unknown provider: {provider}")


def _sse_data(line: str) -> str | None:
    """Return the payload of an SSE ``data:`` line, or None for other lines."""
    if line.startswith("data:"):
        return line[len("data:"):].strip()
    return None


async def _raise_for_stream_status(provider: str, r: httpx.Response) -> None:
    """Read the body of a failed streamed response, then raise ValueError."""
    if r.is_success:
        return
    await r.aread()
    _raise_for_status(provider, r)


async def _stream_anthropic(
    client: httpx.AsyncClient,
    text: str,
    model: str,
    api_key: str,
    system_prompt: str | None,
    max_tokens: int,
    images: list[dict[str, str]] | None = None,
    history: list[dict[str, str]] | None = None,
) -> AsyncIterator[str]:
    body: dict[str, Any] = {
        "model": model,
        "max_tokens": max_tokens,
        "stream": True,
        "messages": _anthropic_messages(text, images, history),
    }
    if system_prompt:
        body["system"] = system_prompt
    async with client.stream(
        "POST",
        "https://api.anthropic.com/v1/messages",
        headers={
            "x-api-key": api_key,
            "anthropic-version": "2023-06-01",
            "content-type": "application/json",
        },
        json=body,
    ) as r:
        await _raise_for_stream_status("anthropic", r)
        async for line in r.aiter_lines():
            data = _sse_data(line)
            if not data:
                continue
            try:
                evt = json.loads(data)
            except json.JSONDecodeError:
                continue
            if evt.get("type") == "content_block_delta":
                piece = evt.get("delta", {}).get("text")
                if piece:
                    yield piece


async def _stream_openai(
    client: httpx.AsyncClient,
    text: str,
    model: str,
    api_key: str,
    system_prompt: str | None,
    max_tokens: int,
    url: str,
    token_field: str = "max_completion_tokens",
    images: list[dict[str, str]] | None = None,
    history: list[dict[str, str]] | None = None,
) -> AsyncIterator[str]:
    messages = _openai_messages(text, system_prompt, images, history)
    body: dict[str, Any] = {
        "model": model,
        token_field: max_tokens,
        "stream": True,
        "messages": messages,
    }
    async with client.stream(
        "POST", url, headers={"Authorization": f"Bearer {api_key}"}, json=body
    ) as r:
        await _raise_for_stream_status("openai", r)
        async for line in r.aiter_lines():
            data = _sse_data(line)
            if data is None or data == "[DONE]":
                continue
            try:
                evt = json.loads(data)
                piece = evt["choices"][0]["delta"].get("content")
            except (json.JSONDecodeError, KeyError, IndexError, TypeError):
                continue
            if piece:
                yield piece


async def _stream_gemini(
    client: httpx.AsyncClient,
    text: str,
    model: str,
    api_key: str,
    system_prompt: str | None,
    max_tokens: int,
    images: list[dict[str, str]] | None = None,
    history: list[dict[str, str]] | None = None,
) -> AsyncIterator[str]:
    body: dict[str, Any] = {
        "contents": _gemini_contents(text, images, history),
        "generationConfig": {"maxOutputTokens": max_tokens},
    }
    if system_prompt:
        body["systemInstruction"] = {"parts": [{"text": system_prompt}]}
    url = (
        "https://generativelanguage.googleapis.com/v1beta/models/"
        f"{model}:streamGenerateContent?alt=sse&key={api_key}"
    )
    async with client.stream("POST", url, json=body) as r:
        await _raise_for_stream_status("gemini", r)
        async for line in r.aiter_lines():
            data = _sse_data(line)
            if not data:
                continue
            try:
                evt = json.loads(data)
                parts = evt["candidates"][0]["content"]["parts"]
            except (json.JSONDecodeError, KeyError, IndexError, TypeError):
                continue
            for part in parts:
                piece = part.get("text")
                if piece:
                    yield piece


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
    images: list[dict[str, str]] | None = None,
    history: list[dict[str, str]] | None = None,
) -> str:
    """Call the Anthropic Messages API and return the reply text."""
    body: dict[str, Any] = {
        "model": model,
        "max_tokens": max_tokens,
        "messages": _anthropic_messages(text, images, history),
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
    token_field: str = "max_completion_tokens",
    images: list[dict[str, str]] | None = None,
    history: list[dict[str, str]] | None = None,
) -> str:
    """Call an OpenAI-style chat completions API and return the reply text.

    Shared by the "openai" and "openai_compatible" providers. Native OpenAI
    (and o-series/GPT-5) require ``max_completion_tokens``; third-party
    OpenAI-compatible servers still expect ``max_tokens`` — hence ``token_field``.
    """
    messages = _openai_messages(text, system_prompt, images, history)
    body: dict[str, Any] = {
        "model": model,
        token_field: max_tokens,
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
    images: list[dict[str, str]] | None = None,
    history: list[dict[str, str]] | None = None,
) -> str:
    """Call the Gemini generateContent API and return the reply text."""
    body: dict[str, Any] = {
        "contents": _gemini_contents(text, images, history),
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


# ---------------------------------------------------------------------------
# Ground-truth transcription via audio-capable multimodal models
# ---------------------------------------------------------------------------

TRANSCRIBE_PROMPT = (
    "Transcribe this audio recording verbatim into English. Output ONLY the "
    "words that are spoken, with correct spelling, natural punctuation and "
    "capitalization, as one plain-text passage. The output must be entirely "
    "English in Latin script: if any part of the speech is in another "
    "language, do not transcribe it in that language or its script — replace "
    "that part inline with its natural English translation, so the whole "
    "output reads as one fluent English passage. Disfluencies are not part of "
    "the intended text: when the speaker stutters or accidentally repeats a "
    "word or phrase back-to-back while composing (e.g. 'anything… anything "
    "like that'), write it once; likewise drop abandoned false starts. Keep a "
    "repetition only when it is clearly deliberate (emphasis, or quoted "
    "speech). Do not add anything that was not said, do not describe the "
    "audio or the speaker, no quotation marks around the output, no markdown. "
    "If nothing intelligible is spoken, output an empty string."
)


async def transcribe_audio(
    provider: str,
    model: str,
    api_key: str,
    audio_b64: str,
    media_type: str = "audio/wav",
    base_url: str | None = None,
) -> str:
    """Ask an audio-capable multimodal model for a verbatim transcription.

    Same proxy pattern as ``answer``: the caller supplies provider/model/key per
    request; nothing is stored server-side. Only providers whose models accept
    audio input are supported — Anthropic's API does not take audio, so it is
    rejected explicitly rather than failing confusingly upstream.
    """
    if not audio_b64:
        raise ValueError("Missing audio")
    if provider == "local":
        from flowy import local_infer
        return await run_in_threadpool(
            local_infer.transcribe, model, api_key or None, audio_b64, media_type,
        )
    if not api_key:
        raise ValueError("Missing api_key")

    async with httpx.AsyncClient(timeout=TIMEOUT_SECONDS) as client:
        if provider == "gemini":
            url = (
                "https://generativelanguage.googleapis.com/v1beta/models/"
                f"{model}:generateContent?key={api_key}"
            )
            body = {
                "contents": [{
                    "parts": [
                        {"text": TRANSCRIBE_PROMPT},
                        {"inline_data": {"mime_type": media_type, "data": audio_b64}},
                    ],
                }],
            }
            resp = await client.post(url, json=body)
            _raise_for_status("gemini", resp)
            data = resp.json()
            try:
                parts = data["candidates"][0]["content"]["parts"]
                return "".join(p.get("text", "") for p in parts).strip()
            except (KeyError, IndexError) as exc:
                raise ValueError(f"Unexpected Gemini response shape: {data}") from exc

        if provider in ("openai", "openai_compatible"):
            if provider == "openai_compatible" and not base_url:
                raise ValueError("base_url is required for openai_compatible")
            url = (
                f"{base_url.rstrip('/')}/chat/completions"
                if provider == "openai_compatible"
                else "https://api.openai.com/v1/chat/completions"
            )
            audio_format = "mp3" if "mp3" in media_type or "mpeg" in media_type else "wav"
            body = {
                "model": model,
                "modalities": ["text"],
                "messages": [{
                    "role": "user",
                    "content": [
                        {"type": "text", "text": TRANSCRIBE_PROMPT},
                        {"type": "input_audio",
                         "input_audio": {"data": audio_b64, "format": audio_format}},
                    ],
                }],
            }
            resp = await client.post(
                url, headers={"Authorization": f"Bearer {api_key}"}, json=body
            )
            _raise_for_status(provider, resp)
            data = resp.json()
            try:
                return (data["choices"][0]["message"]["content"] or "").strip()
            except (KeyError, IndexError) as exc:
                raise ValueError(f"Unexpected OpenAI response shape: {data}") from exc

        if provider == "anthropic":
            raise ValueError(
                "Anthropic models do not accept audio input — pick Gemini or an "
                "OpenAI audio model for ground-truth transcription."
            )
        raise ValueError(f"Unknown provider: {provider}")
