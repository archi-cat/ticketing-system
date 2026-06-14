"""Events repository — data access for events."""

from __future__ import annotations

from typing import Any, cast
from uuid import UUID

from sqlalchemy import CursorResult, select
from sqlalchemy.ext.asyncio import AsyncSession

from ticketing_api.domain.models import Event, EventCreate
from ticketing_api.repositories.orm import EventORM


class EventsRepository:
    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    async def get(self, event_id: UUID) -> Event | None:
        stmt = select(EventORM).where(EventORM.id == event_id)
        result = await self._session.execute(stmt)
        row = result.scalar_one_or_none()
        return _to_domain(row) if row else None

    async def list_upcoming(self, limit: int = 50) -> list[Event]:
        from datetime import UTC, datetime

        stmt = (
            select(EventORM)
            .where(EventORM.starts_at > datetime.now(UTC))
            .order_by(EventORM.starts_at)
            .limit(limit)
        )
        result = await self._session.execute(stmt)
        return [_to_domain(row) for row in result.scalars()]

    async def decrement_available_seats(self, event_id: UUID, seat_count: int) -> bool:
        """Atomically decrement available seats. Returns False if insufficient.

        Uses a conditional UPDATE so the check and decrement happen in a single
        statement — no race window between read and write.
        """
        from sqlalchemy import update

        stmt = (
            update(EventORM)
            .where(
                EventORM.id == event_id,
                EventORM.available_seats >= seat_count,
            )
            .values(available_seats=EventORM.available_seats - seat_count)
        )
        result = cast(CursorResult[Any], await self._session.execute(stmt))
        return result.rowcount > 0

    async def increment_available_seats(self, event_id: UUID, seat_count: int) -> None:
        """Release seats back to the pool (used on reservation expiry)."""
        from sqlalchemy import update

        stmt = (
            update(EventORM)
            .where(EventORM.id == event_id)
            .values(available_seats=EventORM.available_seats + seat_count)
        )
        await self._session.execute(stmt)

    async def create(self, events: list[EventCreate]) -> int:
        """Bulk-insert events. Skips rows whose id already exists.

        Returns the number of rows actually inserted (duplicates are silently
        ignored via ON CONFLICT DO NOTHING).
        """
        from datetime import UTC, datetime

        from sqlalchemy.dialects.postgresql import insert as pg_insert

        if not events:
            return 0

        now = datetime.now(UTC)
        stmt = (
            pg_insert(EventORM)
            .values(
                [
                    {
                        "id": e.id,
                        "name": e.name,
                        "venue": e.venue,
                        "starts_at": e.starts_at,
                        "total_seats": e.total_seats,
                        "available_seats": e.total_seats,
                        "price_pence": e.price_pence,
                        "created_at": now,
                        "updated_at": now,
                    }
                    for e in events
                ]
            )
            .on_conflict_do_nothing(index_elements=["id"])
        )
        result = cast(CursorResult[Any], await self._session.execute(stmt))
        return result.rowcount


def _to_domain(orm: EventORM) -> Event:
    return Event(
        id=orm.id,
        name=orm.name,
        venue=orm.venue,
        starts_at=orm.starts_at,
        total_seats=orm.total_seats,
        available_seats=orm.available_seats,
        price_pence=orm.price_pence,
        created_at=orm.created_at,
        updated_at=orm.updated_at,
    )
