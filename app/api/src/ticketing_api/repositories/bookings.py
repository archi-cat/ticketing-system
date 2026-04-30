"""Bookings repository — confirmed purchases."""

from __future__ import annotations

from datetime import UTC, datetime
from uuid import UUID, uuid4

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from ticketing_api.domain.models import Booking
from ticketing_api.repositories.orm import BookingORM


class BookingsRepository:
    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    async def get(self, booking_id: UUID) -> Booking | None:
        stmt = select(BookingORM).where(BookingORM.id == booking_id)
        result = await self._session.execute(stmt)
        row = result.scalar_one_or_none()
        return _to_domain(row) if row else None

    async def get_by_reservation(self, reservation_id: UUID) -> Booking | None:
        stmt = select(BookingORM).where(
            BookingORM.reservation_id == reservation_id
        )
        result = await self._session.execute(stmt)
        row = result.scalar_one_or_none()
        return _to_domain(row) if row else None

    async def create(
        self,
        reservation_id: UUID,
        payment_reference: str,
    ) -> Booking:
        orm = BookingORM(
            id=uuid4(),
            reservation_id=reservation_id,
            payment_reference=payment_reference,
            confirmed_at=datetime.now(UTC),
        )
        self._session.add(orm)
        await self._session.flush()
        return _to_domain(orm)


def _to_domain(orm: BookingORM) -> Booking:
    return Booking(
        id=orm.id,
        reservation_id=orm.reservation_id,
        payment_reference=orm.payment_reference,
        confirmed_at=orm.confirmed_at,
    )