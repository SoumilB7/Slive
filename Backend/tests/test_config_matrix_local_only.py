"""The local-only gate for every Host / Origin form a client can send.

The rule (``api/middleware.py``): serve a request only when it carries
exactly one Host whose name is 127.0.0.1, localhost or [::1] — optionally
with a numeric port, any case — and no Origin at all. Everything else,
DNS-rebinding names and malformed hosts included, is a 403 that never
reaches a route."""

from __future__ import annotations

import asyncio

import pytest

from flowy.api.middleware import LocalOnlyMiddleware

FORBIDDEN = {"error": "Forbidden: local app requests only."}

ALLOWED_HOSTS = [
    "127.0.0.1:50711",  # what the app's URLSession sends
    "127.0.0.1",
    "127.0.0.1:",  # empty port (RFC 3986 allows it)
    "localhost",
    "localhost:50711",
    "LOCALHOST:50711",
    "LocalHost",
    "[::1]",
    "[::1]:50711",
    "[::1]:",
    " 127.0.0.1:50711 ",  # optional whitespace around the value
    "localhost:50711\t",
]

REJECTED_HOSTS = [
    "",
    "   ",
    # foreign
    "evil.example",
    "evil.example:50711",
    "testserver",
    # DNS rebinding: a name the attacker controls that resolves to loopback
    "127.0.0.1.evil.example",
    "127.0.0.1.evil.example:50711",
    "localhost.evil.example",
    "localhost.evil.example:50711",
    "evil.localhost",
    "evil.example:127.0.0.1",
    # trailing-dot FQDN forms (the app never uses them)
    "localhost.",
    "localhost.:50711",
    "127.0.0.1.",
    # IPv6: unbracketed, other spellings of loopback, malformed brackets
    "::1",
    "::1:50711",
    "[::1].evil.example",
    "[::1]evil",
    "[::1]:50711.evil.example",
    "[::1]:50711:1",
    "[::1",
    "::1]",
    "[0:0:0:0:0:0:0:1]",
    "[::ffff:127.0.0.1]:50711",
    # other loopback / wildcard spellings
    "127.0.0.2",
    "127.1",
    "0.0.0.0:50711",
    "0x7f000001",
    "2130706433",
    # malformed ports and userinfo/fragment tricks
    "127.0.0.1:abc",
    "127.0.0.1:50711:1",
    "localhost:+50711",
    "localhost:-1",
    "localhost:5²",  # latin-1 superscript two: str.isdigit() says yes
    "localhost:50711 evil",
    "127.0.0.1@evil.example",
    "evil.example#@127.0.0.1",
    "127.0.0.1 evil.example",
]

#: Origins a browser (or extension) sends; any of them must be refused.
REJECTED_ORIGINS = [
    "null",
    "https://evil.example",
    "http://127.0.0.1:50711",
    "http://localhost:50711",
    "http://[::1]:50711",
    "HTTP://LOCALHOST:50711",
    "file://",
    "chrome-extension://abcdefghijklmnop",
]
#: Header values that carry no origin (a browser never sends these).
NO_ORIGIN = [None, "", "   "]


def _headers(host: str | None, origin: str | None = None, *extra) -> list[tuple[bytes, bytes]]:
    headers = [(b"content-type", b"application/json")]
    if host is not None:
        headers.append((b"host", host.encode("latin-1")))
    if origin is not None:
        headers.append((b"origin", origin.encode("latin-1")))
    return headers + [(k, v) for k, v in extra]


def _gate(headers, scope_type: str = "http") -> tuple[bool, list[dict]]:
    """Run the middleware alone: (did the route run, messages sent)."""
    reached: list[bool] = []
    sent: list[dict] = []

    async def route(scope, receive, send) -> None:
        reached.append(True)
        await send({"type": "http.response.start", "status": 200, "headers": []})
        await send({"type": "http.response.body", "body": b"{}"})

    async def receive() -> dict:
        return {"type": "http.request", "body": b"", "more_body": False}

    async def send(message: dict) -> None:
        sent.append(message)

    scope = {"type": scope_type, "method": "POST", "path": "/local/delete", "headers": headers,
             "query_string": b"", "scheme": "http", "server": ("127.0.0.1", 50711)}
    asyncio.run(LocalOnlyMiddleware(route)(scope, receive, send))
    return bool(reached), sent


