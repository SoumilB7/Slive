"""3-way consensus labeler: selection logic, request shape, retries, fallback
and fatal-key mapping. Every OpenAI call is served by a mock transport —
nothing here touches the network."""

import asyncio
import base64
import io
import re

import httpx
import numpy as np
import pytest
import soundfile as sf
from fastapi.testclient import TestClient

from flowy import label_consensus as lc
from flowy import server

KEY = "sk-test-consensus-key"


def _wav_b64(seconds: float = 0.5) -> str:
    out = io.BytesIO()
    sf.write(out, np.zeros(int(16_000 * seconds), dtype="float32"), 16_000,
             format="WAV", subtype="FLOAT")
    return base64.b64encode(out.getvalue()).decode()


AUDIO = _wav_b64()


def _fields(request: httpx.Request) -> list[tuple[str, str]]:
    """Plain (non-file) multipart fields of a recorded request, in order."""
    body = request.content.decode("latin-1")
    return re.findall(r'name="([^"]+)"\r\n\r\n(.*?)\r\n--', body, flags=re.S)


def _model(request: httpx.Request) -> str:
    return dict(_fields(request))["model"]


@pytest.fixture
def mock_openai(monkeypatch):
    """Route every httpx call to ``handler(model, request)``; no backoff waits."""
    seen: list[httpx.Request] = []
    state: dict = {}
    real_client = httpx.AsyncClient

    def transport_handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return state["handler"](_model(request), request)

    def factory(*args, **kwargs):
        kwargs["transport"] = httpx.MockTransport(transport_handler)
        return real_client(*args, **kwargs)

    async def no_sleep(_seconds: float) -> None:
        return None

    monkeypatch.setattr(httpx, "AsyncClient", factory)
    monkeypatch.setattr(lc, "_sleep", no_sleep)

    def install(handler):
        state["handler"] = handler
        return seen

    return install


def _replies(**by_model):
    """Handler answering each model with a fixed text (or a Response)."""
    def handler(model, _request):
        reply = by_model[model.replace("-", "_")]
        return reply if isinstance(reply, httpx.Response) else httpx.Response(200, json={"text": reply})
    return handler


def _label(**kwargs):
    kwargs.setdefault("api_key", KEY)
    kwargs.setdefault("audio_b64", AUDIO)
    return asyncio.run(lc.label(**kwargs))


# --- Pure selection ----------------------------------------------------------

def test_medoid_outvotes_the_odd_one_out() -> None:
    text, chosen, agreement = lc.choose({
        "gpt-transcribe": "Ship the build today.",           # truncated
        "whisper-1": "Ship the build today and tell Asha.",
        "typed": "ship the build today and tell asha",
    })
    assert chosen == "whisper-1"
    assert text == "Ship the build today and tell Asha."
    assert 0 < agreement < 1


def test_same_words_keep_the_best_formatting() -> None:
    text, chosen, agreement = lc.choose({
        "gpt-transcribe": "Okay, open the z-docs folder.",
        "whisper-1": "okay open the z docs folder",
        "typed": "Okay open the z docs folder.",
    })
    assert chosen == "gpt-transcribe"
    assert text == "Okay, open the z-docs folder."
    assert agreement == 1.0


def test_style_tie_break_prefers_whisper_over_typed() -> None:
    _, chosen, _ = lc.choose({
        "gpt-transcribe": "Totally different words here.",
        "whisper-1": "Run the tests now.",
        "typed": "run the tests now",
    })
    assert chosen == "whisper-1"


def test_two_candidates_never_pick_typed() -> None:
    _, chosen, agreement = lc.choose({"whisper-1": "Run it.", "typed": "Run it twice please."})
    assert chosen == "whisper-1"
    assert agreement < 1


def test_normalize_words_treats_hyphens_as_spaces() -> None:
    assert lc.normalize_words("Sub-agent’s GPT-6, OK?") == ["sub", "agent's", "gpt", "6", "ok"]


def test_hotword_parsing_matches_the_app() -> None:
    raw = "OnFinance, z-docs\n  Argo   CD ,onfinance,,<script>, cos-mp-agent\r\n"
    assert lc.parse_hotwords(raw) == ["OnFinance", "z-docs", "Argo CD", "cos-mp-agent"]
    assert lc.parse_hotwords(["Claude", "a, b", "claude", "x>y"]) == ["Claude", "a", "b"]
    assert lc.parse_hotwords("") == [] and lc.parse_hotwords(None) == []


def test_prompt_has_generic_line_and_user_context() -> None:
    assert lc.compose_prompt("") == lc.DEFAULT_CONTEXT
    assert lc.compose_prompt("  An engineer   at OnFinance. ").endswith("An engineer at OnFinance.")


# --- Calls -------------------------------------------------------------------

