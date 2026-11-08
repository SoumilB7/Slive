"""Ground-truth labels for every recipe the app can pick, through the real
routes and labelers with only OpenAI's wire faked: each degraded candidate
set (gpt-transcribe / whisper-1 failing in every way, typed present or
empty), the format step's gate × key × upstream outcome, and the request
shapes the app sends. A route answers a well-formed result or a documented
error — never a 500, never a hang."""

from __future__ import annotations

import base64
import json
import re

import httpx
import pytest

from flowy import label_consensus as lc
from flowy import label_format as lf
from flowy import local_infer
from flowy.providers import default_registry
from matrix_support import (
    AUDIO,
    Wire,
    assert_error,
    fake_for,
    swift_enum_cases,
    swift_source,
    wire_handler,
)
from test_label_consensus import _model

pytestmark = pytest.mark.usefixtures("deadline")

KEY = "sk-test-labels"

#: The routes each GroundTruthRecipe drives, in order (LabelRun.swift:
#: ``consensusJob`` for the consensus recipes, ``singleText`` for single).
RECIPES = {
    "consensusFormat": ("/label_consensus", "/label_format"),
    "consensus": ("/label_consensus",),
    "single": ("/transcribe_llm",),
}
CONSENSUS_RECIPES = [r for r, steps in RECIPES.items() if "/label_consensus" in steps]

TEXTS = {lc.GPT_TRANSCRIBE: "Deploy to staging now, please.",
         lc.WHISPER: "deploy to staging now please"}

#: How one hosted transcriber can answer.
OUTCOMES = {
    "ok": lambda model: httpx.Response(200, json={"text": TEXTS[model]}),
    "fail": lambda model: httpx.Response(500, text="upstream down"),  # retried, then gives up
    "empty": lambda model: httpx.Response(200, json={"text": "  "}),
    "garbled": lambda model: httpx.Response(200, text="<html>not json</html>"),
    "auth": lambda model: httpx.Response(401, json={"error": {"code": "invalid_api_key"}}),
    "quota": lambda model: httpx.Response(429, json={"error": {"code": "insufficient_quota"}}),
}
FATAL = {"auth", "quota"}
TYPED = {"none": "", "blank": "   ", "typed": "Deploy to staging now please"}


def _transcript_in(request: httpx.Request) -> str:
    """The label the formatter was asked about (last user turn)."""
    content = json.loads(request.content)["messages"][-1]["content"]
    return re.search(r"<transcript>\n(.*)\n</transcript>", content, flags=re.S).group(1)


def _chat(content: str) -> httpx.Response:
    return httpx.Response(200, json={"choices": [{"message": {"content": content}}],
                                     "usage": {"prompt_tokens": 1}})


def _openai(gpt: str = "ok", whisper: str = "ok", fmt: str = "echo"):
    """OpenAI as both labelers see it: /audio/transcriptions per model, and
    the formatter's /chat/completions (``echo`` = returns the label as is)."""

    def handle(request: httpx.Request) -> httpx.Response:
        if request.url.path.endswith("/chat/completions"):
            return FORMAT_REPLIES[fmt](_transcript_in(request))
        model = _model(request)
        return OUTCOMES[gpt if model == lc.GPT_TRANSCRIBE else whisper](model)

    return handle


def _consensus_body(**overrides) -> dict:
    """LabelsAPI.Consensus.Body as the app encodes it."""
    return {"api_key": KEY, "audio_b64": AUDIO, "media_type": "audio/wav", "typed": "",
            "hotwords": "OnFinance, z-docs", "context": "An engineer.", "base_prompt": "",
            **overrides}


def _format_body(result: dict, **overrides) -> dict:
    """LabelsAPI.Format.Body from a consensus result, as ``consensusJob`` sends it."""
    return {"api_key": KEY, "label": result["text"], "hotwords": "OnFinance, z-docs",
            "agreement": result["agreement"], "word_count": len(result["text"].split()),
            **overrides}


def _assert_consensus_result(body: dict) -> None:
    """What LabelsAPI.Consensus.decodeResult accepts (and the store keeps)."""
    assert set(body) == {"text", "chosen", "agreement", "unconfirmed", "candidates", "prompt"}
    assert isinstance(body["text"], str) and body["text"].strip()
    assert body["chosen"] in body["candidates"] and body["chosen"] != lc.TYPED
    assert isinstance(body["agreement"], float) and 0.0 <= body["agreement"] <= 1.0
    assert all(isinstance(w, str) for w in body["unconfirmed"])
    assert all(isinstance(t, str) and t for t in body["candidates"].values())
    assert isinstance(body["prompt"], str) and body["prompt"]


def _assert_format_result(body: dict) -> None:
    """What LabelsAPI.Format.decodeResult accepts."""
    assert set(body) == {"formatted", "status", "model"}
    assert body["formatted"].strip() and body["model"] == lf.MODEL
    assert body["status"] in ("formatted", "unchanged", "skipped") or body["status"].startswith(
        "rejected:")


