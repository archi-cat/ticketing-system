# Ticketing Worker

Async Service Bus consumer for the ticketing system. Processes reservation
and booking events asynchronously — seat decrement, audit logging, and
mock confirmation emails.

## Quick start

```bash
uv sync
uv run python -m ticketing_worker
```

## Subscriptions consumed

| Topic | Subscription | Handler |
|---|---|---|
| reservation-events | seat-decrement | SeatDecrementHandler |
| reservation-events | audit-log | AuditLogHandler |
| booking-events | confirmation-email | ConfirmationEmailHandler |
| booking-events | audit-log | AuditLogHandler |

## How idempotency works

Each message is uniquely identified by its Service Bus `message_id`. Before
dispatching to a handler, the consumer:

1. Tries to insert the message ID into `processed_messages` with
   `ON CONFLICT DO NOTHING`
2. If the row was inserted (first time seeing this message), the handler runs
3. If the row already existed (redelivery), the message is completed without
   running the handler

Idempotency record + handler execution share a database transaction. If the
handler raises, both are rolled back — so the next redelivery sees the
message as fresh and retries cleanly.

## Health endpoints

The worker doesn't serve user traffic but exposes K8s probes on port 8001:

- `GET /health/live` — always 200 if the process is alive
- `GET /health/ready` — 200 if database is reachable, 503 otherwise

## Authentication

In production, the worker authenticates to PostgreSQL and Service Bus using
Workload Identity. The pod's UAMI must have:

- The `uami-ticketing-uksouth-worker` PostgreSQL role with table-level grants
  (see `scripts/Grant-PostgresWorkloadIdentity.ps1`)
- `Azure Service Bus Data Receiver` on the namespace (granted in the
  Terraform environment composition)
