"""One APIRouter per area. Adding a route: put it in the area's module (or a
new module listed in ``ROUTERS``), take ``ServicesDep`` for what it needs, and
raise ``flowy.errors`` types for failures — the app's error handler writes
the ``{"error": ...}`` body.

Handlers return plain dicts and carry no return annotation: FastAPI would
turn one into a response_model and re-validate every payload (training polls
included)."""

from __future__ import annotations

from typing import Annotated

from fastapi import Depends, Request

from flowy.api.services import Services


def get_services(request: Request) -> Services:
    return request.app.state.services


ServicesDep = Annotated[Services, Depends(get_services)]


def routers():
    from flowy.api.routes import assistant, health, labels, local, training

    return [health.router, assistant.router, labels.router, local.router, training.router]
