"""OpenAI, and anything that speaks its API at a custom ``base_url``
(OpenRouter, Groq, a local Ollama / LM Studio at ``http://localhost:11434/v1``)."""

from __future__ import annotations

import base64
import logging
from collections.abc import AsyncIterator
from typing import Any

import httpx

from flowy.providers.base import (
    AudioInput,
    ChatInput,
    http_client,
    raise_for_status,
    raise_for_stream_status,
    sse_events,
    stream_error_message,
)
from flowy.providers.transcription import full_prompt, guard_transcription, with_vocab_hint
from flowy.util import truncate

logger = logging.getLogger("flowy.assistant")

#: Compact instruction for the dedicated transcriptions endpoint (its prompt
#: field has tight token limits — whisper-1 caps around 224 tokens).
ENDPOINT_TRANSCRIBE_PROMPT = (
    "Verbatim English transcription. Translate any non-English speech inline "
    "to English. Write accidental back-to-back repetitions once; drop "
    "abandoned false starts. No commentary."
)


def _content(text: str, images: list[dict[str, str]] | None) -> Any:
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


def _messages(req: ChatInput) -> list[dict[str, Any]]:
    """System (optional), prior turns, then the current user message."""
    messages: list[dict[str, Any]] = []
    if req.system_prompt:
        messages.append({"role": "system", "content": req.system_prompt})
    for h in req.history or []:
        messages.append({"role": h["role"], "content": h["content"]})
    messages.append({"role": "user", "content": _content(req.text, req.images)})
    return messages


