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

# Entra ID access policy assignments — one per consumer UAMI (api, worker,
# scheduler). This is what each service needs in order to AUTH.
#
# Chained (not for_each) on purpose: Azure Managed Redis processes only ONE
# database control-plane operation at a time. Creating these in parallel makes
# the 2nd/3rd fail with 429 "Unable to update the database from its current
# state 'Updating'". The depends_on chain forces Terraform to create them
# strictly one after another — each finishes (DB back to 'Succeeded') before
# the next starts — so the database never sees concurrent updates. Terraform
# can't order for_each instances, hence the explicit resources.
resource "azurerm_managed_redis_access_policy_assignment" "api" {
  managed_redis_id = azurerm_managed_redis.main.id
  object_id        = var.consumer_object_ids["api"]
}

resource "azurerm_managed_redis_access_policy_assignment" "worker" {
  managed_redis_id = azurerm_managed_redis.main.id
  object_id        = var.consumer_object_ids["worker"]
  depends_on       = [azurerm_managed_redis_access_policy_assignment.api]
}

resource "azurerm_managed_redis_access_policy_assignment" "scheduler" {
  managed_redis_id = azurerm_managed_redis.main.id
  object_id        = var.consumer_object_ids["scheduler"]
  depends_on       = [azurerm_managed_redis_access_policy_assignment.worker]
}

# Migrate the previous for_each instances to the chained resources above so the
# transition is a state rename, not a destroy+recreate (a recreate would race
# the destroy on the single-op database and risk the same 429). Safe no-op for
# any instance that doesn't exist in state. These can be removed after the next
# apply lands.
moved {
  from = azurerm_managed_redis_access_policy_assignment.consumers["api"]
  to   = azurerm_managed_redis_access_policy_assignment.api
}

moved {
  from = azurerm_managed_redis_access_policy_assignment.consumers["worker"]
  to   = azurerm_managed_redis_access_policy_assignment.worker
}

moved {
  from = azurerm_managed_redis_access_policy_assignment.consumers["scheduler"]
  to   = azurerm_managed_redis_access_policy_assignment.scheduler
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
#
# Diagnostic setting #1 — metrics on the cache (parent) resource.
# 'AllMetrics' is the only category supported at this level.
resource "azurerm_monitor_diagnostic_setting" "redis_metrics" {
  count = var.diagnostic_settings_enabled ? 1 : 0

  name                       = "diag-metrics-${var.name}"
  target_resource_id         = azurerm_managed_redis.main.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  metric {
    category = "AllMetrics"
  }

  lifecycle {
    precondition {
      condition     = !var.diagnostic_settings_enabled || var.log_analytics_workspace_id != null
      error_message = "log_analytics_workspace_id must be set when diagnostic_settings_enabled is true."
    }
  }
}

# Diagnostic setting #2 — connection events on the default database
# (child) resource. ConnectionEvents only exists at this level.
#
# The default database is implicitly created by azurerm_managed_redis as
# a child resource named 'default'. We construct its resource ID rather
# than declare it separately.
resource "azurerm_monitor_diagnostic_setting" "redis_database_logs" {
  count = var.diagnostic_settings_enabled ? 1 : 0

  name                       = "diag-logs-${var.name}"
  target_resource_id         = "${azurerm_managed_redis.main.id}/databases/default"
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "ConnectionEvents"
  }
}
