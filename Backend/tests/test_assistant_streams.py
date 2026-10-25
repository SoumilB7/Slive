"""Assistant provider calls, with every request served by a mock transport.

Nothing here touches the network: ``httpx.AsyncClient`` is swapped for one
whose transport records the request and answers with a canned response.
"""

import asyncio
import base64
import json

import httpx
import pytest
from fastapi.testclient import TestClient

from flowy import assistant, server

KEY = "AIzaSy-super-secret-test-key"


@pytest.fixture
def mock_http(monkeypatch):
    """Route every assistant HTTP call to ``handler``; returns the request log."""
    seen: list[httpx.Request] = []
    state: dict = {"handler": None}
    real_client = httpx.AsyncClient

    def transport_handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return state["handler"](request)

    def factory(*args, **kwargs):
        kwargs["transport"] = httpx.MockTransport(transport_handler)
        return real_client(*args, **kwargs)

    monkeypatch.setattr(httpx, "AsyncClient", factory)

    def install(handler):
        state["handler"] = handler
        return seen

    return install


def _sse(*events) -> bytes:
    return "".join(f"data: {json.dumps(e)}\n\n" for e in events).encode()


async def _collect(**kwargs) -> list[str]:
    return [d async for d in assistant.answer_stream(text="hi", api_key=KEY, **kwargs)]


def _run_stream(**kwargs) -> list[str]:
    return asyncio.run(_collect(**kwargs))


# --- Gemini key never rides in a URL -----------------------------------------

def _gemini_handler(request: httpx.Request) -> httpx.Response:
    path = request.url.path
    if path.endswith(":streamGenerateContent"):
        return httpx.Response(200, content=_sse(
            {"candidates": [{"content": {"parts": [{"text": "ok"}]}, "finishReason": "STOP"}]}
        ))
    if path.endswith(":generateContent"):
        return httpx.Response(200, json={"candidates": [{"content": {"parts": [{"text": "ok"}]}}]})
    return httpx.Response(200, json={"models": [
        {"name": "models/gemini-2.5-flash", "supportedGenerationMethods": ["generateContent"]}
    ]})


def test_gemini_key_is_a_header_never_in_the_url(mock_http) -> None:
    seen = mock_http(_gemini_handler)
    audio = base64.b64encode(b"\0" * 8_000).decode()

    asyncio.run(assistant.answer("hi", "gemini", "gemini-2.5-flash", KEY))
    _run_stream(provider="gemini", model="gemini-2.5-flash")
    asyncio.run(assistant.list_models("gemini", KEY))
    asyncio.run(assistant.transcribe_audio("gemini", "gemini-2.5-flash", KEY, audio))

    assert len(seen) == 4
    for request in seen:
        assert KEY not in str(request.url)
        assert "key=" not in str(request.url)
        assert request.headers["x-goog-api-key"] == KEY


# --- Mid-stream provider errors surface instead of an empty answer ------------

def test_anthropic_error_event_raises_readable_message(mock_http) -> None:
    mock_http(lambda r: httpx.Response(200, content=_sse(
        {"type": "message_start"},
        {"type": "error", "error": {"type": "overloaded_error", "message": "Overloaded"}},
    )))
    with pytest.raises(ValueError, match="Anthropic is overloaded"):
        _run_stream(provider="anthropic", model="claude-sonnet-5")


def test_anthropic_error_after_partial_text_keeps_the_text(mock_http) -> None:
    mock_http(lambda r: httpx.Response(200, content=_sse(
        {"type": "content_block_delta", "delta": {"text": "Hel"}},
        {"type": "error", "error": {"type": "api_error", "message": "Internal boom"}},
    )))
    got: list[str] = []

    async def run() -> None:
        async for d in assistant.answer_stream(
            text="hi", provider="anthropic", model="m", api_key=KEY
        ):
            got.append(d)

    with pytest.raises(ValueError, match="Anthropic error: Internal boom"):
        asyncio.run(run())
    assert got == ["Hel"]


def test_openrouter_error_event_raises(mock_http) -> None:
    mock_http(lambda r: httpx.Response(200, content=_sse(
        {"error": {"code": 502, "message": "Upstream provider died"},
         "choices": [{"delta": {"content": ""}, "finish_reason": "error"}]},
    )))
    with pytest.raises(ValueError, match="OpenRouter error: Upstream provider died"):
        _run_stream(provider="openai_compatible", model="x/y",
                    base_url="https://openrouter.ai/api/v1")


def test_openai_rate_limit_event_raises(mock_http) -> None:
    mock_http(lambda r: httpx.Response(200, content=_sse(
        {"error": {"type": "rate_limit_exceeded", "code": 429, "message": "Slow down"}},
    )))
    with pytest.raises(ValueError, match="OpenAI rate limit hit"):
        _run_stream(provider="openai", model="gpt-4o")


def test_gemini_prompt_block_raises(mock_http) -> None:
    mock_http(lambda r: httpx.Response(200, content=_sse(
        {"promptFeedback": {"blockReason": "SAFETY"}},
    )))
    with pytest.raises(ValueError, match=r"Gemini blocked this request \(SAFETY\)"):
        _run_stream(provider="gemini", model="gemini-2.5-flash")


def test_gemini_safety_finish_raises(mock_http) -> None:
    mock_http(lambda r: httpx.Response(200, content=_sse(
        {"candidates": [{"finishReason": "SAFETY"}]},
    )))
    with pytest.raises(ValueError, match=r"Gemini stopped the answer \(SAFETY\)"):
        _run_stream(provider="gemini", model="gemini-2.5-flash")


def test_stream_with_no_text_raises(mock_http) -> None:
    mock_http(lambda r: httpx.Response(200, content=b"data: [DONE]\n\n"))
    with pytest.raises(ValueError, match="OpenAI returned an empty answer"):
        _run_stream(provider="openai", model="gpt-4o")


def test_normal_stream_still_yields_deltas(mock_http) -> None:
    mock_http(lambda r: httpx.Response(200, content=_sse(
        {"choices": [{"delta": {"content": "Hello"}}]},
        {"choices": [{"delta": {"content": " there"}}]},
    ) + b"data: [DONE]\n\n"))
    assert _run_stream(provider="openai", model="gpt-4o") == ["Hello", " there"]


def test_server_stream_reports_provider_error_as_ndjson_error_line(mock_http) -> None:
    mock_http(lambda r: httpx.Response(200, content=_sse(
        {"type": "error", "error": {"type": "overloaded_error", "message": "Overloaded"}},
    )))
    client = TestClient(server.app, base_url="http://127.0.0.1:50711")
    resp = client.post("/assistant/stream", json={
        "text": "hi", "provider": "anthropic", "model": "m", "api_key": KEY,
    })
    assert resp.status_code == 200
    lines = [json.loads(line) for line in resp.text.splitlines() if line]
    assert lines == [{"error": "Anthropic is overloaded — try again in a moment."}]
