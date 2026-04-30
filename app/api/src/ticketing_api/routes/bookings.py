"""HTTP routes for bookings."""

from __future__ import annotations

from uuid import UUID, uuid4

from fastapi import APIRouter, HTTPException, Request

from ticketing_api.repositories.bookings import BookingsRepository
from ticketing_api.routes.schemas import (
    BookingResponse,
    ConfirmReservationRequest,
)

router = APIRouter(tags=["bookings"])


@router.post(
    "/reservations/{reservation_id}/confirm",
    response_model=BookingResponse,
    status_code=201,
)
async def confirm_reservation(
    reservation_id: UUID,
    body: ConfirmReservationRequest,
    request: Request,
) -> BookingResponse:
    """Confirm a pending reservation by completing (mock) payment.

    Returns the booking that resulted from the confirmation.
    """
    service = request.app.state.booking_service

    # In a real system, this is where we'd call the payment gateway and use
    # its returned reference. Mocked here as a UUID prefixed with the last
    # four digits of the card.
    payment_reference = f"mock-{body.card_last_four}-{uuid4()}"

    booking = await service.confirm(
        reservation_id=reservation_id,
        payment_reference=payment_reference,
    )

    return BookingResponse.from_domain(booking)


@router.get("/bookings/{booking_id}", response_model=BookingResponse)
async def get_booking(
    booking_id: UUID,
    request: Request,
) -> BookingResponse:
    """Look up a booking by ID."""
    database = request.app.state.database

    async with database.session() as session:
        repo = BookingsRepository(session)
        booking = await repo.get(booking_id)

    if booking is None:
        raise HTTPException(status_code=404, detail="booking_not_found")

    return BookingResponse.from_domain(booking)