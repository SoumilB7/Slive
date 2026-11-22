"""Fixtures shared by the config-matrix suites: a fake upstream for every
httpx call, a per-test deadline, and an app wired to the real gateway and
labelers (only the background services are faked)."""

from __future__ import annotations

import http.client
import signal
import socket
import urllib.request

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


# ---------------------------------------------------------------------------
# The Gauntlet's egress fixture (marker: gauntlet)
# ---------------------------------------------------------------------------

_LOOPBACK = {"127.0.0.1", "::1", "localhost"}


class Outbound:
    """Every attempt to leave the process: ``calls`` holds ``(client, url)``.

    Blocking is the point — nothing a test does can reach a real service —
    and recording is how a test proves a code path stayed home."""

    def __init__(self) -> None:
        self.calls: list[tuple[str, str]] = []

    def record(self, client: str, url: str) -> None:
        self.calls.append((client, url))

    @property
    def hosts(self) -> set[str]:
        from urllib.parse import urlsplit

        found = set()
        for _client, url in self.calls:
            host = urlsplit(url if "://" in url else f"//{url}").hostname
            found.add(host or url)
        return found

    def urls(self) -> list[str]:
        return [url for _client, url in self.calls]


class OutboundBlocked(httpx.ConnectError):
    """What a blocked client sees: the network is down, like any other outage."""


@pytest.fixture
def outbound(monkeypatch) -> Outbound:
    """Block and record ALL outbound HTTP: httpx (sync and async), requests,
    urllib, the openai client, and any raw non-loopback socket connect. Local
    traffic (the test client, loopback sockets) is untouched."""
    seen = Outbound()

    async def async_send(self, request, *args, **kwargs):
        seen.record("httpx.async", str(request.url))
        raise OutboundBlocked("blocked by the gauntlet", request=request)

    def sync_send(self, request, *args, **kwargs):
        seen.record("httpx", str(request.url))
        raise OutboundBlocked("blocked by the gauntlet", request=request)

    monkeypatch.setattr(httpx.AsyncHTTPTransport, "handle_async_request", async_send)
    monkeypatch.setattr(httpx.HTTPTransport, "handle_request", sync_send)

    def http_connect(self, *args, **kwargs):
        seen.record("http.client", f"{self.host}:{self.port}")
        raise OSError("blocked by the gauntlet")

    monkeypatch.setattr(http.client.HTTPConnection, "connect", http_connect)

    real_connect, real_connect_ex = socket.socket.connect, socket.socket.connect_ex

    def is_remote(address) -> bool:
        return isinstance(address, tuple) and str(address[0]) not in _LOOPBACK

    def guarded(real):
        def connect(self, address, *args, **kwargs):
            if is_remote(address):
                seen.record("socket", f"{address[0]}:{address[1]}")
                raise OSError("blocked by the gauntlet")
            return real(self, address, *args, **kwargs)
        return connect

    monkeypatch.setattr(socket.socket, "connect", guarded(real_connect))
    monkeypatch.setattr(socket.socket, "connect_ex", guarded(real_connect_ex))

    # urllib ends in http.client, but naming its opener records the URL itself.
    def opener(self, fullurl, *args, **kwargs):
        seen.record("urllib", fullurl if isinstance(fullurl, str) else fullurl.full_url)
        raise OSError("blocked by the gauntlet")

    monkeypatch.setattr(urllib.request.OpenerDirector, "open", opener)

    try:
        import requests

        def requests_send(self, request, *args, **kwargs):
            seen.record("requests", request.url)
            raise requests.ConnectionError("blocked by the gauntlet")

        monkeypatch.setattr(requests.adapters.HTTPAdapter, "send", requests_send)
    except ImportError:
        pass
    try:
        from openai import _base_client as openai_client

        def openai_request(self, *args, **kwargs):
            seen.record("openai", str(getattr(self, "base_url", "openai")))
            raise OutboundBlocked("blocked by the gauntlet",
                                  request=httpx.Request("POST", "https://api.openai.com/"))

        async def openai_arequest(self, *args, **kwargs):
            return openai_request(self)

        monkeypatch.setattr(openai_client.SyncAPIClient, "request", openai_request)
        monkeypatch.setattr(openai_client.AsyncAPIClient, "request", openai_arequest)
    except (ImportError, AttributeError):
        pass
    return seen
