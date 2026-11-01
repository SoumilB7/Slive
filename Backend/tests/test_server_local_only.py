"""The local port only serves the app: loopback Host, no browser Origin."""

import pytest
from fastapi.testclient import TestClient

from flowy import lifecycle, server
from flowy.api.middleware import InFlightMiddleware
from flowy.api.routes.health import is_busy


@pytest.fixture
def client() -> TestClient:
    # TestClient defaults to Host "testserver" — use the app's real base URL.
    return TestClient(server.app, base_url="http://127.0.0.1:50711")


@pytest.mark.parametrize("host", ["127.0.0.1:50711", "localhost:50711", "127.0.0.1", "[::1]:50711"])
def test_loopback_hosts_are_served(client: TestClient, host: str) -> None:
    resp = client.get("/health", headers={"Host": host})
    assert resp.status_code == 200
    assert resp.json()["status"] == "ok"


def test_app_style_request_passes(client: TestClient) -> None:
    # Exactly what the Swift URLSession sends: Host 127.0.0.1:50711, no Origin.
    resp = client.get("/transcribe_llm/prompt")
    assert resp.status_code == 200


@pytest.mark.parametrize("host", ["evil.example", "evil.example:50711", "testserver", ""])
def test_foreign_hosts_are_rejected(client: TestClient, host: str) -> None:
    resp = client.post("/local/delete", json={"repo_id": "a/b"}, headers={"Host": host})
    assert resp.status_code == 403
    assert "error" in resp.json()


@pytest.mark.parametrize("origin", ["https://evil.example", "http://127.0.0.1:50711", "null"])
def test_any_origin_is_rejected(client: TestClient, origin: str) -> None:
    resp = client.post("/local/delete", json={"repo_id": "a/b"}, headers={"Origin": origin})
    assert resp.status_code == 403


def test_default_testserver_host_is_rejected() -> None:
    resp = TestClient(server.app).get("/health")
    assert resp.status_code == 403


def test_health_reports_busy_while_a_download_runs(monkeypatch):
    from flowy import local
    from flowy.training import jobs

    client = TestClient(server.app, base_url="http://127.0.0.1:50711")
    monkeypatch.setattr(local, "busy", lambda: False)
    monkeypatch.setattr(jobs, "busy", lambda: False)
    assert client.get("/health").json() == {"status": "ok", "busy": False}
    monkeypatch.setattr(local, "busy", lambda: True)
    assert client.get("/health").json()["busy"] is True


def test_health_reports_busy_while_a_request_is_in_flight(monkeypatch):
    import asyncio

    from flowy import local
    from flowy.training import jobs

    monkeypatch.setattr(local, "busy", lambda: False)
    monkeypatch.setattr(jobs, "busy", lambda: False)
    seen: list[bool] = []

    state = server.app.state

    async def inner(scope, receive, send) -> None:
        seen.append(is_busy(state))

    middleware = InFlightMiddleware(inner, state.in_flight)
    asyncio.run(middleware({"type": "http", "path": "/assistant/stream"}, None, None))
    # /health itself never counts, or the idle check would always see busy.
    asyncio.run(middleware({"type": "http", "path": "/health"}, None, None))
    assert seen == [True, False]
    assert is_busy(state) is False


def test_in_flight_count_drops_when_a_request_fails():
    import asyncio

    async def inner(scope, receive, send) -> None:
        raise RuntimeError("boom")

    counter = server.app.state.in_flight
    middleware = InFlightMiddleware(inner, counter)
    with pytest.raises(RuntimeError):
        asyncio.run(middleware({"type": "http", "path": "/assistant"}, None, None))
    assert counter.count == 0


def test_error_messages_are_never_blank(client: TestClient, monkeypatch) -> None:
    async def fail(*_args, **_kwargs):
        raise TimeoutError()

    monkeypatch.setattr(server.app.state.services.ai, "list_models", fail)
    resp = client.post("/models", json={"provider": "openai", "api_key": "k"})
    assert resp.status_code == 502
    assert resp.json()["error"] == "TimeoutError"


def test_parent_watch_fires_once_the_app_is_gone(monkeypatch) -> None:
    ppids = iter([4242, 4242, 1])
    monkeypatch.setattr(lifecycle.os, "getppid", lambda: next(ppids))
    gone: list[bool] = []
    lifecycle.watch_parent(4242, lambda: gone.append(True), interval=0)
    assert gone == [True]
