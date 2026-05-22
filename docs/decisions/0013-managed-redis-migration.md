# 13. Migrate from Azure Cache for Redis to Azure Managed Redis

Date: 2026-05-12
Status: Accepted
Supersedes: [ADR-0008](0008-redis-design.md)

## Context

Microsoft retired Azure Cache for Redis during the lifetime of this
project. New instances cannot be created — `azurerm_redis_cache` returns
a 400 Bad Request with a directive to use Azure Managed Redis instead.

Azure Managed Redis (AMR) is the successor service:

- Built on Redis Enterprise (under the hood it's Microsoft.Cache/redisEnterprise)
- Native Entra ID authentication at the data plane
- Different SKU family (Balanced_Bn rather than Premium/Standard)
- Region-specific Private DNS zone (privatelink.<region>.redisenterprise.cache.azure.net)
- Port 10000 rather than 6380
- "redisEnterprise" Private Endpoint subresource (not "redisCache")

## Decision

Migrate the project's Redis dependency to Azure Managed Redis. Use the
Balanced_B0 SKU (the smallest, ~£0.10/hour) — appropriate for the
learning-project scale.

Take the opportunity to simplify the auth flow that the old service
required. Previously:
```
Workload Identity → Key Vault (fetch key) → AUTH to Redis with the key
```
AMR's native Entra ID support collapses this to:
```
Workload Identity → mint token → AUTH to Redis with the token
```
The token is refreshed every ~70 minutes in a background task within each
service's `RedisClient`.

## Architectural implications

### Simplifications
- All four upstream services (Postgres, Redis, Service Bus, Key Vault)
  now authenticate the same way: passwordless via Workload Identity
- `KeyVaultClient` is no longer needed by the application code
- The `redis-primary-key` Key Vault bootstrap secret is removed
- The `scheduler-redis-credentials` Kubernetes Secret is removed
- The deploy workflow no longer needs a Key Vault → Kubernetes Secret
  refresh step

### New complexity
- The `RedisClient` runs a background asyncio task to refresh the AAD
  token and re-AUTH the connection before expiry
- The AMR private DNS zone is region-scoped — adding a region means adding
  a region-specific zone, not reusing one
- The principal object ID of each consumer UAMI must flow from Terraform
  through to the Kubernetes manifests as `REDIS_USERNAME`

## Trade-offs

### What we gained
- A consistent authentication story across all data plane services
- Removal of a key-rotation footgun (no key to rotate)
- Architecturally cleaner — no auxiliary Kubernetes Secret for Redis
- Future-proof (AMR is Microsoft's current Redis offering)

### What we lost
- Balanced_B0 is more expensive than the smallest old Premium SKU was
  (~£0.10/hour vs ~£0.04/hour for Premium P1 monthly, comparing list
  prices). For this learning project the difference is small.
- One extra moving part — the token-refresh background task — that can
  fail silently if not monitored

## Out of scope

- Migrating data between instances — there is no data to migrate; the
  cache is intentionally ephemeral
- Geo-replication setup — deferred to Phase 4 when the second region
  is added. `azurerm_managed_redis_geo_replication` supports linking
  databases across regions and will be used then.
