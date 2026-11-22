"""The Gauntlet's server-side properties (G7): what must hold for ANY input,
not for the one example a review found. Hypothesis is derandomized, so the
same code gives the same verdict on every machine and every run.

Run alone: ``pytest -m gauntlet``. Known-red checks are strict xfails: they
stay red until the bug is fixed, and an unexpected pass fails the run, so the
marker has to come off with the fix.
"""

from __future__ import annotations

import json
import unicodedata

import pytest
from fastapi.testclient import TestClient
from hypothesis import HealthCheck, given, settings
from hypothesis import strategies as st
from test_http_api import FakeLocal, FakeTraining

from flowy import label_consensus, label_format
from flowy.api import Services, create_app
from flowy.providers import Gateway, default_registry
from flowy.settings import Settings
from flowy.training import jobs

pytestmark = pytest.mark.gauntlet

PROPERTY = settings(derandomize=True, deadline=None, max_examples=400,
                    suppress_health_check=[HealthCheck.function_scoped_fixture])

# --- F24: a spoken number is the number ---------------------------------------

_ONES = ("zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen "
         "fifteen sixteen seventeen eighteen nineteen").split()
_TENS = "_ _ twenty thirty forty fifty sixty seventy eighty ninety".split()


def _below_thousand(n: int, *, and_word: bool) -> list[str]:
    words: list[str] = []
    if n >= 100:
        words += [_ONES[n // 100], "hundred"]
        n %= 100
        if n and and_word:
            words.append("and")
    if n >= 20:
        words.append(_TENS[n // 10])
        n %= 10
        if n:
            words.append(_ONES[n])
    elif n or not words:
        if n or not words:
            words.append(_ONES[n]) if (n or not words) else None
    return words


def spell(n: int, *, and_word: bool = False) -> list[str]:
    """``n`` (0..999,999) the way people say it, as tokens."""
    if n == 0:
        return ["zero"]
    words: list[str] = []
    if n >= 1000:
        words += _below_thousand(n // 1000, and_word=and_word) + ["thousand"]
        n %= 1000
        if n and and_word and n < 100:
            words.append("and")
    if n:
        words += _below_thousand(n, and_word=and_word)
    return words


def test_spell_helper_is_itself_right():
    assert spell(0) == ["zero"]
    assert " ".join(spell(105, and_word=True)) == "one hundred and five"
    assert " ".join(spell(2020)) == "two thousand twenty"
    assert " ".join(spell(999_999)) == ("nine hundred ninety nine thousand "
                                         "nine hundred ninety nine")
    assert " ".join(spell(100_000)) == "one hundred thousand"


@PROPERTY
@given(st.integers(0, 999_999), st.booleans())
def test_f24_spelled_number_is_its_value(n, and_word):
    got = label_format.num_value(spell(n, and_word=and_word))[0]
    assert got == str(n), f"{' '.join(spell(n, and_word=and_word))!r} read as {got}"


def test_f24_every_boundary_and_a_stride_through_the_range():
    cases = {0, 1, 9, 10, 11, 19, 20, 21, 99, 100, 101, 110, 111, 119, 120, 999, 1_000, 1_001, 1_010,
             1_100, 1_101, 10_000, 10_001, 20_020, 100_000, 100_001, 110_000, 999_999}
    cases |= set(range(0, 1_000_000, 997))
    wrong = [(n, label_format.num_value(spell(n))[0]) for n in sorted(cases)
             if label_format.num_value(spell(n))[0] != str(n)]
    assert not wrong, wrong[:5]


# --- label_consensus: normalization never erases real text --------------------

def _has_latin_letter(text: str) -> bool:
    return any(ch.isalpha() and unicodedata.name(ch, "").startswith("LATIN") for ch in text) \
        or any(ch.isdigit() for ch in text)


ASCII_LATIN = st.text(alphabet=st.characters(whitelist_categories=("L", "N", "Zs", "Po"),
                                              max_codepoint=0x7F), min_size=1, max_size=40)
ANY_LATIN = st.text(alphabet=st.characters(whitelist_categories=("L", "N", "Zs", "Po"),
                                            max_codepoint=0x24F), min_size=1, max_size=40)


@PROPERTY
@given(ASCII_LATIN.filter(_has_latin_letter))
def test_normalization_keeps_something_for_ascii_text(text):
    assert label_consensus.normalize_words(text), f"{text!r} normalized to no words"


@PROPERTY
@given(ANY_LATIN.filter(_has_latin_letter))
def test_props_latin_normalize_keeps_something_for_accented_text(text):
    assert label_consensus.normalize_words(text), f"{text!r} normalized to no words"


# --- F26: a torn or non-UTF-8 training index never 500s -----------------------

def _line(i: int) -> bytes:
    return json.dumps({
        "id": f"s{i}", "createdAt": "2026-11-01T10:00:00Z", "app": None,
        "transcript": f"hello there my friend number {i}", "finalText": "", "edited": False,
        "confidence": "audio", "audioFile": f"audio/s{i}.wav", "llmTranscript": None,
        "llmModel": None}).encode()


def _readiness_client(root):
    class IndexTraining(FakeTraining):
        def readiness(self):
            return jobs.readiness(store_root=root)

    services = Services(ai=Gateway(default_registry()), labeler=label_consensus,
                        local_models=FakeLocal(), training=IndexTraining(), formatter=label_format)
    app = create_app(Settings.from_env({}), services)
    return TestClient(app, base_url="http://127.0.0.1:50711", raise_server_exceptions=False)


def _readiness(tmp_path_factory_dir, index: bytes):
    (tmp_path_factory_dir / "samples.jsonl").write_bytes(index)
    return _readiness_client(tmp_path_factory_dir).get("/training/readiness")


def _damage(lines: list[bytes], ops: list[tuple[int, int, int]], *, utf8: bool) -> bytes:
    """Apply (line, position, kind) edits: tear a line, flip a byte, junk."""
    lines = list(lines)
    for which, at, kind in ops:
        i = which % len(lines)
        raw = lines[i]
        cut = at % (len(raw) + 1)
        if kind == 0:
            lines[i] = raw[:cut]                                  # torn write
        elif kind == 1 and raw:
            lines[i] = raw[:cut % len(raw)] + bytes([raw[cut % len(raw)] ^ (1 << (at % 7))]) \
                + raw[cut % len(raw) + 1:]                         # a bit flip
        elif kind == 2:
            lines[i] = raw[:cut] + b"\x00\x00" + raw[cut:]         # NULs
        elif kind == 3:
            lines[i] = b"[1, 2" if at % 2 else b"null"             # not an object
        elif kind == 4 and utf8:
            lines[i] = raw[:cut] + b"\xff\xfe\xc3\x28" + raw[cut:]  # invalid UTF-8
    return b"\n".join(lines) + b"\n"


OPS = st.lists(st.tuples(st.integers(0, 50), st.integers(0, 400), st.integers(0, 3)),
               min_size=1, max_size=4)


@settings(PROPERTY, max_examples=40)
@given(OPS, st.integers(2, 8))
def test_training_readiness_survives_torn_lines(tmp_path_factory, ops, count):
    root = tmp_path_factory.mktemp("index")
    reply = _readiness(root, _damage([_line(i) for i in range(count)], ops, utf8=False))
    assert reply.status_code == 200, reply.text
    assert "ready" in reply.json()


def test_f26_invalid_utf8_in_the_index_never_500s(tmp_path):
    index = _damage([_line(i) for i in range(5)], [(2, 30, 4)], utf8=True)
    reply = _readiness(tmp_path, index)
    assert reply.status_code == 200, f"HTTP {reply.status_code}: {reply.text[:120]}"
