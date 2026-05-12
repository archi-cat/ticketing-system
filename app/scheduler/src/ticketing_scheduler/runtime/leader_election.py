"""Redis-based leader election.

The pattern:
    - Try to acquire a lease on a single Redis key with SET NX EX
    - If acquired: we're the leader. Periodically renew the lease via
      EXPIRE before it lapses
    - If not acquired: another instance holds the lease. Sleep, retry

Loss of leadership:
    - Process death: lease expires after TTL, another instance takes over
    - Redis disconnect: renewal fails, instance steps down voluntarily
    - Lock theft (impossible here — we use a token): if another instance
      stole the lease, the token-based release fails noisily

The lease holder is identified by a fresh token on each acquisition.
Renewal verifies token ownership atomically via Lua to ensure we never
extend a lease we don't actually hold.
"""

from __future__ import annotations

import asyncio
from collections.abc import AsyncIterator, Callable
from contextlib import asynccontextmanager
from secrets import token_hex

import structlog
from redis.asyncio import Redis
from redis.exceptions import RedisError

logger = structlog.get_logger(__name__)


# Lua: extend the lease ONLY if we still own it (token matches)
_RENEW_SCRIPT = """
if redis.call("GET", KEYS[1]) == ARGV[1] then
    return redis.call("PEXPIRE", KEYS[1], ARGV[2])
else
    return 0
end
"""

# Lua: release ONLY if we still own it
_RELEASE_SCRIPT = """
if redis.call("GET", KEYS[1]) == ARGV[1] then
    return redis.call("DEL", KEYS[1])
else
    return 0
end
"""


class LeaderElection:
    """Manages leadership lifecycle for a single Redis-backed lease."""

    def __init__(
        self,
        redis: Redis[str],
        lock_key: str,
        lease_ttl_seconds: int,
        renew_interval_seconds: int,
    ) -> None:
        if renew_interval_seconds >= lease_ttl_seconds:
            raise ValueError(
                "renew_interval must be less than lease_ttl, "
                f"got renew={renew_interval_seconds} ttl={lease_ttl_seconds}"
            )
        self._redis = redis
        self._lock_key = lock_key
        self._lease_ttl = lease_ttl_seconds
        self._renew_interval = renew_interval_seconds
        self._token: str | None = None

    async def try_acquire(self) -> bool:
        """Attempt to become the leader. Returns True on success."""
        token = token_hex(16)
        acquired = await self._redis.set(
            name=self._lock_key,
            value=token,
            nx=True,
            ex=self._lease_ttl,
        )
        if acquired:
            self._token = token
            logger.info(
                "leader_acquired",
                lock_key=self._lock_key,
                ttl_seconds=self._lease_ttl,
            )
            return True
        return False

    async def renew(self) -> bool:
        """Extend the lease. Returns False if leadership has been lost."""
        if self._token is None:
            return False

        result = await self._redis.eval(  # type: ignore[no-untyped-call]
            _RENEW_SCRIPT,
            1,
            self._lock_key,
            self._token,
            self._lease_ttl * 1000,  # PEXPIRE wants milliseconds
        )

        if result == 1:
            logger.debug("leader_renewed", lock_key=self._lock_key)
            return True

        logger.warning(
            "leader_lost",
            lock_key=self._lock_key,
            reason="renewal_returned_zero",
        )
        self._token = None
        return False

    async def release(self) -> None:
        """Voluntarily release the lease. Token-checked, so safe even if
        leadership has already been lost."""
        if self._token is None:
            return

        try:
            await self._redis.eval(  # type: ignore[no-untyped-call]
                _RELEASE_SCRIPT, 1, self._lock_key, self._token
            )
            logger.info("leader_released", lock_key=self._lock_key)
        except RedisError as exc:
            logger.warning(
                "leader_release_failed",
                lock_key=self._lock_key,
                error=str(exc),
            )
        finally:
            self._token = None


@asynccontextmanager
async def leadership_loop(
    election: LeaderElection,
    *,
    acquisition_retry_seconds: int,
) -> AsyncIterator[Callable[[], bool]]:
    """Drive the leader election lifecycle.

    Yields a callable ``is_leader()`` that returns True if we are currently
    the leader. The function consults the most recent renewal — it does NOT
    make a Redis call (that would be expensive on a hot path).

    Internally runs a background task that:
        1. Tries to acquire the lease
        2. Once acquired, periodically renews it
        3. On renewal failure, returns to step 1

    The background task is cancelled when the context manager exits.

    Usage::

        async with leadership_loop(election, ...) as is_leader:
            while True:
                if is_leader():
                    await do_work()
                await asyncio.sleep(60)
    """
    state = {"is_leader": False}

    async def _loop() -> None:
        while True:
            if not state["is_leader"]:
                acquired = await election.try_acquire()
                if acquired:
                    state["is_leader"] = True
                else:
                    logger.debug(
                        "leader_acquisition_skipped",
                        lock_key=election._lock_key,
                    )
                    await asyncio.sleep(acquisition_retry_seconds)
                    continue

            # We're the leader — sleep until next renewal
            await asyncio.sleep(election._renew_interval)

            # Renew the lease
            still_leader = await election.renew()
            if not still_leader:
                state["is_leader"] = False
                # Loop will go back to the acquisition path next iteration

    task = asyncio.create_task(_loop())

    try:
        yield lambda: state["is_leader"]
    finally:
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass
        await election.release()
