"""Unit tests for the Consumer message processing loop.

Mocks Service Bus and the database. Verifies idempotency and error handling.
"""

from __future__ import annotations

import json
from contextlib import asynccontextmanager
from unittest.mock import AsyncMock, MagicMock

import pytest

from ticketing_worker.handlers.base import MessageHandler
from ticketing_worker.runtime.consumer import Consumer


class FakeHandler(MessageHandler):
    """Records the payloads it sees, optionally raising."""

    def __init__(self, *, raises: Exception | None = None) -> None:
        super().__init__(database=None)  # type: ignore[arg-type]
        self.calls: list[dict] = []
        self._raises = raises

    async def handle(self, payload: dict) -> None:
        self.calls.append(payload)
        if self._raises is not None:
            raise self._raises


def _make_message(message_id: str, payload: dict) -> MagicMock:
    msg = MagicMock()
    msg.message_id = message_id
    msg.delivery_count = 1
    msg.body = [json.dumps(payload).encode("utf-8")]
    return msg


def _make_database_with_idempotency(*, already_processed: bool = False) -> MagicMock:
    """Build a mocked Database whose session() context manager records via patched
    record_message_processed.
    """
    session = AsyncMock()

    @asynccontextmanager
    async def _cm():
        yield session

    db = MagicMock()
    db.session = _cm
    return db, session


@pytest.mark.asyncio
async def test_handler_called_for_new_message(monkeypatch):
    """A message not in processed_messages dispatches to the handler."""
    handler = FakeHandler()
    database, _session = _make_database_with_idempotency()

    receiver = AsyncMock()

    # Patch idempotency to claim "first time seeing this message"
    monkeypatch.setattr(
        "ticketing_worker.runtime.consumer.record_message_processed",
        AsyncMock(return_value=True),
    )

    consumer = Consumer(
        client=MagicMock(),
        topic_name="t",
        subscription_name="s",
        handler=handler,
        database=database,
        max_concurrent_messages=1,
        message_lock_seconds=60,
    )

    payload = {"reservation_id": "abc", "seat_count": 2}
    msg = _make_message("msg-1", payload)

    await consumer._process_message(receiver, msg)

    assert handler.calls == [payload]
    receiver.complete_message.assert_awaited_once_with(msg)


@pytest.mark.asyncio
async def test_handler_skipped_for_redelivered_message(monkeypatch):
    """A message already in processed_messages skips the handler entirely."""
    handler = FakeHandler()
    database, _session = _make_database_with_idempotency()
    receiver = AsyncMock()

    # Idempotency claims the message was already processed
    monkeypatch.setattr(
        "ticketing_worker.runtime.consumer.record_message_processed",
        AsyncMock(return_value=False),
    )

    consumer = Consumer(
        client=MagicMock(),
        topic_name="t",
        subscription_name="s",
        handler=handler,
        database=database,
        max_concurrent_messages=1,
        message_lock_seconds=60,
    )

    msg = _make_message("msg-2", {"reservation_id": "abc"})
    await consumer._process_message(receiver, msg)

    assert handler.calls == []
    receiver.complete_message.assert_awaited_once_with(msg)


@pytest.mark.asyncio
async def test_handler_failure_abandons_message(monkeypatch):
    """If the handler raises, the message is abandoned."""
    handler = FakeHandler(raises=RuntimeError("simulated"))
    database, _session = _make_database_with_idempotency()
    receiver = AsyncMock()

    monkeypatch.setattr(
        "ticketing_worker.runtime.consumer.record_message_processed",
        AsyncMock(return_value=True),
    )

    consumer = Consumer(
        client=MagicMock(),
        topic_name="t",
        subscription_name="s",
        handler=handler,
        database=database,
        max_concurrent_messages=1,
        message_lock_seconds=60,
    )

    msg = _make_message("msg-3", {"reservation_id": "abc"})
    await consumer._process_message(receiver, msg)

    assert len(handler.calls) == 1  # called once, then raised
    receiver.complete_message.assert_not_awaited()
    receiver.abandon_message.assert_awaited_once_with(msg)