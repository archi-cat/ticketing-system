# Redis Sub-module

Creates an Azure Cache for Redis Premium instance with a Private Endpoint, public access disabled, and access keys output for Key Vault storage.

## Usage

```hcl
module "redis" {
  source = "../../modules/data/redis"

  location            = "uksouth"
  resource_group_name = "rg-ticketing-uksouth"
  cache_name          = "redis-ticketing-uksouth"

  sku_name = "Premium"
  capacity = 1   # P1

  private_endpoint_subnet_id = module.network.subnet_ids.private_endpoints
  private_dns_zone_id        = module.network.private_dns_zone_ids.redis

  log_analytics_workspace_id = module.observability.log_analytics_workspace_id

  tags = {
    environment = "primary"
    project     = "ticketing-system"
  }
}
```

## Resources created

| Resource | Quantity | Notes |
|---|---|---|
| Redis Cache | 1 | Premium, P1, public access disabled, TLS 1.2 minimum |
| Private Endpoint | 1 | NIC in the private-endpoints subnet |
| Private DNS zone group | 1 | Registers the endpoint in `privatelink.redis.cache.windows.net` |
| Diagnostic setting | 1 | Logs and metrics to Log Analytics |

## Inputs

See `variables.tf`.

## Outputs

| Output | Sensitive | Description |
|---|---|---|
| `cache_id` | No | Cache resource ID |
| `cache_name` | No | Cache name |
| `hostname` | No | FQDN — resolves to Private Endpoint IP |
| `ssl_port` | No | SSL port (typically 6380) |
| `primary_access_key` | Yes | Should be stored in Key Vault |
| `secondary_access_key` | Yes | Used during key rotation |
| `connection_string_template` | No | Template with `{KEY}` placeholder |

## How authentication works

1. The module outputs the primary and secondary access keys.
2. The Key Vault sub-module consumes these outputs and stores them as secrets.
3. Application pods running with Workload Identity fetch the primary key from Key Vault at startup.
4. The application constructs the connection string by substituting the key into the template.
5. The Redis client opens a TLS connection using the key.

This is unlike PostgreSQL where pods authenticate as themselves via Workload Identity directly. Redis Cache (the original service, not Azure Managed Redis) does not support Entra ID authentication, so the access key remains the auth mechanism — but the key never appears in app config or environment variables, only in Key Vault.

## Notes

- This module requires **Premium** SKU. Standard does not support Private Endpoints.
- Persistence is not configured in Phase 1. The cache and lock data are ephemeral by design — Phase 2 will add RDB persistence with a dedicated storage account.
- The `non_ssl_port` is disabled — only `rediss://` (TLS) connections work. Apps must use the SSL port.
- The DNS zone group inside the Private Endpoint is what makes resolution work — without it, the cache hostname still resolves to the public IP from inside the VNet.