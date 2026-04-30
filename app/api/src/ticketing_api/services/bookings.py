"""Booking service — confirms a reservation into a booking."""

from __future__ import annotations

from datetime import UTC, datetime
from uuid import UUID

import structlog

from ticketing_api.domain.models import Booking, ReservationStatus
from ticketing_api.infrastructure.database import Database
from ticketing_api.infrastructure.servicebus import ServiceBusPublisher
from ticketing_api.repositories.bookings import BookingsRepository
from ticketing_api.repositories.reservations import ReservationsRepository
from ticketing_api.services.exceptions import (
    ReservationExpired,
    ReservationNotFound,
    ReservationNotPending,
)
from ticketing_api.settings import Settings

logger = structlog.get_logger(__name__)


class BookingService:
    def __init__(
        self,
        settings: Settings,
        database: Database,
        servicebus: ServiceBusPublisher,
    ) -> None:
        self._settings = settings
        self._database = database
        self._servicebus = servicebus

    async def confirm(
        self,
        reservation_id: UUID,
        payment_reference: str,
    ) -> Booking:
        """Confirm a pending reservation, creating a booking.

        The status transition (PENDING → CONFIRMED) is atomic at the database
        level — the conditional UPDATE in the repository ensures we cannot
        confirm a reservation that's already expired or already confirmed.
        """
        async with self._database.session() as session:
            reservations_repo = ReservationsRepository(session)
            bookings_repo = BookingsRepository(session)

            reservation = await reservations_repo.get(reservation_id)
            if reservation is None:
                raise ReservationNotFound(
                    f"Reservation {reservation_id} not found"
                )

            if reservation.is_expired:
                raise ReservationExpired(
                    f"Reservation {reservation_id} expired at "
                    f"{reservation.expires_at.isoformat()}"
                )

            transitioned = await reservations_repo.transition_status(
                reservation_id,
                from_status=ReservationStatus.PENDING,
                to_status=ReservationStatus.CONFIRMED,
            )
            if not transitioned:
                # Either already confirmed or expired between the read above
                # and the UPDATE here.
                raise ReservationNotPending(
                    f"Reservation {reservation_id} is no longer pending"
                )

            booking = await bookings_repo.create(
                reservation_id=reservation_id,
                payment_reference=payment_reference,
            )

            logger.info(
                "booking_confirmed",
                booking_id=str(booking.id),
                reservation_id=str(reservation_id),
            )

        # Publish after commit
        await self._servicebus.publish(
            topic=self._settings.servicebus_booking_topic,
            event_type="booking.created",
            payload={
                "booking_id": str(booking.id),
                "reservation_id": str(reservation_id),
                "payment_reference": payment_reference,
                "confirmed_at": booking.confirmed_at.isoformat(),
            },
        )

        return booking