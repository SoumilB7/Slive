"""Shared pieces of the config-matrix suites: the documented response
contract (what the Swift client can decode), one fake wire per provider,
and readers for the Swift enums the app sends values from."""

from __future__ import annotations

import base64
import io
import json
import re
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path

import httpx
import numpy as np
import soundfile as sf

#: Statuses ``flowy.errors`` documents (plus FastAPI's 422 for a body that
#: fails validation). A 500 is always a bug: the app shows "Server error 500".
DOCUMENTED_ERRORS = {400, 401, 403, 404, 409, 422, 424, 502}

FRONTEND = Path(__file__).resolve().parents[2] / "Frontend" / "Sources" / "Slive"


def wav_b64(seconds: float = 0.5) -> str:
    """What the app uploads: a Float32 16 kHz mono WAV."""
    out = io.BytesIO()
    sf.write(out, np.zeros(int(16_000 * seconds), dtype="float32"), 16_000,
             format="WAV", subtype="FLOAT")
    return base64.b64encode(out.getvalue()).decode()


AUDIO = wav_b64()


def assert_error(resp, status: int | None = None) -> str:
    """A documented non-2xx: the status is one ``flowy.errors`` maps to, and
    the body carries the message the Swift client reads (``error``, or
    ``detail`` on a validation 422). Returns the message."""
    assert resp.status_code in DOCUMENTED_ERRORS, (resp.status_code, resp.text)
    if status is not None:
        assert resp.status_code == status, (resp.status_code, resp.text)
    body = resp.json()
    assert isinstance(body, dict)
    if "error" in body:
        assert isinstance(body["error"], str) and body["error"].strip(), body
        assert set(body) <= {"error", "fatal"}, body
        if "fatal" in body:
            assert resp.status_code == 401 and body["fatal"] in ("auth", "quota"), body
        return body["error"]
    assert resp.status_code == 422 and body.get("detail"), body
    return str(body["detail"])


def read_ndjson(resp) -> list[dict]:
    """``/assistant/stream``'s framing: always 200 NDJSON, every line one JSON
    object, deltas then exactly one terminal ``done`` or ``error`` — never a
    stream that just stops."""
    assert resp.status_code == 200, resp.text
    assert resp.headers["content-type"] == "application/x-ndjson"
    assert resp.text.endswith("\n"), "the last line must be terminated"
    events = [json.loads(line) for line in resp.text.split("\n")[:-1]]
    assert events, "an empty stream leaves the overlay waiting"
    for event in events[:-1]:
        assert set(event) == {"delta"} and isinstance(event["delta"], str) and event["delta"], event
    last = events[-1]
    assert last == {"done": True} or (
        set(last) == {"error"} and isinstance(last["error"], str) and last["error"].strip()), last
    return events


# ---------------------------------------------------------------------------
# One fake wire per provider
# ---------------------------------------------------------------------------

def sse(*events) -> bytes:
    return "".join(f"data: {e if isinstance(e, str) else json.dumps(e)}\n\n" for e in events).encode()


def _openai_reply(text: str) -> dict:
    return {"choices": [{"message": {"content": text}}]}


def _gemini_reply(text: str) -> dict:
    return {"candidates": [{"content": {"parts": [{"text": text}]}, "finishReason": "STOP"}]}


@dataclass(frozen=True)
class Wire:
    """How one HTTP provider talks: enough to fake every call the routes make.
    ``audio`` is None for a provider that can't hear (its route must say so)."""

    extra: dict
    reply: Callable[[str], dict]
    #: One streamed text event, and the events that end a stream normally.
    delta: Callable[[str], object]
    end: tuple
    #: An error event the provider sends mid-stream.
    stream_error: object
    models: Callable[[list[str]], dict]
    #: The ids /models should return for ``models(ids)``: filtered + sorted.
    listed: Callable[[list[str]], list[str]]
    audio: Callable[[str], httpx.Response] | None
    #: A typical id list (with ids the provider's filter drops).
    model_ids: list[str] = field(default_factory=list)


ANTHROPIC = Wire(
    extra={},
    reply=lambda text: {"content": [{"type": "text", "text": text}]},
    delta=lambda d: {"type": "content_block_delta", "delta": {"type": "text_delta", "text": d}},
    end=({"type": "message_delta"}, {"type": "message_stop"}),
    stream_error={"type": "error", "error": {"type": "overloaded_error", "message": "Overloaded"}},
    models=lambda ids: {"data": [{"id": i} for i in ids]},
    listed=lambda ids: sorted(ids, reverse=True),
    audio=None,
    model_ids=["claude-haiku-4", "claude-sonnet-5"],
)

OPENAI = Wire(
    extra={},
    reply=_openai_reply,
    delta=lambda d: {"choices": [{"delta": {"content": d}}]},
    end=("[DONE]",),
    stream_error={"error": {"message": "The server is overloaded", "code": 503}},
    models=lambda ids: {"data": [{"id": i} for i in ids]},
    listed=lambda ids: sorted((i for i in ids if i.startswith(("gpt", "o1", "o3", "o4", "chatgpt"))),
                              reverse=True),
    audio=lambda text: httpx.Response(200, text=f" {text} "),
    model_ids=["gpt-4o", "text-embedding-3-small", "o3", "whisper-1"],
)

