from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path

import pytest

from flowy.training import jobs
from flowy.training.pipeline import PipelineConfig
from flowy.training.models import get_training_model, training_models_payload


def test_fine_tuned_model_name_is_picker_and_filesystem_safe() -> None:
    now = datetime(2026, 7, 18, 14, 5, 9, tzinfo=timezone.utc)

    assert jobs.fine_tuned_model_name(now) == "balenced-ft-20260718-140509"


def test_catalog_covers_pinned_whisperkit_variants_and_optimized_alias() -> None:
    ids = {item["id"] for item in training_models_payload()}
    assert ids == {
        "tiny", "tiny.en", "base", "base.en", "small", "small.en",
        "medium", "medium.en", "large", "large-v2", "large-v3",
        "large-v3-v20240930_626MB",
    }
    assert get_training_model("large-v3-v20240930_626MB").hf_model == (
        "openai/whisper-large-v3"
    )


def test_profiles_reduce_large_model_update_pressure() -> None:
    tiny = get_training_model("tiny.en")
    large = get_training_model("large-v3")
    assert large.learning_rate < tiny.learning_rate
    assert large.lora_rank < tiny.lora_rank
    assert large.gradient_accumulation_steps > tiny.gradient_accumulation_steps


def test_start_job_requires_fifty_eligible_samples(monkeypatch) -> None:
    monkeypatch.setattr(
        jobs,
        "readiness",
        lambda _=None: {
            "ready": False,
            "eligible_count": 49,
            "remaining_samples": 1,
            "eligible_audio_minutes": 6.2,
        },
    )

    with pytest.raises(ValueError, match="50 well-populated samples and 5 minutes"):
        jobs.start_job()


def test_readiness_requires_audio_minutes_as_well_as_count(monkeypatch, tmp_path) -> None:
    """Fifty tiny clips must NOT unlock training — both gates hold together."""

    class FakeReport:
        eligible_count = 50
        total_audio_seconds = 120.0  # 2 min < 5 min floor

        def summary_dict(self):
            return {"eligible_count": 50, "eligible_audio_minutes": 2.0}

    class FakeStore:
        def __init__(self, _root):
            pass

        def inspect(self, **_kwargs):
            return FakeReport()

    monkeypatch.setattr(jobs, "TrainingStore", FakeStore)
    result = jobs.readiness(tmp_path)
    assert result["ready"] is False
    assert result["remaining_samples"] == 0
    assert result["remaining_audio_minutes"] == 3.0


def test_job_runs_pipeline_and_records_installed_model(tmp_path: Path, monkeypatch) -> None:
    jobs._jobs.clear()
    monkeypatch.setattr(
        jobs,
        "readiness",
        lambda _=None: {
            "ready": True,
            "eligible_count": 50,
            "remaining_samples": 0,
            "eligible_audio_minutes": 7.5,
        },
    )
    installed = tmp_path / "Models" / "Custom" / "balenced-ft-test"
    finished = __import__("threading").Event()

    def runner(config: PipelineConfig, progress):
        assert config.model_name.startswith("balenced-ft-")
        run_dir = tmp_path / "runs" / config.model_name
        run_dir.mkdir(parents=True)
        progress(stage="training", message="Training", value=0.5, run_dir=str(run_dir))
        installed.mkdir(parents=True)
        finished.set()
        return installed

    job = jobs.start_job(output_root=tmp_path / "runs", runner=runner)

    assert finished.wait(timeout=2)
    current = jobs.get_job(job.id)
    assert current is not None
    # The worker may have set the event immediately before its final state write.
    for _ in range(100):
        current = jobs.get_job(job.id)
        if current and current.state == "done":
            break
        __import__("time").sleep(0.005)
    assert current is not None
    assert current.state == "done"
    assert current.installed_model_dir == str(installed)
    assert current.progress == 1.0
