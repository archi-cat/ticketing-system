# Architectural Decision Records (ADRs)

This directory contains the architectural decisions made during the development of this project. Each ADR documents the context, the options considered, the decision taken, and the consequences.

ADRs follow a numbered sequence — they are immutable once accepted. If a decision is later reversed, a new ADR is added that supersedes the old one rather than editing the original.

## Format

ADRs use the [MADR (Markdown Any Decision Records)](https://adr.github.io/madr/) format. Each ADR has:

- **Context** — the situation that requires a decision
- **Decision drivers** — the factors influencing the decision
- **Considered options** — alternatives evaluated
- **Decision** — what was chosen and why
- **Consequences** — positive and negative outcomes of the decision

## Index

| # | Title | Status |
|---|---|---|
| [0001](0001-record-architecture-decisions.md) | Record architecture decisions | Accepted |
| [0002](0002-use-postgresql.md) | Use PostgreSQL Flexible Server (not Azure SQL) | Accepted |
| [0003](0003-network-design.md) | Regional VNet design (subnet-per-role, DNS in-region) | Accepted |
| [0004](0004-workload-identity-per-service.md) | One Workload Identity per service | Accepted |
| [0005](0005-aks-cluster-design.md) | AKS cluster design — node pools, Cilium, Azure CNI Overlay | Accepted |

| [0003](0003-use-fastapi.md) | Use FastAPI for the HTTP API | Accepted |
| [0004](0004-use-sqlalchemy-async.md) | Use SQLAlchemy 2.0 async with Alembic | Accepted |
| [0005](0005-three-service-architecture.md) | Split into three Python services | Accepted |
| [0006](0006-service-bus-premium.md) | Use Service Bus Premium for messaging | Accepted |
| [0007](0007-redis-distributed-locking.md) | Use Redis for distributed locking | Accepted |
| [0008](0008-multi-region-active-passive.md) | Multi-region active-passive (not active-active) | Accepted |