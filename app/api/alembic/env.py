"""Alembic environment configuration.

Reuses the application's Settings and the Database client's connection logic
so migrations authenticate the same way as the API itself — Workload Identity
in Azure, password locally.
"""

from __future__ import annotations

import asyncio
from logging.config import fileConfig

import asyncpg
from alembic import context
from sqlalchemy.engine import Connection
from sqlalchemy.ext.asyncio import async_engine_from_config

from ticketing_api.repositories.orm import Base
from ticketing_api.settings import get_settings

# Alembic Config object — gives access to alembic.ini values
config = context.config

if config.config_file_name is not None:
    fileConfig(config.config_file_name)

# Target metadata for autogenerate
target_metadata = Base.metadata


def _build_url(settings) -> str:
    """Build the SQLAlchemy URL.

    For Workload Identity, the URL has no password — we inject the token
    via asyncpg's `connect_args`. For password auth we embed the password.
    """
    if settings.postgres_use_workload_identity:
        return (
            f"postgresql+asyncpg://"
            f"{settings.postgres_user}@"
            f"{settings.postgres_host}:{settings.postgres_port}/"
            f"{settings.postgres_database}"
        )

    password = (
        settings.postgres_password.get_secret_value()
        if settings.postgres_password
        else ""
    )
    return (
        f"postgresql+asyncpg://"
        f"{settings.postgres_user}:{password}@"
        f"{settings.postgres_host}:{settings.postgres_port}/"
        f"{settings.postgres_database}"
    )


async def _create_workload_identity_connection() -> asyncpg.Connection:
    """Create a single asyncpg connection with a fresh Entra ID token.

    Used as the `async_creator` for the SQLAlchemy engine when running
    against Azure PostgreSQL.
    """
    from azure.identity.aio import DefaultAzureCredential

    settings = get_settings()
    async with DefaultAzureCredential() as credential:
        token = await credential.get_token(
            "https://ossrdbms-aad.database.windows.net/.default"
        )
    return await asyncpg.connect(
        user=settings.postgres_user,
        password=token.token,
        host=settings.postgres_host,
        port=settings.postgres_port,
        database=settings.postgres_database,
        ssl="require",
    )


def run_migrations_offline() -> None:
    """Run migrations in 'offline' mode (emit SQL to stdout, no live DB).

    Useful for inspecting the SQL that would be applied. Not used in CI.
    """
    settings = get_settings()
    url = _build_url(settings)

    context.configure(
        url=url,
        target_metadata=target_metadata,
        literal_binds=True,
        dialect_opts={"paramstyle": "named"},
    )
    with context.begin_transaction():
        context.run_migrations()


def _do_run_migrations(connection: Connection) -> None:
    context.configure(
        connection=connection,
        target_metadata=target_metadata,
        compare_type=True,  # detect column type changes in autogenerate
    )
    with context.begin_transaction():
        context.run_migrations()


async def run_migrations_online() -> None:
    """Run migrations against a live database."""
    settings = get_settings()

    engine_kwargs: dict = {
        "future": True,
    }

    if settings.postgres_use_workload_identity:
        engine_kwargs["async_creator"] = _create_workload_identity_connection
        url = _build_url(settings)
    else:
        url = _build_url(settings)

    config.set_main_option("sqlalchemy.url", url)

    connectable = async_engine_from_config(
        config.get_section(config.config_ini_section, {}),
        prefix="sqlalchemy.",
        **engine_kwargs,
    )

    async with connectable.connect() as connection:
        await connection.run_sync(_do_run_migrations)

    await connectable.dispose()


if context.is_offline_mode():
    run_migrations_offline()
else:
    asyncio.run(run_migrations_online())