def test_request_fields_for_both_models(mock_openai) -> None:
    seen = mock_openai(_replies(gpt_transcribe="Hello there.", whisper_1="hello there"))
    result = _label(typed="Hello there", hotwords="OnFinance, z-docs", context="Engineer.")

    assert result["text"] == "Hello there." and result["chosen"] == "gpt-transcribe"
    assert set(result["candidates"]) == {"gpt-transcribe", "whisper-1", "typed"}
    by_model = {_model(r): _fields(r) for r in seen}
    gpt = by_model["gpt-transcribe"]
    assert ("languages[]", "en") in gpt and ("response_format", "json") in gpt
    assert [v for k, v in gpt if k == "keywords[]"] == ["OnFinance", "z-docs"]
    assert dict(gpt)["prompt"] == f"{lc.DEFAULT_CONTEXT} Engineer."
    whisper = dict(by_model["whisper-1"])
    assert whisper["language"] == "en" and "prompt" not in whisper
    assert "keywords: OnFinance, z-docs" in result["prompt"]
    for request in seen:
        assert request.headers["authorization"] == f"Bearer {KEY}"
        assert KEY not in str(request.url)


def test_float_wav_is_uploaded_as_16_bit(mock_openai) -> None:
    seen = mock_openai(_replies(gpt_transcribe="Hi.", whisper_1="Hi."))
    _label()
    body = seen[0].content
    wav = body[body.index(b"RIFF"):]
    info = sf.info(io.BytesIO(wav))
    assert info.subtype == "PCM_16"


def test_rate_limit_and_5xx_are_retried(mock_openai) -> None:
    calls = {"gpt-transcribe": 0, "whisper-1": 0}

    def handler(model, _request):
        calls[model] += 1
        if calls[model] == 1:
            return httpx.Response(429 if model == "whisper-1" else 503, json={"error": {}})
        return httpx.Response(200, json={"text": "Same words."})

    mock_openai(handler)
    assert _label()["text"] == "Same words."
    assert calls == {"gpt-transcribe": 2, "whisper-1": 2}


def test_one_failed_call_falls_back_to_the_other(mock_openai) -> None:
    calls = {"whisper-1": 0}

    def handler(model, _request):
        if model == "whisper-1":
            calls["whisper-1"] += 1
            return httpx.Response(500, text="boom")
        return httpx.Response(200, json={"text": "Deploy to staging."})

    mock_openai(handler)
    result = _label(typed="deploy to staging please")
    assert calls["whisper-1"] == 1 + lc.MAX_RETRIES
    assert result["chosen"] == "gpt-transcribe" and result["text"] == "Deploy to staging."
    assert set(result["candidates"]) == {"gpt-transcribe", "typed"}


def test_gpt_failure_falls_back_to_whisper(mock_openai) -> None:
    mock_openai(_replies(
        gpt_transcribe=httpx.Response(400, json={"error": {"message": "bad keyword"}}),
        whisper_1="Deploy to staging."))
    result = _label(typed="Deploy to staging.")
    assert result["chosen"] == "whisper-1"


def test_both_calls_failing_is_an_error_not_the_typed_text(mock_openai) -> None:
    mock_openai(lambda model, r: httpx.Response(500, text="down"))
    with pytest.raises(ValueError, match="Both transcribers failed"):
        _label(typed="what Slive typed")


def test_bad_key_is_fatal(mock_openai) -> None:
    mock_openai(lambda model, r: httpx.Response(401, json={"error": {"code": "invalid_api_key"}}))
    with pytest.raises(lc.LabelFatalError) as info:
        _label()
    assert info.value.kind == "auth"


def test_quota_is_fatal_and_not_retried(mock_openai) -> None:
    seen = mock_openai(lambda model, r: httpx.Response(
        429, json={"error": {"code": "insufficient_quota", "message": "You exceeded your quota"}}))
    with pytest.raises(lc.LabelFatalError) as info:
        _label()
    assert info.value.kind == "quota"
    assert len(seen) == 2  # one per model, no retries


# --- HTTP endpoint -----------------------------------------------------------

def _post(payload):
    client = TestClient(server.app, base_url="http://127.0.0.1:50711")
    return client.post("/label_consensus", json={"api_key": KEY, "audio_b64": AUDIO, **payload})


def test_endpoint_returns_label_and_inspection_fields(mock_openai) -> None:
    mock_openai(_replies(gpt_transcribe="Open z-docs.", whisper_1="open z docs"))
    resp = _post({"typed": "Open z docs.", "hotwords": ["z-docs"]})
    assert resp.status_code == 200
    body = resp.json()
    assert body["text"] == "Open z-docs." and body["chosen"] == "gpt-transcribe"
    assert body["agreement"] == 1.0
    assert set(body) >= {"text", "chosen", "agreement", "candidates", "prompt"}


def test_endpoint_maps_fatal_errors_distinctly(mock_openai) -> None:
    mock_openai(lambda model, r: httpx.Response(403, json={"error": {}}))
    resp = _post({})
    assert resp.status_code == 401
    assert resp.json()["fatal"] == "auth"


def test_endpoint_reports_per_clip_failure_as_400(mock_openai) -> None:
    mock_openai(lambda model, r: httpx.Response(500, text="down"))
    resp = _post({})
    assert resp.status_code == 400
    assert "fatal" not in resp.json()


def test_endpoint_rejects_truncated_audio() -> None:
    resp = _post({"audio_b64": base64.b64encode(b"\0" * 100).decode()})
    assert resp.status_code == 400
