"""Handler for the seat-decrement subscription.

Logically this work has already happened — the API decremented seats
synchronously when creating the reservation. This handler exists for
two reasons:

1. As a place to add side effects (notifications, analytics) that don't
   need to block the API response.
2. As an audit trail point — the handler logs the seat-decrement event
   for consistency checks across services.

In Phase 1 the handler is intentionally minimal — just structured logging.
In a fuller system this would publish to a downstream notification service.
"""

from __future__ import annotations

from typing import Any

import structlog

from ticketing_worker.handlers.base import MessageHandler

logger = structlog.get_logger(__name__)


class SeatDecrementHandler(MessageHandler):
    async def handle(self, payload: dict[str, Any]) -> None:
        logger.info(
            "seat_decrement_processed",
            reservation_id=payload.get("reservation_id"),
            event_id=payload.get("event_id"),
            seat_count=payload.get("seat_count"),
        )