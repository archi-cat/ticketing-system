"""Application settings loaded from environment variables.

Uses pydantic-settings for validation. Settings are immutable once loaded
(frozen=True) — anything that wants to change at runtime should not be a
setting.
"""

from functools import lru_cache
from typing import Literal

from pydantic import Field, SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Top-level settings.

    Sub-settings are nested by prefix (e.g. ``DATABASE_*`` maps to
    ``DatabaseSettings``). This keeps the env namespace organised and
    self-documenting.
    """

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        env_nested_delimiter="__",
        case_sensitive=False,
        frozen=True,
        extra="ignore",
    )

    # ── Runtime context ───────────────────────────────────────────────────────
    environment: Literal["local", "dev", "staging", "prod"] = "local"
    log_level: Literal["DEBUG", "INFO", "WARNING", "ERROR"] = "INFO"
    log_format: Literal["json", "console"] = "console"

    # ── Service identity ──────────────────────────────────────────────────────
    service_name: str = "ticketing-api"
    service_version: str = "0.1.0"

    # ── HTTP server ───────────────────────────────────────────────────────────
    http_host: str = "0.0.0.0"  # noqa: S104 — binding all interfaces inside container is correct
    http_port: int = 8000

    # ── Postgres ──────────────────────────────────────────────────────────────
    postgres_host: str = "localhost"
    postgres_port: int = 5432
    postgres_database: str = "ticketing"
    postgres_user: str = "postgres"
    postgres_password: SecretStr | None = Field(
        default=None,
        description=(
            "Local development only. In Azure, the API uses Workload Identity to "
            "obtain an Entra ID token and authenticates passwordlessly."
        ),
    )
    postgres_use_workload_identity: bool = False
    postgres_pool_min_size: int = 5
    postgres_pool_max_size: int = 20

    # ── Redis ─────────────────────────────────────────────────────────────────
    redis_host: str = "localhost"
    redis_port: int = 6379
    redis_use_tls: bool = False
    redis_password: SecretStr | None = None
    redis_keyvault_secret_name: str = "redis-primary-key"

    # ── Service Bus ───────────────────────────────────────────────────────────
    # Local development uses a docker-compose Service Bus emulator or skips
    # message publishing. In Azure, fully_qualified_namespace is used with
    # passwordless auth (Workload Identity).
    servicebus_fully_qualified_namespace: str | None = None
    servicebus_use_workload_identity: bool = False
    servicebus_reservation_topic: str = "reservation-events"
    servicebus_booking_topic: str = "booking-events"

    # ── Key Vault ─────────────────────────────────────────────────────────────
    keyvault_uri: str | None = None  # not needed for local dev

    # ── Application Insights ──────────────────────────────────────────────────
    applicationinsights_connection_string: SecretStr | None = None

    # ── Reservation business rules ────────────────────────────────────────────
    reservation_ttl_seconds: int = 15 * 60  # 15 minutes
    reservation_lock_ttl_seconds: int = 5
    reservation_max_seats_per_request: int = 10


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    """Return the cached application settings.

    Cached because instantiating Settings re-reads the environment, which is
    wasteful in hot paths. Use ``get_settings.cache_clear()`` in tests if you
    need to override values for a single test.
    """
    return Settings()