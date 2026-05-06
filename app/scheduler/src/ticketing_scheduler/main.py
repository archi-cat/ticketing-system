"""Scheduler service entry point.

Lifecycle:
    1. Start database, Redis, health server
    2. Enter the leader election loop
    3. Run an APScheduler instance that ticks every
       expiry_sweep_interval_seconds, calling the sweeper job ONLY if
       we are currently the leader
    4. On SIGTERM: stop the scheduler, release leadership, shut down
       infrastructure
"""

from __future__ import annotations

import asyncio
import signal

import structlog
from apscheduler.schedulers.asyncio import AsyncIOScheduler
from apscheduler.triggers.interval import IntervalTrigger

from ticketing_scheduler.health_server import HealthServer
from ticketing_scheduler.infrastructure.database import Database
from ticketing_scheduler.infrastructure.redis_client import RedisClient
from ticketing_scheduler.jobs.reservation_expiry import ReservationExpirySweeper
from ticketing_scheduler.observability import configure_observability
from ticketing_scheduler.runtime.leader_election import (
    LeaderElection,
    leadership_loop,
)
from ticketing_scheduler.settings import Settings, get_settings

logger = structlog.get_logger(__name__)


async def run() -> None:
    settings = get_settings()
    configure_observability(settings)

    logger.info(
        "scheduler_starting",
        environment=settings.environment,
        service_version=settings.service_version,
    )

    # ── Construct infrastructure ──────────────────────────────────────────────
    database = Database(settings)
    redis = RedisClient(settings)
    await database.startup()
    await redis.startup()

    health_server = HealthServer(
        database, redis, host=settings.health_host, port=settings.health_port
    )
    await health_server.startup()

    # ── Leader election ───────────────────────────────────────────────────────
    election = LeaderElection(
        redis=redis.client,
        lock_key=settings.leader_lock_key,
        lease_ttl_seconds=settings.leader_lease_ttl_seconds,
        renew_interval_seconds=settings.leader_renew_interval_seconds,
    )

    sweeper = ReservationExpirySweeper(
        database, batch_size=settings.expiry_sweep_batch_size
    )

    # ── APScheduler ──────────────────────────────────────────────────────────
    aps = AsyncIOScheduler()

    async with leadership_loop(
        election,
        acquisition_retry_seconds=settings.leader_acquisition_retry_seconds,
    ) as is_leader:

        async def _tick() -> None:
            if not is_leader():
                logger.debug("scheduler_tick_skipped_not_leader")
                return
            try:
                await sweeper.run()
            except Exception as exc:  # noqa: BLE001
                logger.error(
                    "scheduler_tick_failed",
                    error=str(exc),
                    exception_type=exc.__class__.__name__,
                )

        aps.add_job(
            _tick,
            trigger=IntervalTrigger(seconds=settings.expiry_sweep_interval_seconds),
            id="reservation-expiry-sweeper",
            max_instances=1,
            coalesce=True,
        )

        aps.start()
        logger.info(
            "scheduler_ready",
            tick_interval_seconds=settings.expiry_sweep_interval_seconds,
        )

        # ── Wait for shutdown signal ──────────────────────────────────────────
        await _shutdown_signal()

        logger.info("scheduler_stopping")
        aps.shutdown(wait=True)

    # leadership_loop's __aexit__ has already released leadership at this point
    await health_server.shutdown()
    await redis.shutdown()
    await database.shutdown()
    logger.info("scheduler_stopped")


async def _shutdown_signal() -> None:
    loop = asyncio.get_running_loop()
    stop_event = asyncio.Event()

    def _handler() -> None:
        logger.info("shutdown_signal_received")
        stop_event.set()

    try:
        loop.add_signal_handler(signal.SIGTERM, _handler)
        loop.add_signal_handler(signal.SIGINT, _handler)
    except NotImplementedError:
        pass  # Windows

    await stop_event.wait()