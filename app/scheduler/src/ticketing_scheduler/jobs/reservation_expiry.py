"""Reservation expiry sweeper.

Runs periodically. Finds PENDING reservations past their expires_at,
transitions them to EXPIRED, and returns the released seats to the
event's available_seats.

The work is done in chunks — each batch is a single transaction. If a
batch fails, the sweep skips that batch and tries again on the next tick.
"""

from __future__ import annotations

from datetime import UTC, datetime
from uuid import UUID

import structlog
from sqlalchemy import select, text, update
from sqlalchemy.ext.asyncio import AsyncSession

from ticketing_scheduler.infrastructure.database import Database

logger = structlog.get_logger(__name__)


class ReservationExpirySweeper:
    """Find expired PENDING reservations and release their seats."""

    def __init__(self, database: Database, batch_size: int) -> None:
        self._database = database
        self._batch_size = batch_size

    async def run(self) -> int:
        """Run one sweep. Returns the number of reservations expired."""
        async with self._database.session() as session:
            expired_count = await self._sweep_batch(session)

        if expired_count > 0:
            logger.info(
                "reservation_expiry_sweep_completed",
                expired_count=expired_count,
            )
        else:
            logger.debug("reservation_expiry_sweep_completed", expired_count=0)

        return expired_count

    async def _sweep_batch(self, session: AsyncSession) -> int:
        """Inner sweep — single transaction, bounded batch size."""
        # Step 1: find expired PENDING reservations.
        #
        # FOR UPDATE SKIP LOCKED is the secret sauce — if some other
        # transaction (e.g. a confirmation in flight) is touching one of
        # these rows, we just skip it for now. The next sweep picks it up.
        #
        # This pattern is canonical for queue-like workloads in PostgreSQL.
        find_stmt = text(
            """
            SELECT r.id, r.event_id, r.seat_count
            FROM reservations r
            WHERE r.status = 'PENDING'
              AND r.expires_at <= NOW()
            ORDER BY r.expires_at ASC
            LIMIT :batch_size
            FOR UPDATE SKIP LOCKED
            """
        )
        rows = (
            await session.execute(find_stmt, {"batch_size": self._batch_size})
        ).all()

        if not rows:
            return 0

        # Step 2: transition each reservation to EXPIRED and release its seats.
        # The conditional WHERE on status='PENDING' is belt-and-braces — the
        # FOR UPDATE above already locked these rows so no one else can have
        # transitioned them, but explicit safety in shared state is cheap.
        for row in rows:
            reservation_id: UUID = row.id
            event_id: UUID = row.event_id
            seat_count: int = row.seat_count

            transition_stmt = text(
                """
                UPDATE reservations
                SET status = 'EXPIRED'
                WHERE id = :reservation_id
                  AND status = 'PENDING'
                """
            )
            transition_result = await session.execute(
                transition_stmt, {"reservation_id": reservation_id}
            )

            if transition_result.rowcount == 0:
                # Race lost — someone else just confirmed it. Skip.
                logger.warning(
                    "reservation_transition_skipped",
                    reservation_id=str(reservation_id),
                    reason="not_pending_anymore",
                )
                continue

            release_stmt = text(
                """
                UPDATE events
                SET available_seats = available_seats + :seat_count
                WHERE id = :event_id
                """
            )
            await session.execute(
                release_stmt,
                {"seat_count": seat_count, "event_id": event_id},
            )

            logger.info(
                "reservation_expired",
                reservation_id=str(reservation_id),
                event_id=str(event_id),
                seats_released=seat_count,
            )

        return len(rows)