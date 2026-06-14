"""Tracing-wiring guard.

configure_azure_monitor does NOT auto-activate SQLAlchemy/Redis instrumentation
(they are not in its supported-libraries set), so observability.py activates
them explicitly. These tests guard that wiring against silent removal — without
them, a refactor could drop the instrument() calls and DB/Redis traces would
vanish with no failing test.
"""

from unittest.mock import patch

from pydantic import SecretStr

from ticketing_api.observability import configure_observability
from ticketing_api.settings import Settings

_CONN_STRING = "InstrumentationKey=test;IngestionEndpoint=https://example.com/"


def test_tracing_activates_sqlalchemy_and_redis() -> None:
    """With a connection string set, both instrumentors must be activated."""
    settings = Settings(
        log_format="json",
        applicationinsights_connection_string=SecretStr(_CONN_STRING),
    )

    with (
        patch("azure.monitor.opentelemetry.configure_azure_monitor") as configure,
        patch("opentelemetry.instrumentation.sqlalchemy.SQLAlchemyInstrumentor") as sqlalchemy,
        patch("opentelemetry.instrumentation.redis.RedisInstrumentor") as redis,
    ):
        configure_observability(settings)

    configure.assert_called_once()
    sqlalchemy.return_value.instrument.assert_called_once()
    redis.return_value.instrument.assert_called_once()


def test_tracing_noop_without_connection_string() -> None:
    """No connection string -> tracing setup is a no-op; nothing is instrumented."""
    settings = Settings(log_format="json")

    with (
        patch("azure.monitor.opentelemetry.configure_azure_monitor") as configure,
        patch("opentelemetry.instrumentation.sqlalchemy.SQLAlchemyInstrumentor") as sqlalchemy,
        patch("opentelemetry.instrumentation.redis.RedisInstrumentor") as redis,
    ):
        configure_observability(settings)

    configure.assert_not_called()
    sqlalchemy.assert_not_called()
    redis.assert_not_called()
