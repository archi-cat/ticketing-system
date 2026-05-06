"""HTTP request and response schemas.

These are deliberately separate from the domain models. Domain models
describe the system's internal vocabulary; schemas describe its HTTP
contract. The translation happens in the route handlers.
"""

from __future__ import annotations

from datetime import datetime
from uuid import UUID

from pydantic import BaseModel, ConfigDict, EmailStr, Field

from ticketing_api.domain.models import (
    Booking,
    Event,
    Reservation,
    ReservationStatus,
)


# ── Event schemas ────────────────────────────────────────────────────────────


class EventResponse(BaseModel):
    """Public representation of an event."""

    id: UUID
    name: str
    venue: str
    starts_at: datetime
    total_seats: int
    available_seats: int
    price_pence: int

    @classmethod
    def from_domain(cls, event: Event) -> "EventResponse":
        return cls(
            id=event.id,
            name=event.name,
            venue=event.venue,
            starts_at=event.starts_at,
            total_seats=event.total_seats,
            available_seats=event.available_seats,
            price_pence=event.price_pence,
        )


class EventListResponse(BaseModel):
    items: list[EventResponse]


# ── Reservation schemas ──────────────────────────────────────────────────────


class CreateReservationRequest(BaseModel):
    """Request body for creating a reservation."""

    model_config = ConfigDict(extra="forbid")

    customer_email: EmailStr
    seat_count: int = Field(ge=1, le=10)


class ReservationResponse(BaseModel):
    id: UUID
    event_id: UUID
    customer_email: EmailStr
    seat_count: int
    status: ReservationStatus
    expires_at: datetime
    created_at: datetime

    @classmethod
    def from_domain(cls, reservation: Reservation) -> "ReservationResponse":
        return cls(
            id=reservation.id,
            event_id=reservation.event_id,
            customer_email=reservation.customer_email,
            seat_count=reservation.seat_count,
            status=reservation.status,
            expires_at=reservation.expires_at,
            created_at=reservation.created_at,
        )


# ── Booking schemas ──────────────────────────────────────────────────────────


class ConfirmReservationRequest(BaseModel):
    """Request body for confirming a reservation (mock payment)."""

    model_config = ConfigDict(extra="forbid")

    # In real life this would be a payment token from the payment provider.
    # For this learning project we just take the last 4 digits — never
    # accept full card numbers in any system you actually deploy.
    card_last_four: str = Field(pattern=r"^\d{4}$", description="Last 4 digits")


class BookingResponse(BaseModel):
    id: UUID
    reservation_id: UUID
    payment_reference: str
    confirmed_at: datetime

    @classmethod
    def from_domain(cls, booking: Booking) -> "BookingResponse":
        return cls(
            id=booking.id,
            reservation_id=booking.reservation_id,
            payment_reference=booking.payment_reference,
            confirmed_at=booking.confirmed_at,
        )


# ── Error response schema ────────────────────────────────────────────────────


class ErrorResponse(BaseModel):
    """Standardised error body returned by the API."""

    error_code: str = Field(description="Machine-readable error identifier")
    message: str = Field(description="Human-readable message")