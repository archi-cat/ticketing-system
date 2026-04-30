"""FastAPI application factory."""

from contextlib import asynccontextmanager
from collections.abc import AsyncIterator

import structlog
from fastapi import FastAPI

from ticketing_api.infrastructure.database import Database
from ticketing_api.infrastructure.keyvault import KeyVaultClient
from ticketing_api.infrastructure.redis_client import RedisClient
from ticketing_api.infrastructure.servicebus import ServiceBusPublisher
from ticketing_api.observability import configure_observability
from ticketing_api.services.bookings import BookingService
from ticketing_api.services.locks import DistributedLock
from ticketing_api.services.reservations import ReservationService
from ticketing_api.settings import Settings, get_settings

logger = structlog.get_logger(__name__)


@asynccontextmanager
async def _lifespan(app: FastAPI) -> AsyncIterator[None]:
    """Startup and shutdown hooks."""
    settings: Settings = app.state.settings
    logger.info(
        "api_starting",
        environment=settings.environment,
        service_version=settings.service_version,
    )

    # Construct clients (constructor only — no I/O yet)
    keyvault = KeyVaultClient(settings)
    database = Database(settings)
    redis = RedisClient(settings, keyvault)
    servicebus = ServiceBusPublisher(settings)

    # Startup order matters:
    #   1. Key Vault first (Redis depends on it)
    #   2. Database, Redis, Service Bus in parallel — independent
    await keyvault.startup()
    await database.startup()
    await redis.startup()
    await servicebus.startup()

    # Services
    lock = DistributedLock(redis.client)
    reservation_service = ReservationService(settings, database, lock, servicebus)
    booking_service = BookingService(settings, database, servicebus)

    # Stash on app.state for routes/dependencies to access
    app.state.keyvault = keyvault
    app.state.database = database
    app.state.redis = redis
    app.state.servicebus = servicebus
    app.state.reservation_service = reservation_service
    app.state.booking_service = booking_service

    logger.info("api_ready")
    try:
        yield
    finally:
        # Shutdown in reverse order
        logger.info("api_stopping")
        await servicebus.shutdown()
        await redis.shutdown()
        await database.shutdown()
        await keyvault.shutdown()


def create_app(settings: Settings | None = None) -> FastAPI:
    """Build the FastAPI application."""
    if settings is None:
        settings = get_settings()

    configure_observability(settings)

    app = FastAPI(
        title="Ticketing API",
        version=settings.service_version,
        docs_url="/docs",
        redoc_url=None,
        lifespan=_lifespan,
    )
    app.state.settings = settings

    # ── Health endpoints ──────────────────────────────────────────────────────
    # /health/live  — kubelet liveness probe; succeeds if the process is alive
    # /health/ready — kubelet readiness probe; checks all dependencies

    @app.get("/health/live", tags=["meta"])
    async def liveness() -> dict[str, str]:
        return {"status": "alive"}

    @app.get("/health/ready", tags=["meta"])
    async def readiness() -> dict[str, dict[str, str]]:
        """Verify upstream dependencies are reachable.

        Returns 200 with a per-dependency status. Returns 503 if any are down.
        Kubernetes uses this to decide whether to send traffic to the pod.
        """
        from fastapi import HTTPException
        from sqlalchemy import text

        results: dict[str, str] = {}

        # Database
        try:
            async with app.state.database.engine.begin() as conn:
                await conn.execute(text("SELECT 1"))
            results["database"] = "ok"
        except Exception as exc:  # noqa: BLE001
            results["database"] = f"error: {exc.__class__.__name__}"

        # Redis
        try:
            await app.state.redis.client.ping()
            results["redis"] = "ok"
        except Exception as exc:  # noqa: BLE001
            results["redis"] = f"error: {exc.__class__.__name__}"

        # Service Bus — check is "is_enabled and not closed". We deliberately
        # don't send a real message — Service Bus has no cheap ping equivalent.
        results["servicebus"] = (
            "ok" if app.state.servicebus.is_enabled else "disabled"
        )

        if any(v.startswith("error") for v in results.values()):
            raise HTTPException(status_code=503, detail={"checks": results})
        return {"checks": results}
    
    # Backwards-compat alias
    @app.get("/health", tags=["meta"])
    async def health() -> dict[str, str]:
        return {"status": "ok"}

    return app


app = create_app()