# 7. PostgreSQL — Flexible Server with VNet injection, AAD-only auth

Date: 2026-04-27
Status: Accepted

## Context

The application needs a PostgreSQL database accessible privately from AKS pods, authenticated via Workload Identity, and following production security practices.

## Decision drivers

- Database must be private — no public endpoint
- Authentication must be passwordless — pods authenticate via Workload Identity
- Subscription quotas must accommodate the chosen tier without support requests
- Backup and recovery should align with the multi-region story (Phase 4)

## Considered options

### Networking — Private Endpoint vs VNet injection
Flexible Server doesn't support Private Endpoint. The choice is between public-with-firewall and VNet injection.

### Authentication — password, AAD-only, or hybrid
Password auth requires managing a postgres superuser password. AAD-only eliminates the password entirely. Hybrid is for migrations.

### HA — Disabled vs ZoneRedundant
ZoneRedundant requires General Purpose tier minimum, exceeding the cost-conscious target. The Burstable tier doesn't support HA at all.

### Backups — local vs geo-redundant
Geo-redundant backups add cost. Cross-region protection is also achievable via a read replica.

## Decision

- **VNet injection** (server lives in a delegated subnet) — fully private
- **AAD-only authentication** (`password_auth_enabled = false`) — no postgres password exists
- **HA disabled** — Burstable tier limitation; multi-region story comes from Phase 4 read replica
- **Local backups, 7-day retention** — minimum supported, sufficient for learning
- **Burstable B1ms tier** — fits default subscription quotas without support requests

## Consequences

### Positive
- No password to manage, rotate, or leak
- All access flows through Entra ID — auditable in Azure AD logs
- Server cannot be accidentally exposed to the internet
- Stays within default subscription quotas

### Negative
- VNet injection couples the database to a specific VNet — cross-region reads (Phase 4) require a separate read replica server, not just a different connection string
- AAD-only means migrations and ops scripts must use AAD tokens, not connection strings — slightly more PowerShell setup
- Burstable tier has no HA — single-instance failure means downtime until automatic recovery (~2-5 minutes typically)
- 7-day backup retention is shorter than typical production (35 days) — acceptable for learning