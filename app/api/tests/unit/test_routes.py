"""Unit tests for the HTTP routes.

These tests verify the route layer in isolation — services and the database
are mocked. Integration tests against a real PostgreSQL/Redis come in the
next step.
"""

from __future__ import annotations

from contextlib import asynccontextmanager
from collections.abc import AsyncIterator
from datetime import UTC, datetime, timedelta
from unittest.mock import AsyncMock, MagicMock
from uuid import uuid4

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from ticketing_api.domain.models import (
    Booking,
    Event,
    Reservation,
    ReservationStatus,
)
from ticketing_api.main import create_app
from ticketing_api.services.exceptions import (
    EventNotFound,
    InsufficientSeats,
    TooManySeatsRequested,
)
from ticketing_api.settings import Settings


@asynccontextmanager
async def _noop_lifespan(_app: FastAPI) -> AsyncIterator[None]:
    yield


@pytest.fixture
def settings() -> Settings:
    return Settings(environment="local", log_format="console")


@pytest.fixture
def event() -> Event:
    now = datetime.now(UTC)
    return Event(
        id=uuid4(),
        name="Test Concert",
        venue="O2 Arena",
        starts_at=now + timedelta(days=30),
        total_seats=100,
        available_seats=50,
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


@pytest.fixture
def booking(reservation: Reservation) -> Booking:
    return Booking(
        id=uuid4(),
        reservation_id=reservation.id,
        payment_reference="mock-1234-abcdef",
        confirmed_at=datetime.now(UTC),
    )


def _make_client(
    settings: Settings,
    monkeypatch: pytest.MonkeyPatch,
    *,
    reservation_service: AsyncMock | None = None,
    booking_service: AsyncMock | None = None,
    events_repo: AsyncMock | None = None,
    reservations_repo: AsyncMock | None = None,
    bookings_repo: AsyncMock | None = None,
) -> TestClient:
    """Construct a TestClient with mocked services and repositories."""
    monkeypatch.setattr("ticketing_api.main._lifespan", _noop_lifespan)
    app = create_app(settings)

    # Stash mocks on app.state — routes look these up
    app.state.reservation_service = reservation_service or AsyncMock()
    app.state.booking_service = booking_service or AsyncMock()

    # Mock the database session context manager — repos are constructed
    # against the session, so we patch the repo constructors directly.
    @asynccontextmanager
    async def _session_cm():
        yield AsyncMock()

    db_mock = MagicMock()
    db_mock.session = _session_cm
    app.state.database = db_mock

    if events_repo is not None:
        from ticketing_api.routes import events as events_route_module
        monkeypatch.setattr(
            events_route_module, "EventsRepository", MagicMock(return_value=events_repo)
        )

    if reservations_repo is not None:
        from ticketing_api.routes import reservations as reservations_route_module
        monkeypatch.setattr(
            reservations_route_module,
            "ReservationsRepository",
            MagicMock(return_value=reservations_repo),
        )

    if bookings_repo is not None:
        from ticketing_api.routes import bookings as bookings_route_module
        monkeypatch.setattr(
            bookings_route_module,
            "BookingsRepository",
            MagicMock(return_value=bookings_repo),
        )

    return TestClient(app)


# ── Events ───────────────────────────────────────────────────────────────────


def test_list_upcoming_events(settings, event, monkeypatch):
    repo = AsyncMock()
    repo.list_upcoming.return_value = [event]

    client = _make_client(settings, monkeypatch, events_repo=repo)
    response = client.get("/events")

    assert response.status_code == 200
    body = response.json()
    assert len(body["items"]) == 1
    assert body["items"][0]["id"] == str(event.id)
    assert body["items"][0]["available_seats"] == 50


def test_get_event_returns_404_when_missing(settings, monkeypatch):
    repo = AsyncMock()
    repo.get.return_value = None

    client = _make_client(settings, monkeypatch, events_repo=repo)
    response = client.get(f"/events/{uuid4()}")

    assert response.status_code == 404


def test_get_event_returns_event(settings, event, monkeypatch):
    repo = AsyncMock()
    repo.get.return_value = event

    client = _make_client(settings, monkeypatch, events_repo=repo)
    response = client.get(f"/events/{event.id}")

    assert response.status_code == 200
    assert response.json()["id"] == str(event.id)


# ── Reservations ─────────────────────────────────────────────────────────────


def test_create_reservation_success(settings, event, reservation, monkeypatch):
    service = AsyncMock()
    service.create.return_value = reservation

    client = _make_client(settings, monkeypatch, reservation_service=service)
    response = client.post(
        f"/events/{event.id}/reservations",
        json={"customer_email": "alice@example.com", "seat_count": 2},
    )

    assert response.status_code == 201
    assert response.json()["id"] == str(reservation.id)
    service.create.assert_awaited_once()


def test_create_reservation_event_not_found(settings, event, monkeypatch):
    service = AsyncMock()
    service.create.side_effect = EventNotFound(f"Event {event.id} not found")

    client = _make_client(settings, monkeypatch, reservation_service=service)
    response = client.post(
        f"/events/{event.id}/reservations",
        json={"customer_email": "alice@example.com", "seat_count": 2},
    )

    assert response.status_code == 404
    assert response.json()["error_code"] == "event_not_found"


def test_create_reservation_insufficient_seats(settings, event, monkeypatch):
    service = AsyncMock()
    service.create.side_effect = InsufficientSeats("Not enough seats")

    client = _make_client(settings, monkeypatch, reservation_service=service)
    response = client.post(
        f"/events/{event.id}/reservations",
        json={"customer_email": "alice@example.com", "seat_count": 5},
    )

    assert response.status_code == 409
    assert response.json()["error_code"] == "insufficient_seats"


def test_create_reservation_validates_seat_count(settings, event, monkeypatch):
    """seat_count > 10 is rejected by the schema before reaching the service."""
    service = AsyncMock()

    client = _make_client(settings, monkeypatch, reservation_service=service)
    response = client.post(
        f"/events/{event.id}/reservations",
        json={"customer_email": "alice@example.com", "seat_count": 99},
    )

    assert response.status_code == 422
    service.create.assert_not_awaited()


def test_create_reservation_rejects_unknown_fields(settings, event, monkeypatch):
    """extra='forbid' rejects requests with unknown fields."""
    service = AsyncMock()

    client = _make_client(settings, monkeypatch, reservation_service=service)
    response = client.post(
        f"/events/{event.id}/reservations",
        json={
            "customer_email": "alice@example.com",
            "seat_count": 2,
            "discount_code": "FREEBIE",  # this should not be accepted
        },
    )

    assert response.status_code == 422


# ── Bookings ─────────────────────────────────────────────────────────────────


def test_confirm_reservation_success(
    settings, reservation, booking, monkeypatch
):
    service = AsyncMock()
    service.confirm.return_value = booking

    client = _make_client(settings, monkeypatch, booking_service=service)
    response = client.post(
        f"/reservations/{reservation.id}/confirm",
        json={"card_last_four": "1234"},
    )

    assert response.status_code == 201
    assert response.json()["id"] == str(booking.id)


def test_confirm_reservation_validates_card_format(
    settings, reservation, monkeypatch
):
    """Card number that's not 4 digits is rejected by the schema."""
    service = AsyncMock()

    client = _make_client(settings, monkeypatch, booking_service=service)
    response = client.post(
        f"/reservations/{reservation.id}/confirm",
        json={"card_last_four": "12"},
    )

    assert response.status_code == 422
    service.confirm.assert_not_awaited()