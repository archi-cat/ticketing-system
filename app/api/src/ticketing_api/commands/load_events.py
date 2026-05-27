"""One-shot command — download a JSON blob and bulk-insert events.

Invoked by the db-load-events K8s Job:

    command: ["load-events"]

Required environment variables (injected by the Job manifest):

    EVENTS_STORAGE_ACCOUNT_URL  — blob service endpoint, e.g.
                                   https://stticketinguks<suffix>.blob.core.windows.net
    EVENTS_CONTAINER_NAME       — container that holds the event files
    EVENTS_BLOB_NAME            — blob filename, e.g. sample-events.json

All Postgres connection settings (POSTGRES_HOST, POSTGRES_DATABASE, etc.)
come from the standard ConfigMaps and are read via the existing Settings class.
Authentication to both Postgres and Storage uses Workload Identity
(DefaultAzureCredential) — no passwords or connection strings needed.

JSON format (array of objects):

    [
      {
        "id":          "<uuid>",
        "name":        "Event name",
        "venue":       "Venue name",
        "starts_at":   "2026-06-10T19:30:00+00:00",
        "total_seats": 120,
        "price_pence": 3500
      }
    ]

The id field is required and is used as the idempotency key — running the
command twice with the same file inserts nothing on the second run.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import sys

from ticketing_api.domain.models import EventCreate
from ticketing_api.infrastructure.database import Database
from ticketing_api.repositories.events import EventsRepository
from ticketing_api.settings import get_settings

logger = logging.getLogger(__name__)


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        stream=sys.stdout,
    )
    try:
        asyncio.run(_run())
    except Exception as exc:
        logger.error("load-events failed: %s", exc)
        sys.exit(1)


async def _run() -> None:
    storage_url = _require_env("EVENTS_STORAGE_ACCOUNT_URL")
    container_name = _require_env("EVENTS_CONTAINER_NAME")
    blob_name = _require_env("EVENTS_BLOB_NAME")

    logger.info("Downloading blob: %s / %s / %s", storage_url, container_name, blob_name)
    content = await _download_blob(storage_url, container_name, blob_name)

    raw: list[object] = json.loads(content)
    if not isinstance(raw, list):
        raise ValueError("JSON blob must be a top-level array")

    events = [EventCreate.model_validate(item) for item in raw]
    logger.info("Parsed %d event(s) from blob", len(events))

    settings = get_settings()
    db = Database(settings)
    await db.startup()
    try:
        async with db.session() as session:
            repo = EventsRepository(session)
            inserted = await repo.create(events)
        logger.info(
            "Done — inserted %d event(s), skipped %d duplicate(s)",
            inserted,
            len(events) - inserted,
        )
    finally:
        await db.shutdown()


async def _download_blob(account_url: str, container_name: str, blob_name: str) -> bytes:
    from azure.identity.aio import DefaultAzureCredential
    from azure.storage.blob.aio import BlobClient

    async with DefaultAzureCredential() as credential:
        async with BlobClient(
            account_url=account_url,
            container_name=container_name,
            blob_name=blob_name,
            credential=credential,
        ) as blob_client:
            stream = await blob_client.download_blob()
            return await stream.readall()  # type: ignore[no-any-return]


def _require_env(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise RuntimeError(f"Required environment variable {name!r} is not set")
    return value
