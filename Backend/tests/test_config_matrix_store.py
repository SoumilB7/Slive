"""The training store's gate under every label policy × target style, for
every kind of row the app writes (unlabelled, human, each cloud-label
quality failure, each format status).

Policies and styles are read from their enums, and the expectations are
keyed by them — a new ``LabelPolicy`` / ``TargetStyle`` member fails
``test_every_policy_and_style_has_an_expectation`` until this table says
what it should select."""

from __future__ import annotations

import json
from functools import cache
from pathlib import Path

import pytest

from flowy.training.cli import main
from flowy.training.store import (
    LABEL_QUALITY_REASONS,
    LabelPolicy,
    StoreReport,
    TargetStyle,
    TrainingStore,
)
from test_training_store import _row, _write_rows, _write_wav

#: Which stored labels each policy may use, in preference order.
POLICY_SOURCES = {
    LabelPolicy.VERIFIED: ("human",),
    LabelPolicy.LLM: ("cloud",),
    LabelPolicy.BEST_AVAILABLE: ("human", "cloud"),
}
#: Whether a style writes a passing cloud label's formatted text.
STYLE_USES_FORMATTED = {TargetStyle.PLAIN: False, TargetStyle.FORMATTED: True}

HEARD = "please ship the build today to staging"
CLOUD = "Please ship the build today to staging."
FORMATTED = "Please ship the build today to staging!"


def _cloud(**extra) -> dict:
    return {"llmTranscript": CLOUD, "llmModel": "consensus · gpt-transcribe",
            "llmAgreement": 0.95, **extra}


#: kind → (row fields, gate reasons when its label is used). The reasons of a
#: row with both labels are those of the label the policy picks.
KINDS: dict[str, tuple[dict, dict[str, tuple[str, ...]]]] = {
    "unlabelled": ({}, {}),
    "human": ({"finalText": "Please ship it today.", "confidence": "high"}, {"human": ()}),
    "human-one-word": ({"finalText": "Ship.", "confidence": "high"}, {"human": ("label-too-short",)}),
    "cloud": (_cloud(), {"cloud": ()}),
    "cloud-legacy-single-model": (_cloud(llmModel="gemini-2.5-flash", llmAgreement=None),
                                  {"cloud": ()}),
    "cloud-agreement-at-bar": (_cloud(llmAgreement=0.8), {"cloud": ()}),
    "cloud-low-agreement": (_cloud(llmAgreement=0.79), {"cloud": ("label-low-agreement",)}),
    "cloud-one-unconfirmed": (_cloud(llmUnconfirmed=["claude"]), {"cloud": ()}),
    "cloud-unconfirmed": (_cloud(llmUnconfirmed=["bedrock", "hive"]),
                          {"cloud": ("label-unconfirmed-words",)}),
    "cloud-three-words": (_cloud(llmTranscript="Ship it today.", transcript="ship it today"),
                          {"cloud": ("label-too-short",)}),
    "cloud-meta-reply": (_cloud(llmTranscript=f"Here is the transcription: {CLOUD}"),
                         {"cloud": ("label-meta-reply",)}),
    "cloud-truncated": (_cloud(llmTranscript="Please ship the build."),
                        {"cloud": ("label-length-mismatch",)}),
    "cloud-hallucinated": (_cloud(llmTranscript="Det er en fin dag i Oslo i dag."),
                           {"cloud": ("label-low-similarity",)}),
    "cloud-silent-clip": (_cloud(transcript=""), {"cloud": ("label-length-mismatch",)}),
    "cloud-formatted": (_cloud(llmFormatted=FORMATTED, llmFormatStatus="formatted",
                               llmFormatModel="gpt-5.5"), {"cloud": ()}),
    "cloud-format-unchanged": (_cloud(llmFormatted=CLOUD, llmFormatStatus="unchanged"),
                               {"cloud": ()}),
    "cloud-format-rejected": (_cloud(llmFormatted="Totally different words here now.",
                                     llmFormatStatus="rejected:swapped 'a'→'b'"), {"cloud": ()}),
    "cloud-format-skipped": (_cloud(llmFormatted=CLOUD, llmFormatStatus="skipped"), {"cloud": ()}),
    "cloud-formatted-but-blank": (_cloud(llmFormatted="  ", llmFormatStatus="formatted"),
                                  {"cloud": ()}),
    "cloud-failing-format-gate": (_cloud(llmAgreement=0.5, llmFormatted=FORMATTED,
                                         llmFormatStatus="formatted"),
                                  {"cloud": ("label-low-agreement",)}),
    "human-and-cloud": ({"finalText": "Please ship it today.", "confidence": "high", **_cloud()},
                        {"human": (), "cloud": ()}),
    "human-and-bad-cloud": ({"finalText": "Please ship it today.", "confidence": "high",
                             **_cloud(llmAgreement=0.1)},
                            {"human": (), "cloud": ("label-low-agreement",)}),
}


