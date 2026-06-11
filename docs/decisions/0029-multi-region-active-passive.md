# ADR-0029: Multi-region active-passive (not active-active)

Status: Accepted
Date: 2026-06-11

> Retrospective record — this decision was made at project inception (Phase 1) but never written down. Documented now so the decision log is complete. Phase 4 implements it; this records why the target architecture is active-passive.

## Context

The project's end-state is multi-region: UK South primary, a second region as standby, Azure Front Door routing in front. The foundational choice — made at inception because it shapes every data-layer decision — was between active-active (both regions serve traffic) and active-passive (one serves, one stands by).

## Decision drivers

- The data layer must stay consistent for the domain: seat inventory is a contended, strongly-consistent resource — overselling is the one unforgivable failure
- Tier realities from prior ADRs: Postgres B1ms supports cross-region **read replicas with manual promotion** (ADR-0002), not auto-failover groups
- Cost: a second full-write region doubles the most expensive resources; the project is cost-minimal by posture
- Learning goal: disaster-recovery **automation** (detection, promotion, traffic shift) is an explicit Phase 4 deliverable — a runbook-driven failover is the thing being practised

## Considered options

### Active-active

- Both regions serve writes; Front Door distributes by latency
- Seat inventory becomes a cross-region consistency problem: either synchronous cross-region commits (latency, availability coupling) or conflict resolution on overlapping reservations (overselling risk — unacceptable for the domain)
- Requires data-layer technology the chosen tiers don't offer (multi-master Postgres isn't an Azure PaaS primitive at any tier)

### Active-passive

- One write region; the standby holds read replicas / paired namespaces / restorable state
- Failover = promote replica, flip Service Bus geo-DR pairing, repoint Front Door origin — an orchestratable, testable sequence
- Matches what the chosen tiers actually support; RPO/RTO are non-zero but explicit and measurable

## Decision

**Active-passive**: UK South primary takes all writes; the secondary region runs warm standby data (Postgres read replica, Service Bus geo-DR secondary) and cold compute (AKS deployable on demand or scaled to zero). Azure Front Door fronts both with priority routing. Failover is an automated promotion sequence, not a routing decision.

## Consequences

### Positive

- Seat-inventory consistency is trivially preserved — single write master at all times
- Every component's failover behaviour is explicit and rehearsable; DR automation is a deliverable, not an accident
- Standby region cost is a fraction of a second active region

### Negative

- Non-zero RPO (replica lag at failure moment) and RTO (promotion + DNS/Front Door convergence) — accepted and to be measured in Phase 4
- Failover is a one-way door per incident: failback requires re-establishing replication in reverse
- The passive region is perpetually at risk of config drift from the active one — mitigated by both regions deploying from the same Terraform modules and Kustomize bases with per-region overlays (ADR-0011), which is also why region-coupled values (e.g. NetworkPolicy CIDRs, ADR-0021) are tracked as Phase 4 refactor items
