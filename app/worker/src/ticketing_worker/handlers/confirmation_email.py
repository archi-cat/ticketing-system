"""Handler for the confirmation-email subscription.

In a real system this would call an email service (SendGrid, Azure
Communication Services, etc.). For Phase 1 we just log the intent — the
plumbing of an email integration is orthogonal to the architecture work
this project is teaching.
"""

from __future__ import annotations

from typing import Any

import structlog

from ticketing_worker.handlers.base import MessageHandler

logger = structlog.get_logger(__name__)


class ConfirmationEmailHandler(MessageHandler):
    async def handle(self, payload: dict[str, Any]) -> None:
        logger.info(
            "confirmation_email_sent",
            booking_id=payload.get("booking_id"),
            reservation_id=payload.get("reservation_id"),
            payment_reference=payload.get("payment_reference"),
        )