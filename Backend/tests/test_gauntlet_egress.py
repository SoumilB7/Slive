"""The Gauntlet's egress checks for the server (G4): the labeling pipeline
makes no outbound call unless the request itself carries the user's key, and
a request that does carry one reaches only the provider that key belongs to.

Run alone: ``pytest -m gauntlet``. Every outbound path is blocked and recorded
by the ``outbound`` fixture (conftest.py), so nothing here touches a network.
"""

from __future__ import annotations

import asyncio
import base64
import io
import struct
import urllib.request
import wave

import httpx
import pytest
from fastapi.testclient import TestClient
from test_http_api import FakeLocal, FakeTraining

from flowy import label_consensus, label_format
from flowy.api import Services, create_app
from flowy.providers import Gateway, default_registry
from flowy.settings import Settings

pytestmark = pytest.mark.gauntlet

KEY = "sk-gauntlet-fixture-key-0000000000000000"


def _wav_b64(seconds: float = 0.5) -> str:
    out = io.BytesIO()
    with wave.open(out, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(16_000)
        w.writeframes(struct.pack("<h", 0) * int(16_000 * seconds))
    return base64.b64encode(out.getvalue()).decode()


@pytest.fixture
def no_backoff(monkeypatch):
    """The labelers back off on a failed call; a blocked call fails at once."""

    async def instant(_seconds: float) -> None:
        return None

    monkeypatch.setattr(label_consensus, "_sleep", instant)
    monkeypatch.setattr(label_format, "_sleep", instant)


@pytest.fixture
def client(outbound, no_backoff):
    """The production gateway and labelers behind the real app, started inside
    the blocker so even startup is watched."""
    services = Services(ai=Gateway(default_registry()), labeler=label_consensus,
                        local_models=FakeLocal(), training=FakeTraining(),
                        formatter=label_format)
    app = create_app(Settings.from_env({}), services)
    with TestClient(app, base_url="http://127.0.0.1:50711", raise_server_exceptions=False) as c:
        yield c


# --- the blocker itself: a guard that can't see a client proves nothing -------

def test_blocker_sees_every_client(outbound):
    with pytest.raises(httpx.ConnectError):
        httpx.get("https://sync.example.test/")

    async def go():
        async with httpx.AsyncClient() as c:
            await c.get("https://async.example.test/")

    with pytest.raises(httpx.ConnectError):
        asyncio.run(go())
    with pytest.raises(OSError):
        urllib.request.urlopen("https://urllib.example.test/")
    import socket

    with pytest.raises(OSError):
        socket.create_connection(("203.0.113.9", 443), timeout=1)
    clients = {name for name, _url in outbound.calls}
    assert {"httpx", "httpx.async", "urllib", "socket"} <= clients, outbound.calls


def test_blocker_sees_requests_and_openai(outbound):
    requests = pytest.importorskip("requests")
    with pytest.raises(requests.ConnectionError):
        requests.get("https://requests.example.test/")
    assert ("requests", "https://requests.example.test/") in outbound.calls
    openai = pytest.importorskip("openai")
    with pytest.raises(Exception):  # noqa: B017 - any failure is a block
        openai.OpenAI(api_key="x").models.list()
    assert any(name == "openai" for name, _ in outbound.calls)


def test_blocker_lets_loopback_through(outbound):
    import socket

    server = socket.socket()
    server.bind(("127.0.0.1", 0))
    server.listen(1)
    client = socket.socket()
    client.connect(server.getsockname())
    client.close()
    server.close()
    assert outbound.calls == []


# --- P-NO-PAID-WITHOUT-CONSENT: no key in the request, no call ----------------

AUDIO = _wav_b64()

NO_KEY_REQUESTS = [
    ("POST", "/label_consensus", {"api_key": "", "audio_b64": AUDIO, "media_type": "audio/wav",
                                  "typed": "hello there my friend", "hotwords": "", "context": "",
                                  "base_prompt": ""}),
    ("POST", "/label_format", {"api_key": "", "label": "hello there my good friend",
                               "hotwords": "", "agreement": 0.95, "word_count": 5}),
    *[("POST", "/transcribe_llm", {"provider": p, "model": "m", "api_key": "", "audio_b64": AUDIO,
                                   "media_type": "audio/wav", "base_url": "https://llm.example.test/v1"})
      for p in ("openai", "gemini", "openai_compatible")],
    *[("POST", "/assistant", {"text": "hi", "provider": p, "model": "m", "api_key": "",
                              "base_url": "https://llm.example.test/v1"})
      for p in ("anthropic", "openai", "gemini", "openai_compatible")],
]

LOCAL_ONLY_GETS = ["/health", "/transcribe_llm/prompt", "/label_format/prompt",
                   "/training/readiness", "/training/models", "/local/cache"]


@pytest.mark.parametrize("method,path,body", NO_KEY_REQUESTS,
                         ids=[f"{p}-{b.get('provider', 'labeler')}" for _m, p, b in NO_KEY_REQUESTS])
def test_p_no_paid_without_consent_empty_key(client, outbound, method, path, body):
    """The key is the consent: the app sends it only with a request the user
    asked for, and the server must not spend anything without one."""
    client.request(method, path, json=body)
    assert outbound.calls == [], f"{path} reached out without a key: {outbound.calls}"


@pytest.mark.parametrize("path", LOCAL_ONLY_GETS)
def test_p_no_paid_without_consent_local_reads(client, outbound, path):
    assert client.get(path).status_code < 500
    assert outbound.calls == []


def test_p_no_paid_without_consent_startup_is_silent(client, outbound):
    assert outbound.calls == [], "starting the server and its lifespan made an outbound call"


# --- with consent: only the provider the key belongs to ----------------------

def test_label_consensus_with_a_key_reaches_only_openai(client, outbound):
    client.post("/label_consensus", json={
        "api_key": KEY, "audio_b64": AUDIO, "media_type": "audio/wav", "typed": "hello there",
        "hotwords": "", "context": "", "base_prompt": ""})
    assert outbound.calls, "the recorder saw nothing: the check above would prove nothing"
    assert outbound.hosts == {"api.openai.com"}, outbound.urls()


def test_label_format_with_a_key_reaches_only_openai(client, outbound):
    client.post("/label_format", json={
        "api_key": KEY, "label": "hello there my good friend", "hotwords": "",
        "agreement": 0.95, "word_count": 5})
    assert outbound.calls
    assert outbound.hosts == {"api.openai.com"}, outbound.urls()


@pytest.mark.parametrize("provider,host", [("openai", "api.openai.com"),
                                           ("gemini", "generativelanguage.googleapis.com"),
                                           ("anthropic", "api.anthropic.com")])
def test_assistant_with_a_key_reaches_only_its_provider(client, outbound, provider, host):
    client.post("/assistant", json={"text": "hi", "provider": provider, "model": "m", "api_key": KEY})
    assert outbound.calls
    assert outbound.hosts == {host}, outbound.urls()
