"""Errors the app sees, and the one place they become HTTP responses.

Every non-2xx body is ``{"error": "<message>"}`` (plus ``"fatal"`` for a
labeling key problem) — the Swift clients read exactly that. Routes raise an
``AppError`` (or let a domain error that subclasses one escape) and
``install_handler`` turns it into the response; nothing builds error bodies
by hand.
"""

from __future__ import annotations

import logging
from collections.abc import Iterator
from contextlib import contextmanager

from flowy.util import error_text

logger = logging.getLogger("flowy.server")


class AppError(Exception):
    """An error with an HTTP status. The message is shown to the user."""

    status_code = 500

    def body(self) -> dict[str, object]:
        return {"error": error_text(self)}


class BadRequest(AppError):
    """Bad input, or a provider error we could parse — the client's problem."""

    status_code = 400


class Unauthorized(AppError):
    status_code = 401


class FatalLabel(Unauthorized):
    """The labeling key itself is unusable (rejected, or out of quota): every
    further clip would fail the same way, so ``fatal`` tells the app to stop
    the whole run instead of counting a thousand failures."""

    def __init__(self, kind: str, message: str) -> None:
        super().__init__(message)
        self.kind = kind  # "auth" | "quota"

    def body(self) -> dict[str, object]:
        return {**super().body(), "fatal": self.kind}


class NotFound(AppError, LookupError):
    status_code = 404


class Conflict(AppError):
    """Clashes with existing state (a running job, a taken name)."""

    status_code = 409


class Unprocessable(AppError):
    status_code = 422


class Unavailable(AppError):
    """A missing dependency (converter, CUDA, disk) — not the request's fault."""

    status_code = 424


class Upstream(AppError):
    """A provider or engine failed in a way we couldn't parse."""

    status_code = 502


@contextmanager
def upstream_errors(log_message: str) -> Iterator[None]:
    """For routes that proxy a provider: ``ValueError`` → 400, anything else
    → 502 (logged with ``log_message``). ``AppError`` passes through."""
    try:
        yield
    except AppError:
        raise
    except ValueError as exc:
        raise BadRequest(error_text(exc)) from exc
    except Exception as exc:  # noqa: BLE001 - surface any upstream error as JSON
        logger.exception(log_message)
        raise Upstream(error_text(exc)) from exc


@contextmanager
def invalid_as_unprocessable() -> Iterator[None]:
    """For training routes: a plain ``ValueError`` is bad input (422). Typed
    errors (409/424/404) pass through; anything else stays a 500."""
    try:
        yield
    except AppError:
        raise
    except ValueError as exc:
        raise Unprocessable(error_text(exc)) from exc


def install_handler(app) -> None:
    """The single AppError → JSON response mapping."""
    from fastapi.responses import JSONResponse

    async def handle(_request, exc: AppError) -> JSONResponse:
        return JSONResponse(status_code=exc.status_code, content=exc.body())

    app.add_exception_handler(AppError, handle)
