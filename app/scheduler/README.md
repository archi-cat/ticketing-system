# Ticketing Scheduler

Periodic background job runner for the ticketing system. Runs the
reservation expiry sweeper on a schedule.

## Quick start

```bash
uv sync
uv run python -m ticketing_scheduler
```

## What it does

Every 60 seconds (configurable), the scheduler:

1. Finds PENDING reservations where `expires_at <= NOW()`
2. Atomically transitions them to EXPIRED
3. Returns their seats to the event's `available_seats`

Multi-instance safety is handled by Redis-based leader election. Only the
current leader runs the sweeper; non-leaders sit idle, ready to take over
if the leader dies.

## Leader election
```
┌───────────────┐                         ┌───────────────┐
│   Replica A   │                         │   Replica B   │
│  (LEADER)     │  ──── lease ───→ Redis  │ (NOT LEADER)  │
│  runs sweep   │                         │  idle, polls   │
│  every 60s    │                         │  for leadership│
└───────────────┘                         └───────────────┘
│                                         ▲
│      (replica A crashes)                │
│      (lease expires after 90s)          │
└─────────────────────────────────────────┘
Replica B acquires lease, becomes leader
```
The lease has a 90-second TTL, renewed every 30 seconds by the leader.
A new leader can take over within 90 seconds of the previous leader
dying.

## Health endpoints

- `GET /health/live` — process is alive (port 8002)
- `GET /health/ready` — database and Redis are reachable

Note: non-leader replicas still report "ready" — they're ready to take
over leadership if needed.

## Authentication

In production, the scheduler authenticates to:

- **PostgreSQL** — Workload Identity, via the `uami-ticketing-uksouth-scheduler`
  database role with SELECT/UPDATE on reservations and events
- **Redis** — access key fetched from Key Vault by the deployment workflow,
  injected as a Kubernetes Secret