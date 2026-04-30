"""SQLAlchemy ORM models. Stay inside the repositories layer.

These are the actual mapped types tied to database tables. Repositories
convert these to domain models at their public API boundary, so services
never see ORM types.
"""

from __future__ import annotations

from datetime import datetime
from uuid import UUID

from sqlalchemy import CheckConstraint, ForeignKey, Index
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column


class Base(DeclarativeBase):
    """Base for all ORM models."""


class EventORM(Base):
    __tablename__ = "events"

    id: Mapped[UUID] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column()
    venue: Mapped[str] = mapped_column()
    starts_at: Mapped[datetime] = mapped_column()
    total_seats: Mapped[int] = mapped_column()
    available_seats: Mapped[int] = mapped_column()
    price_pence: Mapped[int] = mapped_column()
    created_at: Mapped[datetime] = mapped_column()
    updated_at: Mapped[datetime] = mapped_column()


class ReservationORM(Base):
    __tablename__ = "reservations"

    id: Mapped[UUID] = mapped_column(primary_key=True)
    event_id: Mapped[UUID] = mapped_column(ForeignKey("events.id"))
    customer_email: Mapped[str] = mapped_column()
    seat_count: Mapped[int] = mapped_column()
    status: Mapped[str] = mapped_column()
    expires_at: Mapped[datetime] = mapped_column()
    created_at: Mapped[datetime] = mapped_column()

    __table_args__ = (
        CheckConstraint(
            "status IN ('PENDING', 'CONFIRMED', 'EXPIRED')",
            name="ck_reservations_status",
        ),
        Index(
            "ix_reservations_pending_expires",
            "expires_at",
            postgresql_where="status = 'PENDING'",
        ),
    )


class BookingORM(Base):
    __tablename__ = "bookings"

    id: Mapped[UUID] = mapped_column(primary_key=True)
    reservation_id: Mapped[UUID] = mapped_column(
        ForeignKey("reservations.id"),
        unique=True,
    )
    payment_reference: Mapped[str] = mapped_column()
    confirmed_at: Mapped[datetime] = mapped_column()


class ProcessedMessageORM(Base):
    """Idempotency table — workers record processed message IDs.

    Lives here because the API doesn't read it directly, but Alembic needs
    one Base with all tables to autogenerate migrations.
    """

    __tablename__ = "processed_messages"

    message_id: Mapped[str] = mapped_column(primary_key=True)
    processed_at: Mapped[datetime] = mapped_column()