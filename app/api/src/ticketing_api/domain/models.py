"""Domain models — pure Pydantic, no database awareness.

These are the types that flow through services and routes. ORM models
(SQLAlchemy) live in the repositories layer and never leak out.
"""

from __future__ import annotations

from datetime import UTC, datetime
from enum import StrEnum
from uuid import UUID

from pydantic import BaseModel, ConfigDict, EmailStr, Field, field_validator


class ReservationStatus(StrEnum):
    PENDING = "PENDING"
    CONFIRMED = "CONFIRMED"
    EXPIRED = "EXPIRED"


# ── Event ────────────────────────────────────────────────────────────────────


class Event(BaseModel):
    """An event customers can buy tickets for."""

    model_config = ConfigDict(frozen=True)

    id: UUID
    name: str
    venue: str
    starts_at: datetime
    total_seats: int = Field(ge=1)
    available_seats: int = Field(ge=0)
    price_pence: int = Field(ge=0)
    created_at: datetime
    updated_at: datetime

    @field_validator("starts_at", "created_at", "updated_at")
    @classmethod
    def _ensure_tz_aware(cls, v: datetime) -> datetime:
        if v.tzinfo is None:
            raise ValueError("timestamp must be timezone-aware")
        return v


# ── Reservation ──────────────────────────────────────────────────────────────


class Reservation(BaseModel):
    """A temporary hold on N seats for a customer."""

    model_config = ConfigDict(frozen=True)

    id: UUID
    event_id: UUID
    customer_email: EmailStr
    seat_count: int = Field(ge=1)
    status: ReservationStatus
    expires_at: datetime
    created_at: datetime

    @property
    def is_expired(self) -> bool:
        return (
            self.status == ReservationStatus.PENDING
            and datetime.now(UTC) >= self.expires_at
        )


# ── Booking ──────────────────────────────────────────────────────────────────


class Booking(BaseModel):
    """A confirmed purchase — created when payment succeeds on a reservation."""

    model_config = ConfigDict(frozen=True)

    id: UUID
    reservation_id: UUID
    payment_reference: str
    confirmed_at: datetime