"""The HTTP contract the Swift app relies on, served by ``create_app`` with fake
providers and services: paths, status codes, ``{"error"}`` bodies, NDJSON
framing. No network, no models, no threads."""

from __future__ import annotations

import base64
import json
from dataclasses import dataclass, field
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from flowy.api import Services, create_app
from flowy.errors import Conflict, NotFound, Unavailable
from flowy.jobs import JobRunner
from flowy.label_consensus import LabelFatalError
from flowy.providers import TRANSCRIBE_PROMPT, Gateway, ProviderRegistry
from flowy.settings import Settings
from flowy.training.jobs import TrainingConflict
from flowy.training.pipeline import TrainingUnavailable

AUDIO = base64.b64encode(b"\0" * 8_000).decode()


class FakeProvider:
    name = "fake"
    requires_key = True

    def __init__(self) -> None:
        self.deltas: list[str] = ["Hel", "lo"]
        self.fail: Exception | None = None
        self.seen: list = []

    def label(self, base_url):
        return "Fake"

    async def chat(self, req):
        self.seen.append(req)
        if self.fail:
            raise self.fail
        return f"reply to {req.text}"

    async def stream(self, req):
        self.seen.append(req)
        for d in self.deltas:
            yield d
        if self.fail:
            raise self.fail

    async def list_models(self, api_key, base_url):
        if self.fail:
            raise self.fail
        return ["fake-2", "fake-1"]

    async def transcribe_audio(self, req):
        self.seen.append(req)
        if self.fail:
            raise self.fail
        return "heard it", f"prompt + {req.vocab_hint}"


class FakeLabeler:
    def __init__(self) -> None:
        self.fail: Exception | None = None

    async def label(self, **kwargs):
        if self.fail:
            raise self.fail
        return {"text": "label", "chosen": "gpt-transcribe", "agreement": 1.0,
                "candidates": {"gpt-transcribe": "label"}, "prompt": kwargs["context"]}


class FakeLocal:
    def __init__(self) -> None:
        self.cached = {"a/b": {"repo_id": "a/b", "size_bytes": 1, "nb_files": 1,
                               "last_modified": 0.0}}
        self.started: list = []
        self.running = False

    def list_cached_models(self):
        return list(self.cached.values())

    def delete_cached_model(self, repo_id):
        return self.cached.pop(repo_id, None) is not None

    def start_download(self, repo_id, token):
        self.started.append((repo_id, token))
        return "job1"

    def download_status(self, job_id):
        if job_id != "job1":
            return None
        return {"id": "job1", "repo_id": "a/b", "state": "running", "message": "", "path": None}

    def busy(self):
        return self.running


@dataclass
class FakeJob:
    id: str
    state: str = "queued"

    def to_dict(self):
        return {"id": self.id, "state": self.state}


@dataclass
class FakeTraining:
    fail: Exception | None = None
    jobs: dict = field(default_factory=dict)
    calls: list = field(default_factory=list)

    def readiness(self):
        return {"ready": False, "eligible_count": 3}

    def start_job(self, **kwargs):
        self.calls.append(kwargs)
        if self.fail:
            raise self.fail
        self.jobs["t1"] = FakeJob("t1")
        return self.jobs["t1"]

    def resume_job(self, job_id):
        if self.fail:
            raise self.fail
        return self.jobs[job_id]

    def latest_job(self):
        return next(reversed(self.jobs.values()), None)

    def get_job(self, job_id):
        return self.jobs.get(job_id)

    def busy(self):
        return False

    def recover_interrupted(self):
        return 0


@dataclass
class World:
    client: TestClient
    provider: FakeProvider
    labeler: FakeLabeler
    local: FakeLocal
    training: FakeTraining


@pytest.fixture
def world() -> World:
    provider = FakeProvider()
    services = Services(
        ai=Gateway(ProviderRegistry([provider])),
        labeler=FakeLabeler(),
        local_models=FakeLocal(),
        training=FakeTraining(),
    )
    app = create_app(Settings.from_env({}), services)
    client = TestClient(app, base_url="http://127.0.0.1:50711")
    return World(client, provider, services.labeler, services.local_models, services.training)


def _chat(**extra) -> dict:
    return {"text": "hi", "provider": "fake", "model": "m", "api_key": "k", **extra}


def _ndjson(resp) -> list[dict]:
    return [json.loads(line) for line in resp.text.splitlines() if line]


# --- /health -----------------------------------------------------------------

def test_health_is_busy_while_a_service_job_runs(world: World) -> None:
    assert world.client.get("/health").json() == {"status": "ok", "busy": False}
    world.local.running = True
    assert world.client.get("/health").json() == {"status": "ok", "busy": True}


