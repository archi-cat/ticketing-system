"""Async SQLAlchemy engine and session factory.

Auth model:
    - Local development: username + password from settings
    - Azure: passwordless auth via Workload Identity

The Azure path is the interesting one. PostgreSQL Flexible Server accepts
short-lived Entra ID access tokens as the password in the wire-protocol
authentication exchange. Tokens expire (typically every 60-90 minutes), so
we obtain a fresh one for every new asyncpg connection — long-lived
connections in the pool keep working until they're recycled.

The mechanism: asyncpg supports a `connect` kwarg for SQLAlchemy's
``create_async_engine`` that accepts a coroutine called immediately before
each connection is opened. We use it to mint a token and inject it as the
connection password.
"""

from __future__ import annotations

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from typing import Any

import asyncpg
import structlog
from azure.identity.aio import DefaultAzureCredential
from sqlalchemy.ext.asyncio import (
    AsyncEngine,
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)

from ticketing_api.settings import Settings

logger = structlog.get_logger(__name__)

_POSTGRES_AAD_SCOPE = "https://ossrdbms-aad.database.windows.net/.default"


class Database:
    """Async SQLAlchemy engine wrapper with Workload Identity-aware auth."""

    def __init__(self, settings: Settings) -> None:
        self._settings = settings
        self._engine: AsyncEngine | None = None
        self._session_factory: async_sessionmaker[AsyncSession] | None = None
        self._credential: DefaultAzureCredential | None = None

    @property
    def engine(self) -> AsyncEngine:
        if self._engine is None:
            raise RuntimeError("Database.startup() has not been called yet")
        return self._engine

    async def startup(self) -> None:
        """Build the engine and verify connectivity."""
        if self._settings.postgres_use_workload_identity:
            self._credential = DefaultAzureCredential()
            self._engine = self._build_engine_with_workload_identity()
        else:
            self._engine = self._build_engine_with_password()

        self._session_factory = async_sessionmaker(
            self._engine,
            expire_on_commit=False,
            class_=AsyncSession,
        )

        await self._verify_connectivity()
        logger.info(
            "database_started",
            host=self._settings.postgres_host,
            database=self._settings.postgres_database,
            workload_identity=self._settings.postgres_use_workload_identity,
        )

    async def shutdown(self) -> None:
        if self._engine is not None:
            await self._engine.dispose()
            self._engine = None
        if self._credential is not None:
            await self._credential.close()
            self._credential = None
        logger.info("database_stopped")

    @asynccontextmanager
    async def session(self) -> AsyncIterator[AsyncSession]:
        """Yield a transactional session. Rolls back on exception."""
        if self._session_factory is None:
            raise RuntimeError("Database.startup() has not been called yet")

        async with self._session_factory() as session:
            try:
                yield session
                await session.commit()
            except Exception:
                await session.rollback()
                raise

    # ── Engine builders ───────────────────────────────────────────────────────

    def _build_engine_with_password(self) -> AsyncEngine:
        """Local dev — password authentication."""
        password = (
            self._settings.postgres_password.get_secret_value()
            if self._settings.postgres_password
            else ""
        )
        url = (
            f"postgresql+asyncpg://"
            f"{self._settings.postgres_user}:{password}@"
            f"{self._settings.postgres_host}:{self._settings.postgres_port}/"
            f"{self._settings.postgres_database}"
        )
        return create_async_engine(
            url,
            pool_pre_ping=True,
            pool_size=self._settings.postgres_pool_min_size,
            max_overflow=(
                self._settings.postgres_pool_max_size
                - self._settings.postgres_pool_min_size
            ),
        )

    def _build_engine_with_workload_identity(self) -> AsyncEngine:
        """Azure — Entra ID token injected per-connection.

        The async_creator hook is asyncpg's escape hatch for custom connection
        creation. We use it to obtain a fresh Entra ID token for every new
        connection. SSL is required by PostgreSQL Flexible Server.
        """
        # URL has no password — the creator supplies it dynamically
        url = (
            f"postgresql+asyncpg://"
            f"{self._settings.postgres_user}@"
            f"{self._settings.postgres_host}:{self._settings.postgres_port}/"
            f"{self._settings.postgres_database}"
        )

        async def _create_connection() -> asyncpg.Connection:
            assert self._credential is not None
            token = await self._credential.get_token(_POSTGRES_AAD_SCOPE)
            return await asyncpg.connect(
                user=self._settings.postgres_user,
                password=token.token,
                host=self._settings.postgres_host,
                port=self._settings.postgres_port,
                database=self._settings.postgres_database,
                ssl="require",
            )

        return create_async_engine(
            url,
            async_creator=_create_connection,
            pool_pre_ping=True,
            pool_size=self._settings.postgres_pool_min_size,
            max_overflow=(
                self._settings.postgres_pool_max_size
                - self._settings.postgres_pool_min_size
            ),
        )

    async def _verify_connectivity(self) -> None:
        """Open a connection and run SELECT 1 to fail-fast on bad config."""
        from sqlalchemy import text

        async with self.engine.begin() as conn:
            result = await conn.execute(text("SELECT 1"))
            assert result.scalar() == 1