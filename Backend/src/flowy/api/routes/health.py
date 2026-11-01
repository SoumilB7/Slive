from __future__ import annotations

from fastapi import APIRouter, Request

router = APIRouter()


def is_busy(state) -> bool:
    """A download, training job or request is running — the app's idle
    shutdown waits for it instead of killing it."""
    return state.in_flight.count > 0 or state.services.busy()


@router.get("/health")
def health(request: Request) -> dict[str, object]:
    return {"status": "ok", "busy": is_busy(request.app.state)}
