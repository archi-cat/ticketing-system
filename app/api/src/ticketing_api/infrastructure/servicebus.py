"""Async Service Bus client for publishing reservation and booking events.

Auth model:
    - Local development: client is disabled (no namespace configured).
      Tests use a mock; real local development without Service Bus is fine.
    - Azure: passwordless via Workload Identity using DefaultAzureCredential.

The client is publish-only — the worker service (separate deployment)
consumes messages. Keeping publish/consume in different processes is the
event-driven pattern the project uses.
"""

from __future__ import annotations

import json
from typing import Any
from uuid import uuid4

import structlog
from azure.identity.aio import DefaultAzureCredential
from azure.servicebus import ServiceBusMessage
from azure.servicebus.aio import ServiceBusClient, ServiceBusSender

from ticketing_api.settings import Settings

logger = structlog.get_logger(__name__)


class ServiceBusPublisher:
    """Async wrapper around the Service Bus SDK for publishing events.

    Maintains one sender per topic. Senders are reused across the application
    lifetime — creating them per-publish is expensive.
    """

    def __init__(self, settings: Settings) -> None:
        self._settings = settings
        self._credential: DefaultAzureCredential | None = None
        self._client: ServiceBusClient | None = None
        self._senders: dict[str, ServiceBusSender] = {}

    @property
    def is_enabled(self) -> bool:
        return self._settings.servicebus_fully_qualified_namespace is not None

    async def startup(self) -> None:
        if not self.is_enabled:
            logger.info("servicebus_disabled", reason="no_fqdn_set")
            return

        self._credential = DefaultAzureCredential()
        self._client = ServiceBusClient(
            fully_qualified_namespace=(
                self._settings.servicebus_fully_qualified_namespace  # type: ignore[arg-type]
            ),
            credential=self._credential,
        )

        # Pre-create senders for the topics we'll publish to
        for topic in (
            self._settings.servicebus_reservation_topic,
            self._settings.servicebus_booking_topic,
        ):
            self._senders[topic] = self._client.get_topic_sender(topic_name=topic)

        logger.info(
            "servicebus_started",
            namespace=self._settings.servicebus_fully_qualified_namespace,
            topics=list(self._senders.keys()),
        )

    async def shutdown(self) -> None:
        for sender in self._senders.values():
            await sender.close()
        self._senders.clear()

        if self._client is not None:
            await self._client.close()
            self._client = None
        if self._credential is not None:
            await self._credential.close()
            self._credential = None

        logger.info("servicebus_stopped")

    async def publish(
        self,
        topic: str,
        event_type: str,
        payload: dict[str, Any],
        correlation_id: str | None = None,
    ) -> None:
        """Publish an event to a topic.

        Adds standard metadata (event type, message id, correlation id) and
        serialises the payload as JSON.

        Parameters
        ----------
        topic:
            Topic name. Must be one of the senders pre-created at startup.
        event_type:
            A string like ``reservation.created`` or ``booking.confirmed``.
            Set as a custom property so subscriptions can filter on it.
        payload:
            JSON-serialisable dictionary.
        correlation_id:
            Optional correlation ID to propagate across services. If omitted,
            a fresh UUID is generated.
        """
        if not self.is_enabled:
            logger.info(
                "servicebus_publish_skipped",
                reason="disabled",
                topic=topic,
                event_type=event_type,
            )
            return

        sender = self._senders.get(topic)
        if sender is None:
            raise RuntimeError(
                f"No sender configured for topic {topic!r}. "
                f"Available: {list(self._senders.keys())}"
            )

        message = ServiceBusMessage(
            body=json.dumps(payload),
            content_type="application/json",
            message_id=str(uuid4()),
            correlation_id=correlation_id or str(uuid4()),
            application_properties={"event_type": event_type},
        )

        await sender.send_messages(message)
        logger.info(
            "servicebus_published",
            topic=topic,
            event_type=event_type,
            message_id=message.message_id,
        )