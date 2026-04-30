"""Reservations repository — CRUD + a few specialised queries."""

from __future__ import annotations

from datetime import UTC, datetime, timedelta
from uuid import UUID, uuid4

from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncSession

from ticketing_api.domain.models import Reservation, ReservationStatus
from ticketing_api.repositories.orm import ReservationORM


class ReservationsRepository:
    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    async def get(self, reservation_id: UUID) -> Reservation | None:
        stmt = select(ReservationORM).where(ReservationORM.id == reservation_id)
        result = await self._session.execute(stmt)
        row = result.scalar_one_or_none()
        return _to_domain(row) if row else None

    async def create(
        self,
        event_id: UUID,
        customer_email: str,
        seat_count: int,
        ttl_seconds: int,
    ) -> Reservation:
        now = datetime.now(UTC)
        orm = ReservationORM(
            id=uuid4(),
            event_id=event_id,
            customer_email=customer_email,
            seat_count=seat_count,
            status=ReservationStatus.PENDING.value,
            expires_at=now + timedelta(seconds=ttl_seconds),
            created_at=now,
        )
        self._session.add(orm)
        await self._session.flush()
        return _to_domain(orm)

    async def transition_status(
        self,
        reservation_id: UUID,
        from_status: ReservationStatus,
        to_status: ReservationStatus,
    ) -> bool:
        """Atomic status transition. Returns False if the from_status didn't match.

        Used for both PENDING → CONFIRMED (confirmation flow) and
        PENDING → EXPIRED (sweeper flow). The conditional WHERE prevents
        races: a reservation cannot be both confirmed and expired.
        """
        stmt = (
            update(ReservationORM)
            .where(
                ReservationORM.id == reservation_id,
                ReservationORM.status == from_status.value,
            )
            .values(status=to_status.value)
        )
        result = await self._session.execute(stmt)
        return result.rowcount > 0

    async def list_expired_pending(self, limit: int = 100) -> list[Reservation]:
        """Find PENDING reservations past their expiry. Used by the scheduler."""
        stmt = (
            select(ReservationORM)
            .where(
                ReservationORM.status == ReservationStatus.PENDING.value,
                ReservationORM.expires_at <= datetime.now(UTC),
            )
            .limit(limit)
        )
        result = await self._session.execute(stmt)
        return [_to_domain(row) for row in result.scalars()]


def _to_domain(orm: ReservationORM) -> Reservation:
    return Reservation(
        id=orm.id,
        event_id=orm.event_id,
        customer_email=orm.customer_email,
        seat_count=orm.seat_count,
        status=ReservationStatus(orm.status),
        expires_at=orm.expires_at,
        created_at=orm.created_at,
    )