def _status(sent: list[dict]) -> int:
    return next(m["status"] for m in sent if m["type"].endswith("http.response.start"))


@pytest.mark.parametrize("origin", NO_ORIGIN, ids=["absent", "empty", "blank"])
@pytest.mark.parametrize("host", ALLOWED_HOSTS)
def test_loopback_hosts_without_an_origin_are_served(host, origin) -> None:
    reached, sent = _gate(_headers(host, origin))
    assert reached and _status(sent) == 200


@pytest.mark.parametrize("host", REJECTED_HOSTS)
def test_other_hosts_are_forbidden(host) -> None:
    reached, sent = _gate(_headers(host))
    assert not reached and _status(sent) == 403


def test_a_missing_host_is_forbidden() -> None:
    reached, sent = _gate(_headers(None))
    assert not reached and _status(sent) == 403


@pytest.mark.parametrize("origin", REJECTED_ORIGINS)
@pytest.mark.parametrize("host", ["127.0.0.1:50711", "localhost:50711", "[::1]:50711"])
def test_any_origin_is_forbidden_even_on_a_loopback_host(host, origin) -> None:
    reached, sent = _gate(_headers(host, origin))
    assert not reached and _status(sent) == 403


@pytest.mark.parametrize("headers", [
    [(b"host", b"evil.example"), (b"host", b"127.0.0.1:50711")],
    [(b"host", b"127.0.0.1:50711"), (b"host", b"evil.example")],
    [(b"host", b"127.0.0.1:50711"), (b"host", b"127.0.0.1:50711")],
    [(b"host", b"127.0.0.1:50711"), (b"origin", b"https://evil.example"), (b"origin", b"")],
    [(b"host", b"127.0.0.1:50711"), (b"origin", b""), (b"origin", b"null")],
], ids=["foreign-then-local", "local-then-foreign", "duplicate-local", "origin-then-empty",
        "empty-then-origin"])
def test_duplicate_headers_cannot_shadow_a_rejection(headers) -> None:
    reached, sent = _gate(headers)
    assert not reached and _status(sent) == 403


def test_header_names_are_case_insensitive() -> None:
    assert _gate([(b"HOST", b"127.0.0.1:50711")])[0]
    assert not _gate([(b"Host", b"127.0.0.1:50711"), (b"ORIGIN", b"null")])[0]


@pytest.mark.parametrize("host, served", [("127.0.0.1:50711", True), ("evil.example", False)])
def test_websockets_follow_the_same_rule(host, served) -> None:
    reached, sent = _gate(_headers(host), scope_type="websocket")
    assert reached is served
    if not served:
        assert sent[0]["type"] == "websocket.http.response.start" and sent[0]["status"] == 403


def test_lifespan_passes_through() -> None:
    reached, _ = _gate([], scope_type="lifespan")
    assert reached


# --- through the real app: a forbidden request never reaches a route -----------------

@pytest.mark.parametrize("host, origin", [
    *((h, None) for h in ["evil.example:50711", "127.0.0.1.evil.example:50711",
                          "localhost.evil.example", "[::1].evil.example", "localhost.:50711"]),
    *(("127.0.0.1:50711", o) for o in ["null", "http://127.0.0.1:50711", "https://evil.example"]),
])
@pytest.mark.parametrize("method, path", [("GET", "/health"), ("POST", "/local/delete"),
                                          ("POST", "/assistant/stream")])
def test_the_app_answers_forbidden_with_the_error_body(real_client, host, origin, method,
                                                       path) -> None:
    services = real_client.app.state.services
    cached_before = list(services.local_models.cached)
    headers = {"Host": host, **({"Origin": origin} if origin else {})}
    resp = real_client.request(method, path, headers=headers, json={"repo_id": "a/b"})
    assert (resp.status_code, resp.json()) == (403, FORBIDDEN)
    assert list(services.local_models.cached) == cached_before  # the delete never ran


@pytest.mark.parametrize("host", ALLOWED_HOSTS)
def test_the_app_serves_every_loopback_host(real_client, host) -> None:
    resp = real_client.get("/health", headers={"Host": host})
    assert resp.status_code == 200 and resp.json()["status"] == "ok"
