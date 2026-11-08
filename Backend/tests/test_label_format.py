"""Step 4 of Slive Custom 4: cue detection, the verifier's edit classes, the
skip rule, the request shape and error mapping, and the store's target
option. Every OpenAI call is served by a mock transport — nothing here
touches the network."""

import asyncio
import json
import struct
import wave
from pathlib import Path

import httpx
import pytest
from fastapi.testclient import TestClient

from flowy import label_format as lf
from flowy import server
from flowy.training.store import LabelPolicy, TargetStyle, TrainingStore

KEY = "sk-test-format-key"

# Real labels from the formatter bench (Nov 9 2026) with the replies it kept.
THREE_THINGS = (
    "Okay, so there are three things I want you to do. One, please write all of the context you have "
    "into the Z docs and obviously update any stale context over there. Two, I want you to understand "
    "where we are right now because this exact cluster would be facing the production traffic tonight "
    "after we switch the ingress. So what I want you to do is compare everything from the prod cluster "
    "and find me every possible nook and cranny that it can go wrong within this cluster and everything. "
    "I want you to be able to perfectly be ready with it. Yeah, that's all. The third thing is mainly just "
    "keep me in the loop and keep writing small concise summaries of what you did so that I know what's "
    "happening.")
THREE_THINGS_OUT = (
    "Okay, so there are three things I want you to do:\n"
    "1. Please write all of the context you have into the z-docs and obviously update any stale context "
    "over there.\n"
    "2. I want you to understand where we are right now because this exact cluster would be facing the "
    "production traffic tonight after we switch the ingress. So what I want you to do is compare everything "
    "from the prod cluster and find me every possible nook and cranny that it can go wrong within this "
    "cluster and everything. I want you to be able to perfectly be ready with it. Yeah, that's all.\n"
    "3. Mainly just keep me in the loop and keep writing small concise summaries of what you did so that I "
    "know what's happening.")
LIKE_FILLER = (
    "Take a look. It didn't, like, as in I think the last message didn't get copied well enough. Point one. "
    "Point two being, you see the token that is used up in that, the token context for that, for example, "
    "is completely empty.")
LIKE_FILLER_OUT = (
    "Take a look. It didn't, as in, I think the last message didn't get copied well enough. Point one. "
    "Point two being, you see the token that is used up in that, the token context for that, for example, "
    "is completely empty.")


# --- 4.1 Structure flag ------------------------------------------------------

@pytest.mark.parametrize("label", [
    "there are three things I want you to check",
    "a few issues with the build today",
    "first fix the build and then second ship the release",
    "one, open the doc. two, read it",
    "number one is the cluster",
    "new paragraph thanks for the help",
    "see the api, the client, the store and the tests",
    "word " * 100,
])
def test_cues_allow_structure(label) -> None:
    assert lf.structure_allowed(label)


@pytest.mark.parametrize("label", [
    "set the timeout to 99 seconds",
    "I like this approach a lot",
    "it is the first time I see this",
    "two of them failed",
])
def test_no_cue_no_structure(label) -> None:
    assert not lf.structure_allowed(label)


# --- 4.3 Verifier ------------------------------------------------------------

def test_a_swapped_word_is_rejected() -> None:
    status = lf.verify("we should look at the compaction logic before the release goes out today",
                       "We should look at the refactoring logic before the release goes out today.", False)
    assert status == "rejected:swapped 'compaction'→'refactoring'"


def test_html_and_headings_are_rejected() -> None:
    label = "three things fix the build update the docs and ship the release"
    assert lf.verify(label, "<ul><li>Fix the build</li></ul>", True) == "rejected:html-or-heading"
    assert lf.verify(label, "# Three things\nFix the build", True) == "rejected:html-or-heading"


def test_a_list_of_two_is_rejected() -> None:
    label = "two things first fix the build second ship the release"
    out = "Two things:\n1. Fix the build\n2. Ship the release"
    assert lf.verify(label, out, True) == "rejected:list-under-3-items"


def test_newlines_without_a_cue_are_rejected() -> None:
    label = "fix the build please and then ship the release to staging"
    assert lf.verify(label, "Fix the build, please.\nThen ship the release to staging.", False) \
        == "rejected:structure-not-allowed"


