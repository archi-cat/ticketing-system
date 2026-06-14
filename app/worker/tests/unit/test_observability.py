"""Tracing-wiring guard.

configure_azure_monitor does NOT auto-activate SQLAlchemy instrumentation (it's
not in its supported-libraries set), so observability.py activates it explicitly.
This test guards that wiring against silent removal. The worker has no Redis
dependency, so only SQLAlchemy is instrumented.
"""

from unittest.mock import patch

from pydantic import SecretStr

from ticketing_worker.observability import configure_observability
from ticketing_worker.settings import Settings

_CONN_STRING = "InstrumentationKey=test;IngestionEndpoint=https://example.com/"


def test_tracing_activates_sqlalchemy() -> None:
    """With a connection string set, SQLAlchemy instrumentation must be activated."""
    settings = Settings(
        log_format="json",
        applicationinsights_connection_string=SecretStr(_CONN_STRING),
    )

    with (
        patch("azure.monitor.opentelemetry.configure_azure_monitor") as configure,
        patch("opentelemetry.instrumentation.sqlalchemy.SQLAlchemyInstrumentor") as sqlalchemy,
    ):
        configure_observability(settings)

    configure.assert_called_once()
    sqlalchemy.return_value.instrument.assert_called_once()


def test_tracing_noop_without_connection_string() -> None:
    """No connection string -> tracing setup is a no-op; nothing is instrumented."""
    settings = Settings(log_format="json")

    with (
        patch("azure.monitor.opentelemetry.configure_azure_monitor") as configure,
        patch("opentelemetry.instrumentation.sqlalchemy.SQLAlchemyInstrumentor") as sqlalchemy,
    ):
        configure_observability(settings)

    configure.assert_not_called()
    sqlalchemy.assert_not_called()
