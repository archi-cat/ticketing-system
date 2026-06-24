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
| --- | --- | --- |
| [0001](0001-record-architecture-decisions.md) | Record architecture decisions | Accepted |
| [0002](0002-use-postgresql.md) | Use PostgreSQL Flexible Server (not Azure SQL) | Accepted |
| [0003](0003-network-design.md) | Regional VNet design (subnet-per-role, DNS in-region) | Accepted |
| [0004](0004-workload-identity-per-service.md) | One Workload Identity per service | Accepted |
| [0005](0005-aks-cluster-design.md) | AKS cluster design — node pools, Cilium, Azure CNI Overlay | Accepted |
| [0006](0006-observability-design.md) | Observability — single workspace, split App Insights | Accepted |
| [0007](0007-postgres-design.md) | PostgreSQL — Flexible Server with VNet injection, AAD-only auth | Accepted |
| [0008](0008-redis-design.md) | Redis — Premium with Private Endpoint, access-key auth via Key Vault | Superseded |
| [0009](0009-servicebus-design.md) | Service Bus — Premium with Private Endpoint, SAS auth disabled | Accepted |
| [0010](0010-keyvault-design.md) | Key Vault — RBAC mode, Private Endpoint, purge protection on | Accepted |
| [0011](0011-kustomize-manifest-structure.md) | Kubernetes manifests with Kustomize — base + per-region overlays | Accepted |
| [0012](0012-deploy-pipeline-design.md) | Deploy pipeline — per-service workflows with reusable common workflow | Accepted |
| [0013](0013-managed-redis-migration.md) | Migrate from Azure Cache for Redis to Azure Managed Redis | Accepted (supersedes 0008) |
| [0014](0014-agc-deployment-pattern.md) | AGC deployment pattern — BYO over ALB-managed | Accepted |
| [0015](0015-aks-node-resource-group-colocation.md) | AKS node resource group colocation | Accepted |
| [0016](0016-azapi-for-agc-addon.md) | Use azapi to enable the AGC AKS add-on | Accepted |
| [0017](0017-phase-reorder-ci-before-hardening.md) | Phase reorder — CI maturity before production hardening | Accepted |
| [0018](0018-database-bootstrap-jobs.md) | Database bootstrap via in-cluster Kubernetes Jobs | Accepted |
| [0019](0019-db-load-events-design.md) | Event data loading via Blob Storage and a K8s Job | Accepted |
| [0020](0020-gateway-tls-termination.md) | Gateway TLS termination — cert-manager + Let's Encrypt + DuckDNS + Gateway API | Accepted |
| [0021](0021-default-deny-network-policies.md) | Default-deny network policies with FQDN-scoped egress | Accepted |
| [0022](0022-baseline-alerts.md) | Baseline alerting via Azure Monitor | Accepted |
| [0023](0023-supply-chain-hardening.md) | Supply-chain hardening — Dependabot and SHA-pinned Actions | Accepted |
| [0024](0024-use-fastapi.md) | Use FastAPI for the HTTP API | Accepted (retrospective) |
| [0025](0025-use-sqlalchemy-async.md) | Use SQLAlchemy 2.0 async with Alembic | Accepted (retrospective) |
| [0026](0026-three-service-architecture.md) | Split into three Python services | Accepted (retrospective) |
| [0027](0027-service-bus-for-messaging.md) | Use Service Bus Premium for messaging | Accepted (retrospective) |
| [0028](0028-redis-distributed-locking.md) | Use Redis for distributed locking | Accepted (retrospective) |
| [0029](0029-multi-region-active-passive.md) | Multi-region active-passive (not active-active) | Accepted (retrospective) |
| [0030](0030-postgres-audit-logging.md) | PostgreSQL audit logging via pgaudit (DDL + ROLE) | Accepted |
| [0031](0031-cluster-cosign-enforcement.md) | Cluster-level Cosign enforcement via Kyverno (Audit-first) | Accepted |
| [0032](0032-event-upload-job.md) | In-cluster event upload via a Kubernetes Job | Accepted |
| [0033](0033-workload-resilience-resource-governance.md) | Workload resilience (PDBs) and resource governance (LimitRange/ResourceQuota, HPA) | Accepted |
| [0034](0034-storage-public-endpoint-off.md) | Close the event-data storage public endpoint (data_plane_available=false) | Accepted |
