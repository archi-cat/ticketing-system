"""HTTP routes for reservations."""

from __future__ import annotations

from uuid import UUID

from fastapi import APIRouter, HTTPException, Request

from ticketing_api.repositories.reservations import ReservationsRepository
from ticketing_api.routes.schemas import (
    CreateReservationRequest,
    ReservationResponse,
)

router = APIRouter(tags=["reservations"])


@router.post(
    "/events/{event_id}/reservations",
    response_model=ReservationResponse,
    status_code=201,
)
async def create_reservation(
    event_id: UUID,
    body: CreateReservationRequest,
    request: Request,
) -> ReservationResponse:
    """Create a new reservation for an event.

    The reservation has a 15-minute TTL — confirm it via
    POST /reservations/{id}/confirm before it expires.
    """
    service = request.app.state.reservation_service

    reservation = await service.create(
        event_id=event_id,
        customer_email=body.customer_email,
        seat_count=body.seat_count,
    )

    return ReservationResponse.from_domain(reservation)


@router.get("/reservations/{reservation_id}", response_model=ReservationResponse)
async def get_reservation(
    reservation_id: UUID,
    request: Request,
) -> ReservationResponse:
    """Look up a reservation by ID."""
    database = request.app.state.database

    async with database.session() as session:
        repo = ReservationsRepository(session)
        reservation = await repo.get(reservation_id)

    if reservation is None:
        raise HTTPException(status_code=404, detail="reservation_not_found")

    return ReservationResponse.from_domain(reservation)