@pytest.fixture(scope="module")
def store_root(tmp_path_factory) -> Path:
    """One store with a row of every kind, each with its own audio."""
    root = tmp_path_factory.mktemp("training")
    rows = []
    for index, (kind, (fields, _)) in enumerate(KINDS.items()):
        _write_wav(root / "audio" / f"{kind}.wav", seconds=1.0 + index / 100)
        rows.append(_row(kind, **{"transcript": HEARD, **fields}))
    _write_rows(root, rows)
    return root


@pytest.fixture(scope="module")
def inspect(store_root):
    @cache
    def run(policy: LabelPolicy, style: TargetStyle) -> StoreReport:
        return TrainingStore(store_root).inspect(label_policy=policy, target_style=style)

    return run


def test_every_policy_and_style_has_an_expectation() -> None:
    assert set(POLICY_SOURCES) == set(LabelPolicy)
    assert set(STYLE_USES_FORMATTED) == set(TargetStyle)
    reasons = {r for _, by_source in KINDS.values() for rs in by_source.values() for r in rs}
    assert reasons >= set(LABEL_QUALITY_REASONS) - {"label-too-short"}, (
        "a quality reason no row kind exercises")


@pytest.mark.parametrize("kind", KINDS)
@pytest.mark.parametrize("style", list(TargetStyle))
@pytest.mark.parametrize("policy", list(LabelPolicy))
def test_gate(inspect, policy, style, kind) -> None:
    report = inspect(policy, style)
    eligible = {s.id: s for s in report.eligible_samples}
    rejected = {s.id: s for s in report.rejected_samples}
    assert kind in eligible or kind in rejected

    fields, reasons_by_source = KINDS[kind]
    source = next((s for s in POLICY_SOURCES[policy] if s in reasons_by_source), None)
    if source is None:
        assert rejected[kind].reasons == (f"no-{policy.value}-label",)
        return
    if reasons_by_source[source]:
        assert set(rejected[kind].reasons) == set(reasons_by_source[source])
        return

    sample = eligible[kind]
    if source == "human":
        assert (sample.reference_text, sample.label_source) == (
            fields["finalText"], f"finalText:{fields['confidence']}")
        return
    use_formatted = (STYLE_USES_FORMATTED[style] and fields.get("llmFormatStatus") == "formatted"
                     and (fields.get("llmFormatted") or "").strip())
    if use_formatted:
        assert (sample.reference_text, sample.label_source) == (FORMATTED, "llmFormatted")
    else:
        assert (sample.reference_text, sample.label_source) == (fields["llmTranscript"], "llmTranscript")
    assert sample.original_transcript == fields.get("transcript", HEARD)


@pytest.mark.parametrize("style", list(TargetStyle))
@pytest.mark.parametrize("policy", list(LabelPolicy))
def test_summary_counts_are_consistent(inspect, policy, style) -> None:
    summary = inspect(policy, style).summary_dict()
    assert summary["label_policy"] == policy.value
    assert summary["eligible_count"] + summary["rejected_count"] == summary["total_rows"] == len(KINDS)
    assert summary["label_rejected_count"] <= summary["rejected_count"]


@pytest.mark.parametrize("policy", list(LabelPolicy))
def test_cli_accepts_every_policy(store_root, capsys, policy) -> None:
    code = main(["--store", str(store_root), "inspect", "--json", "--label-policy", policy.value])
    report = json.loads(capsys.readouterr().out)
    assert report["label_policy"] == policy.value
    assert code == (0 if report["eligible_count"] else 1)