def test_list_with_item_lead_words_is_accepted() -> None:
    assert lf.structure_allowed(THREE_THINGS)
    assert lf.verify(THREE_THINGS, THREE_THINGS_OUT, True) == "formatted"   # "the third thing is" dropped


def test_restart_is_accepted() -> None:
    label = "we want the migration to be only be done on the staging cluster first this week"
    out = "We want the migration to only be done on the staging cluster first this week."
    assert lf.verify(label, out, False) == "formatted"


def test_comma_like_filler_is_accepted() -> None:
    assert lf.verify(LIKE_FILLER, LIKE_FILLER_OUT, lf.structure_allowed(LIKE_FILLER)) == "formatted"


def test_meaningful_like_is_kept() -> None:
    label = ("I think the strength is needing it, but it definitely is like a bigger muscle going all "
             "the way through the arm and the wrist.")
    out = ("I think the strength is needing it, but it definitely is a bigger muscle going all "
           "the way through the arm and the wrist.")
    assert lf.verify(label, out, False) == "rejected:deleted 'like'"


TAIL = " and then we can look at the dashboards together tomorrow morning with the whole team"


def test_other_edit_classes() -> None:
    assert lf.verify("um so we uh ship it on friday after the review" + TAIL,
                     "So we ship it on Friday after the review" + TAIL + ".", False) == "formatted"   # filler
    assert lf.verify("set the timeout to 90 no sorry 99 seconds" + TAIL,
                     "Set the timeout to 99 seconds" + TAIL + ".", False) == "formatted"   # self-correction
    assert lf.verify("bump the learning rate to point three for the next run" + TAIL,
                     "Bump the learning rate to 0.3 for the next run" + TAIL + ".", False) == "formatted"
    assert lf.verify("open the file config dot json" + TAIL,
                     "Open the file config.json" + TAIL + ".", False) == "formatted"   # spoken symbol
    assert lf.verify("ship it.", "Ship it.", False) == "formatted"
    assert lf.verify("Ship it.", "Ship it.", False) == "unchanged"
    assert lf.verify("we ship the build today", "We ship the build today and tell Asha.", False) \
        == "rejected:added 'and tell asha'"
    long_label = "please fix it now " * 5
    assert lf.verify(long_label, "Fix it now.", False).startswith("rejected:")


def test_number_forms() -> None:
    assert lf.num_value(["point", "three"]) == lf.num_value(["0.3"])
    assert lf.num_value(["twenty", "percent"]) == ("20", True) == lf.num_value(["20%"])
    assert lf.num_value(["four", "point", "five"])[0] == "4.5"
    assert lf.num_value(["release"])[0] is None


@pytest.mark.parametrize("flag,label,out", lf.FEWSHOT)
def test_few_shot_examples_pass_the_verifier(flag, label, out) -> None:
    status = lf.verify(label, out, flag == "allowed")
    if label.startswith("set the timeout"):
        # The bench's own verifier (ported 1:1) passes every edit in this
        # one but rejects it on the 15% budget: a self-correction is 5 of
        # its 11 words. Longer labels with the same edit pass.
        assert status == "rejected:touched 5/11 words"
        assert lf.verify(label + TAIL * 2, out.rstrip(".") + TAIL * 2 + ".", False) == "formatted"
    else:
        assert status == "formatted"


# --- 4.0 Skip + 4.2 the call -------------------------------------------------

@pytest.fixture
def mock_openai(monkeypatch):
    """Route every httpx call to ``handler(request)``; no backoff waits."""
    seen: list[httpx.Request] = []
    state: dict = {}
    real_client = httpx.AsyncClient

    def transport_handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return state["handler"](request)

    def factory(*args, **kwargs):
        kwargs["transport"] = httpx.MockTransport(transport_handler)
        return real_client(*args, **kwargs)

    async def no_sleep(_seconds: float) -> None:
        return None

    monkeypatch.setattr(httpx, "AsyncClient", factory)
    monkeypatch.setattr(lf, "_sleep", no_sleep)

    def install(handler):
        state["handler"] = handler
        return seen

    return install


