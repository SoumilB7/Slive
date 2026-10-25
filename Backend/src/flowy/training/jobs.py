"""Background training-job coordination for the local Slive backend."""

from __future__ import annotations

import json
import math
import shutil
import threading
import uuid
from dataclasses import asdict, dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Callable

from flowy.training import pipeline
from flowy.training.pipeline import TRAINING_METHODS, PipelineConfig, run_pipeline
from flowy.training.models import DEFAULT_TRAINING_MODEL, get_training_model
from flowy.training.store import LabelPolicy, TrainingStore

MIN_TRAINING_SAMPLES = 50
#: Fifty one-second clips are not a dataset — training also needs this much
#: eligible audio in total before it may begin.
MIN_TRAINING_AUDIO_MINUTES = 5.0


def fine_tuned_model_name(now: datetime | None = None) -> str:
    """Filesystem- and picker-safe name required for trained Balanced models."""

    return (now or datetime.now().astimezone()).strftime("balenced-ft-%Y%m%d-%H%M%S")


def sanitize_model_name(raw: str) -> str:
    """A user-chosen model name, made filesystem- and picker-safe.

    Spaces become dashes; anything outside [A-Za-z0-9._-] is dropped; leading
    dots (hidden dirs / the installer's staging prefix) are stripped. Returns
    "" when nothing safe remains — callers fall back to the timestamped name.
    """

    cleaned = "".join(
        ch for ch in raw.strip().replace(" ", "-") if ch.isalnum() or ch in "._-"
    ).lstrip(".")
    return cleaned[:80]


@dataclass
class TrainingJob:
    id: str
    model_name: str
    source_model: str
    base_model: str
    method: str
    max_ram_gb: float
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
    method: str = "hybrid",
    custom_name: str | None = None,
    max_ram_gb: float = 12.0,
    store_root: Path | str | None = None,
    output_root: Path | str | None = None,
    runner: Callable[[PipelineConfig, Callable[..., None]], Path] = run_pipeline,
) -> TrainingJob:
    profile = get_training_model(source_model)
    if method not in TRAINING_METHODS:
        raise ValueError(f"Unsupported training method: {method}")
    if not math.isfinite(max_ram_gb) or not 2 <= max_ram_gb <= 128:
        raise ValueError("SFT RAM limit must be between 2 and 128 GB")
    recommended = profile.qlora_ram_gb if method == "qlora" else profile.lora_ram_gb
    if max_ram_gb < recommended:
        raise ValueError(
            f"{profile.label} {method.upper()} needs about {recommended:g} GB RAM; "
            f"raise the SFT limit or choose a smaller model."
        )

    # Only NEW fine-tunes are nameable — the name is the installed folder and
    # the picker id, so collisions must fail here, not after an hour of
    # training when the installer refuses to overwrite.
    model_name = sanitize_model_name(custom_name or "") or fine_tuned_model_name()
    if (pipeline.custom_models_root() / model_name).exists():
        raise ValueError(
            f"A personal model named “{model_name}” already exists — pick a "
            f"different name."
        )

    # The real pipeline converts for WhisperKit only after training — make a
    # missing converter fail now, not after tens of minutes. Injected test
    # runners don't convert, so they skip the check.
    if runner is run_pipeline:
        pipeline.whisperkit_converter()

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

        # No job is running, so any leftover run folder for this name is a
        # failed run (the installed-model check above rules out a success).
        # run_pipeline refuses an existing run dir, so move it aside — kept
        # for its logs — instead of failing the retry inside the thread.
        run_root = Path(output_root).expanduser() if output_root else pipeline.default_output_root()
        _set_aside_failed_run(run_root / model_name, pipeline.custom_models_root(), model_name)

        job = TrainingJob(
            id=str(uuid.uuid4()),
            model_name=model_name,
            source_model=profile.id,
            base_model=profile.hf_model,
            method=method,
            max_ram_gb=max_ram_gb,
            eligible_samples=ready["eligible_count"],
        )
        _jobs[job.id] = job

    config = PipelineConfig.for_model(
        model_name=job.model_name,
        source_model=profile.id,
        method=method,
        max_ram_gb=max_ram_gb,
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


def _set_aside_failed_run(run_dir: Path, models_root: Path, model_name: str) -> None:
    if run_dir.exists():
        stamp = datetime.now().astimezone().strftime("%Y%m%d-%H%M%S")
        aside = run_dir.with_name(f"{run_dir.name}.failed-{stamp}")
        suffix = 1
        while aside.exists():
            aside = run_dir.with_name(f"{run_dir.name}.failed-{stamp}-{suffix}")
            suffix += 1
        run_dir.rename(aside)
    # An install interrupted mid-copy leaves a staging folder that would make
    # the installer refuse this name; it is incomplete by definition.
    shutil.rmtree(models_root / f".{model_name}.staging", ignore_errors=True)


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


def _non_finite(value) -> bool:
    return isinstance(value, float) and not math.isfinite(value)


def _clean_metric(metric: dict) -> dict | None:
    """Job dicts go through Starlette's JSONResponse (allow_nan=False): one
    NaN would 500 every /training/jobs/* poll for the server's lifetime. The
    Swift chart decodes ``loss`` as a number and ``kl`` as optional, so a
    non-finite loss drops the point and a non-finite kl becomes null."""
    if _non_finite(metric.get("loss")):
        return None
    return {key: None if _non_finite(value) else value for key, value in metric.items()}


def _update(job_id: str, **changes) -> None:
    metric = changes.pop("metric", None)
    with _lock:
        job = _jobs[job_id]
        if metric is not None and (metric := _clean_metric(metric)) is not None:
            job.metrics.append(metric)
        for key, value in changes.items():
            # Non-finite scalars (progress) keep the last good value.
            if hasattr(job, key) and not _non_finite(value):
                setattr(job, key, value)
        if job.run_dir:
            path = Path(job.run_dir) / "job.json"
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(job.to_dict(), indent=2), encoding="utf-8")
