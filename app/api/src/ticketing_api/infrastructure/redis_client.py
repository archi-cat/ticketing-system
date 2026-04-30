"""Async Redis client.

Auth model:
    - Local development: optional password from settings, plain TCP
    - Azure: TLS, key fetched from Key Vault using Workload Identity

The cache is used for two purposes:
    - Caching event/seat data
    - Distributed locking for reservation creation (prevents oversell)
"""

from __future__ import annotations

import structlog
from redis.asyncio import Redis

from ticketing_api.infrastructure.keyvault import KeyVaultClient
from ticketing_api.settings import Settings

logger = structlog.get_logger(__name__)


class RedisClient:
    """Async wrapper around redis.asyncio.Redis."""

    def __init__(self, settings: Settings, keyvault: KeyVaultClient) -> None:
        self._settings = settings
        self._keyvault = keyvault
        self._client: Redis | None = None

    @property
    def client(self) -> Redis:
        """Return the underlying SDK client. Raises if not started."""
        if self._client is None:
            raise RuntimeError("RedisClient.startup() has not been called yet")
        return self._client

    async def startup(self) -> None:
        """Initialise the Redis connection.

        Resolves the password according to the auth model:
            - Cloud (KEYVAULT_URI set + REDIS_USE_TLS=true): fetch from Key Vault
            - Local: use REDIS_PASSWORD or no password
        """
        password = await self._resolve_password()

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

        # Verify the connection works at startup so we fail fast on bad config
        await self._client.ping()
        logger.info(
            "redis_started",
            host=self._settings.redis_host,
            port=self._settings.redis_port,
            tls=self._settings.redis_use_tls,
        )

    async def shutdown(self) -> None:
        """Close the connection pool."""
        if self._client is not None:
            await self._client.aclose()
            self._client = None
        logger.info("redis_stopped")

    async def _resolve_password(self) -> str | None:
        """Return the Redis password, fetching from Key Vault if applicable."""
        if self._keyvault.is_enabled:
            logger.info("redis_fetching_password_from_keyvault")
            return await self._keyvault.get_secret(
                self._settings.redis_keyvault_secret_name
            )

        if self._settings.redis_password is not None:
            return self._settings.redis_password.get_secret_value()

        return None