"""Redis-based distributed lock.

We use a simple single-key approach: ``SET key token NX EX ttl``. The token
is a random value the holder uses to verify ownership when releasing. This
prevents a slow holder from accidentally releasing a lock acquired by a
different request after their TTL expired.

For production scale this would move to Redlock or a similar consensus
protocol, but for this project's single-Redis-instance Phase 1 the simple
approach is correct.
"""

from __future__ import annotations

from contextlib import asynccontextmanager
from collections.abc import AsyncIterator
from secrets import token_hex

import structlog
from redis.asyncio import Redis

logger = structlog.get_logger(__name__)


# Lua script — atomic compare-and-delete.
# Used to release the lock only if we still own it (token matches).
_RELEASE_SCRIPT = """
if redis.call("GET", KEYS[1]) == ARGV[1] then
    return redis.call("DEL", KEYS[1])
else
    return 0
end
"""


class LockNotAcquired(Exception):
    """Raised when a lock cannot be acquired within the timeout."""


class DistributedLock:
    def __init__(self, redis: Redis) -> None:
        self._redis = redis

    @asynccontextmanager
    async def acquire(
        self,
        key: str,
        ttl_seconds: int = 5,
    ) -> AsyncIterator[None]:
        """Acquire a lock, run the protected block, release the lock.

        Raises
        ------
        LockNotAcquired
            If the lock is already held by another caller.
        """
        token = token_hex(16)
        acquired = await self._redis.set(
            name=key,
            value=token,
            nx=True,
            ex=ttl_seconds,
        )
        if not acquired:
            raise LockNotAcquired(f"Could not acquire lock {key!r}")

        logger.debug("lock_acquired", key=key, ttl_seconds=ttl_seconds)
        try:
            yield
        finally:
            # Compare-and-delete via Lua so we only release our own lock.
            # If the TTL expired and someone else now holds the key, we leave
            # theirs alone.
            released = await self._redis.eval(_RELEASE_SCRIPT, 1, key, token)
            if released:
                logger.debug("lock_released", key=key)
            else:
                logger.warning(
                    "lock_release_failed",
                    key=key,
                    reason="already_expired_or_taken",
                )