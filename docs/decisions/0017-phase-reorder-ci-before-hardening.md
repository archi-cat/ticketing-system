# ADR-0017: Reorder phases — CI maturity before production hardening

Status: Accepted
Date: 2026-05-22

## Context

The project's original phase plan was:

- Phase 0 — Repository scaffolding, cost guardrails
- Phase 1 — Single-region application foundation
- Phase 2 — Production hardening (Workload Identity, Private Endpoints,
  OpenTelemetry)
- Phase 3 — Testing and CI maturity
- Phase 4 — Second region deployment
- Phase 5 — Front Door + active-passive failover
- Phase 6 — Disaster recovery automation

As Phase 1 completed, two observations made the original Phase 2 / Phase 3
ordering look wrong:

1. **Workload Identity — an original Phase 2 item — was already done.**
   It was pulled forward during Phase 1: all four data-plane services
   (PostgreSQL, Redis, Service Bus, Key Vault) authenticate passwordlessly
   via Workload Identity. The original Phase 2 was already partly consumed.

2. **The live technical debt is in the deployment pipeline.** The
   per-service deploy workflows all called one reusable workflow that
   deployed every service at once; the database bootstrap required a
   manually-created temp VM. These caused friction on every deploy cycle.
   Production hardening (Private Endpoints, Defender) does not have that
   "hurts every time" quality — it is important but not blocking daily work.

3. **Several hardening tasks depend on a clean deploy pipeline.** Moving
   the DB bootstrap into a Kubernetes Job, adding image signing — these
   are easier to build on a decoupled, correct pipeline than on the
   coupled one.

## Decision

Swap the original Phase 2 and Phase 3:

- **Phase 2 — Deployment & CI maturity**: per-service deployment
  decoupling, pre-commit hooks, Terraform formatting and security
  scanning, Kubernetes Job for database bootstrap, auto-diagnostics on
  rollout failure, scheduled vulnerability scans, image signing.
- **Phase 3 — Production hardening**: Private Endpoints for ACR and Key
  Vault, NetworkPolicies, PodDisruptionBudgets, Microsoft Defender for
  Containers, end-to-end OpenTelemetry tracing.

Phases 4 onward (multi-region, Front Door failover, DR automation) are
unchanged.

## Rationale

- The technical debt being addressed first is the debt currently slowing
  every iteration.
- CI maturity is a foundation other work builds on; doing it first means
  later phases build on a correct pipeline.
- Workload Identity, the headline item of the original Phase 2, is already
  delivered — so the original Phase 2 was no longer a full phase of work.

## Consequence

The original Phase 2's remaining items (Private Endpoints, OpenTelemetry)
move wholesale into Phase 3. No work is dropped — only resequenced.