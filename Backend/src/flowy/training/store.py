"""Read and validate the training data captured by the Slive macOS app.

The Swift app owns the append-only store at::

    ~/Library/Application Support/Slive/training/
      samples.jsonl
      audio/<sample-id>.wav

This module is deliberately independent from PyTorch and Transformers. It is the
input boundary for future training code: malformed rows, unsafe paths, missing
audio, and ineligible labels are surfaced before any expensive model is loaded.
"""

from __future__ import annotations

import hashlib
import json
import math
import os
from dataclasses import asdict, dataclass
from enum import StrEnum
from pathlib import Path
from typing import Any

import soundfile


class LabelPolicy(StrEnum):
    """Which stored text may become a supervised training target.

    The raw ``transcript`` is intentionally never a target: it is Slive's own
    prediction and training on it would reinforce existing errors.
    """

    VERIFIED = "verified"
    LLM = "llm"
    BEST_AVAILABLE = "best-available"


@dataclass(frozen=True)
class StoredSample:
    id: str
    created_at: str
    app: str | None
    transcript: str
    final_text: str
    edited: bool
    confidence: str
    audio_file: str | None
    llm_transcript: str | None
    llm_model: str | None
    line_number: int


@dataclass(frozen=True)
class AudioInfo:
    path: str
    sha256: str
    bytes: int
    frames: int
    sample_rate: int
    channels: int
    duration_seconds: float
    format: str
    subtype: str


@dataclass(frozen=True)
class PreparedSample:
    id: str
    created_at: str
    app: str | None
    audio: AudioInfo
    reference_text: str
    label_source: str
    original_transcript: str
    llm_model: str | None

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass(frozen=True)
class RejectedSample:
    id: str | None
    line_number: int | None
    reasons: tuple[str, ...]

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass(frozen=True)
class StoreReport:
    store_root: str
    index_file: str
    label_policy: str
    total_rows: int
    eligible_samples: tuple[PreparedSample, ...]
    rejected_samples: tuple[RejectedSample, ...]

    @property
    def eligible_count(self) -> int:
        return len(self.eligible_samples)

    @property
    def rejected_count(self) -> int:
        return len(self.rejected_samples)

    @property
    def total_audio_seconds(self) -> float:
        return sum(item.audio.duration_seconds for item in self.eligible_samples)

    def summary_dict(self) -> dict[str, Any]:
        reason_counts: dict[str, int] = {}
        for item in self.rejected_samples:
            for reason in item.reasons:
                reason_counts[reason] = reason_counts.get(reason, 0) + 1
        return {
            "store_root": self.store_root,
            "index_file": self.index_file,
            "label_policy": self.label_policy,
            "total_rows": self.total_rows,
            "eligible_count": self.eligible_count,
            "rejected_count": self.rejected_count,
            "eligible_audio_seconds": round(self.total_audio_seconds, 3),
            "eligible_audio_minutes": round(self.total_audio_seconds / 60, 3),
            "rejection_reason_counts": reason_counts,
        }

    def to_dict(self, *, include_samples: bool = True) -> dict[str, Any]:
        result = self.summary_dict()
        if include_samples:
            result["eligible_samples"] = [item.to_dict() for item in self.eligible_samples]
            result["rejected_samples"] = [item.to_dict() for item in self.rejected_samples]
        return result


def default_store_root() -> Path:
    """Return Slive's default per-user training-store directory."""

    override = os.environ.get("SLIVE_TRAINING_DIR")
    if override:
        return Path(override).expanduser()
    return Path.home() / "Library" / "Application Support" / "Slive" / "training"