def test_created_app_is_local_only(world: World) -> None:
    assert world.client.get("/health", headers={"Host": "evil.example"}).status_code == 403
    resp = world.client.get("/health", headers={"Origin": "https://evil.example"})
    assert resp.json() == {"error": "Forbidden: local app requests only."}


# --- /assistant ----------------------------------------------------------------

def test_assistant_returns_text_and_passes_the_whole_request(world: World) -> None:
    resp = world.client.post("/assistant", json=_chat(
        images=[{"media_type": "image/png", "data": "QUJD"}],
        history=[{"role": "user", "content": "before"}],
        api_key="  k\n", local_mem_gb=6,
    ))
    assert (resp.status_code, resp.json()) == (200, {"text": "reply to hi"})
    req = world.provider.seen[0]
    assert req.api_key == "k"  # whitespace stripped at the boundary
    assert req.images == [{"media_type": "image/png", "data": "QUJD"}]
    assert req.history == [{"role": "user", "content": "before"}]
    assert (req.max_tokens, req.local_quantized, req.local_mem_gb) == (1024, True, 6)


@pytest.mark.parametrize("error, status, message", [
    (ValueError("bad input"), 400, "bad input"),
    (RuntimeError("upstream broke"), 502, "upstream broke"),
    (TimeoutError(), 502, "TimeoutError"),
])
def test_assistant_error_mapping(world: World, error, status, message) -> None:
    world.provider.fail = error
    resp = world.client.post("/assistant", json=_chat())
    assert (resp.status_code, resp.json()) == (status, {"error": message})


@pytest.mark.parametrize("body, message", [
    (_chat(text="  "), "Empty prompt text"),
    (_chat(api_key=""), "Missing api_key"),
    (_chat(provider="nope"), "Unknown provider: nope"),
    (_chat(provider="nope", api_key=""), "Missing api_key"),
])
def test_assistant_request_checks_are_400s(world: World, body, message) -> None:
    resp = world.client.post("/assistant", json=body)
    assert (resp.status_code, resp.json()) == (400, {"error": message})


def test_control_characters_in_a_key_are_a_validation_error(world: World) -> None:
    resp = world.client.post("/assistant", json=_chat(api_key="k\x00ey"))
    assert resp.status_code == 422
    assert "detail" in resp.json()


# --- /assistant/stream ---------------------------------------------------------

def test_stream_frames_deltas_then_done(world: World) -> None:
    resp = world.client.post("/assistant/stream", json=_chat())
    assert resp.status_code == 200
    assert resp.headers["content-type"] == "application/x-ndjson"
    assert resp.text == '{"delta": "Hel"}\n{"delta": "lo"}\n{"done": true}\n'


def test_stream_failure_after_partial_text_is_an_error_line(world: World) -> None:
    world.provider.fail = RuntimeError("cut off")
    resp = world.client.post("/assistant/stream", json=_chat())
    assert resp.status_code == 200
    assert _ndjson(resp) == [{"delta": "Hel"}, {"delta": "lo"}, {"error": "cut off"}]


def test_stream_with_no_text_names_the_provider(world: World) -> None:
    world.provider.deltas = []
    resp = world.client.post("/assistant/stream", json=_chat())
    assert _ndjson(resp) == [{"error": "Fake returned an empty answer — try again."}]


def test_stream_request_errors_ride_in_the_stream(world: World) -> None:
    resp = world.client.post("/assistant/stream", json=_chat(provider="nope"))
    assert resp.status_code == 200
    assert _ndjson(resp) == [{"error": "Unknown provider: nope"}]


# --- /models -------------------------------------------------------------------

def test_models_lists_and_maps_errors(world: World) -> None:
    body = {"provider": "fake", "api_key": "k"}
    assert world.client.post("/models", json=body).json() == {"models": ["fake-2", "fake-1"]}
    resp = world.client.post("/models", json={**body, "api_key": ""})
    assert (resp.status_code, resp.json()) == (400, {"error": "Missing api_key"})
    world.provider.fail = OSError("dns")
    resp = world.client.post("/models", json=body)
    assert (resp.status_code, resp.json()) == (502, {"error": "dns"})


# --- /transcribe_llm -------------------------------------------------------------

def test_transcribe_llm_returns_text_and_prompt(world: World) -> None:
    resp = world.client.post("/transcribe_llm", json={
        "provider": "fake", "model": "m", "api_key": "k", "audio_b64": AUDIO,
        "vocab_hint": "Slive",
    })
    assert resp.status_code == 200
    assert resp.json() == {"text": "heard it", "prompt": "prompt + Slive"}


