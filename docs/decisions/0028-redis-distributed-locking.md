# ADR-0028: Use Redis for distributed locking

Status: Accepted
Date: 2026-06-11

> Retrospective record — this decision was made at project inception (Phase 1) but never written down. Documented now so the decision log is complete. ADR-0008 / ADR-0013 cover the Redis *infrastructure*; this ADR records the locking *pattern* and why Redis is its home.

## Context

Two places in the system need mutual exclusion across replicas:

1. **Seat holds (api):** two requests reserving the same seat must serialise — one wins, one gets a clean "not available"
2. **Scheduler leadership:** the scheduler runs ≥ 1 replicas for availability, but the expiry sweep must run exactly once per tick

Redis was already in the architecture as a cache, so the question was whether locking lives there too or somewhere else.

## Decision drivers

- Sub-millisecond acquire/release on the seat-hold path (request-latency sensitive)
- TTL-based self-healing: a crashed holder must not leave a permanent lock
- Safe release/renewal: a slow holder must never release or extend a lock it no longer owns
- No new infrastructure for locking alone

## Considered options

### Postgres advisory locks

- No extra infrastructure; transactional integration
- Couples lock traffic to the B1ms database's tiny connection budget (ADR-0022 alerts at 80% of 50); a lock-heavy path competes with real queries
- Session-scoped locks + async connection pooling is a subtle, easy-to-get-wrong combination

### Kubernetes Lease objects (client-go style leader election)

- Native primitive for the scheduler-leadership half
- Useless for the seat-hold half (API-server round-trips on a request path; etcd churn)
- Would split locking across two mechanisms

### Redis `SET NX EX` + ownership token

- One mechanism serves both cases
- TTL gives crash-recovery for free
- Token + Lua compare-and-delete (release) / compare-and-expire (renew) makes release and renewal safe against expired ownership

## Decision

**Redis single-key locks: `SET key token NX EX ttl`**, with Lua-scripted token-checked release. Two consumers of the pattern:

- `app/api/.../services/locks.py` — `DistributedLock` context manager for seat holds (short TTL)
- `app/scheduler/.../runtime/leader_election.py` — `LeaderElection` lease with periodic Lua-verified renewal; loss of Redis connectivity causes voluntary step-down

## Consequences

### Positive

- One small, well-understood pattern in two thin modules; no locking library dependency
- Crash anywhere → lock self-clears after TTL; theft is impossible because release/renew verify the token atomically
- The scheduler can run 2 replicas (rolling updates stay zero-gap) with exactly-one-active semantics

### Negative

- Single-instance Redis lock, not Redlock: a Redis failover can briefly hand leadership to two holders. Accepted — the expiry sweep is idempotent and seat holds are short-TTL; documented in `locks.py` as the production-scale upgrade path
- Lock correctness now depends on Redis availability; the scheduler deliberately fails toward "nobody runs" rather than "two run" when Redis is unreachable
- TTL tuning is a judgement call: too short risks expiry mid-operation, too long delays takeover after a crash
