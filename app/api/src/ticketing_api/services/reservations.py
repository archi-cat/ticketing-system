"""Reservation service — orchestrates the seat-reservation flow.

The flow:
    1. Validate request (event exists, seat count within bounds)
    2. Acquire distributed lock on the event ID
    3. Atomically decrement available seats (DB-level conditional UPDATE)
    4. Insert reservation row (status=PENDING)
    5. Publish reservation.created event to Service Bus
    6. Release lock
    7. Return reservation

Steps 3-5 happen inside a database transaction; the lock guards the whole
operation; the event is published after commit so consumers don't see
events for transactions that rolled back.
"""

from __future__ import annotations

from uuid import UUID

import structlog

from ticketing_api.domain.models import Reservation
from ticketing_api.infrastructure.database import Database
from ticketing_api.infrastructure.servicebus import ServiceBusPublisher
from ticketing_api.repositories.events import EventsRepository
from ticketing_api.repositories.reservations import ReservationsRepository
from ticketing_api.services.exceptions import (
    ConcurrentReservationConflict,
    EventNotFound,
    InsufficientSeats,
    TooManySeatsRequested,
)
from ticketing_api.services.locks import DistributedLock, LockNotAcquired
from ticketing_api.settings import Settings

logger = structlog.get_logger(__name__)


class ReservationService:
    def __init__(
        self,
        settings: Settings,
        database: Database,
        lock: DistributedLock,
        servicebus: ServiceBusPublisher,
    ) -> None:
        self._settings = settings
        self._database = database
        self._lock = lock
        self._servicebus = servicebus

    async def create(
        self,
        event_id: UUID,
        customer_email: str,
        seat_count: int,
    ) -> Reservation:
        """Create a reservation, decrementing seat availability.

        Raises
        ------
        TooManySeatsRequested
            seat_count exceeds the per-request maximum.
        EventNotFound
            event_id does not match an existing event.
        InsufficientSeats
            Not enough seats available for this reservation.
        ConcurrentReservationConflict
            Another reservation for this event is in flight; client should retry.
        """
        if seat_count > self._settings.reservation_max_seats_per_request:
            raise TooManySeatsRequested(
                f"Cannot reserve more than "
                f"{self._settings.reservation_max_seats_per_request} seats per request"
            )

        lock_key = f"lock:reservation:{event_id}"

        try:
            async with self._lock.acquire(
                lock_key,
                ttl_seconds=self._settings.reservation_lock_ttl_seconds,
            ):
                reservation = await self._create_locked(
                    event_id, customer_email, seat_count
                )
        except LockNotAcquired as exc:
            raise ConcurrentReservationConflict(
                f"Another reservation for event {event_id} is in flight"
            ) from exc

        # Publish AFTER the transaction commits — consumers must not see
        # events for transactions that rolled back.
        await self._servicebus.publish(
            topic=self._settings.servicebus_reservation_topic,
            event_type="reservation.created",
            payload={
                "reservation_id": str(reservation.id),
                "event_id": str(reservation.event_id),
                "customer_email": reservation.customer_email,
                "seat_count": reservation.seat_count,
                "expires_at": reservation.expires_at.isoformat(),
            },
        )

        return reservation

    async def _create_locked(
        self,
        event_id: UUID,
        customer_email: str,
        seat_count: int,
    ) -> Reservation:
        """Inner transactional logic — runs while holding the distributed lock."""
        async with self._database.session() as session:
            events_repo = EventsRepository(session)
            reservations_repo = ReservationsRepository(session)

            event = await events_repo.get(event_id)
            if event is None:
                raise EventNotFound(f"Event {event_id} not found")

            decremented = await events_repo.decrement_available_seats(
                event_id, seat_count
            )
            if not decremented:
                raise InsufficientSeats(
                    f"Not enough seats for event {event_id}"
                )

            reservation = await reservations_repo.create(
                event_id=event_id,
                customer_email=customer_email,
                seat_count=seat_count,
                ttl_seconds=self._settings.reservation_ttl_seconds,
            )

            logger.info(
                "reservation_created",
                reservation_id=str(reservation.id),
                event_id=str(event_id),
                seat_count=seat_count,
            )
            return reservation