# --- completeness ----------------------------------------------------------------

def test_every_app_recipe_is_covered() -> None:
    source = swift_source("Training/LabelRun.swift")
    if source is None:
        pytest.skip("Frontend sources not present")
    assert set(swift_enum_cases(source, "GroundTruthRecipe")) == set(RECIPES)


# --- consensus recipes × every candidate set --------------------------------------

@pytest.mark.parametrize("typed", TYPED)
@pytest.mark.parametrize("whisper", OUTCOMES)
@pytest.mark.parametrize("gpt", OUTCOMES)
@pytest.mark.parametrize("recipe", CONSENSUS_RECIPES)
def test_consensus_recipe_candidate_sets(real_client, fake_http, recipe, gpt, whisper, typed):
    fake_http(_openai(gpt, whisper))
    resp = real_client.post("/label_consensus", json=_consensus_body(typed=TYPED[typed]))

    fatal = next((o for o in (gpt, whisper) if o in FATAL), None)
    heard = [m for m, o in ((lc.GPT_TRANSCRIBE, gpt), (lc.WHISPER, whisper)) if o == "ok"]
    if fatal:
        assert_error(resp, 401)
        assert resp.json()["fatal"] == fatal  # the app stops the whole run
        return
    if not heard:
        assert assert_error(resp, 400).startswith("Both transcribers failed — ")
        assert "fatal" not in resp.json()  # this clip only; the run goes on
        return

    assert resp.status_code == 200, resp.text
    result = resp.json()
    _assert_consensus_result(result)
    expected = heard + ([lc.TYPED] if TYPED[typed].strip() else [])
    assert list(result["candidates"]) == expected
    assert result["chosen"] == heard[0]  # gpt-transcribe, else whisper-1; typed never labels
    assert result["text"] == TEXTS[heard[0]]
    if len(expected) == 1:
        assert result["agreement"] == 0.0 and result["unconfirmed"] == []

    if "/label_format" not in RECIPES[recipe]:
        return
    resp = real_client.post("/label_format", json=_format_body(result))
    assert resp.status_code == 200, resp.text
    formatted = resp.json()
    _assert_format_result(formatted)
    skip = result["agreement"] < lf.MIN_AGREEMENT or len(result["text"].split()) < lf.MIN_WORDS
    assert formatted["status"] == ("skipped" if skip else "unchanged")
    assert formatted["formatted"] == result["text"]


# --- the format step: gate × key × upstream ----------------------------------------

LABEL = "okay so run the the tests on staging"
FORMAT_REPLIES = {
    "echo": lambda label: _chat(json.dumps({"formatted": label})),
    "formatted": lambda label: _chat(json.dumps({"formatted": "Okay, so run the tests on staging."})),
    "unchanged": lambda label: _chat(json.dumps({"formatted": LABEL})),
    "rejected": lambda label: _chat(json.dumps({"formatted": "Okay, so run the tests on production."})),
    "unreadable": lambda label: _chat("Sure! Here is the formatted text."),
    "fail": lambda label: httpx.Response(503, text="overloaded"),
    "auth": lambda label: httpx.Response(403, json={"error": {}}),
    "quota": lambda label: httpx.Response(429, json={"error": {"code": "insufficient_quota"}}),
}
#: agreement: omitted = not a consensus label (no gate); else around the 0.8 bar.
AGREEMENTS = {"omitted": None, "below": 0.79, "at-bar": 0.8}
#: word_count: omitted = counted server-side (8); else around the 4-word bar.
WORD_COUNTS = {"counted": None, "three": 3, "four": 4}


@pytest.mark.parametrize("upstream", [k for k in FORMAT_REPLIES if k != "echo"])
@pytest.mark.parametrize("key", ["present", "missing"])
@pytest.mark.parametrize("words", WORD_COUNTS)
@pytest.mark.parametrize("agreement", AGREEMENTS)
def test_format_step(real_client, fake_http, agreement, words, key, upstream) -> None:
    seen = fake_http(lambda r: FORMAT_REPLIES[upstream](_transcript_in(r)))
    body = {"api_key": KEY if key == "present" else "", "label": LABEL, "hotwords": ""}
    if AGREEMENTS[agreement] is not None:
        body["agreement"] = AGREEMENTS[agreement]
    if WORD_COUNTS[words] is not None:
        body["word_count"] = WORD_COUNTS[words]
    resp = real_client.post("/label_format", json=body)

    count = len(LABEL.split()) if WORD_COUNTS[words] is None else WORD_COUNTS[words]
    gate = AGREEMENTS[agreement]
    if (gate is not None and gate < lf.MIN_AGREEMENT) or count < lf.MIN_WORDS:
        assert resp.json() == {"formatted": LABEL, "status": "skipped", "model": lf.MODEL}
        assert seen == []  # no paid call for a label training won't use
        return
    if key == "missing":
        assert_error(resp, 401)
        assert resp.json()["fatal"] == "auth"
        return
    if upstream in ("auth", "quota"):
        assert_error(resp, 401)
        assert resp.json()["fatal"] == upstream
    elif upstream in ("fail", "unreadable"):
        assert assert_error(resp, 400).startswith("Formatter failed — ")
    else:
        assert resp.status_code == 200, resp.text
        result = resp.json()
        _assert_format_result(result)
        assert result["status"].split(":")[0] == upstream
        if upstream == "rejected":
            assert result["formatted"] == LABEL  # a rejected format keeps the plain label


