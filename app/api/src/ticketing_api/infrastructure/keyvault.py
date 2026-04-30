"""Async Key Vault client for fetching secrets at application startup.

In production, the API uses Workload Identity to obtain a short-lived Azure AD
token, which the Key Vault SDK uses transparently. Locally, the client is
disabled — there's no Key Vault to talk to and no need for one.
"""

from __future__ import annotations

import structlog
from azure.identity.aio import DefaultAzureCredential
from azure.keyvault.secrets.aio import SecretClient

from ticketing_api.settings import Settings

logger = structlog.get_logger(__name__)


class KeyVaultClient:
    """Async wrapper around azure-keyvault-secrets.

    Owns the credential and SDK client lifecycle. Use ``startup()`` and
    ``shutdown()`` to manage them — these integrate with FastAPI's lifespan.
    """

    def __init__(self, settings: Settings) -> None:
        self._settings = settings
        self._credential: DefaultAzureCredential | None = None
        self._client: SecretClient | None = None

    @property
    def is_enabled(self) -> bool:
        """True when a Key Vault URI is configured."""
        return self._settings.keyvault_uri is not None

    async def startup(self) -> None:
        """Initialise the credential and SecretClient."""
        if not self.is_enabled:
            logger.info("keyvault_disabled", reason="no_keyvault_uri_set")
            return

        self._credential = DefaultAzureCredential()
        self._client = SecretClient(
            vault_url=self._settings.keyvault_uri,  # type: ignore[arg-type]
            credential=self._credential,
        )
        logger.info("keyvault_started", uri=self._settings.keyvault_uri)

    async def shutdown(self) -> None:
        """Close the SDK client and credential."""
        if self._client is not None:
            await self._client.close()
            self._client = None
        if self._credential is not None:
            await self._credential.close()
            self._credential = None
        logger.info("keyvault_stopped")

    async def get_secret(self, name: str) -> str:
        """Return the current value of a secret.

        Raises
        ------
        RuntimeError
            If Key Vault is disabled (no URI configured).
        """
        if self._client is None:
            raise RuntimeError(
                "Key Vault is not configured. Set KEYVAULT_URI to enable."
            )

        secret = await self._client.get_secret(name)
        if secret.value is None:
            raise RuntimeError(f"Secret {name!r} has no value")
        return secret.value