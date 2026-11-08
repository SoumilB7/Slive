"""Fixtures shared by the config-matrix suites: a fake upstream for every
httpx call, a per-test deadline, and an app wired to the real gateway and
labelers (only the background services are faked)."""

from __future__ import annotations

import signal

import httpx
import pytest
from fastapi.testclient import TestClient

from flowy import label_consensus, label_format
from flowy.api import Services, create_app
from flowy.providers import Gateway, default_registry
from flowy.settings import Settings
from test_http_api import FakeLocal, FakeTraining

#: Seconds a matrix case may take before it counts as a hang.
DEADLINE_SECONDS = 5.0


@pytest.fixture
def deadline():
    """Fail (instead of hanging the run) when one case takes too long."""

    def expired(_signum, _frame):
        raise TimeoutError(f"test exceeded {DEADLINE_SECONDS:.0f}s — a hung stream or call")

    previous = signal.signal(signal.SIGALRM, expired)
    signal.setitimer(signal.ITIMER_REAL, DEADLINE_SECONDS)
    try:
        yield
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous)


@pytest.fixture
def fake_http(monkeypatch):
    """Answer every ``httpx.AsyncClient`` request with ``handler(request)``
    and skip retry backoff. Unset handler = the call fails at once, so a
    test that forgot to fake a path can never reach the network."""
    seen: list[httpx.Request] = []
    state: dict = {"handler": None}
    real_client = httpx.AsyncClient

    def answer(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        if state["handler"] is None:
            raise httpx.ConnectError("no fake upstream installed", request=request)
        return state["handler"](request)

    def factory(*args, **kwargs):
        kwargs["transport"] = httpx.MockTransport(answer)
        return real_client(*args, **kwargs)

    async def no_sleep(_seconds: float) -> None:
        return None

    monkeypatch.setattr(httpx, "AsyncClient", factory)
    monkeypatch.setattr(label_consensus, "_sleep", no_sleep)
    monkeypatch.setattr(label_format, "_sleep", no_sleep)

    def install(handler):
        state["handler"] = handler
        return seen

    return install


@pytest.fixture(scope="module")
def real_client() -> TestClient:
    """The production gateway, labeler and formatter behind the real app;
    downloads and training are faked (they never touch an upstream)."""
    services = Services(ai=Gateway(default_registry()), labeler=label_consensus,
                        local_models=FakeLocal(), training=FakeTraining(),
                        formatter=label_format)
    app = create_app(Settings.from_env({}), services)
    return TestClient(app, base_url="http://127.0.0.1:50711")
