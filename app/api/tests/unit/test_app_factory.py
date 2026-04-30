"""Test that create_app() produces a working FastAPI application."""

from contextlib import asynccontextmanager
from collections.abc import AsyncIterator

from fastapi import FastAPI
from fastapi.testclient import TestClient

from ticketing_api.main import create_app
from ticketing_api.settings import Settings


@asynccontextmanager
async def _noop_lifespan(_app: FastAPI) -> AsyncIterator[None]:
    """Skip real client startup in unit tests."""
    yield


def test_app_starts_and_liveness_returns_ok(monkeypatch):
    """The app starts cleanly and /health/live returns 200.

    We replace the real lifespan so unit tests don't try to connect to
    a real database/Redis/Service Bus.
    """
    settings = Settings(environment="local", log_format="console")

    # Override the lifespan before app construction
    monkeypatch.setattr("ticketing_api.main._lifespan", _noop_lifespan)
    app = create_app(settings)

    with TestClient(app) as client:
        response = client.get("/health/live")

    assert response.status_code == 200
    assert response.json() == {"status": "alive"}


def test_app_uses_provided_settings(monkeypatch):
    """create_app() respects the settings argument."""
    monkeypatch.setattr("ticketing_api.main._lifespan", _noop_lifespan)

    settings = Settings(
        environment="dev",
        service_version="9.9.9",
        log_format="console",
    )
    app = create_app(settings)

    assert app.state.settings.environment == "dev"
    assert app.state.settings.service_version == "9.9.9"
    assert app.version == "9.9.9"