@pytest.mark.parametrize("label", ["", "   ", "two words"])
def test_format_step_with_too_short_a_label_is_skipped(real_client, fake_http, label) -> None:
    seen = fake_http(None)
    resp = real_client.post("/label_format", json={"label": label})
    assert (resp.status_code, resp.json()["status"]) == (200, "skipped")
    assert seen == []


# --- the single recipe: one provider's /transcribe_llm -------------------------------

PROVIDERS = default_registry().names()


@pytest.mark.parametrize("override", [None, "", "  Transcribe exactly.  "], ids=["default", "blank", "custom"])
@pytest.mark.parametrize("vocab", [None, "Words: OnFinance."], ids=["no-vocab", "vocab"])
@pytest.mark.parametrize("name", PROVIDERS)
def test_single_recipe(real_client, fake_http, monkeypatch, name, vocab, override) -> None:
    """GroundTruthClient.transcribe's body for every provider, vocabulary
    hint and prompt override: the prompt that comes back is the one used."""
    fake = fake_for(name)
    if isinstance(fake, Wire):
        fake_http(wire_handler(fake, key="present", reply="text", text="Spoken words."))
    else:
        fake_http(None)
        monkeypatch.setattr(local_infer, "transcribe", lambda *a, **k: "Spoken words.")
    body = {"provider": name, "model": "m", "api_key": KEY, "audio_b64": AUDIO,
            "media_type": "audio/wav", "vocab_hint": vocab, "prompt_override": override,
            **fake.extra}
    resp = real_client.post("/transcribe_llm", json=body)
    if isinstance(fake, Wire) and fake.audio is None:
        assert "do not accept audio" in assert_error(resp, 400)
        return
    assert resp.status_code == 200, resp.text
    result = resp.json()
    assert result["text"] == "Spoken words."
    prompt = result["prompt"]
    if override and override.strip():
        assert prompt.startswith(override.strip())
    if vocab:
        assert prompt.endswith(vocab)


# --- request shapes the app (or a hand-edited setting) can send -----------------------

def _b64(raw: bytes) -> str:
    return base64.b64encode(raw).decode()


CONSENSUS_SHAPES = {
    # name: (body overrides, expected status, check)
    "app-default": ({}, 200, None),
    "key-with-newline": ({"api_key": f"  {KEY}\n"}, 200, None),
    "no-key": ({"api_key": ""}, 401, "auth"),
    "key-with-control-char": ({"api_key": "sk\x07x"}, 422, None),
    "hotwords-as-list": ({"hotwords": ["OnFinance", "z-docs"]}, 200, None),
    "hotwords-with-markup": ({"hotwords": "<script>, OnFinance"}, 200, None),
    "hotwords-empty": ({"hotwords": ""}, 200, None),
    "custom-base-prompt": ({"base_prompt": "  Notes   for code. "}, 200, None),
    "long-context": ({"context": "word " * 500}, 200, None),
    "mp3-media-type": ({"media_type": "audio/mpeg"}, 200, None),
    "unknown-media-type": ({"media_type": "application/octet-stream"}, 200, None),
    "audio-not-base64": ({"audio_b64": "not base64!!"}, 400, None),
    "audio-truncated": ({"audio_b64": _b64(b"RIFF" + b"\0" * 100)}, 400, None),
    "audio-unreadable-but-long": ({"audio_b64": _b64(b"\x01" * 8_000)}, 200, None),
    "typed-only-whitespace": ({"typed": "\n\t "}, 200, None),
    "missing-optional-fields": ("minimal", 200, None),
}


@pytest.mark.parametrize("shape", CONSENSUS_SHAPES)
def test_consensus_request_shapes(real_client, fake_http, shape) -> None:
    seen = fake_http(_openai())
    overrides, status, fatal = CONSENSUS_SHAPES[shape]
    body = ({"api_key": KEY, "audio_b64": AUDIO} if overrides == "minimal"
            else _consensus_body(**overrides))
    resp = real_client.post("/label_consensus", json=body)
    if status != 200:
        assert_error(resp, status)
        assert resp.json().get("fatal") == fatal
        assert seen == []  # rejected before any paid call
        return
    assert resp.status_code == 200, resp.text
    result = resp.json()
    _assert_consensus_result(result)
    assert "<script>" not in result["prompt"]
    for request in seen:
        assert request.headers["authorization"] == f"Bearer {KEY}"