def _reply(text: str, usage: dict | None = None) -> httpx.Response:
    return httpx.Response(200, json={
        "choices": [{"message": {"content": json.dumps({"formatted": text})}}],
        "usage": usage or {"prompt_tokens": 1500, "completion_tokens": 250}})


def _format(**kwargs):
    kwargs.setdefault("api_key", KEY)
    return asyncio.run(lf.format_label(**kwargs))


def test_skip_rule() -> None:
    assert lf.should_skip(0.79, 10) and lf.should_skip(0.95, 3)
    assert not lf.should_skip(0.8, 4) and not lf.should_skip(None, 4)


def test_skipped_labels_make_no_call(mock_openai) -> None:
    seen = mock_openai(lambda r: _reply("never"))
    low = _format(label="Ship the build to staging today.", agreement=0.5)
    short = _format(label="Ship it now.", agreement=1.0)
    assert low == {"formatted": "Ship the build to staging today.", "status": "skipped", "model": "gpt-5.5",
                   "usage": {}}
    assert short["status"] == "skipped"
    assert seen == []


def test_request_shape(mock_openai) -> None:
    seen = mock_openai(lambda r: _reply("Do it, add the commit."))
    result = _format(label="do it add the commit", agreement=0.97,
                     hotwords=" OnFinance, z-docs \n", word_count=5)
    assert result["status"] == "formatted" and result["formatted"] == "Do it, add the commit."
    assert result["usage"]["prompt_tokens"] == 1500
    (request,) = seen
    assert str(request.url) == lf.CHAT_URL
    assert request.headers["authorization"] == f"Bearer {KEY}"
    body = json.loads(request.content)
    assert set(body) == {"model", "messages", "response_format"}   # nothing gpt-5.5 might refuse
    assert body["model"] == "gpt-5.5"
    assert body["response_format"]["json_schema"]["schema"]["required"] == ["formatted"]
    messages = body["messages"]
    assert messages[0] == {"role": "system", "content": lf.SYSTEM}
    assert len(messages) == 1 + 2 * len(lf.FEWSHOT) + 1
    assert json.loads(messages[2]["content"]) == {"formatted": lf.FEWSHOT[0][2]}
    assert messages[-1]["content"] == (
        "STRUCTURE: not allowed\n"
        "CUSTOM WORDS (spell exactly like this; never introduce one that wasn't said):\n"
        "OnFinance, z-docs\n<transcript>\ndo it add the commit\n</transcript>")


def test_a_rejected_format_keeps_the_plain_label(mock_openai) -> None:
    mock_openai(lambda r: _reply("We should look at the refactoring logic today."))
    result = _format(label="we should look at the compaction logic today", agreement=0.9)
    assert result["status"].startswith("rejected:swapped")
    assert result["formatted"] == "we should look at the compaction logic today"


def test_rate_limit_and_5xx_are_retried(mock_openai) -> None:
    calls = iter([httpx.Response(429, json={}), httpx.Response(503, text="busy"), _reply("Ship it today.")])
    seen = mock_openai(lambda r: next(calls))
    assert _format(label="ship it today please", agreement=1.0)["status"] == "rejected:deleted 'please'"
    assert len(seen) == 3


def test_bad_key_and_quota_are_fatal(mock_openai) -> None:
    mock_openai(lambda r: httpx.Response(401, json={"error": {}}))
    with pytest.raises(lf.LabelFatalError) as info:
        _format(label="ship the build to staging", agreement=1.0)
    assert info.value.kind == "auth"
    seen = mock_openai(lambda r: httpx.Response(429, json={"error": {"code": "insufficient_quota"}}))
    with pytest.raises(lf.LabelFatalError) as info:
        _format(label="ship the build to staging", agreement=1.0)
    assert info.value.kind == "quota" and len(seen) == 2   # one call above, one here: no retries


def test_a_bad_request_fails_this_clip_only(mock_openai) -> None:
    seen = mock_openai(lambda r: httpx.Response(400, json={"error": {"message": "bad"}}))
    with pytest.raises(ValueError, match="Formatter failed"):
        _format(label="ship the build to staging", agreement=1.0)
    assert len(seen) == 1


