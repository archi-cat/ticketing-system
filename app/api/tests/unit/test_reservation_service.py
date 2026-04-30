"""Unit tests for ReservationService.

Mocks the database, Redis lock, and Service Bus. Verifies the orchestration
logic without standing up real infrastructure.
"""

from __future__ import annotations

from contextlib import asynccontextmanager
from datetime import UTC, datetime, timedelta
from unittest.mock import AsyncMock, MagicMock
from uuid import uuid4

import pytest

from ticketing_api.domain.models import Event, Reservation, ReservationStatus
from ticketing_api.services.exceptions import (
    ConcurrentReservationConflict,
    EventNotFound,
    InsufficientSeats,
    TooManySeatsRequested,
)
from ticketing_api.services.locks import LockNotAcquired
from ticketing_api.services.reservations import ReservationService
from ticketing_api.settings import Settings


@pytest.fixture
def settings() -> Settings:
    return Settings(
        environment="local",
        log_format="console",
        reservation_max_seats_per_request=10,
    )


@pytest.fixture
def event() -> Event:
    now = datetime.now(UTC)
    return Event(
        id=uuid4(),
        name="Test Concert",
        venue="Test Venue",
        starts_at=now + timedelta(days=30),
        total_seats=100,
        available_seats=100,
        price_pence=2500,
        created_at=now,
        updated_at=now,
    )


@pytest.fixture
def reservation(event: Event) -> Reservation:
    now = datetime.now(UTC)
    return Reservation(
        id=uuid4(),
        event_id=event.id,
        customer_email="alice@example.com",
        seat_count=2,
        status=ReservationStatus.PENDING,
        expires_at=now + timedelta(minutes=15),
        created_at=now,
    )


def _make_service(
    settings: Settings,
    *,
    event: Event | None = None,
    decrement_returns: bool = True,
    reservation: Reservation | None = None,
    lock_acquires: bool = True,
) -> tuple[ReservationService, MagicMock]:
    """Construct a ReservationService with mocked dependencies."""
    database = MagicMock()
    servicebus = AsyncMock()
    lock = MagicMock()

    # Lock context manager — either yields successfully or raises.
    if lock_acquires:
        @asynccontextmanager
        async def _ok_lock(*_args, **_kwargs):
            yield

        lock.acquire = _ok_lock
    else:
        @asynccontextmanager
        async def _bad_lock(*_args, **_kwargs):
            raise LockNotAcquired("contention")
            yield  # unreachable

        lock.acquire = _bad_lock

    # Database session — yields a mock that the repositories use.
    session = AsyncMock()

    @asynccontextmanager
    async def _session_cm():
        yield session

    database.session = _session_cm

    # Patch repository constructors at the class level for this test.
    # Cleaner alternative would be DI; for a learning project this is fine.
    from ticketing_api.services import reservations as svc_module

    events_repo = AsyncMock()
    events_repo.get.return_value = event
    events_repo.decrement_available_seats.return_value = decrement_returns

    reservations_repo = AsyncMock()
    reservations_repo.create.return_value = reservation

    svc_module.EventsRepository = MagicMock(return_value=events_repo)
    svc_module.ReservationsRepository = MagicMock(return_value=reservations_repo)

    return ReservationService(settings, database, lock, servicebus), servicebus


@pytest.mark.asyncio
async def test_create_publishes_event_after_commit(
    settings: Settings, event: Event, reservation: Reservation
):
    service, servicebus = _make_service(
        settings, event=event, reservation=reservation
    )

    result = await service.create(event.id, "alice@example.com", 2)

    assert result == reservation
    servicebus.publish.assert_awaited_once()
    call = servicebus.publish.await_args
    assert call.kwargs["event_type"] == "reservation.created"
    assert call.kwargs["payload"]["reservation_id"] == str(reservation.id)


@pytest.mark.asyncio
async def test_too_many_seats_raises(settings: Settings):
    service, _ = _make_service(settings)
    with pytest.raises(TooManySeatsRequested):
        await service.create(uuid4(), "alice@example.com", 999)


@pytest.mark.asyncio
async def test_event_not_found_raises(settings: Settings):
    service, _ = _make_service(settings, event=None)
    with pytest.raises(EventNotFound):
        await service.create(uuid4(), "alice@example.com", 2)


@pytest.mark.asyncio
async def test_insufficient_seats_raises(
    settings: Settings, event: Event
):
    service, _ = _make_service(
        settings, event=event, decrement_returns=False
    )
    with pytest.raises(InsufficientSeats):
        await service.create(event.id, "alice@example.com", 2)


@pytest.mark.asyncio
async def test_lock_contention_raises(settings: Settings):
    service, _ = _make_service(settings, lock_acquires=False)
    with pytest.raises(ConcurrentReservationConflict):
        await service.create(uuid4(), "alice@example.com", 2)