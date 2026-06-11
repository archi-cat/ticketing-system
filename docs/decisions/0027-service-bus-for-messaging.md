# ADR-0027: Use Service Bus Premium for messaging

Status: Accepted
Date: 2026-06-11

> Retrospective record — this decision was made at project inception (Phase 1) but never written down. Documented now so the decision log is complete. ADR-0009 documents the *configuration* of the namespace (Private Endpoint, SAS disabled); this ADR records why Service Bus Premium was the messaging technology in the first place.

## Context

The reservation lifecycle is event-driven: the API publishes events (reservation created, confirmed, expired) and the worker consumes them asynchronously. The platform needs a message broker with at-least-once delivery, dead-lettering, and Azure-native auth.

## Decision drivers

- Entra ID (Workload Identity) authentication — the project's no-secrets rule (ADR-0004)
- Private-network access — the broker must sit behind a Private Endpoint like the rest of the data layer
- Real queue semantics: competing consumers, dead-letter queue, message lock/renewal
- Multi-region story for Phase 4 (geo-DR or at least a documented failover shape)
- Operational weight appropriate to a learning project — no self-hosted broker to babysit

## Considered options

### Azure Storage Queues

- Cheapest by far
- No dead-letter queue, no sessions, 64 KB messages, polling-only; too little broker for the learning goals

### Azure Event Hubs

- Stream/log semantics (partitions, offsets) — built for telemetry ingestion, not work queues
- Competing-consumer work distribution and per-message dead-lettering are not its model

### Self-hosted RabbitMQ / Kafka on AKS

- Maximum learning about brokers themselves, full control
- A stateful clustered system to operate, upgrade, and back up — a project within the project, and it forfeits the managed-PaaS + Workload Identity integration the project is demonstrating

### Azure Service Bus (Standard vs Premium)

- Proper queue semantics: DLQ, lock renewal, sessions, competing consumers
- Entra ID data-plane auth; SAS can be disabled outright
- **Private Endpoint support is Premium-only** — Standard would leave the broker on a public endpoint, breaking the private-data-layer rule
- Premium also adds geo-DR namespace pairing for the Phase 4 multi-region story (ADR-0029)

## Decision

**Azure Service Bus, Premium tier** — the only option satisfying both the queue-semantics and the private-networking requirements with Entra ID auth.

## Consequences

### Positive

- The worker is a textbook competing-consumer with DLQ; the DLQ alert (ADR-0022) and poison-message handling have real semantics to hook into
- No connection strings anywhere — Workload Identity end to end
- Geo-DR pairing available when Phase 4 needs it

### Negative

- Premium is the single most expensive resource in the platform — materially shapes the teardown-loop posture (the project is deployed for testing windows, not continuously)
- Premium capacity is per-messaging-unit; vastly over-provisioned for this workload (accepted: the tier is bought for PE + auth features, not throughput)
