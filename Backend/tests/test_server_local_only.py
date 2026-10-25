"""The local port only serves the app: loopback Host, no browser Origin."""

import pytest
from fastapi.testclient import TestClient

from flowy import server


@pytest.fixture
def client() -> TestClient:
    # TestClient defaults to Host "testserver" — use the app's real base URL.
    return TestClient(server.app, base_url="http://127.0.0.1:50711")


@pytest.mark.parametrize("host", ["127.0.0.1:50711", "localhost:50711", "127.0.0.1", "[::1]:50711"])
def test_loopback_hosts_are_served(client: TestClient, host: str) -> None:
    resp = client.get("/health", headers={"Host": host})
    assert resp.status_code == 200
    assert resp.json() == {"status": "ok"}


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
