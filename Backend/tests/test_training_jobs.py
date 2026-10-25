from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path

import pytest

from flowy.training import jobs
from flowy.training.pipeline import PipelineConfig
from flowy.training.pipeline import MemoryGuard
from flowy.training import pipeline
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
    # Balanced is turbo (4 decoder layers) — training plain large-v3 made a
    # different model.
    assert get_training_model("large-v3-v20240930_626MB").hf_model == (
        "openai/whisper-large-v3-turbo"
    )


def test_profiles_move_large_models_slower() -> None:
    tiny = get_training_model("tiny.en")
    large = get_training_model("large-v3")
    assert large.learning_rate < tiny.learning_rate
    assert get_training_model("large-v3-v20240930_626MB").learning_rate == 1e-4


def test_start_job_rejects_ram_cap_below_selected_profile() -> None:
    with pytest.raises(ValueError, match="needs about 10 GB RAM"):
        jobs.start_job(source_model="large-v3", method="hybrid", max_ram_gb=8)


def test_start_job_rejects_unknown_and_retired_methods() -> None:
    for method in ("lora", "full"):
        with pytest.raises(ValueError, match="Unsupported training method"):
            jobs.start_job(source_model="tiny", method=method)


def test_encoder_cut_trains_top_quarter_or_freezes() -> None:
    assert pipeline.encoder_cut("hybrid", 32) == 24
    assert pipeline.encoder_cut("hybrid", 4) == 3
    assert pipeline.encoder_cut("decoder", 32) == 32


def test_lora_targets_cover_decoder_and_top_encoder_only() -> None:
    import re

    pattern = pipeline.lora_target_pattern(24, 32)
    hits = [
        "model.decoder.layers.0.self_attn.q_proj",
        "model.decoder.layers.3.encoder_attn.out_proj",
        "model.decoder.layers.2.fc2",
        "model.encoder.layers.24.self_attn.v_proj",
        "model.encoder.layers.31.fc1",
    ]
    misses = [
        "model.encoder.layers.23.self_attn.q_proj",
        "model.encoder.layers.2.fc1",
        "model.encoder.conv1",
        "proj_out",
    ]
    assert all(re.fullmatch(pattern, name) for name in hits)
    assert not any(re.fullmatch(pattern, name) for name in misses)
    decoder_only = pipeline.lora_target_pattern(32, 32)
    assert not re.fullmatch(decoder_only, "model.encoder.layers.31.fc1")
    assert re.fullmatch(decoder_only, "model.decoder.layers.1.fc1")


def test_lr_factor_warms_up_then_decays_to_zero() -> None:
    assert pipeline.lr_factor(0, 100) == pytest.approx(0.1)
    assert pipeline.lr_factor(9, 100) == pytest.approx(1.0)
    assert pipeline.lr_factor(55, 100) == pytest.approx(0.5)
    assert pipeline.lr_factor(100, 100) == pytest.approx(0.0)


def test_pad_label_batch_masks_forced_prefix_and_padding() -> None:
    # SOT en transcribe notimestamps w1 w2 EOT  /  SOT en transcribe notimestamps w1 EOT
    inputs, labels = pipeline.pad_label_batch(
        [[1, 2, 3, 4, 10, 11, 99], [1, 2, 3, 4, 10, 99]], pad_id=99, forced=3)
    assert inputs == [[1, 2, 3, 4, 10, 11], [1, 2, 3, 4, 10, 99]]
    assert labels == [[-100, -100, -100, 10, 11, 99], [-100, -100, -100, 10, 99, -100]]


def test_memory_guard_counts_metal_allocations(monkeypatch) -> None:
    guard = MemoryGuard(4)
    monkeypatch.setattr(guard.process, "memory_info", lambda: type("M", (), {"rss": 1 * 1024**3})())
    guard.extra_bytes = lambda: 4 * 1024**3
    with pytest.raises(RuntimeError, match="above the 4 GB limit"):
        guard.check("training")


def test_memory_guard_stops_after_process_crosses_cap(monkeypatch) -> None:
    guard = MemoryGuard(4)
    monkeypatch.setattr(guard.process, "memory_info", lambda: type("M", (), {"rss": 5 * 1024**3})())
    with pytest.raises(RuntimeError, match="above the 4 GB limit"):
        guard.check("training")


def test_sanitize_model_name_is_filesystem_and_picker_safe() -> None:
    assert jobs.sanitize_model_name("My Voice v2") == "My-Voice-v2"
    assert jobs.sanitize_model_name("  .hidden/../etc  ") == "hidden..etc"
    assert jobs.sanitize_model_name("!!!") == ""
    assert len(jobs.sanitize_model_name("x" * 200)) == 80


