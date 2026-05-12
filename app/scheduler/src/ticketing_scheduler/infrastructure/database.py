"""Async SQLAlchemy engine — same pattern as the API and worker services."""

from __future__ import annotations

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

import asyncpg
import structlog
from azure.identity.aio import DefaultAzureCredential
from sqlalchemy.ext.asyncio import (
    AsyncEngine,
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)

from ticketing_scheduler.settings import Settings

logger = structlog.get_logger(__name__)

_POSTGRES_AAD_SCOPE = "https://ossrdbms-aad.database.windows.net/.default"


class Database:
    def __init__(self, settings: Settings) -> None:
        self._settings = settings
        self._engine: AsyncEngine | None = None
        self._session_factory: async_sessionmaker[AsyncSession] | None = None
        self._credential: DefaultAzureCredential | None = None

    @property
    def engine(self) -> AsyncEngine:
        if self._engine is None:
            raise RuntimeError("Database.startup() has not been called")
        return self._engine

    async def startup(self) -> None:
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
        if self._session_factory is None:
            raise RuntimeError("Database.startup() has not been called")
        async with self._session_factory() as session:
            try:
                yield session
                await session.commit()
            except Exception:
                await session.rollback()
                raise

    def _build_engine_with_password(self) -> AsyncEngine:
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
                self._settings.postgres_pool_max_size - self._settings.postgres_pool_min_size
            ),
        )

    def _build_engine_with_workload_identity(self) -> AsyncEngine:
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
                self._settings.postgres_pool_max_size - self._settings.postgres_pool_min_size
            ),
        )

    async def _verify_connectivity(self) -> None:
        from sqlalchemy import text

        async with self.engine.begin() as conn:
            result = await conn.execute(text("SELECT 1"))
            assert result.scalar() == 1
