"""Application settings for the worker service."""

from functools import lru_cache
from typing import Literal

from pydantic import Field, SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
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

    service_name: str = "ticketing-worker"
    service_version: str = "0.1.0"

    # ── Health server ─────────────────────────────────────────────────────────
    health_host: str = "0.0.0.0"  # noqa: S104 — binding all interfaces inside container
    health_port: int = 8001

    # ── Postgres (same env vars as API) ───────────────────────────────────────
    postgres_host: str = "localhost"
    postgres_port: int = 5432
    postgres_database: str = "ticketing"
    postgres_user: str = "postgres"
    postgres_password: SecretStr | None = None
    postgres_use_workload_identity: bool = False
    postgres_pool_min_size: int = 2
    postgres_pool_max_size: int = 5

    # ── Service Bus consumption ───────────────────────────────────────────────
    servicebus_fully_qualified_namespace: str | None = None
    servicebus_use_workload_identity: bool = False

    # Topic + subscription names — must match what the Terraform module created
    servicebus_reservation_topic: str = "reservation-events"
    servicebus_booking_topic: str = "booking-events"
    servicebus_seat_decrement_subscription: str = "seat-decrement"
    servicebus_audit_log_subscription: str = "audit-log"
    servicebus_confirmation_email_subscription: str = "confirmation-email"

    # Per-subscription concurrency. The receiver processes this many messages
    # in parallel. For Phase 1 we keep these conservative.
    servicebus_max_concurrent_messages: int = Field(default=4, ge=1, le=32)

    # Lock duration on a received message — must be long enough for the handler
    # to complete. Service Bus's max is 5 minutes; we set it to 60 seconds
    # which is generous for our handlers (typically <100ms).
    servicebus_message_lock_seconds: int = 60

    # ── App Insights ──────────────────────────────────────────────────────────
    applicationinsights_connection_string: SecretStr | None = None


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    return Settings()