def test_start_job_rejects_name_collisions(monkeypatch, tmp_path) -> None:
    from flowy.training import pipeline

    monkeypatch.setattr(pipeline, "custom_models_root", lambda: tmp_path)
    (tmp_path / "my-voice").mkdir()

    with pytest.raises(ValueError, match="already exists"):
        jobs.start_job(source_model="large-v3", custom_name="my voice")


def test_start_job_requires_fifty_eligible_samples(monkeypatch) -> None:
    monkeypatch.setattr(pipeline, "whisperkit_converter", lambda: "/usr/bin/true")
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


def _ready(monkeypatch) -> None:
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


def _wait_for_state(job_id: str, *states: str):
    import time

    for _ in range(400):
        current = jobs.get_job(job_id)
        if current is not None and current.state in states:
            return current
        time.sleep(0.005)
    raise AssertionError(f"job never reached {states}")


def _no_tools(monkeypatch, tmp_path) -> None:
    monkeypatch.delenv("WHISPERKIT_GENERATE_MODEL", raising=False)
    monkeypatch.setenv("SLIVE_WHISPERKIT_TOOLS", str(tmp_path / "no-tools"))
    monkeypatch.setattr(pipeline.shutil, "which", lambda _name: None)


def test_missing_whisperkit_converter_fails_before_any_work(monkeypatch, tmp_path) -> None:
    _no_tools(monkeypatch, tmp_path)
    monkeypatch.setattr(
        jobs, "readiness", lambda _=None: pytest.fail("readiness ran before the preflight"))

    with pytest.raises(pipeline.ConverterUnavailable, match="install-whisperkit-tools.sh"):
        jobs.start_job(source_model="tiny")


def test_whisperkit_converter_env_must_be_executable(monkeypatch, tmp_path) -> None:
    monkeypatch.setattr(pipeline, "_compiler_available", lambda: True)
    monkeypatch.setenv("WHISPERKIT_GENERATE_MODEL", str(tmp_path / "nope"))
    with pytest.raises(ValueError, match="not an executable file"):
        pipeline.whisperkit_converter()

    tool = tmp_path / "whisperkit-generate-model"
    tool.write_text("#!/bin/sh\n", encoding="utf-8")
    tool.chmod(0o755)
    monkeypatch.setenv("WHISPERKIT_GENERATE_MODEL", str(tool))
    assert pipeline.whisperkit_converter() == str(tool)


def test_run_pipeline_checks_converter_before_reading_the_store(monkeypatch, tmp_path) -> None:
    _no_tools(monkeypatch, tmp_path)
    monkeypatch.setattr(
        pipeline, "TrainingStore", lambda *_a, **_k: pytest.fail("store read before preflight"))
    config = PipelineConfig.for_model(model_name="x", source_model="tiny", output_root=tmp_path)

    with pytest.raises(ValueError, match="isn't installed"):
        pipeline.run_pipeline(config, lambda **_: None)
    assert not (tmp_path / "x").exists()


def test_retry_after_failed_run_sets_old_run_dir_aside(monkeypatch, tmp_path) -> None:
    jobs._jobs.clear()
    _ready(monkeypatch)
    monkeypatch.setattr(pipeline, "custom_models_root", lambda: tmp_path / "Custom")
    runs = tmp_path / "runs"
    (runs / "my-voice" / "merged-hf").mkdir(parents=True)
    (runs / "my-voice" / "conversion.log").write_text("failed", encoding="utf-8")
    (tmp_path / "Custom" / ".my-voice.staging").mkdir(parents=True)

    def runner(config: PipelineConfig, progress):
        run_dir = runs / config.model_name
        run_dir.mkdir(parents=True, exist_ok=False)  # as run_pipeline does
        progress(stage="training", message="Training", value=0.5, run_dir=str(run_dir))
        return tmp_path / "Custom" / config.model_name

    job = jobs.start_job(custom_name="my voice", output_root=runs, runner=runner)

    assert _wait_for_state(job.id, "done", "error").state == "done"
    aside = [p for p in runs.iterdir() if p.name.startswith("my-voice.failed-")]
    assert len(aside) == 1
    assert (aside[0] / "conversion.log").read_text(encoding="utf-8") == "failed"
    assert not (tmp_path / "Custom" / ".my-voice.staging").exists()


