# 8. Redis — Premium with Private Endpoint, access-key auth via Key Vault

Date: 2026-04-27
Status: Accepted

## Context

The application uses Redis for two purposes: caching event/seat data and providing distributed locks for reservation creation. The cache must be private, secure, and fit the project's Workload Identity authentication story as closely as possible.

## Decision drivers

- Cache must be private — no public endpoint
- Authentication must avoid storing secrets in application config
- Tier must support cross-region replication (Phase 4)
- Subscription quotas must accommodate the chosen tier without support requests

## Considered options

### Service choice — Azure Cache for Redis vs Azure Managed Redis
Azure Managed Redis is a newer service supporting Entra ID auth, but is not yet generally available in all regions. Azure Cache for Redis (the original service) is mature and available everywhere — but does not support Entra ID at the data plane.

### Networking — VNet injection vs Private Endpoint
Both are private. VNet injection puts Redis inside our subnet; Private Endpoint creates a NIC in our VNet pointing to Microsoft-hosted Redis. Microsoft is moving away from VNet injection in favour of Private Endpoints.

### Tier — Standard vs Premium
Standard is cheaper but does not support Private Endpoints, geo-replication, or persistence. Premium P1 is the smallest tier with these features.

### Authentication — access keys vs Entra ID
Azure Cache for Redis does not support Entra ID. Access keys are the only option.

## Decision

- **Azure Cache for Redis** (not Azure Managed Redis) — for guaranteed regional availability
- **Private Endpoint**, not VNet injection — aligned with Microsoft's direction
- **Premium P1 tier** — smallest tier with required features
- **Access-key authentication**, with keys stored in Key Vault and fetched at runtime via Workload Identity

## Consequences

### Positive
- Cache is private, no public endpoint
- Apps never have Redis credentials in their config — they fetch them from Key Vault using Workload Identity
- Tier supports geo-replication for Phase 4
- Aligned with Microsoft's networking direction

### Negative
- Auth flow is two-step (Workload Identity → Key Vault → key → Redis) instead of direct Workload Identity
- Premium P1 is more expensive than Standard, but is the smallest tier with required features
- Key rotation involves Key Vault secret updates as well as Azure key rotation — automation deferred to Phase 2
- When Azure Managed Redis becomes broadly available, this decision should be revisited (would simplify the auth flow significantly)