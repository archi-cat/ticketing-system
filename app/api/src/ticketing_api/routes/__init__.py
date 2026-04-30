"""Mount all routers on the FastAPI application."""

from __future__ import annotations

from fastapi import FastAPI

from ticketing_api.routes import bookings, events, reservations
from ticketing_api.routes.error_handlers import register_exception_handlers


def register_routes(app: FastAPI) -> None:
    """Mount all route modules on the given FastAPI app."""
    app.include_router(events.router)
    app.include_router(reservations.router)
    app.include_router(bookings.router)
    register_exception_handlers(app)