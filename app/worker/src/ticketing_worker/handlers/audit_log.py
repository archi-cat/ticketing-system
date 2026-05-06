"""Handler for the audit-log subscription.

Logs every reservation/booking event for traceability. In a real system
this would write to an immutable audit store (cold storage, append-only
log). For Phase 1 we use structured logging — Log Analytics retains the
events.
"""

from __future__ import annotations

from typing import Any

import structlog

from ticketing_worker.handlers.base import MessageHandler

logger = structlog.get_logger(__name__)


class AuditLogHandler(MessageHandler):
    async def handle(self, payload: dict[str, Any]) -> None:
        logger.info("audit_event", **payload)