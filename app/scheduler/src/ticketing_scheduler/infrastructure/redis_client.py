"""Async Redis client.

Local development: plain TCP, optional password.
Azure: TLS, password injected via Kubernetes Secret (fetched from Key Vault
at deploy time by the GitHub Actions workflow).
"""

from __future__ import annotations

import structlog
from redis.asyncio import Redis

from ticketing_scheduler.settings import Settings

logger = structlog.get_logger(__name__)


class RedisClient:
    def __init__(self, settings: Settings) -> None:
        self._settings = settings
        self._client: Redis | None = None

    @property
    def client(self) -> Redis:
        if self._client is None:
            raise RuntimeError("RedisClient.startup() has not been called")
        return self._client

    async def startup(self) -> None:
        password = (
            self._settings.redis_password.get_secret_value()
            if self._settings.redis_password
            else None
        )

        self._client = Redis(
            host=self._settings.redis_host,
            port=self._settings.redis_port,
            password=password,
            ssl=self._settings.redis_use_tls,
            decode_responses=True,
            socket_timeout=5,
            socket_connect_timeout=5,
            retry_on_timeout=True,
            health_check_interval=30,
        )

        await self._client.ping()
        logger.info(
            "redis_started",
            host=self._settings.redis_host,
            port=self._settings.redis_port,
            tls=self._settings.redis_use_tls,
        )

    async def shutdown(self) -> None:
        if self._client is not None:
            await self._client.aclose()
            self._client = None
        logger.info("redis_stopped")