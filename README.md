# Ticketing System

A multi-region, event-driven event ticketing platform deployed on Azure. Built as a learning and showcase project demonstrating production-grade patterns: infrastructure as code, automated CI/CD, secret-less authentication, distributed locking, async workers, and disaster recovery automation.

> **Status:** under active development. See [docs/decisions/README.md](docs/decisions/README.md) for the architectural decision log.

---

## What it does

A simplified but realistic ticketing system:

- Customers browse events and reserve seats with a 15-minute hold
- Reservations are confirmed via mock payment to become bookings
- Background workers process reservation lifecycle events asynchronously
- A scheduler sweeps expired reservations to release seats
- Multi-region active-passive with Azure Front Door routing

## Tech stack

| Layer | Technology |
|---|---|
| API | Python 3.13, FastAPI, SQLAlchemy 2.0 async |
| Workers | Python 3.13, Azure Service Bus SDK |
| Scheduler | Python 3.13, APScheduler |
| Database | Azure Database for PostgreSQL Flexible Server (B1ms) |
| Cache + locks | Azure Cache for Redis (Premium P1) |
| Messaging | Azure Service Bus Premium |
| Container orchestration | Azure Kubernetes Service (AKS) |
| Ingress | Application Gateway for Containers (AGC) |
| Global edge | Azure Front Door Standard |
| Secrets | Azure Key Vault |
| Identity | Workload Identity (no passwords anywhere) |
| Observability | Application Insights + Log Analytics + OpenTelemetry |
| IaC | Terraform |
| CI/CD | GitHub Actions |
| Automation scripts | PowerShell |

## Architecture

![Architecture](docs/architecture.png)

See [docs/architecture.md](docs/architecture.md) for the full architecture description.

## Repository layout

```
ticketing-system/
├── app/                            # Application source code
│   ├── api/                        # FastAPI service
│   ├── worker/                     # Service Bus consumer
│   └── scheduler/                  # Scheduled background jobs
├── terraform/                      # Infrastructure as code
│   ├── modules/                    # Reusable Terraform modules
│   ├── environments/               # Per-environment compositions
│   └── shared/                     # Cross-region shared resources (ACR)
├── k8s/                            # Kubernetes manifests (Kustomize)
│   ├── base/                       # Common base manifests
│   └── overlays/                   # Per-region patches
├── scripts/                        # PowerShell automation
├── docs/                           # Documentation, ADRs, runbooks
└── .github/workflows/              # CI/CD pipelines
```

## Documentation

- [Architecture overview](docs/architecture.md)
- [Architectural Decision Records](docs/decisions/README.md)
- [Operational runbooks](docs/runbooks/)
- [Contributing guide](CONTRIBUTING.md)

## Project phases

This project is being built in phases. Each phase produces a working, demoable system.

| Phase | Scope | Status |
|---|---|---|
| 0 | Repository scaffolding, cost guardrails | ✅ Complete |
| 1 | Single-region application foundation | 🚧 In progress |
| 2 | Production hardening (Workload Identity, Private Endpoints, OpenTelemetry) | ⬜ Not started |
| 3 | Testing and CI maturity | ⬜ Not started |
| 4 | Second region deployment | ⬜ Not started |
| 5 | Front Door + active-passive failover | ⬜ Not started |
| 6 | Disaster recovery automation | ⬜ Not started |