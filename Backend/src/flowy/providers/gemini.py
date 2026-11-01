"""Google Gemini (generateContent / streamGenerateContent)."""

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
from flowy.providers.transcription import full_prompt, guard_transcription
from flowy.util import truncate

API = "https://generativelanguage.googleapis.com/v1beta/models"

#: Gemini finish reasons that mean "stopped normally" — anything else (SAFETY,
#: RECITATION, PROHIBITED_CONTENT, ...) is a block the user should see.
_OK_FINISH = {"STOP", "MAX_TOKENS", "FINISH_REASON_UNSPECIFIED"}


def _headers(api_key: str) -> dict[str, str]:
    """Gemini auth rides in a header, never the URL: httpx logs request URLs,
    and a ``?key=`` would land the plaintext key in the backend log."""
    return {"x-goog-api-key": api_key}


def _parts(text: str, images: list[dict[str, str]] | None) -> list[dict[str, Any]]:
    """Gemini user parts: the text part, then inlineData parts for each image."""
    parts: list[dict[str, Any]] = [{"text": text}]
    for img in images or []:
        parts.append({
            "inlineData": {"mimeType": img["media_type"], "data": img["data"]}
        })
    return parts


def _body(req: ChatInput) -> dict[str, Any]:
    """Prior turns (assistant → 'model'), then the current user content."""
    contents: list[dict[str, Any]] = []
    for h in req.history or []:
        role = "model" if h["role"] == "assistant" else "user"
        contents.append({"role": role, "parts": [{"text": h["content"]}]})
    contents.append({"role": "user", "parts": _parts(req.text, req.images)})
    body: dict[str, Any] = {
        "contents": contents,
        "generationConfig": {"maxOutputTokens": req.max_tokens},
    }
    if req.system_prompt:
        body["systemInstruction"] = {"parts": [{"text": req.system_prompt}]}
    return body


class GeminiProvider:
    name = "gemini"
    requires_key = True
    #: Reference model — the app always sends the one it wants.
    default_model = "gemini-2.5-flash"

    def label(self, base_url: str | None) -> str:
        return "Gemini"

    async def chat(self, req: ChatInput) -> str:
        """Call the Gemini generateContent API and return the reply text."""
        async with http_client() as client:
            response = await client.post(
                f"{API}/{req.model}:generateContent",
                headers=_headers(req.api_key), json=_body(req),
            )
        raise_for_status("gemini", response)
        try:
            return response.json()["candidates"][0]["content"]["parts"][0]["text"].strip()
        except (KeyError, IndexError, TypeError) as exc:
            raise ValueError(
                f"Unexpected gemini response: {truncate(response.text)}"
            ) from exc

    async def stream(self, req: ChatInput) -> AsyncIterator[str]:
        async with http_client() as client, client.stream(
            "POST", f"{API}/{req.model}:streamGenerateContent?alt=sse",
            headers=_headers(req.api_key), json=_body(req),
        ) as r:
            await raise_for_stream_status("gemini", r)
            async for evt in sse_events(r):
                if not isinstance(evt, dict):
                    continue
                if evt.get("error"):
                    raise ValueError(stream_error_message("Gemini", evt["error"]))
                # A blocked prompt comes back with no candidates, only feedback.
                block = (evt.get("promptFeedback") or {}).get("blockReason")
                if block:
                    raise ValueError(f"Gemini blocked this request ({block}) — try rephrasing.")
                candidates = evt.get("candidates") or []
                if not candidates or not isinstance(candidates[0], dict):
                    continue
                cand = candidates[0]
                for part in (cand.get("content") or {}).get("parts") or []:
                    piece = part.get("text") if isinstance(part, dict) else None
                    if piece:
                        yield piece
                finish = cand.get("finishReason")
                if finish and finish not in _OK_FINISH:
                    raise ValueError(f"Gemini stopped the answer ({finish}) — try rephrasing.")

    async def list_models(self, api_key: str, base_url: str | None) -> list[str]:
        async with http_client() as client:
            response = await client.get(
                API, headers=_headers(api_key), params={"pageSize": 1000}
            )
        raise_for_status("gemini", response)
        out: list[str] = []
        for m in response.json().get("models", []):
            methods = m.get("supportedGenerationMethods", [])
            if "generateContent" not in methods:
                continue
            # Names look like "models/gemini-2.5-flash" → strip the prefix.
            out.append(m.get("name", "").removeprefix("models/"))
        return sorted(x for x in out if x)

    async def transcribe_audio(self, req: AudioInput) -> tuple[str, str]:
        prompt = full_prompt(req)
        body = {
            "contents": [{
                "parts": [
                    {"text": prompt},
                    {"inline_data": {"mime_type": req.media_type, "data": req.audio_b64}},
                ],
            }],
        }
        async with http_client() as client:
            resp = await client.post(
                f"{API}/{req.model}:generateContent", headers=_headers(req.api_key), json=body
            )
        raise_for_status("gemini", resp)
        data = resp.json()
        try:
            parts = data["candidates"][0]["content"]["parts"]
            text = "".join(p.get("text", "") for p in parts).strip()
        except (KeyError, IndexError) as exc:
            raise ValueError(f"Unexpected Gemini response shape: {data}") from exc
        return guard_transcription(text), prompt
