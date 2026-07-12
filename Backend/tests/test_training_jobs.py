from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path

import pytest

from flowy.training import jobs
from flowy.training.pipeline import PipelineConfig


def test_fine_tuned_model_name_is_picker_and_filesystem_safe() -> None:
    now = datetime(2026, 7, 18, 14, 5, 9, tzinfo=timezone.utc)

    assert jobs.fine_tuned_model_name(now) == "balenced-ft-20260718-140509"


def test_start_job_requires_fifty_eligible_samples(monkeypatch) -> None:
    monkeypatch.setattr(
        jobs,
        "readiness",
        lambda _=None: {
            "ready": False,
            "eligible_count": 49,
            "remaining_samples": 1,
        },
    )

    with pytest.raises(ValueError, match="Need at least 50 eligible samples; have 49"):
        jobs.start_job()


def test_job_runs_pipeline_and_records_installed_model(tmp_path: Path, monkeypatch) -> None:
    jobs._jobs.clear()
    monkeypatch.setattr(
        jobs,
        "readiness",
        lambda _=None: {
            "ready": True,
            "eligible_count": 50,
            "remaining_samples": 0,
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
