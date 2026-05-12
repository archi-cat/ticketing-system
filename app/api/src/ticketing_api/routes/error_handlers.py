"""Convert service-layer exceptions to HTTP responses.

Each domain exception maps to a specific HTTP status code and error code.
The error code is a stable machine-readable string clients can match on,
distinct from the human-readable message.
"""

from __future__ import annotations

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

from ticketing_api.routes.schemas import ErrorResponse
from ticketing_api.services.exceptions import (
    ConcurrentReservationConflictError,
    EventNotFoundError,
    InsufficientSeatsError,
    ReservationExpiredError,
    ReservationNotFoundError,
    ReservationNotPendingError,
    TicketingError,
    TooManySeatsRequestedError,
)

# ── Mapping table ────────────────────────────────────────────────────────────
# exception_class → (http_status, error_code)

_EXCEPTION_MAP: dict[type[TicketingError], tuple[int, str]] = {
    EventNotFoundError: (404, "event_not_found"),
    ReservationNotFoundError: (404, "reservation_not_found"),
    InsufficientSeatsError: (409, "insufficient_seats"),
    ConcurrentReservationConflictError: (409, "concurrent_reservation_conflict"),
    ReservationNotPendingError: (409, "reservation_not_pending"),
    ReservationExpiredError: (410, "reservation_expired"),
    TooManySeatsRequestedError: (422, "too_many_seats_requested"),
}


def _handler(exc_class: type[TicketingError]) -> callable:
    status, error_code = _EXCEPTION_MAP[exc_class]

    async def handle(_request: Request, exc: TicketingError) -> JSONResponse:
        return JSONResponse(
            status_code=status,
            content=ErrorResponse(
                error_code=error_code,
                message=str(exc),
            ).model_dump(),
        )

    return handle


def register_exception_handlers(app: FastAPI) -> None:
    """Wire all service exceptions into FastAPI's exception handler system."""
    for exc_class in _EXCEPTION_MAP:
        app.add_exception_handler(exc_class, _handler(exc_class))
