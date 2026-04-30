"""FastAPI application factory.

The ``create_app()`` function builds and configures the app. Tests can call it
with overridden settings; production calls it once at startup.
"""

from contextlib import asynccontextmanager
from collections.abc import AsyncIterator

import structlog
from fastapi import FastAPI

from ticketing_api.observability import configure_observability
from ticketing_api.settings import Settings, get_settings

logger = structlog.get_logger(__name__)


@asynccontextmanager
async def _lifespan(app: FastAPI) -> AsyncIterator[None]:
    """Startup and shutdown hooks.

    On startup:
        - Verify connectivity to upstream dependencies (eventually).
    On shutdown:
        - Close database/Redis/Service Bus connections (eventually).

    For now this is a placeholder — we'll add real startup checks in
    subsequent steps as we wire in infrastructure clients.
    """
    settings: Settings = app.state.settings
    logger.info(
        "api_starting",
        environment=settings.environment,
        service_version=settings.service_version,
    )
    yield
    logger.info("api_stopping")


def create_app(settings: Settings | None = None) -> FastAPI:
    """Build the FastAPI application.

    Parameters
    ----------
    settings:
        Optional settings override. Defaults to ``get_settings()``. Tests
        pass a custom Settings instance to exercise specific configurations.
    """
    if settings is None:
        settings = get_settings()

    configure_observability(settings)

    app = FastAPI(
        title="Ticketing API",
        version=settings.service_version,
        docs_url="/docs",
        redoc_url=None,
    )
    app.state.settings = settings

    # Routers will be mounted here as we add them in subsequent steps.

    # Trivial health endpoint until we add a proper one with dependency checks
    @app.get("/health", tags=["meta"])
    async def health() -> dict[str, str]:
        return {"status": "ok"}

    return app


# Module-level app for `uvicorn ticketing_api.main:app`
app = create_app()