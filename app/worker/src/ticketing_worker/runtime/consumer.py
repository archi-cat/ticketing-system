"""Generic Service Bus subscription consumer.

One Consumer runs per subscription. It owns the Service Bus receiver and
runs an async loop:

    1. Receive a batch of messages
    2. For each message:
        a. Parse the JSON body
        b. Check the idempotency table — skip if already processed
        c. Dispatch to the handler
        d. Record processed and complete the message
    3. On any exception:
        - Abandon the message (Service Bus retries)
        - On max delivery count, Service Bus dead-letters automatically

Concurrency: each Consumer processes its subscription serially within an
instance, but multiple Consumers run concurrently across subscriptions.
For higher throughput, run more pod replicas — Service Bus splits message
delivery across active receivers.
"""

from __future__ import annotations

import asyncio
import json
from typing import Any

import structlog
from azure.servicebus.aio import ServiceBusClient, ServiceBusReceiver
from azure.servicebus.exceptions import (
    MessageAlreadySettled,
    MessageLockLostError,
    ServiceBusError,
)

from ticketing_worker.handlers.base import MessageHandler
from ticketing_worker.infrastructure.database import Database
from ticketing_worker.runtime.idempotency import record_message_processed

logger = structlog.get_logger(__name__)


class Consumer:
    """Consume a single Service Bus subscription with a single handler."""

    def __init__(
        self,
        client: ServiceBusClient,
        topic_name: str,
        subscription_name: str,
        handler: MessageHandler,
        database: Database,
        max_concurrent_messages: int,
        message_lock_seconds: int,
    ) -> None:
        self._client = client
        self._topic = topic_name
        self._subscription = subscription_name
        self._handler = handler
        self._database = database
        self._max_concurrent = max_concurrent_messages
        self._lock_seconds = message_lock_seconds
        self._stop_event = asyncio.Event()

    async def run(self) -> None:
        """Run the consumer loop until stop() is called."""
        logger.info(
            "consumer_starting",
            topic=self._topic,
            subscription=self._subscription,
        )

        # max_wait_time = how long the receiver waits if the queue is empty
        # before returning an empty batch. Tune this against the desired
        # responsiveness to shutdown signals.
        async with self._client.get_subscription_receiver(
            topic_name=self._topic,
            subscription_name=self._subscription,
            max_wait_time=5,
        ) as receiver:
            logger.info(
                "consumer_started",
                topic=self._topic,
                subscription=self._subscription,
            )

            while not self._stop_event.is_set():
                try:
                    messages = await receiver.receive_messages(
                        max_message_count=self._max_concurrent,
                        max_wait_time=5,
                    )
                except ServiceBusError as exc:
                    logger.error(
                        "consumer_receive_error",
                        topic=self._topic,
                        subscription=self._subscription,
                        error=str(exc),
                    )
                    await asyncio.sleep(1)
                    continue

                if not messages:
                    continue

                # Process messages concurrently within the batch
                await asyncio.gather(*[self._process_message(receiver, m) for m in messages])

        logger.info(
            "consumer_stopped",
            topic=self._topic,
            subscription=self._subscription,
        )

    async def stop(self) -> None:
        """Request a graceful shutdown."""
        self._stop_event.set()

    async def _process_message(
        self,
        receiver: ServiceBusReceiver,
        message: Any,  # ServiceBusReceivedMessage — typed as Any to keep imports tight
    ) -> None:
        """Process a single message — idempotency, handler dispatch, lifecycle."""
        message_id = message.message_id or "unknown"

        log = logger.bind(
            topic=self._topic,
            subscription=self._subscription,
            message_id=message_id,
            delivery_count=message.delivery_count,
        )

        try:
            payload_bytes = b"".join(message.body)
            payload = json.loads(payload_bytes.decode("utf-8"))

            async with self._database.session() as session:
                inserted = await record_message_processed(session, message_id)
                if not inserted:
                    # Already processed — complete the message and move on
                    await receiver.complete_message(message)
                    log.info("message_skipped_already_processed")
                    return

                # First time seeing this message — dispatch to the handler.
                # If the handler raises, the transaction rolls back and the
                # idempotency row is undone — next delivery will retry cleanly.
                await self._handler.handle(payload)

            # Handler succeeded and idempotency record is committed
            await receiver.complete_message(message)
            log.info("message_processed")

        except (MessageLockLostError, MessageAlreadySettled) as exc:
            # Lock expired or the message was settled by another receiver.
            # Don't abandon — already gone from our perspective.
            log.warning("message_lock_lost", error=str(exc))

        except Exception as exc:  # noqa: BLE001
            log.error(
                "message_processing_failed",
                error=str(exc),
                exception_type=exc.__class__.__name__,
            )
            try:
                await receiver.abandon_message(message)
                log.info("message_abandoned_for_retry")
            except (MessageLockLostError, MessageAlreadySettled):
                # Lock already lost — Service Bus will redeliver naturally
                pass
