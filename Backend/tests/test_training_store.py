from __future__ import annotations

import json
import struct
import wave
from pathlib import Path

from flowy.training.cli import main
from flowy.training.store import (
    LABEL_META_MARKERS,
    LabelPolicy,
    TrainingStore,
    label_quality_issues,
    write_manifest,
)


def _write_wav(path: Path, *, seconds: float = 1.0, sample_rate: int = 16_000) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    frames = int(seconds * sample_rate)
    samples = struct.pack("<" + "h" * frames, *([0] * frames))
    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(sample_rate)
        handle.writeframes(samples)


def _row(sample_id: str, **overrides) -> dict:
    result = {
        "id": sample_id,
        "createdAt": "2026-07-18T10:00:00Z",
        "app": "com.example.editor",
        "transcript": "raw model prediction",
        "finalText": "",
        "edited": False,
        "confidence": "audio",
        "audioFile": f"audio/{sample_id}.wav",
        "llmTranscript": None,
        "llmModel": None,
    }
    result.update(overrides)
    return result


def _write_rows(root: Path, rows: list[dict | str]) -> None:
    root.mkdir(parents=True, exist_ok=True)
    with (root / "samples.jsonl").open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(row if isinstance(row, str) else json.dumps(row))
            handle.write("\n")


def test_verified_policy_never_falls_back_to_raw_prediction(tmp_path: Path) -> None:
    root = tmp_path / "training"
    _write_wav(root / "audio" / "one.wav")
    _write_rows(root, [_row("one")])

    report = TrainingStore(root).inspect(label_policy=LabelPolicy.VERIFIED)

    assert report.eligible_count == 0
    assert report.rejected_samples[0].reasons == ("no-verified-label",)


def test_best_available_prefers_final_text_then_llm(tmp_path: Path) -> None:
    root = tmp_path / "training"
    _write_wav(root / "audio" / "corrected.wav")
    _write_wav(root / "audio" / "llm.wav", seconds=1.1)
    _write_rows(
        root,
        [
            _row(
                "corrected",
                finalText="human corrected text",
                confidence="high",
                llmTranscript="llm text should not win",
                llmModel="provider/model",
            ),
            _row(
                "llm",
                transcript="llm reference text",
                llmTranscript="LLM reference text",
                llmModel="provider/model",
            ),
        ],
    )

    report = TrainingStore(root).inspect(label_policy=LabelPolicy.BEST_AVAILABLE)

    assert report.eligible_count == 2
    assert report.eligible_samples[0].reference_text == "human corrected text"
    assert report.eligible_samples[0].label_source == "finalText:high"
    assert report.eligible_samples[1].reference_text == "LLM reference text"
    assert report.eligible_samples[1].label_source == "llmTranscript"


def test_rejects_unsafe_missing_short_and_duplicate_audio(tmp_path: Path) -> None:
    root = tmp_path / "training"
    _write_wav(root / "audio" / "short.wav", seconds=0.1)
    _write_wav(root / "audio" / "same-a.wav")
    (root / "audio" / "same-b.wav").write_bytes((root / "audio" / "same-a.wav").read_bytes())
    _write_rows(
        root,
        [
            _row("unsafe", finalText="a valid label", audioFile="../../outside.wav"),
            _row("missing", finalText="a valid label"),
            _row("short", finalText="a valid label"),
            _row("same-a", finalText="a valid label"),
            _row("same-b", finalText="a valid label"),
        ],
    )

    report = TrainingStore(root).inspect()
    reasons = {item.id: item.reasons for item in report.rejected_samples}

    assert "audio-path-outside-store" in reasons["unsafe"]
    assert "audio-file-missing" in reasons["missing"]
    assert "audio-too-short" in reasons["short"]
    assert report.eligible_count == 1
    assert "duplicate-audio" in reasons["same-b"]


def test_one_word_labels_are_not_well_populated(tmp_path: Path) -> None:
    root = tmp_path / "training"
    _write_wav(root / "audio" / "terse.wav")
    _write_rows(root, [_row("terse", finalText="okay")])

    report = TrainingStore(root).inspect()

    assert report.eligible_count == 0
    assert "label-too-short" in report.rejected_samples[0].reasons


def test_invalid_json_is_reported_without_stopping_other_rows(tmp_path: Path) -> None:
    root = tmp_path / "training"
    _write_wav(root / "audio" / "good.wav")
    _write_rows(root, ["not-json", _row("good", finalText="this is correct")])

    report = TrainingStore(root).inspect()

    assert report.total_rows == 2
    assert report.eligible_count == 1
    assert report.rejected_count == 1
    assert report.rejected_samples[0].reasons[0].startswith("invalid-row:")