OPENAI_COMPATIBLE = Wire(
    extra={"base_url": "https://openrouter.ai/api/v1/"},
    reply=OPENAI.reply,
    delta=OPENAI.delta,
    end=OPENAI.end,
    stream_error={"error": {"message": "Rate limit exceeded", "code": 429}},
    models=OPENAI.models,
    listed=lambda ids: sorted(ids, reverse=True),  # a custom host: nothing filtered
    audio=OPENAI.audio,
    model_ids=["meta/llama-4", "openai/gpt-5", "text-embedding-3-small"],
)

GEMINI = Wire(
    extra={},
    reply=_gemini_reply,
    delta=lambda d: {"candidates": [{"content": {"parts": [{"text": d}]}}]},
    end=({"candidates": [{"content": {"parts": []}, "finishReason": "STOP"}]},),
    stream_error={"error": {"status": "UNAVAILABLE", "message": "overloaded"}},
    models=lambda ids: {"models": [
        {"name": f"models/{i}", "supportedGenerationMethods":
            ["embedContent"] if "embedding" in i else ["generateContent"]} for i in ids]},
    listed=lambda ids: sorted(i for i in ids if "embedding" not in i),
    audio=lambda text: httpx.Response(200, json=_gemini_reply(text)),
    model_ids=["gemini-2.5-flash", "text-embedding-004", "gemini-2.5-pro"],
)

#: Every HTTP provider's fake, by registry name. ``local`` runs on-device and
#: is faked at ``local_infer`` instead (see ``LOCAL``).
WIRES: dict[str, Wire] = {
    "anthropic": ANTHROPIC,
    "openai": OPENAI,
    "openai_compatible": OPENAI_COMPATIBLE,
    "gemini": GEMINI,
}


@dataclass(frozen=True)
class OnDevice:
    """A provider that never touches HTTP: ``local_infer`` is faked."""

    extra: dict
    #: The user-facing error its engine raises for a token/model problem.
    auth_error: str


LOCAL = OnDevice(extra={"model": "google/gemma-3n-E2B-it"},
                 auth_error="Couldn't load google/gemma-3n-E2B-it: 401 gated repo, token rejected")

ON_DEVICE: dict[str, OnDevice] = {"local": LOCAL}


def fake_for(name: str) -> Wire | OnDevice:
    fake = WIRES.get(name) or ON_DEVICE.get(name)
    if fake is None:
        raise AssertionError(
            f"provider {name!r} is in the registry but has no fake in tests/matrix_support.py — "
            f"add a Wire (HTTP) or OnDevice entry so every config matrix covers it")
    return fake


def wire_handler(wire: Wire, *, key: str, reply: str, text: str = "Hello there",
                 deltas: tuple[str, ...] = ("Hel", "lo there"), model_ids: list[str] | None = None,
                 models_payload: dict | None = None,
                 cut: bool = False) -> Callable[[httpx.Request], httpx.Response]:
    """An upstream that answers like ``wire``.

    ``key``: ``invalid`` = every call 401s (the provider's auth error).
    ``reply``: ``text`` | ``empty`` (a 2xx with no words) | ``broken`` (503).
    ``models_payload``: the raw /models body (overrides ``model_ids``).
    ``cut``: the stream sends its deltas, then an error event.
    """

    def handle(request: httpx.Request) -> httpx.Response:
        if key == "invalid":
            return httpx.Response(401, json={"error": {"message": "Incorrect API key provided",
                                                       "type": "authentication_error"}})
        if reply == "broken":
            return httpx.Response(503, text="upstream unavailable")
        path = request.url.path
        if request.method == "GET":
            if models_payload is not None:
                return httpx.Response(200, json=models_payload)
            return httpx.Response(200, json=wire.models(
                wire.model_ids if model_ids is None else model_ids))
        if path.endswith("/audio/transcriptions"):
            return wire.audio("" if reply == "empty" else text)
        body = json.loads(request.content or b"{}")
        if body.get("stream") or path.endswith(":streamGenerateContent"):
            chunks = [] if reply == "empty" else list(deltas)
            tail = (wire.stream_error,) if cut else wire.end
            payload = sse(*(wire.delta(d) for d in chunks), *tail)
            return httpx.Response(200, content=payload,
                                  headers={"content-type": "text/event-stream"})
        return httpx.Response(200, json=wire.reply("" if reply == "empty" else text))

    return handle


# ---------------------------------------------------------------------------
# The Swift side (read-only): values the app can send
# ---------------------------------------------------------------------------

def swift_source(relative: str) -> str | None:
    path = FRONTEND / relative
    return path.read_text(encoding="utf-8") if path.is_file() else None


def swift_enum_cases(source: str, enum: str) -> list[str]:
    """The ``case`` names of ``enum <name>`` (one case per line, as the
    codebase writes them)."""
    match = re.search(rf"enum {enum}\b[^{{]*\{{(.*?)\n\}}", source, flags=re.S)
    assert match, f"enum {enum} not found"
    return re.findall(r"^\s*case (\w+)\s*$", match.group(1), flags=re.M)


def swift_provider_specs(source: str) -> dict[str, set[str]]:
    """``wire`` name → capabilities, from ``ProviderCatalog.make``."""
    specs: dict[str, set[str]] = {}
    for block in source.split("return ProviderSpec(")[1:]:
        wire = re.search(r'wire: "(\w+)"', block)
        caps = re.search(r"capabilities: \[([^\]]*)\]", block)
        assert wire and caps, block[:200]
        specs[wire.group(1)] = set(re.findall(r"\.(\w+)", caps.group(1)))
    return specs
