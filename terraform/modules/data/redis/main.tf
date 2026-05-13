# Azure Managed Redis (AMR) — successor to Azure Cache for Redis.
#
# Why we migrated:
#   - Azure Cache for Redis is retired; new instances cannot be created
#   - AMR supports Entra ID authentication at the data plane, removing the
#     Key Vault round-trip pattern we previously used for access keys
#
# Auth model:
#   Workload Identity (UAMI) → DefaultAzureCredential → mint token for
#   https://redis.azure.com/.default → AUTH to Redis with the token
#   No keys, no Key Vault round trip, no Kubernetes Secrets.

resource "azurerm_managed_redis" "main" {
  name                = var.name
  location            = var.location
  resource_group_name = var.resource_group_name
  sku_name            = var.sku_name

  high_availability_enabled = var.high_availability_enabled

  default_database {
    # Disable access keys entirely. Entra ID is the only path.
    # Combined with public_network_access=Disabled and the PE below, the
    # cache is unreachable except via tokens minted by recognised principals.
    access_keys_authentication_enabled = false

    # OSSCluster gives us the same single-node-as-cluster experience as the
    # old Premium tier. Clients use the cluster protocol automatically.
    clustering_policy = "OSSCluster"

    # When memory fills, evict the keys most likely to be safe to drop.
    eviction_policy = "VolatileLRU"
  }

  tags = var.tags
}

# Entra ID access policy assignments — one per consumer UAMI.
# This is what the API, worker, and scheduler need in order to AUTH.
resource "azurerm_managed_redis_access_policy_assignment" "consumers" {
  for_each = var.consumer_object_ids

  managed_redis_id = azurerm_managed_redis.main.id
  object_id        = each.value
}

# Private endpoint — the only network path into the cache.
resource "azurerm_private_endpoint" "redis" {
  name                = "pe-${var.name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.private_endpoints_subnet_id

  private_service_connection {
    name                           = "psc-${var.name}"
    private_connection_resource_id = azurerm_managed_redis.main.id
    is_manual_connection           = false
    # IMPORTANT: AMR uses 'redisEnterprise' as the subresource, not 'redisCache'.
    # This is the underlying Microsoft.Cache/redisEnterprise resource type.
    subresource_names = ["redisEnterprise"]
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [var.private_dns_zone_id]
  }

  tags = var.tags
}

# ── Diagnostic settings ───────────────────────────────────────────────────────
# Stream connection events and metrics to Log Analytics for security audit
# and operational monitoring.
#
# Note: AMR uses 'ConnectionEvents' as the log category name. The old Azure
# Cache for Redis used 'ConnectedClientList' — that category doesn't exist
# on AMR.

resource "azurerm_monitor_diagnostic_setting" "redis" {
  count = var.log_analytics_workspace_id == null ? 0 : 1

  name                       = "diag-${var.name}"
  target_resource_id         = azurerm_managed_redis.main.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "ConnectionEvents"
  }

  metric {
    category = "AllMetrics"
  }
}