def test_manifest_contains_only_eligible_samples(tmp_path: Path) -> None:
    root = tmp_path / "training"
    _write_wav(root / "audio" / "good.wav")
    _write_wav(root / "audio" / "raw-only.wav", seconds=1.2)
    _write_rows(
        root,
        [
            _row("good", finalText="this is correct"),
            _row("raw-only"),
        ],
    )
    report = TrainingStore(root).inspect()

    destination = write_manifest(report, tmp_path / "output" / "manifest.jsonl")
    lines = destination.read_text(encoding="utf-8").splitlines()

    assert len(lines) == 1
    payload = json.loads(lines[0])
    assert payload["id"] == "good"
    assert payload["reference_text"] == "this is correct"
    assert payload["original_transcript"] == "raw model prediction"
    assert payload["audio"]["sample_rate"] == 16_000
    assert len(payload["audio"]["sha256"]) == 64


SPOKEN = (
    "Can you push this to the branch we are working on? Or the PR basically, "
    "PR fourteen I guess, and then run the release."
)


def test_label_gate_rejects_first_sentence_truncation() -> None:
    issues = label_quality_issues("Can you push this to the branch we are working on?", SPOKEN)
    assert "label-length-mismatch" in issues


def test_label_gate_rejects_meta_reply_preamble() -> None:
    label = (
        "Sure, here’s the transcription of the audio you requested:\n\n" + SPOKEN
    )
    assert "label-meta-reply" in label_quality_issues(label, SPOKEN)


def test_label_gate_rejects_foreign_language_hallucination() -> None:
    issues = label_quality_issues(
        "Altså, da kingen hadde vist.",
        "Can you run a few and four inch to check? I hope you can bring your own actions.",
    )
    assert "label-low-similarity" in issues


def test_label_gate_passes_punctuation_casing_and_number_word_fixes() -> None:
    cases = [
        ("Can you push this to the branch we are working on? Or the PR, basically — "
         "PR 14, I guess. And then run the release.", SPOKEN),
        ("What other problems do you think a 120-billion-parameter model is facing?",
         "what other problems do you think a 120 billion parameter model is facing"),
        ("test one test two test three test four test five",
         "test 1 test 2 test 3 test 4 test 5."),
        ("I was okay with the transcript, here's the transcription I wanted.",
         "i was okay with the transcript here's the transcription i wanted"),
    ]
    for label, transcript in cases:
        assert label_quality_issues(label, transcript) == (), label


def test_label_gate_markers_cover_the_assistant_guard() -> None:
    from flowy.assistant import _META_REPLY_MARKERS

    assert set(_META_REPLY_MARKERS) <= set(LABEL_META_MARKERS)


def test_rejected_cloud_labels_are_excluded_and_counted(tmp_path: Path) -> None:
    root = tmp_path / "training"
    for name in ("good", "cut", "meta", "human"):
        _write_wav(root / "audio" / f"{name}.wav", seconds=1.0 + len(name) / 10)
    _write_rows(
        root,
        [
            _row("good", transcript=SPOKEN, llmTranscript=SPOKEN.upper()),
            _row("cut", transcript=SPOKEN,
                 llmTranscript="Can you push this to the branch we are working on?"),
            _row("meta", transcript=SPOKEN,
                 llmTranscript="Here is the transcription: " + SPOKEN),
            # A human correction is trusted even when it rewrites heavily.
            _row("human", transcript=SPOKEN, finalText="Push it.", confidence="manual",
                 llmTranscript="Altså, da kingen hadde vist."),
        ],
    )

    report = TrainingStore(root).inspect(label_policy=LabelPolicy.BEST_AVAILABLE)
    summary = report.summary_dict()

    # "human" is rejected only for being one word short of three, not by the gate.
    assert [item.id for item in report.eligible_samples] == ["good"]
    reasons = {item.id: item.reasons for item in report.rejected_samples}
    assert reasons["cut"] == ("label-length-mismatch",)
    assert "label-meta-reply" in reasons["meta"]
    assert reasons["human"] == ("label-too-short",)
    assert summary["label_rejected_count"] == 2
    assert summary["rejection_reason_counts"]["label-length-mismatch"] == 1


def test_cli_inspect_and_empty_manifest_failure(tmp_path: Path, capsys) -> None:
    root = tmp_path / "training"
    _write_wav(root / "audio" / "one.wav")
    _write_rows(root, [_row("one")])

    inspect_code = main(["--store", str(root), "inspect"])
    manifest_code = main(
        [
            "--store",
            str(root),
            "build-manifest",
            "--output",
            str(tmp_path / "manifest.jsonl"),
        ]
    )

    captured = capsys.readouterr()
    assert inspect_code == 1
    assert manifest_code == 1
    assert "Eligible: 0" in captured.out
    assert "manifest was not written" in captured.err
    assert not (tmp_path / "manifest.jsonl").exists()

