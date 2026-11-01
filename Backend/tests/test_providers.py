"""Each provider's request shape and error text, through the registry. Every
HTTP call is answered by a mock transport — nothing touches the network."""

from __future__ import annotations

import asyncio
import base64
import json

import httpx
import pytest

from flowy import providers

KEY = "sk-test"
AUDIO = base64.b64encode(b"\0" * 8_000).decode()


@pytest.fixture
def mock_http(monkeypatch):
    seen: list[httpx.Request] = []
    state: dict = {}
    real_client = httpx.AsyncClient

    def factory(*args, **kwargs):
        def handle(request: httpx.Request) -> httpx.Response:
            seen.append(request)
            return state["handler"](request)

        kwargs["transport"] = httpx.MockTransport(handle)
        return real_client(*args, **kwargs)

    monkeypatch.setattr(httpx, "AsyncClient", factory)

    def install(handler):
        state["handler"] = handler
        return seen

    return install


def _openai_reply(_request) -> httpx.Response:
    return httpx.Response(200, json={"choices": [{"message": {"content": " ok "}}]})


def test_openai_uses_max_completion_tokens(mock_http) -> None:
    seen = mock_http(_openai_reply)
    assert asyncio.run(providers.answer("hi", "openai", "gpt-x", KEY, system_prompt="sys")) == "ok"
    body = json.loads(seen[0].content)
    assert str(seen[0].url) == "https://api.openai.com/v1/chat/completions"
    assert body == {"model": "gpt-x", "max_completion_tokens": 1024, "messages": [
        {"role": "system", "content": "sys"}, {"role": "user", "content": "hi"}]}
    assert seen[0].headers["authorization"] == f"Bearer {KEY}"


def test_openai_compatible_uses_base_url_and_max_tokens(mock_http) -> None:
    seen = mock_http(_openai_reply)
    asyncio.run(providers.answer("hi", "openai_compatible", "m", KEY,
                                 base_url="http://localhost:11434/v1/", max_tokens=7))
    assert str(seen[0].url) == "http://localhost:11434/v1/chat/completions"
    assert json.loads(seen[0].content)["max_tokens"] == 7


def test_openai_compatible_requires_a_base_url(mock_http) -> None:
    mock_http(_openai_reply)
    for call in (providers.answer("hi", "openai_compatible", "m", KEY),
                 providers.list_models("openai_compatible", KEY),
                 providers.transcribe_audio("openai_compatible", "m", KEY, AUDIO)):
        with pytest.raises(ValueError, match="base_url is required for openai_compatible"):
            asyncio.run(call)


def test_anthropic_body_and_images(mock_http) -> None:
    seen = mock_http(lambda r: httpx.Response(200, json={"content": [{"text": "yo"}]}))
    images = [{"media_type": "image/png", "data": "QUJD"}]
    assert asyncio.run(providers.answer("hi", "anthropic", "c", KEY, system_prompt="s",
                                        images=images)) == "yo"
    body = json.loads(seen[0].content)
    assert list(body) == ["model", "max_tokens", "messages", "system"]
    assert body["messages"][0]["content"][0]["source"]["data"] == "QUJD"
    assert seen[0].headers["anthropic-version"] == "2023-06-01"


def test_non_2xx_names_the_provider(mock_http) -> None:
    mock_http(lambda r: httpx.Response(401, text="bad key"))
    with pytest.raises(ValueError, match=r"^anthropic request failed \(401\): bad key$"):
        asyncio.run(providers.answer("hi", "anthropic", "c", KEY))
    with pytest.raises(ValueError, match=r"^openai_compatible request failed \(401\)"):
        asyncio.run(providers.list_models("openai_compatible", KEY, "https://x.example/v1"))


def test_openai_model_list_keeps_chat_models_only(mock_http) -> None:
    mock_http(lambda r: httpx.Response(200, json={"data": [
        {"id": "gpt-4o"}, {"id": "text-embedding-3"}, {"id": "o3"}]}))
    assert asyncio.run(providers.list_models("openai", KEY)) == ["o3", "gpt-4o"]
    assert asyncio.run(providers.list_models("openai_compatible", KEY, "https://x/v1")) == [
        "text-embedding-3", "o3", "gpt-4o"]


def test_local_is_not_a_model_list_provider() -> None:
    with pytest.raises(ValueError, match="Missing api_key"):
        asyncio.run(providers.list_models("local", ""))
    with pytest.raises(ValueError, match="Unknown provider: local"):
        asyncio.run(providers.list_models("local", "hf_token"))


def test_anthropic_cannot_transcribe(mock_http) -> None:
    seen = mock_http(_openai_reply)
    with pytest.raises(ValueError, match="Anthropic models do not accept audio input"):
        asyncio.run(providers.transcribe_audio("anthropic", "c", KEY, AUDIO))
    assert seen == []


def test_openai_transcription_prefers_the_dedicated_endpoint(mock_http) -> None:
    def handler(request):
        if request.url.path.endswith("/audio/transcriptions"):
            return httpx.Response(200, text=" spoken words ")
        return _openai_reply(request)

    seen = mock_http(handler)
    text, prompt = asyncio.run(providers.transcribe_audio(
        "openai", "gpt-4o-mini-audio", KEY, AUDIO, vocab_hint="Slive"))
    assert text == "spoken words"
    assert prompt.endswith("\n\nSlive")
    assert b'gpt-4o-mini-transcribe' in seen[0].content


def test_openai_transcription_falls_back_to_guarded_chat(mock_http) -> None:
    def handler(request):
        if request.url.path.endswith("/audio/transcriptions"):
            return httpx.Response(404, text="nope")
        return httpx.Response(200, json={"choices": [{"message": {
            "content": "Please provide the audio file."}}]})

    seen = mock_http(handler)
    with pytest.raises(ValueError, match="replied about transcribing"):
        asyncio.run(providers.transcribe_audio("openai", "gpt-audio", KEY, AUDIO))
    # gpt-4o-transcribe, whisper-1, then the chat fallback.
    assert [r.url.path.rsplit("/", 1)[-1] for r in seen] == [
        "transcriptions", "transcriptions", "completions"]


def test_local_provider_runs_local_infer(monkeypatch) -> None:
    from flowy import local_infer

    calls = []

    def fake_chat(*args):
        calls.append(args)
        return ""

    monkeypatch.setattr(local_infer, "chat", fake_chat)
    images = [{"media_type": "image/png", "data": "QUJD"}]
    assert asyncio.run(providers.answer("hi", "local", "a/b", "", images=images)) == ""
    assert calls[0] == ("a/b", None, "", [], "hi", ["QUJD"], 1024, True, local_infer.DEFAULT_MEM_GB)

    async def collect():
        return [d async for d in providers.answer_stream("hi", "local", "a/b", "")]

    with pytest.raises(ValueError, match="^The local model returned an empty answer — try again.$"):
        asyncio.run(collect())


def test_local_transcription_appends_the_vocabulary(monkeypatch) -> None:
    from flowy import local_infer

    seen = {}

    def fake_transcribe(*args):
        seen["args"] = args
        return "words"

    monkeypatch.setattr(local_infer, "transcribe", fake_transcribe)
    text, prompt = asyncio.run(providers.transcribe_audio(
        "local", "a/b", "", AUDIO, vocab_hint="Slive", prompt_override="  Mine  "))
    assert (text, prompt) == ("words", "Mine\n\nSlive")
    assert seen["args"][-1] == prompt and seen["args"][4] == 448
