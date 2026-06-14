"""Observability — structured logging and OpenTelemetry tracing."""

import logging
import sys

import structlog
from structlog.types import EventDict, Processor

from ticketing_worker.settings import Settings


def configure_observability(settings: Settings) -> None:
    _configure_logging(settings)
    _configure_tracing(settings)


def _configure_logging(settings: Settings) -> None:
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
        processors=[*shared_processors, structlog.processors.format_exc_info, renderer],
        wrapper_class=structlog.make_filtering_bound_logger(getattr(logging, settings.log_level)),
        logger_factory=structlog.PrintLoggerFactory(file=sys.stderr),
        cache_logger_on_first_use=True,
    )

    logging.basicConfig(
        format="%(message)s",
        stream=sys.stderr,
        level=getattr(logging, settings.log_level),
    )


def _add_service_identity(settings: Settings) -> Processor:
    def processor(_logger: object, _method_name: str, event_dict: EventDict) -> EventDict:
        event_dict["service.name"] = settings.service_name
        event_dict["service.version"] = settings.service_version
        event_dict["deployment.environment"] = settings.environment
        return event_dict

    return processor


def _configure_tracing(settings: Settings) -> None:
    if settings.applicationinsights_connection_string is None:
        return

    from azure.monitor.opentelemetry import configure_azure_monitor
    from opentelemetry.instrumentation.sqlalchemy import SQLAlchemyInstrumentor

    configure_azure_monitor(
        connection_string=settings.applicationinsights_connection_string.get_secret_value(),
        enable_live_metrics=False,
    )

    # SQLAlchemy is not in configure_azure_monitor's supported-libraries set,
    # so activate it explicitly. The global instrument() wraps
    # create_async_engine; configure_observability runs before the engine is
    # created in Database.startup(), so this traces the engine that follows.
    SQLAlchemyInstrumentor().instrument()