def test_installed_model_name_still_collides_even_with_run_dir(monkeypatch, tmp_path) -> None:
    monkeypatch.setattr(pipeline, "custom_models_root", lambda: tmp_path / "Custom")
    (tmp_path / "Custom" / "my-voice").mkdir(parents=True)
    (tmp_path / "runs" / "my-voice").mkdir(parents=True)

    with pytest.raises(ValueError, match="already exists"):
        jobs.start_job(custom_name="my voice", output_root=tmp_path / "runs",
                       runner=lambda *_: None)
    assert (tmp_path / "runs" / "my-voice").is_dir()


def test_non_finite_metrics_are_stored_as_null_and_serialize(monkeypatch, tmp_path) -> None:
    import json

    jobs._jobs.clear()
    _ready(monkeypatch)
    monkeypatch.setattr(pipeline, "custom_models_root", lambda: tmp_path / "Custom")

    def runner(config: PipelineConfig, progress):
        progress(stage="training", message="Training", value=0.3,
                 metric={"update": 1, "loss": 2.0, "kl": float("inf")})
        progress(stage="training", message="Training", value=float("nan"),
                 metric={"update": 2, "loss": float("nan"), "kl": 0.1})
        raise RuntimeError("diverged")

    job = jobs.start_job(output_root=tmp_path / "runs", runner=runner)
    current = _wait_for_state(job.id, "error")

    # Swift decodes loss/progress as numbers and kl as optional.
    assert current.metrics == [{"update": 1, "loss": 2.0, "kl": None}]
    assert current.progress == 0.3
    json.dumps(current.to_dict(), allow_nan=False)  # what JSONResponse does


def test_require_finite_loss_aborts_on_nan_and_inf() -> None:
    pipeline.require_finite_loss("epoch 1 step 1", loss=2.5, kl=0.01)
    with pytest.raises(RuntimeError, match="diverged at epoch 1 step 3: loss=nan"):
        pipeline.require_finite_loss("epoch 1 step 3", loss=float("nan"), kl=0.1)
    with pytest.raises(RuntimeError, match="kl=inf"):
        pipeline.require_finite_loss("epoch 2 step 1", loss=1.0, kl=float("inf"))


def test_qlora_teacher_forcing_has_single_sot_and_masks_prefix() -> None:
    # tokenizer(text).input_ids with prefix: SOT en transcribe notimestamps w1 w2 EOT
    sot, en, transcribe, notimestamps, eot = 50258, 50259, 50360, 50364, 50257
    sequence = [sot, en, transcribe, notimestamps, 11, 12, eot]

    decoder_ids, labels = pipeline.teacher_forcing_pair(sequence, forced=3)

    assert decoder_ids == [sot, en, transcribe, notimestamps, 11, 12]
    assert decoder_ids.count(sot) == 1
    assert labels == [-100, -100, -100, 11, 12, eot]
    assert len(labels) == len(decoder_ids)


def test_configure_prefix_tokens_counts_tokens_after_sot() -> None:
    class Tokenizer:
        def set_prefix_tokens(self, **kwargs):
            self.kwargs = kwargs
            self.prefix_tokens = [1, 2, 3, 4] if "language" in kwargs else [1, 4]

    def model(multilingual):
        config = type("G", (), {"is_multilingual": multilingual})()
        return type("M", (), {"generation_config": config})()

    tok = Tokenizer()
    assert pipeline.configure_prefix_tokens(tok, model(True)) == 3
    assert tok.kwargs == {"language": "en", "task": "transcribe", "predict_timestamps": False}
    assert pipeline.configure_prefix_tokens(tok, model(False)) == 1


