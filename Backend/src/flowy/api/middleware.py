"""ASGI middleware: local-app-only access, and the in-flight request count
behind ``/health``'s ``busy``."""

from __future__ import annotations

import re

from fastapi.responses import JSONResponse

#: Hostnames the app reaches us by. Anything else is a DNS-rebinding page
#: (evil.example resolved to 127.0.0.1) and must not drive /local/delete,
#: /training/start, etc.
_LOCAL_HOSTS = {"127.0.0.1", "localhost", "::1"}
#: What may follow the name: nothing, or ":" and an ASCII port (RFC 3986).
_PORT = re.compile(r"(?::[0-9]*)?")


def _host_name(host: str) -> str:
    """The hostname part of a Host header (port and IPv6 brackets dropped),
    or "" when anything but an optional numeric port follows the name — so
    "[::1].evil.example" can't pass as ::1."""
    host = host.strip().lower()
    if host.startswith("["):
        name, bracket, rest = host[1:].partition("]")
        if not bracket:
            return ""
    else:
        name, colon, port = host.partition(":")
        rest = colon + port
    return name if _PORT.fullmatch(rest) else ""


class LocalOnlyMiddleware:
    """Reject (403) requests not addressed to a loopback Host, and any request
    carrying an Origin. The app's URLSession sends no Origin; a browser always
    does on cross-origin POSTs (``null`` from sandboxed frames included), so
    this blocks web pages from calling the local port at all."""

    def __init__(self, inner) -> None:
        self.inner = inner

    async def __call__(self, scope, receive, send) -> None:
        if scope["type"] in ("http", "websocket"):
            headers = [(k.lower(), v.decode("latin-1")) for k, v in scope.get("headers", [])]
            hosts = [v for k, v in headers if k == b"host"]
            # Every Origin counts and only one Host may be sent: a later
            # duplicate must not shadow the header that should reject.
            origin = any(v.strip() for k, v in headers if k == b"origin")
            if len(hosts) != 1 or _host_name(hosts[0]) not in _LOCAL_HOSTS or origin:
                response = JSONResponse(
                    status_code=403, content={"error": "Forbidden: local app requests only."}
                )
                await response(scope, receive, send)
                return
        await self.inner(scope, receive, send)


class InFlight:
    """Requests being served right now (``/health`` excluded). Only touched on
    the event loop, so a plain int is safe."""

    def __init__(self) -> None:
        self.count = 0


class InFlightMiddleware:
    """Count requests until their last byte is sent (streams included), so
    ``/health`` reports busy while one runs and the app's idle shutdown can't
    kill a long local-model generation mid-reply."""

    def __init__(self, inner, counter: InFlight) -> None:
        self.inner = inner
        self.counter = counter

    async def __call__(self, scope, receive, send) -> None:
        if scope["type"] != "http" or scope.get("path") == "/health":
            await self.inner(scope, receive, send)
            return
        self.counter.count += 1
        try:
            await self.inner(scope, receive, send)
        finally:
            self.counter.count -= 1
