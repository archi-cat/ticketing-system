"""One-shot command — upload local JSON event files to Blob Storage.

Invoked by the event-upload K8s Job:

    command: ["upload-events"]

Required environment variables (injected by the Job manifest):

    EVENTS_STORAGE_ACCOUNT_URL  — blob service endpoint, e.g.
                                   https://stticketinguks<suffix>.blob.core.windows.net
    EVENTS_CONTAINER_NAME       — container that holds the event files
    EVENTS_SOURCE_DIR           — directory of *.json files to upload. The Job
                                   mounts the repo's data/events/ here via a
                                   ConfigMap. Defaults to /events.

Authentication uses Workload Identity (DefaultAzureCredential) over the storage
account's private endpoint — no keys or connection strings. This is the
in-cluster replacement for the manual `az storage blob upload` step, so the
storage account's public endpoint can be closed (see ADR-0032).

Every *.json file in EVENTS_SOURCE_DIR is uploaded with its filename as the
blob name, overwriting any existing blob of the same name. The db-load-events
Job then reads those blobs; that load is idempotent on the event `id`, so
re-uploading and re-loading the same file is safe.
"""

from __future__ import annotations

import asyncio
import logging
import os
import sys
from pathlib import Path

logger = logging.getLogger(__name__)


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        stream=sys.stdout,
    )
    try:
        storage_url = _require_env("EVENTS_STORAGE_ACCOUNT_URL")
        container_name = _require_env("EVENTS_CONTAINER_NAME")
        source_dir = Path(os.environ.get("EVENTS_SOURCE_DIR", "/events"))

        # Read the files up front (synchronous filesystem I/O stays out of the
        # async upload path). Each entry is (blob name, bytes).
        files = sorted(source_dir.glob("*.json"))
        if not files:
            raise RuntimeError(f"No *.json files found in {source_dir}")
        payloads = [(path.name, path.read_bytes()) for path in files]

        logger.info("Uploading %d file(s) to %s / %s", len(payloads), storage_url, container_name)
        asyncio.run(_upload(storage_url, container_name, payloads))
        logger.info("Done — uploaded %d file(s).", len(payloads))
    except Exception as exc:
        logger.error("upload-events failed: %s", exc)
        sys.exit(1)


async def _upload(account_url: str, container_name: str, payloads: list[tuple[str, bytes]]) -> None:
    from azure.identity.aio import DefaultAzureCredential
    from azure.storage.blob.aio import ContainerClient

    async with DefaultAzureCredential() as credential:
        async with ContainerClient(
            account_url=account_url,
            container_name=container_name,
            credential=credential,
        ) as container_client:
            for name, data in payloads:
                blob_client = container_client.get_blob_client(name)
                await blob_client.upload_blob(data, overwrite=True)
                logger.info("Uploaded %s (%d bytes)", name, len(data))


def _require_env(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise RuntimeError(f"Required environment variable {name!r} is not set")
    return value