def _executable(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("#!/bin/sh\n", encoding="utf-8")
    path.chmod(0o755)
    return path


def test_converter_prefers_slive_tools_venv_and_puts_shim_first(monkeypatch, tmp_path) -> None:
    monkeypatch.delenv("WHISPERKIT_GENERATE_MODEL", raising=False)
    monkeypatch.setenv("SLIVE_WHISPERKIT_TOOLS", str(tmp_path))
    tool = _executable(tmp_path / "venv" / "bin" / "whisperkit-generate-model")
    _executable(tmp_path / "shim" / "xcrun")

    assert pipeline.whisperkit_converter() == str(tool)
    assert pipeline.converter_env()["PATH"].split(":")[0] == str(tmp_path / "shim")


def test_converter_without_any_compiler_is_unavailable(monkeypatch, tmp_path) -> None:
    monkeypatch.setenv("SLIVE_WHISPERKIT_TOOLS", str(tmp_path))
    monkeypatch.setenv("WHISPERKIT_GENERATE_MODEL", str(_executable(tmp_path / "wk")))
    monkeypatch.setattr(
        pipeline.subprocess, "run", lambda *_a, **_k: type("R", (), {"returncode": 1})())
    with pytest.raises(pipeline.ConverterUnavailable, match="Xcode or the Slive compile shim"):
        pipeline.whisperkit_converter()


def test_tokenizer_repo_matches_whisperkit_variant_detection() -> None:
    assert pipeline.whisperkit_tokenizer_repo(51866, 1280) == "openai/whisper-large-v3"
    assert pipeline.whisperkit_tokenizer_repo(51865, 1280) == "openai/whisper-large-v2"
    assert pipeline.whisperkit_tokenizer_repo(51865, 384) == "openai/whisper-tiny"
    assert pipeline.whisperkit_tokenizer_repo(51864, 768) == "openai/whisper-small.en"


def _fake_whisperkit(folder, *, mel=True):
    for name in pipeline.WHISPERKIT_MODELS:
        if mel or name != "MelSpectrogram.mlmodelc":
            (folder / name).mkdir(parents=True)
    return folder


def test_converter_output_needs_mel_and_picks_shallowest(tmp_path) -> None:
    _fake_whisperkit(tmp_path / "a" / "deep" / "variant")
    _fake_whisperkit(tmp_path / "b", mel=False)
    assert pipeline.find_whisperkit_folder(tmp_path) == tmp_path / "a" / "deep" / "variant"
    _fake_whisperkit(tmp_path / "c")
    assert pipeline.find_whisperkit_folder(tmp_path) == tmp_path / "c"


def test_install_lays_tokenizer_out_where_whisperkit_looks(monkeypatch, tmp_path) -> None:
    import json

    monkeypatch.setattr(pipeline, "custom_models_root", lambda: tmp_path / "Custom")
    merged = tmp_path / "merged"
    merged.mkdir()
    (merged / "config.json").write_text(json.dumps({"vocab_size": 51866, "d_model": 1280}))
    (merged / "tokenizer.json").write_text("{}")
    (merged / "tokenizer_config.json").write_text("{}")
    config = PipelineConfig.for_model(model_name="voice", source_model="large-v3-v20240930_626MB")

    with pytest.raises(RuntimeError, match="MelSpectrogram"):
        pipeline._install_model(config, _fake_whisperkit(tmp_path / "nomel", mel=False),
                                merged, tmp_path, tmp_path / "m.jsonl")
    installed = pipeline._install_model(config, _fake_whisperkit(tmp_path / "out"), merged,
                                        tmp_path, tmp_path / "m.jsonl")
    tokenizer = installed / "tokenizer" / "models" / "openai" / "whisper-large-v3"
    assert (tokenizer / "tokenizer.json").is_file()
    assert (tokenizer / "tokenizer_config.json").is_file()
    manifest = json.loads((installed / "manifest.json").read_text())
    assert manifest["tokenizer_folder"] == "tokenizer"
    assert manifest["created_at"][:4].isdigit()


def test_qlora_is_refused_up_front_without_cuda(monkeypatch) -> None:
    monkeypatch.setattr(pipeline, "whisperkit_converter", lambda: "/bin/true")
    monkeypatch.setattr(
        jobs, "readiness", lambda _=None: pytest.fail("readiness ran before the preflight"))
    with pytest.raises(jobs.TrainingUnavailable, match="NVIDIA"):
        jobs.start_job(source_model="tiny", method="qlora")


def test_start_refuses_when_disk_is_too_full(monkeypatch, tmp_path) -> None:
    _ready(monkeypatch)
    monkeypatch.setattr(jobs.shutil, "disk_usage", lambda _p: type("D", (), {"free": 1024**3})())
    with pytest.raises(jobs.TrainingUnavailable, match="free disk"):
        jobs.start_job(source_model="tiny", output_root=tmp_path, runner=lambda c, p: tmp_path)


def test_failed_status_write_never_leaves_a_job_running(monkeypatch, tmp_path) -> None:
    jobs._jobs.clear()
    _ready(monkeypatch)

    def broken_write(_job):
        raise RuntimeError("disk full")

    monkeypatch.setattr(jobs, "_write_job_file", broken_write)

    def runner(config, progress):
        progress(stage="training", message="Training", value=0.5, run_dir=str(tmp_path))
        raise AssertionError("unreachable")

    job = jobs.start_job(source_model="tiny", output_root=tmp_path, runner=runner)
    done = _wait_for_state(job.id, "error")
    assert "disk full" in done.error
    assert done.failed_stage == "preparing"


def test_failed_job_records_the_stage_it_failed_in(monkeypatch, tmp_path) -> None:
    jobs._jobs.clear()
    _ready(monkeypatch)

    def runner(config, progress):
        progress(stage="converting", message="Converting", value=0.84)
        raise RuntimeError("conversion broke")

    job = jobs.start_job(source_model="tiny", output_root=tmp_path, runner=runner)
    done = _wait_for_state(job.id, "error")
    assert (done.stage, done.failed_stage, done.error) == ("error", "converting", "conversion broke")


def test_restart_marks_running_jobs_interrupted_and_reloads_them(monkeypatch, tmp_path) -> None:
    import json

    jobs._jobs.clear()
    monkeypatch.setattr(pipeline, "custom_models_root", lambda: tmp_path / "Custom")
    run = tmp_path / "runs" / "voice"
    (run / "encoder-cache").mkdir(parents=True)
    (run / "merged-hf").mkdir()
    (run / "adapter").mkdir()
    (tmp_path / "Custom" / ".voice.staging").mkdir(parents=True)
    old = jobs.TrainingJob(id="j1", model_name="voice", source_model="tiny", base_model="b",
                           method="hybrid", max_ram_gb=8, state="running", stage="training",
                           run_dir=str(run))
    (run / "job.json").write_text(json.dumps(old.to_dict()))

    assert jobs.recover_interrupted(tmp_path / "runs") == 1
    latest = jobs.latest_job()
    assert (latest.id, latest.state, latest.failed_stage) == ("j1", "error", "training")
    assert "Interrupted" in latest.error
    assert not (run / "encoder-cache").exists() and not (run / "merged-hf").exists()
    assert (run / "adapter").exists()
    assert json.loads((run / "job.json").read_text())["state"] == "error"
    assert not (tmp_path / "Custom" / ".voice.staging").exists()


def test_start_endpoint_status_reflects_the_kind_of_failure(monkeypatch) -> None:
    from fastapi.testclient import TestClient

    from flowy import server

    client = TestClient(server.app, base_url="http://127.0.0.1:50711")
    cases = [
        (jobs.TrainingUnavailable("no converter"), 424),
        (jobs.TrainingConflict("already running"), 409),
        (ValueError("bad ram"), 422),
    ]
    for error, status in cases:
        def refuse(**_kwargs):
            raise error

        monkeypatch.setattr(server.training_jobs, "start_job", refuse)
        response = client.post("/training/start", json={"source_model": "tiny"})
        assert response.status_code == status
        assert response.json() == {"error": str(error)}


def test_conversion_runs_space_free_and_collects_the_model(monkeypatch, tmp_path) -> None:
    # Run dirs live under "Application Support"; argmaxtools shells out with
    # unquoted paths, so the converter must only ever see space-free ones.
    run = tmp_path / "Application Support" / "run"
    merged = run / "merged-hf"
    merged.mkdir(parents=True)
    converter = tmp_path / "fake-converter"
    converter.write_text(
        "#!/bin/sh\n"
        'case "$2$4" in *" "*) echo "space in $2 $4"; exit 3;; esac\n'
        'test -d "$2" || exit 4\n'
        'for m in AudioEncoder TextDecoder MelSpectrogram; do mkdir -p "$4/x_model/$m.mlmodelc"; done\n'
        'echo converted\n',
        encoding="utf-8",
    )
    converter.chmod(0o755)
    monkeypatch.setattr(pipeline.time, "sleep", lambda _s: None)
    beats = []

    folder = pipeline._convert_whisperkit(merged, run / "whisperkit", str(converter),
                                          lambda **kw: beats.append(kw))

    assert folder == run / "whisperkit" / "model"
    assert all((folder / name).is_dir() for name in pipeline.WHISPERKIT_MODELS)
    assert "converted" in (run / "whisperkit" / "conversion.log").read_text()


def test_conversion_failure_reports_the_log_tail(monkeypatch, tmp_path) -> None:
    converter = tmp_path / "fail"
    converter.write_text("#!/bin/sh\necho 'xcrun: unable to find utility'\nexit 1\n")
    converter.chmod(0o755)
    monkeypatch.setattr(pipeline.time, "sleep", lambda _s: None)
    (tmp_path / "merged").mkdir()
    with pytest.raises(RuntimeError, match="unable to find utility"):
        pipeline._convert_whisperkit(tmp_path / "merged", tmp_path / "wk", str(converter))
