"""Idempotency tracking via the processed_messages table.

A worker that crashes mid-processing may receive the same message again.
The pattern: try to record the message ID; if it's already there, skip
processing entirely.

We use INSERT ... ON CONFLICT DO NOTHING and check the rowcount, which is
race-free at the database level — two parallel attempts to record the
same ID result in exactly one insert.
"""

from __future__ import annotations

import structlog
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

logger = structlog.get_logger(__name__)


async def record_message_processed(session: AsyncSession, message_id: str) -> bool:
    """Record that a message has been processed.

    Returns
    -------
    bool
        True if the row was inserted (first time we've seen this message),
        False if a row already existed (this is a redelivery).
    """
    stmt = text(
        "INSERT INTO processed_messages (message_id, processed_at) "
        "VALUES (:message_id, NOW()) "
        "ON CONFLICT (message_id) DO NOTHING"
    )
    result = await session.execute(stmt, {"message_id": message_id})
    inserted = result.rowcount > 0
    if not inserted:
        logger.info("message_already_processed", message_id=message_id)
    return inserted