class TrainingStore:
    """Parser and validator for the Swift app's training JSONL store."""

    def __init__(self, root: Path | str | None = None) -> None:
        self.root = Path(root).expanduser() if root is not None else default_store_root()
        self.index_file = self.root / "samples.jsonl"

    def inspect(
        self,
        *,
        label_policy: LabelPolicy = LabelPolicy.VERIFIED,
        min_duration: float = 0.5,
        max_duration: float = 30.0,
    ) -> StoreReport:
        """Parse the store and return eligible and rejected samples.

        Inspection is read-only. It does not normalize, copy, or modify audio.
        """

        if min_duration < 0:
            raise ValueError("min_duration must be non-negative")
        if max_duration <= min_duration:
            raise ValueError("max_duration must be greater than min_duration")

        if not self.index_file.is_file():
            rejection = RejectedSample(
                id=None,
                line_number=None,
                reasons=("index-file-missing",),
            )
            return StoreReport(
                store_root=str(self.root),
                index_file=str(self.index_file),
                label_policy=label_policy.value,
                total_rows=0,
                eligible_samples=(),
                rejected_samples=(rejection,),
            )

        eligible: list[PreparedSample] = []
        rejected: list[RejectedSample] = []
        total_rows = 0
        seen_ids: set[str] = set()
        seen_audio_hashes: set[str] = set()

        with self.index_file.open("r", encoding="utf-8") as handle:
            for line_number, raw_line in enumerate(handle, start=1):
                if not raw_line.strip():
                    continue
                total_rows += 1
                try:
                    payload = json.loads(raw_line)
                    sample = _parse_sample(payload, line_number)
                except (json.JSONDecodeError, TypeError, ValueError) as exc:
                    rejected.append(
                        RejectedSample(
                            id=None,
                            line_number=line_number,
                            reasons=(f"invalid-row:{exc}",),
                        )
                    )
                    continue

                reasons: list[str] = []
                if sample.id in seen_ids:
                    reasons.append("duplicate-id")
                else:
                    seen_ids.add(sample.id)

                label, label_source = _select_label(sample, label_policy)
                if label is None:
                    reasons.append(f"no-{label_policy.value}-label")

                audio_path, path_error = self._resolve_audio(sample.audio_file)
                if path_error:
                    reasons.append(path_error)

                audio_info: AudioInfo | None = None
                if audio_path is not None and not path_error:
                    try:
                        audio_info = _inspect_audio(audio_path)
                    except (OSError, RuntimeError, ValueError) as exc:
                        reasons.append(f"invalid-audio:{exc}")

                if audio_info is not None:
                    if audio_info.duration_seconds < min_duration:
                        reasons.append("audio-too-short")
                    if audio_info.duration_seconds > max_duration:
                        reasons.append("audio-too-long")
                    if audio_info.sha256 in seen_audio_hashes:
                        reasons.append("duplicate-audio")
                    else:
                        seen_audio_hashes.add(audio_info.sha256)

                if reasons:
                    rejected.append(
                        RejectedSample(
                            id=sample.id,
                            line_number=sample.line_number,
                            reasons=tuple(reasons),
                        )
                    )
                    continue

                assert label is not None
                assert label_source is not None
                assert audio_info is not None
                eligible.append(
                    PreparedSample(
                        id=sample.id,
                        created_at=sample.created_at,
                        app=sample.app,
                        audio=audio_info,
                        reference_text=label,
                        label_source=label_source,
                        original_transcript=sample.transcript,
                        llm_model=sample.llm_model,
                    )
                )

        return StoreReport(
            store_root=str(self.root),
            index_file=str(self.index_file),
            label_policy=label_policy.value,
            total_rows=total_rows,
            eligible_samples=tuple(eligible),
            rejected_samples=tuple(rejected),
        )

    def _resolve_audio(self, relative: str | None) -> tuple[Path | None, str | None]:
        if not relative or not relative.strip():
            return None, "audio-path-missing"

        candidate = Path(relative)
        if candidate.is_absolute():
            return None, "audio-path-absolute"

        root = self.root.resolve()
        resolved = (root / candidate).resolve()
        try:
            resolved.relative_to(root)
        except ValueError:
            return None, "audio-path-outside-store"

        if not resolved.is_file():
            return None, "audio-file-missing"
        return resolved, None


def write_manifest(report: StoreReport, destination: Path | str) -> Path:
    """Write eligible samples as deterministic JSONL for future training."""

    path = Path(destination).expanduser()
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp")
    with temporary.open("w", encoding="utf-8") as handle:
        for sample in report.eligible_samples:
            handle.write(json.dumps(sample.to_dict(), sort_keys=True, ensure_ascii=False))
            handle.write("\n")
    temporary.replace(path)
    return path


def _parse_sample(payload: Any, line_number: int) -> StoredSample:
    if not isinstance(payload, dict):
        raise TypeError("row must be a JSON object")

    sample_id = _required_string(payload, "id")
    created_at = _required_string(payload, "createdAt")
    transcript = _required_string(payload, "transcript", allow_empty=True)
    final_text = _optional_string(payload, "finalText") or ""
    confidence = _optional_string(payload, "confidence") or "unknown"

    return StoredSample(
        id=sample_id,
        created_at=created_at,
        app=_optional_string(payload, "app"),
        transcript=transcript.strip(),
        final_text=final_text.strip(),
        edited=bool(payload.get("edited", False)),
        confidence=confidence,
        audio_file=_optional_string(payload, "audioFile"),
        llm_transcript=(_optional_string(payload, "llmTranscript") or "").strip() or None,
        llm_model=_optional_string(payload, "llmModel"),
        line_number=line_number,
    )


def _select_label(sample: StoredSample, policy: LabelPolicy) -> tuple[str | None, str | None]:
    # A non-empty finalText is the only current field representing a corrected
    # post-dictation value. Confidence is retained in the source label for audit.
    if policy in (LabelPolicy.VERIFIED, LabelPolicy.BEST_AVAILABLE) and sample.final_text:
        return sample.final_text, f"finalText:{sample.confidence}"
    if policy in (LabelPolicy.LLM, LabelPolicy.BEST_AVAILABLE) and sample.llm_transcript:
        return sample.llm_transcript, "llmTranscript"
    return None, None


def _inspect_audio(path: Path) -> AudioInfo:
    info = soundfile.info(str(path))
    if info.frames <= 0 or info.samplerate <= 0 or info.channels <= 0:
        raise ValueError("audio metadata is empty or invalid")
    duration = info.frames / info.samplerate
    if not math.isfinite(duration):
        raise ValueError("audio duration is not finite")
    return AudioInfo(
        path=str(path),
        sha256=_sha256(path),
        bytes=path.stat().st_size,
        frames=info.frames,
        sample_rate=info.samplerate,
        channels=info.channels,
        duration_seconds=round(duration, 6),
        format=info.format,
        subtype=info.subtype,
    )


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def _required_string(payload: dict[str, Any], key: str, *, allow_empty: bool = False) -> str:
    value = payload.get(key)
    if not isinstance(value, str):
        raise TypeError(f"{key} must be a string")
    value = value.strip()
    if not allow_empty and not value:
        raise ValueError(f"{key} must not be empty")
    return value


def _optional_string(payload: dict[str, Any], key: str) -> str | None:
    value = payload.get(key)
    if value is None:
        return None
    if not isinstance(value, str):
        raise TypeError(f"{key} must be a string or null")
    return value