def test_transcribe_llm_rejects_truncated_audio_before_the_provider(world: World) -> None:
    resp = world.client.post("/transcribe_llm", json={
        "provider": "fake", "model": "m", "api_key": "k",
        "audio_b64": base64.b64encode(b"\0" * 10).decode(),
    })
    assert resp.status_code == 400
    assert resp.json()["error"].startswith("Audio payload is only 10 bytes")
    assert world.provider.seen == []


def test_transcribe_llm_default_prompt(world: World) -> None:
    assert world.client.get("/transcribe_llm/prompt").json() == {"prompt": TRANSCRIBE_PROMPT}


# --- /label_consensus -------------------------------------------------------------

def _label(world: World):
    return world.client.post("/label_consensus", json={
        "api_key": "k", "audio_b64": AUDIO, "context": "ctx"})


def test_label_consensus_success(world: World) -> None:
    resp = _label(world)
    assert resp.status_code == 200
    assert resp.json()["prompt"] == "ctx"


@pytest.mark.parametrize("error, status, body", [
    (LabelFatalError("quota", "Out of quota."), 401, {"error": "Out of quota.", "fatal": "quota"}),
    (LabelFatalError("auth", "Bad key."), 401, {"error": "Bad key.", "fatal": "auth"}),
    (ValueError("Both transcribers failed — x"), 400, {"error": "Both transcribers failed — x"}),
    (RuntimeError("boom"), 502, {"error": "boom"}),
])
def test_label_consensus_error_mapping(world: World, error, status, body) -> None:
    world.labeler.fail = error
    resp = _label(world)
    assert (resp.status_code, resp.json()) == (status, body)


# --- /local/* ----------------------------------------------------------------------

def test_local_cache_and_delete(world: World) -> None:
    assert world.client.get("/local/cache").json()["models"][0]["repo_id"] == "a/b"
    assert world.client.post("/local/delete", json={"repo_id": "a/b"}).json() == {"deleted": "a/b"}
    resp = world.client.post("/local/delete", json={"repo_id": "a/b"})
    assert (resp.status_code, resp.json()) == (404, {"error": "Not in the cache."})


@pytest.mark.parametrize("repo_id", ["", "  ", "noslash", "a/\x01b"])
def test_local_download_rejects_bad_ids_with_a_readable_400(world: World, repo_id) -> None:
    resp = world.client.post("/local/download", json={"repo_id": repo_id})
    assert resp.status_code == 400
    assert resp.json() == {"error": "Enter a model id like 'owner/name'."}
    assert world.local.started == []


def test_local_download_starts_and_polls(world: World) -> None:
    resp = world.client.post("/local/download", json={"repo_id": " a/b ", "token": "  "})
    assert resp.json() == {"job_id": "job1"}
    assert world.local.started == [("a/b", None)]
    assert world.client.get("/local/download/job1").json()["state"] == "running"
    resp = world.client.get("/local/download/nope")
    assert (resp.status_code, resp.json()) == (404, {"error": "Unknown job."})


# --- /training/* --------------------------------------------------------------------

def test_training_start_is_202_with_the_job(world: World) -> None:
    resp = world.client.post("/training/start", json={"source_model": "tiny", "name": "voice"})
    assert (resp.status_code, resp.json()) == (202, {"job": {"id": "t1", "state": "queued"}})
    assert world.training.calls == [{"source_model": "tiny", "method": "hybrid",
                                     "custom_name": "voice", "max_ram_gb": 12.0}]


@pytest.mark.parametrize("error, status", [
    (TrainingConflict("Already training."), 409),
    (TrainingUnavailable("Needs 9 GB free disk (2 free)."), 424),
    (Conflict("taken"), 409),
    (Unavailable("no converter"), 424),
    (ValueError("Unsupported training method: x"), 422),
])
def test_training_start_status_reflects_the_failure(world: World, error, status) -> None:
    world.training.fail = error
    resp = world.client.post("/training/start", json={"source_model": "tiny"})
    assert (resp.status_code, resp.json()) == (status, {"error": str(error)})


def test_training_start_ram_bounds_are_a_validation_error(world: World) -> None:
    resp = world.client.post("/training/start", json={"source_model": "tiny", "max_ram_gb": 1})
    assert resp.status_code == 422
    assert "detail" in resp.json()


def test_training_resume_status_codes(world: World) -> None:
    world.training.jobs["t1"] = FakeJob("t1", "error")
    resp = world.client.post("/training/jobs/t1/resume")
    assert (resp.status_code, resp.json()["job"]["id"]) == (202, "t1")
    for error, status in [(NotFound("Unknown training job x"), 404),
                          (TrainingConflict("is already installed"), 409),
                          (TrainingUnavailable("disk"), 424),
                          (ValueError("bad"), 422)]:
        world.training.fail = error
        resp = world.client.post("/training/jobs/x/resume")
        assert (resp.status_code, resp.json()) == (status, {"error": str(error)})