# --- HTTP endpoint -----------------------------------------------------------

def _post(payload):
    client = TestClient(server.app, base_url="http://127.0.0.1:50711")
    return client.post("/label_format", json={"api_key": KEY, **payload})


def test_endpoint_formats(mock_openai) -> None:
    mock_openai(lambda r: _reply("Okay, so I wanna run the tests on staging."))
    resp = _post({"label": "okay so I wanna run the the tests on staging", "hotwords": "z-docs",
                  "agreement": 0.9, "word_count": 10})
    assert resp.status_code == 200
    assert resp.json() == {"formatted": "Okay, so I wanna run the tests on staging.", "status": "formatted",
                           "model": "gpt-5.5"}


def test_endpoint_skips_without_a_key(mock_openai) -> None:
    seen = mock_openai(lambda r: _reply("never"))
    resp = TestClient(server.app, base_url="http://127.0.0.1:50711").post(
        "/label_format", json={"label": "Do it.", "agreement": 1.0})
    assert resp.status_code == 200 and resp.json()["status"] == "skipped" and seen == []


def test_endpoint_error_mapping(mock_openai) -> None:
    mock_openai(lambda r: httpx.Response(403, json={"error": {}}))
    resp = _post({"label": "ship the build to staging", "agreement": 1.0})
    assert resp.status_code == 401 and resp.json()["fatal"] == "auth"
    mock_openai(lambda r: httpx.Response(500, text="down"))
    resp = _post({"label": "ship the build to staging", "agreement": 1.0})
    assert resp.status_code == 400 and "fatal" not in resp.json()


def test_endpoint_serves_the_instruction() -> None:
    resp = TestClient(server.app, base_url="http://127.0.0.1:50711").get("/label_format/prompt")
    assert resp.status_code == 200 and resp.json()["prompt"] == lf.SYSTEM


# --- Store target option -----------------------------------------------------

def _write_wav(path: Path, seconds: float) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    frames = int(seconds * 16_000)
    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(16_000)
        handle.writeframes(struct.pack("<" + "h" * frames, *([0] * frames)))


def test_store_target_style(tmp_path: Path) -> None:
    root = tmp_path / "training"
    spoken = "three things fix the build update the docs and ship the release"
    plain = "Three things: fix the build, update the docs and ship the release."
    formatted = "Three things:\n- Fix the build\n- Update the docs\n- Ship the release"
    base = {"createdAt": "2026-11-09T10:00:00Z", "transcript": spoken, "finalText": "", "edited": False,
            "confidence": "audio", "llmTranscript": plain, "llmModel": "consensus · gpt-transcribe",
            "llmAgreement": 0.95}
    rows = {
        "done": {"llmFormatted": formatted, "llmFormatStatus": "formatted", "llmFormatModel": "gpt-5.5"},
        "rejected": {"llmFormatted": plain, "llmFormatStatus": "rejected:list-under-3-items",
                     "llmFormatModel": "gpt-5.5"},
        "old": {},
        "human": {"finalText": "Fix the build.", "llmFormatted": formatted, "llmFormatStatus": "formatted"},
    }
    for seconds, name in enumerate(rows, start=1):
        _write_wav(root / "audio" / f"{name}.wav", float(seconds))
    with (root / "samples.jsonl").open("w", encoding="utf-8") as handle:
        for name, extra in rows.items():
            handle.write(json.dumps({"id": name, "audioFile": f"audio/{name}.wav", **base, **extra}) + "\n")

    store = TrainingStore(root)
    default = {s.id: s for s in store.inspect(label_policy=LabelPolicy.BEST_AVAILABLE).eligible_samples}
    assert {s.reference_text for k, s in default.items() if k != "human"} == {plain}   # plain by default
    styled = {s.id: s for s in store.inspect(label_policy=LabelPolicy.BEST_AVAILABLE,
                                             target_style=TargetStyle.FORMATTED).eligible_samples}
    assert (styled["done"].reference_text, styled["done"].label_source) == (formatted, "llmFormatted")
    assert styled["rejected"].reference_text == plain and styled["old"].reference_text == plain
    assert styled["human"].reference_text == "Fix the build."
