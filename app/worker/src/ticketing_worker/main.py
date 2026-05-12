"""Worker service entry point.

Starts:
    - Database engine
    - Service Bus client + credential
    - Health HTTP server
    - One Consumer per subscription, all running concurrently

Stops gracefully on SIGTERM (Kubernetes pod termination).
"""

from __future__ import annotations

import asyncio
import signal
from typing import NoReturn

import structlog
from azure.identity.aio import DefaultAzureCredential
from azure.servicebus.aio import ServiceBusClient

from ticketing_worker.handlers.audit_log import AuditLogHandler
from ticketing_worker.handlers.confirmation_email import ConfirmationEmailHandler
from ticketing_worker.handlers.seat_decrement import SeatDecrementHandler
from ticketing_worker.health_server import HealthServer
from ticketing_worker.infrastructure.database import Database
from ticketing_worker.observability import configure_observability
from ticketing_worker.runtime.consumer import Consumer
from ticketing_worker.settings import Settings, get_settings

logger = structlog.get_logger(__name__)


async def run() -> None:
    """Async entry point — orchestrates the worker lifecycle."""
    settings = get_settings()
    configure_observability(settings)

    logger.info(
        "worker_starting",
        environment=settings.environment,
        service_version=settings.service_version,
    )

    # ── Construct everything ──────────────────────────────────────────────────
    database = Database(settings)
    await database.startup()

    health_server = HealthServer(database, host=settings.health_host, port=settings.health_port)
    await health_server.startup()

    if not settings.servicebus_use_workload_identity:
        logger.warning(
            "servicebus_disabled",
            reason="workload_identity_disabled_locally",
        )
        # Wait forever doing nothing — keeps the health server up for K8s probes
        await _shutdown_signal()
        await _shutdown_resources(database, health_server)
        return

    credential = DefaultAzureCredential()
    sb_client = ServiceBusClient(
        fully_qualified_namespace=(
            settings.servicebus_fully_qualified_namespace  # type: ignore[arg-type]
        ),
        credential=credential,
    )

    # ── One consumer per subscription ─────────────────────────────────────────
    consumers = [
        Consumer(
            client=sb_client,
            topic_name=settings.servicebus_reservation_topic,
            subscription_name=settings.servicebus_seat_decrement_subscription,
            handler=SeatDecrementHandler(database),
            database=database,
            max_concurrent_messages=settings.servicebus_max_concurrent_messages,
            message_lock_seconds=settings.servicebus_message_lock_seconds,
        ),
        Consumer(
            client=sb_client,
            topic_name=settings.servicebus_reservation_topic,
            subscription_name=settings.servicebus_audit_log_subscription,
            handler=AuditLogHandler(database),
            database=database,
            max_concurrent_messages=settings.servicebus_max_concurrent_messages,
            message_lock_seconds=settings.servicebus_message_lock_seconds,
        ),
        Consumer(
            client=sb_client,
            topic_name=settings.servicebus_booking_topic,
            subscription_name=settings.servicebus_confirmation_email_subscription,
            handler=ConfirmationEmailHandler(database),
            database=database,
            max_concurrent_messages=settings.servicebus_max_concurrent_messages,
            message_lock_seconds=settings.servicebus_message_lock_seconds,
        ),
        Consumer(
            client=sb_client,
            topic_name=settings.servicebus_booking_topic,
            subscription_name=settings.servicebus_audit_log_subscription,
            handler=AuditLogHandler(database),
            database=database,
            max_concurrent_messages=settings.servicebus_max_concurrent_messages,
            message_lock_seconds=settings.servicebus_message_lock_seconds,
        ),
    ]

    # ── Run consumers + wait for shutdown signal ──────────────────────────────
    consumer_tasks = [asyncio.create_task(c.run()) for c in consumers]
    logger.info("worker_ready", consumers=len(consumers))

    await _shutdown_signal()

    # ── Shutdown sequence ─────────────────────────────────────────────────────
    logger.info("worker_stopping")
    for c in consumers:
        await c.stop()

    await asyncio.gather(*consumer_tasks, return_exceptions=True)

    await sb_client.close()
    await credential.close()
    await _shutdown_resources(database, health_server)

    logger.info("worker_stopped")


async def _shutdown_signal() -> None:
    """Block until SIGTERM or SIGINT is received."""
    loop = asyncio.get_running_loop()
    stop_event = asyncio.Event()

    def _signal_handler() -> None:
        logger.info("shutdown_signal_received")
        stop_event.set()

    # asyncio.Event.set() is thread-safe, but signal handlers run in the main
    # thread on Unix. add_signal_handler fails on Windows, so we fall back.
    try:
        loop.add_signal_handler(signal.SIGTERM, _signal_handler)
        loop.add_signal_handler(signal.SIGINT, _signal_handler)
    except NotImplementedError:
        # Windows — Ctrl+C still works via the default handler
        pass

    await stop_event.wait()


async def _shutdown_resources(
    database: Database,
    health_server: HealthServer,
) -> None:
    await health_server.shutdown()
    await database.shutdown()
