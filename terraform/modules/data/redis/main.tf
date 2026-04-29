terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
  required_version = ">= 1.9.0"
}

# ── Redis Cache — Premium ─────────────────────────────────────────────────────

resource "azurerm_redis_cache" "main" {
  name                = var.cache_name
  location            = var.location
  resource_group_name = var.resource_group_name

  capacity = var.capacity
  family   = "P"
  sku_name = var.sku_name

  # ── Public access disabled ──────────────────────────────────────────────────
  # Once the Private Endpoint is in place, the public endpoint is unnecessary
  # and represents needless attack surface.
  public_network_access_enabled = false

  # ── TLS ─────────────────────────────────────────────────────────────────────
  minimum_tls_version  = "1.2"
  non_ssl_port_enabled = false

  # ── Redis configuration ─────────────────────────────────────────────────────
  redis_configuration {
    # MAXMEMORY policy — allkeys-lru evicts least recently used keys when
    # memory is full. Right choice for cache + ephemeral locks use case.
    maxmemory_policy = "allkeys-lru"

    # Persistence intentionally not configured in Phase 1.
    # Cache + lock data is regenerable; we accept restart data loss.
    # Phase 2 will add RDB persistence with a dedicated storage account.

    # Authentication — access keys remain enabled. Redis (the original
    # service, not Azure Managed Redis) does not support Entra ID auth.
    # The keys are stored in Key Vault and retrieved by apps via Workload
    # Identity.
    authentication_enabled = true
  }

  tags = var.tags

  lifecycle {
    # Patch schedule and zones may change during maintenance — don't drift on these
    ignore_changes = [
      patch_schedule,
      zones,
    ]
  }
}

# ── Private Endpoint ──────────────────────────────────────────────────────────
# Creates a NIC in the private-endpoints subnet that resolves to the Redis
# cache. The Private DNS zone link (set up by the network module) ensures
# *.redis.cache.windows.net resolves to the Private Endpoint IP from anywhere
# in the VNet.

resource "azurerm_private_endpoint" "redis" {
  name                = "pe-${var.cache_name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.private_endpoint_subnet_id

  private_service_connection {
    name                           = "psc-${var.cache_name}"
    private_connection_resource_id = azurerm_redis_cache.main.id
    is_manual_connection           = false
    subresource_names              = ["redisCache"]
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [var.private_dns_zone_id]
  }

  tags = var.tags
}

# ── Diagnostic settings ───────────────────────────────────────────────────────

resource "azurerm_monitor_diagnostic_setting" "redis" {
  name                       = "diag-${var.cache_name}"
  target_resource_id         = azurerm_redis_cache.main.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "ConnectedClientList"
  }

  metric {
    category = "AllMetrics"
  }
}