# 10. Key Vault — RBAC mode, Private Endpoint, purge protection on

Date: 2026-04-27
Status: Accepted

## Context

The project authenticates almost everything via Workload Identity, eliminating most secret storage needs. However, Azure Cache for Redis (the original service, not Azure Managed Redis) does not support Entra ID authentication — its access keys remain the only authentication mechanism. These keys must be stored somewhere that:

- Is not in application config or environment variables
- Application UAMIs can fetch via Workload Identity
- Supports rotation and audit
- Can also serve future operational secrets (third-party API keys, etc.) without redesign

## Decision drivers

- Authorisation model must be consistent with the rest of the project
- Vault must be private — no public endpoint
- Accidental deletion must be recoverable
- Adversarial deletion must be preventable
- Secret access must be auditable

## Considered options

### Authorisation — access policies vs RBAC
Access policies are the legacy model. RBAC has been Microsoft's recommended default since 2022.

### Network access — public with firewall vs Private Endpoint
Both are valid. Private Endpoint matches the rest of the data layer.

### Purge protection — on vs off
Off allows quick teardown of test environments. On prevents accidental and adversarial permanent deletion within the soft-delete window. The trade-off is that mistaken vaults take up to 7 days to fully clean up.

### Vault layout — one per region vs one shared
One per region is simpler — secrets stay in the region that produced them (e.g. regional Redis keys go in the regional vault). One shared adds cross-region complexity for unclear benefit.

## Decision

- **One Key Vault per region**
- **RBAC authorisation** — consistent with the project's pattern
- **Private Endpoint** + `public_network_access_enabled = false` + `network_acls.default_action = "Deny"`
- **Purge protection enabled** — irreversible, accepted trade-off for safety
- **Bootstrap secrets via Terraform** for values flowing from other resources (Redis keys); operational secrets via `az keyvault secret set` post-creation

## Consequences

### Positive
- Application UAMIs fetch secrets via Workload Identity — no credentials in app config
- Vault cannot be reached from outside the VNet
- Accidental and adversarial deletion both protected against
- Audit log of every secret access lands in Log Analytics

### Negative
- Purge protection means mistaken vaults take up to 7 days to fully delete — slows iteration on the vault's own name/region
- Bootstrap-secret pattern requires explicit `depends_on` to avoid race conditions on first apply
- The two-step Redis auth flow (Workload Identity → Key Vault → key → Redis) is more complex than direct Entra ID auth would be — but is the only available pattern for Azure Cache for Redis

## Future revisits

When Azure Managed Redis becomes broadly available across both target regions, ADR-0008 should be revisited. If Redis can be authenticated via Entra ID directly, the only consumer of Key Vault becomes operational secrets — which would still justify the vault's existence but reduce its centrality.