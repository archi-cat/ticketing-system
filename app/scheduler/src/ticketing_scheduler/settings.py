"""Application settings for the scheduler service."""

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

    service_name: str = "ticketing-scheduler"
    service_version: str = "0.1.0"

    # ── Health server ─────────────────────────────────────────────────────────
    health_host: str = "0.0.0.0"  # noqa: S104
    health_port: int = 8002

    # ── Postgres ──────────────────────────────────────────────────────────────
    postgres_host: str = "localhost"
    postgres_port: int = 5432
    postgres_database: str = "ticketing"
    postgres_user: str = "postgres"
    postgres_password: SecretStr | None = None
    postgres_use_workload_identity: bool = False
    postgres_pool_min_size: int = 2
    postgres_pool_max_size: int = 5

    # ── Redis (for leader election) ───────────────────────────────────────────
    redis_host: str = "localhost"
    redis_port: int = 6379
    redis_use_tls: bool = False
    redis_use_entra_id: bool = False
    redis_username: str = ""
    redis_password: SecretStr | None = None

    # ── Leader election ───────────────────────────────────────────────────────
    leader_lock_key: str = "lock:scheduler:expiry-sweeper"
    leader_lease_ttl_seconds: int = Field(default=90, ge=10)
    leader_renew_interval_seconds: int = Field(default=30, ge=5)
    leader_acquisition_retry_seconds: int = Field(default=10, ge=1)

    # ── Job scheduling ────────────────────────────────────────────────────────
    expiry_sweep_interval_seconds: int = Field(default=60, ge=10)
    expiry_sweep_batch_size: int = Field(default=100, ge=1)

    # ── App Insights ──────────────────────────────────────────────────────────
    applicationinsights_connection_string: SecretStr | None = None


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    return Settings()
