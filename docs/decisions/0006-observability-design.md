# 6. Observability — single Log Analytics workspace, split App Insights

Date: 2026-04-27
Status: Accepted

## Context

The application has three runtime services (API, worker, scheduler) plus several PaaS dependencies (PostgreSQL, Service Bus, Redis, Key Vault) and an AKS cluster. All produce telemetry that needs to land somewhere queryable, with cost guardrails to prevent surprises.

## Decision drivers

- Cross-resource queries (e.g. correlating a database slowdown with API latency) must be straightforward
- Application-level telemetry needs SDK-compatible ingestion endpoints
- Cost must be bounded — a misbehaving log statement should not produce an unbounded bill
- Retention should cover typical incident investigation timescales

## Considered options

### One Log Analytics workspace per service
Maximum isolation, but cross-service queries become painful and costly (cross-workspace `union` queries are slower).

### One workspace, classic (non-workspace-based) App Insights
Older pattern. Telemetry storage is split between workspace and App Insights, complicating queries. Deprecated by Microsoft in 2024.

### One workspace, workspace-based App Insights, single shared App Insights instance
Simplest, but mixing user-facing API telemetry with worker/scheduler telemetry makes sampling and alerting harder to tune separately.

### One workspace, workspace-based App Insights, split per concern
Single workspace for unified queries; separate App Insights for the API (user-facing latency) and workers (async background work). Scheduler shares the workers' instance because they have similar telemetry profiles.

## Decision

- **One Log Analytics workspace** per region
- **Workspace-based Application Insights** (telemetry stored in the workspace)
- **Two App Insights instances** per region: one for the API, one shared by workers and scheduler
- **30-day retention** and **1 GB/day ingestion cap** as cost guardrails
- IP masking enabled (default) to avoid GDPR exposure

## Consequences

### Positive
- Cross-resource queries are trivial — no `union workspace()` needed
- API can be tuned for high-volume sampling without reducing fidelity for background workers
- Alert rules can target the API specifically without false positives from worker work
- Costs are bounded predictably by the daily cap

### Negative
- Two App Insights instances to wire into application config (mitigated — `for_each` makes this trivial)
- 1 GB/day cap will be hit in busy load tests; needs raising for any meaningful load testing in CI
- IP masking limits some forensic capabilities — flip to disabled when actual fraud/abuse investigation is needed