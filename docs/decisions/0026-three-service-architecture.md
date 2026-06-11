# ADR-0026: Split into three Python services

Status: Accepted
Date: 2026-06-11

> Retrospective record — this decision was made at project inception (Phase 1) but never written down. Documented now so the decision log is complete.

## Context

The ticketing domain has three distinct kinds of work:

1. **Synchronous request handling** — browse, reserve, confirm (latency-sensitive, scales with users)
2. **Asynchronous event processing** — reservation lifecycle messages from Service Bus (throughput-sensitive, scales with queue depth)
3. **Scheduled sweeps** — expiring stale reservations to release seats (time-driven, exactly-one-runner semantics)

The question was whether these live in one deployable or several.

## Decision drivers

- Independent scaling: queue spikes shouldn't force API replicas (and vice versa)
- Failure isolation: a poison message crash-looping the consumer must not take the API down
- Kubernetes-native shapes: each kind of work maps to a clean primitive
- Learning value: multi-service operation (per-service identity, deploys, observability) is a core goal of the project
- Single-language simplicity: all three stay Python to share idioms and tooling

## Considered options

### Single service (API + background tasks in-process)

- One deploy, one image, simplest local dev
- FastAPI background tasks / a thread consuming Service Bus couples all three workloads' resource profiles and failure modes
- Scheduled work in N replicas needs leader election anyway — in-process buys nothing there

### Celery (worker + beat) behind the API

- Established Python pattern
- Brings its own broker semantics on top of Service Bus (or replaces it with Redis-as-broker, losing the Service Bus learning goal)
- Celery beat is a single point of failure unless paired with its own locking

### Three services: api / worker / scheduler

- api: FastAPI Deployment behind the Gateway, scales on traffic
- worker: Service Bus consumer Deployment, scales on queue depth
- scheduler: APScheduler Deployment with Redis leader election (ADR-0028) for exactly-one-active semantics
- Each gets its own image, Workload Identity (ADR-0004), App Insights role, deploy workflow (ADR-0012), and NetworkPolicy (ADR-0021)

## Decision

**Three services** — `app/api`, `app/worker`, `app/scheduler` — sharing language and project conventions but deployed, scaled, and secured independently.

## Consequences

### Positive

- Per-service least privilege became natural: the scheduler's identity can't touch Service Bus, the worker has no ingress, every later hardening ADR keyed off this split
- Failure domains match the domain: a stuck consumer never blocks reservations
- Each service's Dockerfile/deploy/alerting story is small and uniform (the `_deploy-common.yml` reusable workflow exists because the three shapes are identical)

### Negative

- Three of everything: images, lockfiles, deploy workflows, identities, policy files — real overhead for a small system (accepted as the point of the exercise)
- Shared code between services must be duplicated or packaged; so far small enough to duplicate consciously
- Local "run the whole system" requires orchestrating three processes plus dependencies
