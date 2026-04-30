"""Test that create_app() produces a working FastAPI application."""

from fastapi.testclient import TestClient

from ticketing_api.main import create_app
from ticketing_api.settings import Settings


def test_app_starts_and_health_returns_ok():
    """The app starts cleanly and /health returns 200."""
    settings = Settings(environment="local", log_format="console")
    app = create_app(settings)

    with TestClient(app) as client:
        response = client.get("/health")

    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_app_uses_provided_settings():
    """create_app() respects the settings argument."""
    settings = Settings(
        environment="dev",
        service_version="9.9.9",
        log_format="console",
    )
    app = create_app(settings)

    assert app.state.settings.environment == "dev"
    assert app.state.settings.service_version == "9.9.9"
    assert app.version == "9.9.9"