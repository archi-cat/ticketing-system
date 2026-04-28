terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
  required_version = ">= 1.9.0"
}

# ── PostgreSQL Flexible Server ────────────────────────────────────────────────
# VNet-injected — server lives inside the delegated subnet, no public endpoint.
# Authentication is Entra ID only — no postgres superuser password exists.

resource "azurerm_postgresql_flexible_server" "main" {
  name                = var.server_name
  location            = var.location
  resource_group_name = var.resource_group_name

  version    = var.postgres_version
  sku_name   = var.sku_name
  storage_mb = var.storage_mb

  # ── VNet injection ──────────────────────────────────────────────────────────
  # Server is provisioned INSIDE this subnet (different from a Private Endpoint).
  # The subnet must be delegated to Microsoft.DBforPostgreSQL/flexibleServers.
  delegated_subnet_id = var.delegated_subnet_id
  private_dns_zone_id = var.private_dns_zone_id

  # ── Public access disabled ──────────────────────────────────────────────────
  # No public endpoint, no firewall rules needed. The server is reachable only
  # from within the VNet (and peered networks).
  public_network_access_enabled = false

  # ── Authentication ──────────────────────────────────────────────────────────
  # AzureADOnly mode — no password authentication. Eliminates the postgres
  # superuser password as an attack surface entirely.
  authentication {
    active_directory_auth_enabled = true
    password_auth_enabled         = false
    tenant_id                     = data.azurerm_client_config.current.tenant_id
  }

  # ── Backups ─────────────────────────────────────────────────────────────────
  # Geo-redundant backups disabled — adds cost and isn't needed for learning.
  # Phase 4 will add a cross-region read replica which provides similar
  # protection at the application level.
  backup_retention_days        = var.backup_retention_days
  geo_redundant_backup_enabled = false

  # ── HA ──────────────────────────────────────────────────────────────────────
  # Disabled — Burstable tier doesn't support HA anyway. Multi-region
  # redundancy comes from the Phase 4 read replica.
  # high_availability omitted entirely — adding a block (even Disabled) errors
  # out on the Burstable tier in some regions.

  tags = var.tags

  lifecycle {
    # Critical: ignore changes to administrator credentials. The provider
    # tries to manage these even when we use AAD-only auth, causing diffs.
    ignore_changes = [
      administrator_login,
      administrator_password,
      zone,
    ]
  }
}

data "azurerm_client_config" "current" {}

# ── Entra ID admin ────────────────────────────────────────────────────────────
# The initial Entra admin. Application UAMIs will be added separately as
# database users via the Set-PostgresWorkloadIdentity.ps1 script in CI.

resource "azurerm_postgresql_flexible_server_active_directory_administrator" "main" {
  server_name         = azurerm_postgresql_flexible_server.main.name
  resource_group_name = var.resource_group_name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  object_id           = var.entra_admin_principal_id
  principal_name      = var.entra_admin_principal_name
  principal_type      = var.entra_admin_principal_type
}

# ── Application database ──────────────────────────────────────────────────────
# Created inside the server. The default 'postgres' database is the maintenance
# database and shouldn't host application data.

resource "azurerm_postgresql_flexible_server_database" "ticketing" {
  name      = var.database_name
  server_id = azurerm_postgresql_flexible_server.main.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

# ── Server parameters ─────────────────────────────────────────────────────────
# require_secure_transport=ON enforces TLS on all connections. Default in
# Flexible Server, but explicit configuration documents intent and prevents
# accidental disabling.

resource "azurerm_postgresql_flexible_server_configuration" "require_ssl" {
  name      = "require_secure_transport"
  server_id = azurerm_postgresql_flexible_server.main.id
  value     = "ON"
}

# Useful for application observability — logs queries slower than 1s
resource "azurerm_postgresql_flexible_server_configuration" "log_min_duration" {
  name      = "log_min_duration_statement"
  server_id = azurerm_postgresql_flexible_server.main.id
  value     = "1000"
}

# ── Diagnostic settings ───────────────────────────────────────────────────────
# Stream PostgreSQL logs and metrics to Log Analytics for centralised query.

resource "azurerm_monitor_diagnostic_setting" "postgres" {
  name                       = "diag-${var.server_name}"
  target_resource_id         = azurerm_postgresql_flexible_server.main.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "PostgreSQLLogs"
  }

  enabled_log {
    category = "PostgreSQLFlexSessions"
  }

  enabled_log {
    category = "PostgreSQLFlexQueryStoreRuntime"
  }

  enabled_log {
    category = "PostgreSQLFlexQueryStoreWaitStats"
  }

  metric {
    category = "AllMetrics"
  }
}