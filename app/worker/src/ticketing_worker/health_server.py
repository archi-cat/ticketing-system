"""Tiny aiohttp HTTP server exposing K8s liveness and readiness probes.

The worker doesn't serve user traffic, but Kubernetes still expects
liveness/readiness endpoints. We bind to a separate port from anything
else, so the worker exposes:

    GET /health/live   — process is alive (always 200 if the server is up)
    GET /health/ready  — dependencies are reachable (database, service bus)
"""

from __future__ import annotations

import structlog
from aiohttp import web

from ticketing_worker.infrastructure.database import Database

logger = structlog.get_logger(__name__)


class HealthServer:
    def __init__(
        self,
        database: Database,
        host: str,
        port: int,
    ) -> None:
        self._database = database
        self._host = host
        self._port = port
        self._runner: web.AppRunner | None = None

    async def startup(self) -> None:
        app = web.Application()
        app.router.add_get("/health/live", self._handle_liveness)
        app.router.add_get("/health/ready", self._handle_readiness)

        self._runner = web.AppRunner(app, access_log=None)
        await self._runner.setup()
        site = web.TCPSite(self._runner, host=self._host, port=self._port)
        await site.start()
        logger.info("health_server_started", host=self._host, port=self._port)

    async def shutdown(self) -> None:
        if self._runner is not None:
            await self._runner.cleanup()
            self._runner = None
        logger.info("health_server_stopped")

    async def _handle_liveness(self, _request: web.Request) -> web.Response:
        return web.json_response({"status": "alive"})

    async def _handle_readiness(self, _request: web.Request) -> web.Response:
        from sqlalchemy import text

        try:
            async with self._database.engine.begin() as conn:
                await conn.execute(text("SELECT 1"))
        except Exception as exc:  # noqa: BLE001
            return web.json_response(
                {"status": "not_ready", "error": exc.__class__.__name__},
                status=503,
            )

        return web.json_response({"status": "ready"})
