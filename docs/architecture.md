# Architecture

> This document is a living description of the system's architecture. It is updated as the system evolves.

## Overview

The ticketing system is a multi-region, event-driven application deployed on Azure. It demonstrates production-grade patterns including:

- Stateless application services with horizontal scaling
- Asynchronous event-driven processing via Service Bus
- Distributed locking and caching via Redis
- Workload Identity for secret-less authentication to all Azure services
- Multi-region active-passive with Front Door global routing
- Manual disaster recovery orchestration via PowerShell

## Diagram

![Architecture](architecture.png)

The diagram is generated from `docs/diagram.py` using the Python `diagrams` library. Regenerate with:

```bash
cd docs
python diagram.py
```

## Components

### API service (FastAPI)

Stateless HTTP service handling synchronous client requests. Validates input, persists reservations to PostgreSQL, publishes lifecycle events to Service Bus, returns responses to clients.

### Worker service (asyncio)

Subscribes to Service Bus topics. Handles seat decrement on reservation, confirmation logging on booking, and idempotency tracking via the database.

### Scheduler service (APScheduler)

Single-replica with Redis-based leader election. Sweeps expired reservations every 60 seconds, releasing held seats back to availability.

## Data layer

| Store | Purpose |
|---|---|
| PostgreSQL Flexible Server | System of record for events, reservations, bookings |
| Redis Premium | Cache, distributed locks, scheduler leader election |
| Service Bus Premium | Async event delivery, dead-letter queues for failed processing |

## Networking

(To be expanded in Phase 1.)

## Security

(To be expanded in Phase 2.)

## Observability

(To be expanded in Phase 2.)

## Multi-region topology

(To be expanded in Phases 4–5.)