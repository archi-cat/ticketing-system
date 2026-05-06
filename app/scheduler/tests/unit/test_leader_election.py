"""Unit tests for leader election."""

from __future__ import annotations

from unittest.mock import AsyncMock

import pytest

from ticketing_scheduler.runtime.leader_election import LeaderElection


@pytest.mark.asyncio
async def test_acquire_returns_true_when_set_succeeds():
    redis = AsyncMock()
    redis.set.return_value = True

    election = LeaderElection(
        redis=redis,
        lock_key="lock:test",
        lease_ttl_seconds=60,
        renew_interval_seconds=20,
    )

    acquired = await election.try_acquire()
    assert acquired is True
    redis.set.assert_awaited_once()


@pytest.mark.asyncio
async def test_acquire_returns_false_when_set_fails():
    redis = AsyncMock()
    redis.set.return_value = False

    election = LeaderElection(
        redis=redis,
        lock_key="lock:test",
        lease_ttl_seconds=60,
        renew_interval_seconds=20,
    )

    acquired = await election.try_acquire()
    assert acquired is False


@pytest.mark.asyncio
async def test_renew_returns_true_when_we_still_own_lease():
    redis = AsyncMock()
    redis.set.return_value = True
    redis.eval.return_value = 1  # script returned "extended"

    election = LeaderElection(
        redis=redis,
        lock_key="lock:test",
        lease_ttl_seconds=60,
        renew_interval_seconds=20,
    )

    await election.try_acquire()
    still_leader = await election.renew()

    assert still_leader is True


@pytest.mark.asyncio
async def test_renew_returns_false_when_we_lost_lease():
    redis = AsyncMock()
    redis.set.return_value = True
    redis.eval.return_value = 0  # script returned "not the owner"

    election = LeaderElection(
        redis=redis,
        lock_key="lock:test",
        lease_ttl_seconds=60,
        renew_interval_seconds=20,
    )

    await election.try_acquire()
    still_leader = await election.renew()

    assert still_leader is False


@pytest.mark.asyncio
async def test_renew_returns_false_when_never_acquired():
    redis = AsyncMock()

    election = LeaderElection(
        redis=redis,
        lock_key="lock:test",
        lease_ttl_seconds=60,
        renew_interval_seconds=20,
    )

    still_leader = await election.renew()
    assert still_leader is False
    redis.eval.assert_not_awaited()


def test_constructor_validates_intervals():
    """renew_interval must be less than lease_ttl."""
    redis = AsyncMock()

    with pytest.raises(ValueError, match="renew_interval"):
        LeaderElection(
            redis=redis,
            lock_key="lock:test",
            lease_ttl_seconds=10,
            renew_interval_seconds=10,
        )