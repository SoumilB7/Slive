"""Background training-job coordination for the local Slive backend."""

from __future__ import annotations

import json
import threading
import uuid
from dataclasses import asdict, dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Callable

from flowy.training.pipeline import PipelineConfig, run_pipeline
from flowy.training.models import DEFAULT_TRAINING_MODEL, get_training_model
from flowy.training.store import LabelPolicy, TrainingStore

MIN_TRAINING_SAMPLES = 50
#: Fifty one-second clips are not a dataset — training also needs this much
#: eligible audio in total before it may begin.
MIN_TRAINING_AUDIO_MINUTES = 5.0


def fine_tuned_model_name(now: datetime | None = None) -> str:
    """Filesystem- and picker-safe name required for trained Balanced models."""

    return (now or datetime.now().astimezone()).strftime("balenced-ft-%Y%m%d-%H%M%S")


@dataclass
class TrainingJob:
    id: str
    model_name: str
    source_model: str
    base_model: str
    method: str
    state: str = "queued"  # queued | running | done | error
    stage: str = "queued"
    message: str = "Waiting to start"
    progress: float = 0.0
    eligible_samples: int = 0
    required_samples: int = MIN_TRAINING_SAMPLES
    run_dir: str | None = None
    installed_model_dir: str | None = None
    error: str | None = None
    #: Per-update training telemetry for the live chart: dicts with
    #: update / epoch / loss (CE) and, every few updates, kl — the divergence
    #: of the fine-tuned token distribution from stock Balanced (nats/token).
    metrics: list = field(default_factory=list)
    total_updates: int = 0
    created_at: str = field(default_factory=lambda: datetime.now().astimezone().isoformat())

    def to_dict(self) -> dict:
        return asdict(self)


_jobs: dict[str, TrainingJob] = {}
_lock = threading.Lock()


def readiness(store_root: Path | str | None = None) -> dict:
    report = TrainingStore(store_root).inspect(label_policy=LabelPolicy.BEST_AVAILABLE)
    eligible = report.eligible_count
    minutes = report.total_audio_seconds / 60
    return {
        **report.summary_dict(),
        "required_samples": MIN_TRAINING_SAMPLES,
        "remaining_samples": max(0, MIN_TRAINING_SAMPLES - eligible),
        "required_audio_minutes": MIN_TRAINING_AUDIO_MINUTES,
        "remaining_audio_minutes": round(max(0.0, MIN_TRAINING_AUDIO_MINUTES - minutes), 3),
        # Both gates must hold: enough samples AND enough total audio — each
        # sample individually well-populated (audio present and valid, label
        # ≥ 3 words) is enforced by the store's eligibility rules.
        "ready": eligible >= MIN_TRAINING_SAMPLES and minutes >= MIN_TRAINING_AUDIO_MINUTES,
    }


def start_job(
    *,
    source_model: str = DEFAULT_TRAINING_MODEL,
    method: str = "qlora",
    store_root: Path | str | None = None,
    output_root: Path | str | None = None,
    runner: Callable[[PipelineConfig, Callable[..., None]], Path] = run_pipeline,
) -> TrainingJob:
    profile = get_training_model(source_model)
    if method not in {"lora", "qlora"}:
        raise ValueError(f"Unsupported training method: {method}")
    ready = readiness(store_root)
    if not ready["ready"]:
        raise ValueError(
            f"Training needs at least {MIN_TRAINING_SAMPLES} well-populated "
            f"samples and {MIN_TRAINING_AUDIO_MINUTES:g} minutes of audio; "
            f"have {ready['eligible_count']} samples and "
            f"{ready.get('eligible_audio_minutes', 0):g} minutes."
        )

    with _lock:
        active = next((j for j in _jobs.values() if j.state in {"queued", "running"}), None)
        if active is not None:
            raise ValueError(f"Training job {active.id} is already running")

        job = TrainingJob(
            id=str(uuid.uuid4()),
            model_name=fine_tuned_model_name(),
            source_model=profile.id,
            base_model=profile.hf_model,
            method=method,
            eligible_samples=ready["eligible_count"],
        )
        _jobs[job.id] = job

    config = PipelineConfig.for_model(
        model_name=job.model_name,
        source_model=profile.id,
        method=method,
        store_root=Path(store_root).expanduser() if store_root else None,
        output_root=Path(output_root).expanduser() if output_root else None,
    )
    thread = threading.Thread(
        target=_run_job,
        args=(job.id, config, runner),
        name=f"slive-train-{job.id[:8]}",
        daemon=True,
    )
    thread.start()
    return job


def get_job(job_id: str) -> TrainingJob | None:
    with _lock:
        return _jobs.get(job_id)


def latest_job() -> TrainingJob | None:
    with _lock:
        return next(reversed(_jobs.values()), None) if _jobs else None


def _run_job(job_id: str, config: PipelineConfig, runner) -> None:
    _update(job_id, state="running", stage="preparing", message="Preparing training data")

    def progress(*, stage: str, message: str, value: float, **extra) -> None:
        _update(job_id, stage=stage, message=message, progress=value, **extra)

    try:
        installed = runner(config, progress)
    except Exception as exc:  # noqa: BLE001 - background boundary records full failure
        _update(
            job_id,
            state="error",
            stage="error",
            message=str(exc),
            error=str(exc),
        )
        return
    _update(
        job_id,
        state="done",
        stage="installed",
        message=f"{config.model_name} is ready in the model selector",
        progress=1.0,
        installed_model_dir=str(installed),
    )


def _update(job_id: str, **changes) -> None:
    metric = changes.pop("metric", None)
    with _lock:
        job = _jobs[job_id]
        if metric is not None:
            job.metrics.append(metric)
        for key, value in changes.items():
            if hasattr(job, key):
                setattr(job, key, value)
        if job.run_dir:
            path = Path(job.run_dir) / "job.json"
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(job.to_dict(), indent=2), encoding="utf-8")
