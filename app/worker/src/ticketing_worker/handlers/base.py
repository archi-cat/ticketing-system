"""Base class for message handlers.

Each handler:
    - Gets the parsed message body
    - Performs its specific business logic
    - Either succeeds (message will be completed) or raises (message will
      be abandoned and retried, or dead-lettered after max delivery count)

The handler doesn't manage idempotency or message lifecycle — the consumer
runtime handles those concerns. Handlers focus on business logic only.
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from typing import Any

from ticketing_worker.infrastructure.database import Database


class MessageHandler(ABC):
    """Process a single message. Implementations focus on business logic only."""

    def __init__(self, database: Database) -> None:
        self._database = database

    @abstractmethod
    async def handle(self, payload: dict[str, Any]) -> None:
        """Process the message payload.

        Parameters
        ----------
        payload:
            The decoded JSON body of the Service Bus message.

        Raises
        ------
        Exception
            Any exception causes the message to be abandoned. After
            max_delivery_count attempts, Service Bus dead-letters it.
        """
        ...