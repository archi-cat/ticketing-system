"""Async Redis client.

Auth model:
    Local: plain TCP, optional password
    Cloud: Entra ID via DefaultAzureCredential, token used as the AUTH
           password, periodically refreshed in a background task

Reference:
    https://learn.microsoft.com/en-us/azure/redis/entra-for-authentication
"""

from __future__ import annotations

import asyncio
import time
from typing import TYPE_CHECKING

import structlog
from redis.asyncio import Redis

from ticketing_api.settings import Settings

if TYPE_CHECKING:
    from azure.core.credentials_async import AsyncTokenCredential

logger = structlog.get_logger(__name__)

# Token scope for Azure Managed Redis. The token is used as the AUTH password.
_REDIS_AAD_SCOPE = "https://redis.azure.com/.default"

# How early before expiry to refresh. AMR tokens are typically valid for
# ~75 minutes; refreshing 5 minutes early gives generous margin.
_REFRESH_BUFFER_SECONDS = 300


class RedisClient:
    def __init__(self, settings: Settings) -> None:
        self._settings = settings
        self._client: Redis[str] | None = None
        self._credential: AsyncTokenCredential | None = None
        self._refresh_task: asyncio.Task[None] | None = None

    @property
    def client(self) -> Redis[str]:
        if self._client is None:
            raise RuntimeError("RedisClient.startup() has not been called")
        return self._client

    async def startup(self) -> None:
        if self._settings.redis_use_entra_id:
            await self._startup_entra_id()
        else:
            await self._startup_local()
        assert self._client is not None
        await self._client.ping()
        logger.info(
            "redis_started",
            host=self._settings.redis_host,
            port=self._settings.redis_port,
            entra_id=self._settings.redis_use_entra_id,
        )

    async def _startup_local(self) -> None:
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

    async def _startup_entra_id(self) -> None:
        from azure.identity.aio import DefaultAzureCredential

        self._credential = DefaultAzureCredential()
        token = await self._credential.get_token(_REDIS_AAD_SCOPE)

        self._client = Redis(
            host=self._settings.redis_host,
            port=self._settings.redis_port,
            username=self._settings.redis_username,
            password=token.token,
            ssl=True,
            decode_responses=True,
            socket_timeout=5,
            socket_connect_timeout=5,
            retry_on_timeout=True,
            health_check_interval=30,
        )

        # Start a background task that periodically mints a new token
        # and re-AUTHs the connection before the current token expires.
        self._refresh_task = asyncio.create_task(self._refresh_loop())

    async def _refresh_loop(self) -> None:
        """Refresh the Entra ID token before it expires."""
        assert self._credential is not None
        assert self._client is not None

        while True:
            try:
                # Sleep until just before the current token would expire.
                # We re-fetch the token to get its current expiry rather
                # than tracking it ourselves (DefaultAzureCredential caches
                # internally, so this is cheap).
                token = await self._credential.get_token(_REDIS_AAD_SCOPE)
                seconds_until_expiry = token.expires_on - int(time.time())
                sleep_for = max(60, seconds_until_expiry - _REFRESH_BUFFER_SECONDS)
                await asyncio.sleep(sleep_for)

                # Mint a fresh token and AUTH the existing connection
                new_token = await self._credential.get_token(_REDIS_AAD_SCOPE)
                await self._client.execute_command(  # type: ignore[no-untyped-call]
                    "AUTH",
                    self._settings.redis_username,
                    new_token.token,
                )
                logger.debug("redis_token_refreshed")
            except asyncio.CancelledError:
                break
            except Exception as exc:  # noqa: BLE001
                logger.warning("redis_token_refresh_failed", error=str(exc))
                # Back off and try again
                await asyncio.sleep(30)

    async def shutdown(self) -> None:
        if self._refresh_task is not None:
            self._refresh_task.cancel()
            try:
                await self._refresh_task
            except asyncio.CancelledError:
                pass
            self._refresh_task = None

        if self._client is not None:
            await self._client.aclose()  # type: ignore[attr-defined]
            self._client = None

        if self._credential is not None:
            await self._credential.close()
            self._credential = None

        logger.info("redis_stopped")
