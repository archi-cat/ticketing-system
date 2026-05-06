"""initial schema

Revision ID: 20260427_1200
Revises:
Create Date: 2026-04-27 12:00:00.000000
"""

from __future__ import annotations

from typing import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

# revision identifiers, used by Alembic
revision: str = "20260427_1200"
down_revision: str | None = None
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    # ── events ────────────────────────────────────────────────────────────────
    op.create_table(
        "events",
        sa.Column(
            "id",
            postgresql.UUID(as_uuid=True),
            primary_key=True,
            server_default=sa.text("gen_random_uuid()"),
        ),
        sa.Column("name", sa.String(length=200), nullable=False),
        sa.Column("venue", sa.String(length=200), nullable=False),
        sa.Column("starts_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("total_seats", sa.Integer(), nullable=False),
        sa.Column("available_seats", sa.Integer(), nullable=False),
        sa.Column("price_pence", sa.Integer(), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.text("NOW()"),
        ),
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.text("NOW()"),
        ),
        sa.CheckConstraint("total_seats >= 1", name="ck_events_total_seats_positive"),
        sa.CheckConstraint(
            "available_seats >= 0 AND available_seats <= total_seats",
            name="ck_events_available_seats_in_range",
        ),
        sa.CheckConstraint("price_pence >= 0", name="ck_events_price_non_negative"),
    )

    # ── reservations ──────────────────────────────────────────────────────────
    op.create_table(
        "reservations",
        sa.Column(
            "id",
            postgresql.UUID(as_uuid=True),
            primary_key=True,
            server_default=sa.text("gen_random_uuid()"),
        ),
        sa.Column(
            "event_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("events.id"),
            nullable=False,
        ),
        sa.Column("customer_email", sa.String(length=254), nullable=False),
        sa.Column("seat_count", sa.Integer(), nullable=False),
        sa.Column("status", sa.String(length=20), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.text("NOW()"),
        ),
        sa.CheckConstraint(
            "status IN ('PENDING', 'CONFIRMED', 'EXPIRED')",
            name="ck_reservations_status",
        ),
        sa.CheckConstraint("seat_count >= 1", name="ck_reservations_seats_positive"),
    )

    # Partial index — only PENDING reservations need fast lookup by expiry.
    # The scheduler queries this every 60 seconds.
    op.create_index(
        "ix_reservations_pending_expires",
        "reservations",
        ["expires_at"],
        postgresql_where=sa.text("status = 'PENDING'"),
    )

    # Index supporting "find a customer's reservations" — useful for future
    # admin features and customer-facing reservation history.
    op.create_index(
        "ix_reservations_customer_email_created",
        "reservations",
        ["customer_email", "created_at"],
    )

    # ── bookings ──────────────────────────────────────────────────────────────
    op.create_table(
        "bookings",
        sa.Column(
            "id",
            postgresql.UUID(as_uuid=True),
            primary_key=True,
            server_default=sa.text("gen_random_uuid()"),
        ),
        sa.Column(
            "reservation_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("reservations.id"),
            nullable=False,
            unique=True,
        ),
        sa.Column("payment_reference", sa.String(length=100), nullable=False),
        sa.Column(
            "confirmed_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.text("NOW()"),
        ),
    )

    # ── processed_messages (idempotency) ──────────────────────────────────────
    # Workers record processed Service Bus message IDs here. A second delivery
    # of the same message hits a primary key conflict and is silently ignored.
    op.create_table(
        "processed_messages",
        sa.Column("message_id", sa.String(length=100), primary_key=True),
        sa.Column(
            "processed_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.text("NOW()"),
        ),
    )


def downgrade() -> None:
    op.drop_table("processed_messages")
    op.drop_table("bookings")
    op.drop_index("ix_reservations_customer_email_created", table_name="reservations")
    op.drop_index("ix_reservations_pending_expires", table_name="reservations")
    op.drop_table("reservations")
    op.drop_table("events")