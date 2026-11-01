"""Builds the FastAPI app from settings + services (tests pass fakes)."""

from __future__ import annotations

from fastapi import FastAPI

from flowy.api.middleware import InFlight, InFlightMiddleware, LocalOnlyMiddleware
from flowy.api.routes import routers
from flowy.api.services import Services
from flowy.errors import install_handler
from flowy.settings import Settings


def create_app(settings: Settings, services: Services) -> FastAPI:
    app = FastAPI(title="Slive Server", version="0.1.0")
    app.state.settings = settings
    app.state.services = services
    app.state.in_flight = InFlight()
    install_handler(app)
    for router in routers():
        app.include_router(router)
    # Added last = outermost: a forbidden request never counts as in flight.
    app.add_middleware(InFlightMiddleware, counter=app.state.in_flight)
    app.add_middleware(LocalOnlyMiddleware)
    return app
