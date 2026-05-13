# Redis module — Azure Managed Redis

Provisions an Azure Managed Redis (AMR) instance with a Private Endpoint and
Entra ID access policy assignments for consumer UAMIs.

This module replaced the previous Azure Cache for Redis implementation after
Microsoft retired that service. See [ADR-0013] for the migration rationale.

[ADR-0013]: ../../../../docs/decisions/0013-managed-redis-migration.md

## What this module creates

- One `azurerm_managed_redis` instance with HA enabled, TLS 1.2 enforced,
  public network access disabled, and access keys disabled
- One `azurerm_managed_redis_access_policy_assignment` per consumer UAMI
  (i.e. one per service that needs to use the cache)
- One `azurerm_private_endpoint` in the supplied subnet, registered in the
  caller-supplied region-scoped Private DNS zone

## Auth model

There is **no shared secret**. Each consumer authenticates using its own
Entra ID identity:

1. Consumer mints a token for `https://redis.azure.com/.default`
2. Connects to AMR over TLS to port 10000
3. Sends `AUTH <principal_object_id> <token>`
4. Refreshes the token before expiry (~75 minutes) and re-authenticates

The `consumer_object_ids` variable maps a service name (informational —
used only for the access policy assignment name) to the principal object
ID of the UAMI that should be granted access.

## Network model

AMR is reachable only via the Private Endpoint. The PE is registered in
the AMR-specific Private DNS zone, which **must** be region-scoped:
```
privatelink.<region>.redisenterprise.cache.azure.net
```
This differs from the old Azure Cache for Redis, which used
`privatelink.redis.cache.windows.net` (no region in the path).

The caller is responsible for creating the right DNS zone in the network
module and passing its ID as `private_dns_zone_id`.

## Connection details

| Property | Value |
|---|---|
| Hostname | Output: `hostname` |
| Port | 10000 (always — see below) |
| TLS | Always required, TLS 1.2+ (enforced by AMR; not configurable) |
| Auth | Entra ID, no keys |

AMR runs on a single port (10000) for both clustered and non-clustered
modes. This differs from the old service, which used 6379 for non-TLS
and 6380 for TLS — there's no non-TLS option here.

## Security defaults

AMR enforces several security defaults that this module relies on rather
than explicitly configuring:

- **TLS 1.2 minimum** — there's no `minimum_tls_version` argument on
  `azurerm_managed_redis`. The service simply doesn't accept anything lower.
- **Public network access disabled when PE attached** — the provider
  doesn't surface `public_network_access` as an argument. Adding a Private
  Endpoint is the canonical way to restrict access.

These are immutable defaults of the service rather than configurable
settings, but they apply nonetheless.

## Observability

By default the module creates an `azurerm_monitor_diagnostic_setting`
that streams two things to a Log Analytics workspace:

- **`ConnectionEvents`** — every authenticate / disconnect event, with
  the calling principal. This is the AMR equivalent of the old service's
  `ConnectedClientList` (which doesn't exist for AMR — same observability
  capability, different category name).
- **`AllMetrics`** — built-in metrics including server load, connections
  per second, cache hits/misses, evictions, and used memory.

The connection events land in the `REDConnectionEvents` table in Log
Analytics. To query recent connection failures:

\```kusto
REDConnectionEvents
| where EventName == "AuthenticationFailure"
| project TimeGenerated, ClientIp, ClientUsername
| order by TimeGenerated desc
\```

Set `diagnostic_settings_enabled = false` to skip the diagnostic setting
(useful for tests or out-of-band investigation environments). When
enabled, `log_analytics_workspace_id` is required — a precondition
enforces this at plan time.

## Usage

```hcl
module "redis" {
  source = "../../modules/data/redis"

  name                = "redis-myapp-uksouth-abc123"
  location            = "uksouth"
  resource_group_name = azurerm_resource_group.this.name

  sku_name                  = "Balanced_B0"
  high_availability_enabled = true

  private_endpoints_subnet_id = module.network.subnet_ids.private_endpoints
  private_dns_zone_id         = module.network.private_dns_zone_ids.managed_redis

  consumer_object_ids = {
    api       = module.identity.identity_principal_ids.api
    worker    = module.identity.identity_principal_ids.worker
    scheduler = module.identity.identity_principal_ids.scheduler
  }

  tags = local.tags
}
```

## Inputs

| Name | Description | Type | Default | Required |
|---|---|---|---|---|
| `name` | Name of the AMR instance | `string` | — | yes |
| `location` | Azure region | `string` | — | yes |
| `resource_group_name` | Resource group name | `string` | — | yes |
| `sku_name` | AMR SKU (`Balanced_Bn`) | `string` | `"Balanced_B0"` | no |
| `high_availability_enabled` | HA across AZs | `bool` | `true` | no |
| `private_endpoints_subnet_id` | Subnet ID for PE | `string` | — | yes |
| `private_dns_zone_id` | Region-scoped DNS zone ID | `string` | — | yes |
| `consumer_object_ids` | Map of consumer name → UAMI principal ID | `map(string)` | `{}` | no |
| `tags` | Tags applied to all resources | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|---|---|
| `id` | Resource ID of the AMR instance |
| `name` | Name of the AMR instance |
| `hostname` | FQDN clients connect to |
| `port` | Always `10000` |

## Gotchas

- **Region in the DNS zone name** — Adding a new region means a new DNS
  zone, not reusing the existing one. The network module handles this
  automatically via `var.location`.
- **PE subresource name** — Use `redisEnterprise`, not `redisCache`. The
  underlying resource type is `Microsoft.Cache/redisEnterprise`.
- **Provisioning time** — AMR takes 10–15 minutes to deploy. Be patient.
- **No SKU downgrade** — Once provisioned at e.g. `Balanced_B3`, you
  cannot downgrade to `Balanced_B0`. Replacement is the only option.
- **No access key fallback** — `access_keys_authentication_enabled = false`
  means even break-glass access requires an Entra ID identity. Plan
  operator access via the relevant UAMI accordingly.

## Local development

This module is not used in local development. For local dev, the
application's docker-compose stack runs a plain `redis:7-alpine` container
with no auth and no TLS, which the application's `RedisClient` handles via
the `redis_use_entra_id: false` settings path.