def _auth(api_key: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {api_key}"}


def transcribe_fallback_models(chosen: str) -> list[str]:
    """Dedicated-endpoint models to try for a chat-audio pick, best first.

    A pick that already IS an endpoint model goes first verbatim; otherwise
    mini picks map to the mini transcribe model. whisper-1 is the universal
    last resort (every OpenAI-compatible host that does audio serves it).
    """
    lowered = chosen.lower()
    candidates: list[str] = []
    if "transcribe" in lowered or lowered.startswith("whisper"):
        candidates.append(chosen)
    candidates.append("gpt-4o-mini-transcribe" if "mini" in lowered else "gpt-4o-transcribe")
    candidates.append("whisper-1")
    seen: set[str] = set()
    return [c for c in candidates if not (c in seen or seen.add(c))]


async def _transcriptions_endpoint(
    client: httpx.AsyncClient,
    root: str,
    req: AudioInput,
    audio_format: str,
) -> tuple[str, str] | None:
    """POST /audio/transcriptions — the endpoint that can only transcribe.

    Tries the mapped model, then whisper-1; returns (text, prompt_used), or
    None only if every candidate fails (caller then surfaces the original
    guard error).
    """
    try:
        audio_bytes = base64.b64decode(req.audio_b64)
    except Exception:  # noqa: BLE001 - fall back to the guard error
        return None
    mime = "audio/mpeg" if audio_format == "mp3" else "audio/wav"
    # The dedicated endpoint's prompt budget is tiny (whisper-1 ≈224 tokens):
    # a customized base is clipped to leave room for the vocabulary tail.
    override = req.prompt_override
    endpoint_base = (
        truncate(override.strip(), 500)
        if override and override.strip()
        else ENDPOINT_TRANSCRIBE_PROMPT
    )
    endpoint_prompt = with_vocab_hint(endpoint_base, req.vocab_hint, limit=300)
    for candidate in transcribe_fallback_models(req.model):
        try:
            resp = await client.post(
                f"{root}/audio/transcriptions",
                headers=_auth(req.api_key),
                files={"file": (f"audio.{audio_format}", audio_bytes, mime)},
                data={"model": candidate,
                      # Tighter clip here: whisper-1's prompt budget is small
                      # and the vocabulary is the part that matters most.
                      "prompt": endpoint_prompt,
                      "response_format": "text"},
            )
        except httpx.HTTPError:
            return None
        if resp.status_code // 100 != 2:
            continue   # unknown model / not served here — try the next
        text = resp.text.strip()
        if text:
            logger.info("transcriptions-endpoint fallback served by %s", candidate)
            return text, endpoint_prompt
    return None


class OpenAIProvider:
    name = "openai"
    requires_key = True
    #: Reference model — the app always sends the one it wants.
    default_model = "gpt-4o"
    #: Native OpenAI (and o-series/GPT-5) require ``max_completion_tokens``;
    #: third-party OpenAI-compatible servers still expect ``max_tokens``.
    token_field = "max_completion_tokens"

    def root(self, base_url: str | None) -> str:
        return "https://api.openai.com/v1"

    def label(self, base_url: str | None) -> str:
        return "OpenAI"

    def _chat_body(self, req: ChatInput, **extra: Any) -> dict[str, Any]:
        return {"model": req.model, self.token_field: req.max_tokens, **extra,
                "messages": _messages(req)}

    async def chat(self, req: ChatInput) -> str:
        """Call an OpenAI-style chat completions API and return the reply text."""
        url = f"{self.root(req.base_url)}/chat/completions"
        async with http_client() as client:
            response = await client.post(url, headers=_auth(req.api_key), json=self._chat_body(req))
        raise_for_status("openai", response)
        try:
            return response.json()["choices"][0]["message"]["content"].strip()
        except (KeyError, IndexError, TypeError) as exc:
            raise ValueError(
                f"Unexpected openai response: {truncate(response.text)}"
            ) from exc

    async def stream(self, req: ChatInput) -> AsyncIterator[str]:
        url = f"{self.root(req.base_url)}/chat/completions"
        label = self.label(req.base_url)
        async with http_client() as client, client.stream(
            "POST", url, headers=_auth(req.api_key), json=self._chat_body(req, stream=True)
        ) as r:
            await raise_for_stream_status("openai", r)
            async for evt in sse_events(r):
                # OpenRouter (and OpenAI) report mid-stream failures as an event.
                if isinstance(evt, dict) and evt.get("error"):
                    raise ValueError(stream_error_message(label, evt["error"]))
                try:
                    piece = evt["choices"][0]["delta"].get("content")
                except (KeyError, IndexError, TypeError, AttributeError):
                    continue
                if piece:
                    yield piece

    def _keep_models(self, ids: list[str]) -> list[str]:
        # OpenAI's list mixes in embeddings/tts/whisper/image models; keep the
        # chat-capable ones.
        keep = ("gpt", "o1", "o3", "o4", "chatgpt")
        chat = [i for i in ids if i.startswith(keep)]
        return chat or ids

    async def list_models(self, api_key: str, base_url: str | None) -> list[str]:
        url = f"{self.root(base_url)}/models"
        async with http_client() as client:
            response = await client.get(url, headers=_auth(api_key))
        raise_for_status(self.name, response)
        ids = [m["id"] for m in response.json().get("data", [])]
        return sorted(self._keep_models(ids), reverse=True)

    async def transcribe_audio(self, req: AudioInput) -> tuple[str, str]:
        root = self.root(req.base_url)
        audio_format = "mp3" if "mp3" in req.media_type or "mpeg" in req.media_type else "wav"
        async with http_client() as client:
            # PRIMARY: the dedicated transcriptions endpoint — it structurally
            # CANNOT chat, so "the model answered my audio" is impossible by
            # construction. Chat-audio models were caught both ignoring the
            # audio AND answering it conversationally; no prompt or marker
            # list fixes a chat API, so transcription simply doesn't use one.
            direct = await _transcriptions_endpoint(client, root, req, audio_format)
            if direct is not None:
                return direct

            # Fallback only for OpenAI-compatible gateways that don't serve
            # /audio/transcriptions: a guarded chat attempt (instructions in
            # the system turn, the user turn is audio only).
            chat_prompt = full_prompt(req)
            body = {
                "model": req.model,
                "modalities": ["text"],
                "messages": [
                    {"role": "system", "content": chat_prompt},
                    {"role": "user", "content": [
                        {"type": "input_audio",
                         "input_audio": {"data": req.audio_b64, "format": audio_format}},
                    ]},
                ],
            }
            resp = await client.post(
                f"{root}/chat/completions", headers=_auth(req.api_key), json=body
            )
        raise_for_status(self.name, resp)
        data = resp.json()
        try:
            text = (data["choices"][0]["message"]["content"] or "").strip()
        except (KeyError, IndexError) as exc:
            raise ValueError(f"Unexpected OpenAI response shape: {data}") from exc
        return guard_transcription(text), chat_prompt


class OpenAICompatibleProvider(OpenAIProvider):
    """OpenAI's API at the user's ``base_url``."""

    name = "openai_compatible"
    default_model = ""
    token_field = "max_tokens"

    def root(self, base_url: str | None) -> str:
        if not base_url:
            raise ValueError("base_url is required for openai_compatible")
        return base_url.rstrip("/")

    def label(self, base_url: str | None) -> str:
        host = httpx.URL(base_url).host or "The provider"
        return "OpenRouter" if "openrouter" in host else host

    def _keep_models(self, ids: list[str]) -> list[str]:
        return ids  # a custom base_url: keep everything (can't guess)
