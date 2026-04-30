"""Observability setup — structured logging and OpenTelemetry instrumentation.

Logging:
    - Local dev: human-readable console output (with colours when in a TTY)
    - Cloud: JSON-formatted output ready for Log Analytics ingestion

Tracing:
    - Local dev: disabled
    - Cloud: Azure Monitor OpenTelemetry exporter (set
      APPLICATIONINSIGHTS_CONNECTION_STRING to enable)
"""

import logging
import sys

import structlog
from structlog.types import EventDict, Processor

from ticketing_api.settings import Settings


def configure_observability(settings: Settings) -> None:
    """Configure logging and tracing.

    Called once during application startup, before any logging happens.
    """
    _configure_logging(settings)
    _configure_tracing(settings)


# ── Logging ──────────────────────────────────────────────────────────────────


def _configure_logging(settings: Settings) -> None:
    """Configure structlog for console (dev) or JSON (cloud) output."""
    timestamper = structlog.processors.TimeStamper(fmt="iso", utc=True)

    shared_processors: list[Processor] = [
        structlog.contextvars.merge_contextvars,
        structlog.processors.add_log_level,
        structlog.processors.StackInfoRenderer(),
        timestamper,
        _add_service_identity(settings),
    ]

    if settings.log_format == "console":
        renderer: Processor = structlog.dev.ConsoleRenderer(colors=sys.stderr.isatty())
    else:
        renderer = structlog.processors.JSONRenderer()

    structlog.configure(
        processors=[
            *shared_processors,
            structlog.processors.format_exc_info,
            renderer,
        ],
        wrapper_class=structlog.make_filtering_bound_logger(
            getattr(logging, settings.log_level)
        ),
        logger_factory=structlog.PrintLoggerFactory(file=sys.stderr),
        cache_logger_on_first_use=True,
    )

    # Re-route stdlib logging through structlog for libraries that use it
    logging.basicConfig(
        format="%(message)s",
        stream=sys.stderr,
        level=getattr(logging, settings.log_level),
    )


def _add_service_identity(settings: Settings) -> Processor:
    """Inject service name/version/environment into every log record."""

    def processor(_logger: object, _method_name: str, event_dict: EventDict) -> EventDict:
        event_dict["service.name"] = settings.service_name
        event_dict["service.version"] = settings.service_version
        event_dict["deployment.environment"] = settings.environment
        return event_dict

    return processor


# ── Tracing ──────────────────────────────────────────────────────────────────


def _configure_tracing(settings: Settings) -> None:
    """Configure Azure Monitor OpenTelemetry tracing if connection string is set.

    No-op locally — tracing requires a real Application Insights instance.
    """
    if settings.applicationinsights_connection_string is None:
        return

    from azure.monitor.opentelemetry import configure_azure_monitor

    configure_azure_monitor(
        connection_string=settings.applicationinsights_connection_string.get_secret_value(),
        enable_live_metrics=False,
        instrumentation_options={
            "fastapi": {"enabled": True},
            "sqlalchemy": {"enabled": True},
            "redis": {"enabled": True},
        },
    )