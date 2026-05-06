"""HTTP routes for events."""

from __future__ import annotations

from uuid import UUID

from fastapi import APIRouter, HTTPException, Request

from ticketing_api.repositories.events import EventsRepository
from ticketing_api.routes.schemas import EventListResponse, EventResponse

router = APIRouter(prefix="/events", tags=["events"])


@router.get("", response_model=EventListResponse)
async def list_upcoming_events(request: Request) -> EventListResponse:
    """Return upcoming events ordered by start time."""
    database = request.app.state.database

    async with database.session() as session:
        repo = EventsRepository(session)
        events = await repo.list_upcoming()

    return EventListResponse(
        items=[EventResponse.from_domain(e) for e in events]
    )


@router.get("/{event_id}", response_model=EventResponse)
async def get_event(event_id: UUID, request: Request) -> EventResponse:
    """Return a single event by ID."""
    database = request.app.state.database

    async with database.session() as session:
        repo = EventsRepository(session)
        event = await repo.get(event_id)

    if event is None:
        raise HTTPException(status_code=404, detail="event_not_found")

    return EventResponse.from_domain(event)