def test_training_polls(world: World) -> None:
    assert world.client.get("/training/jobs/latest").json() == {"job": None}
    world.training.jobs["t1"] = FakeJob("t1", "running")
    assert world.client.get("/training/jobs/latest").json() == {
        "job": {"id": "t1", "state": "running"}}
    assert world.client.get("/training/jobs/t1").json()["job"]["state"] == "running"
    resp = world.client.get("/training/jobs/nope")
    assert (resp.status_code, resp.json()) == (404, {"error": "Unknown training job."})
    assert world.client.get("/training/readiness").json() == {"ready": False, "eligible_count": 3}
    assert world.client.get("/training/models").json()["models"]


def test_real_resume_of_an_unknown_job_is_404(world: World) -> None:
    from flowy.training import jobs

    world.client.app.state.services.training = jobs
    resp = world.client.post("/training/jobs/never-existed/resume")
    assert (resp.status_code, resp.json()) == (404, {"error": "Unknown training job never-existed"})


# --- seams ------------------------------------------------------------------------------

def test_registry_reports_missing_key_before_unknown_provider() -> None:
    from flowy.providers import default_registry

    registry = default_registry()
    assert set(registry.names()) == {"anthropic", "openai", "openai_compatible", "gemini", "local"}
    with pytest.raises(ValueError, match="Missing api_key"):
        registry.resolve("nope", "")
    with pytest.raises(ValueError, match="Unknown provider: nope"):
        registry.resolve("nope", "k")
    with pytest.raises(ValueError, match="Missing api_key"):
        registry.resolve("openai", "")
    assert registry.resolve("local", "").name == "local"  # on-device needs no key


def test_job_runner_tracks_busy_latest_and_persists() -> None:
    @dataclass
    class Job:
        id: str
        state: str = "running"

    written: list[tuple[str, str]] = []
    runner: JobRunner[Job] = JobRunner(("queued", "running"),
                                       persist=lambda j: written.append((j.id, j.state)))
    assert not runner.busy() and runner.latest() is None
    runner.add(Job("a"))
    runner.add(Job("b", "queued"))
    assert runner.busy() and runner.latest().id == "b" and runner.active().id == "a"
    runner.update("a", state="done")
    runner.mutate("b", lambda j: setattr(j, "state", "error"))
    assert not runner.busy()
    assert written == [("a", "done"), ("b", "error")]
    runner.restore([Job("a", "running"), Job("c", "done")])
    assert runner.get("a").state == "done"  # a known id wins over the reloaded copy
    assert runner.latest().id == "c"


def test_settings_read_env_overrides_and_defaults(tmp_path: Path) -> None:
    defaults = Settings.from_env({})
    assert (defaults.host, defaults.port) == ("127.0.0.1", 50711)
    assert defaults.training_dir == defaults.app_support / "training"
    assert defaults.custom_models_dir == defaults.app_support / "Models" / "Custom"
    assert defaults.app_support.parts[-3:] == ("Library", "Application Support", "Slive")
    assert (defaults.parent_pid, defaults.own_process_group) == (0, False)

    custom = Settings.from_env({
        "SLIVE_TRAINING_DIR": str(tmp_path / "t"),
        "SLIVE_TRAINING_OUTPUT_DIR": str(tmp_path / "runs"),
        "SLIVE_CUSTOM_MODELS_DIR": str(tmp_path / "custom"),
        "SLIVE_WHISPERKIT_TOOLS": str(tmp_path / "tools"),
        "WHISPERKIT_GENERATE_MODEL": "/x/wk",
        "SLIVE_PARENT_PID": "4242",
        "SLIVE_PROCESS_GROUP": "1",
    })
    assert custom.training_dir == tmp_path / "t"
    assert custom.training_output_dir == tmp_path / "runs"
    assert custom.custom_models_dir == tmp_path / "custom"
    assert custom.whisperkit_tools_dir == tmp_path / "tools"
    assert (custom.whisperkit_generate_model, custom.parent_pid, custom.own_process_group) == (
        "/x/wk", 4242, True)
    assert Settings.from_env({"SLIVE_PARENT_PID": "abc"}).parent_pid == 0


def test_training_paths_follow_the_environment(monkeypatch, tmp_path: Path) -> None:
    from flowy.training import pipeline, store

    monkeypatch.setenv("SLIVE_TRAINING_DIR", str(tmp_path / "t"))
    monkeypatch.setenv("SLIVE_CUSTOM_MODELS_DIR", str(tmp_path / "c"))
    assert store.default_store_root() == tmp_path / "t"
    assert pipeline.custom_models_root() == tmp_path / "c"
