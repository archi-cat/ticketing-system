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

# Enforces the minimum TLS version (TLS 1.2) for connections.
# Note: Trivy's AZU-0026 rule does not recognise this — it only checks
# the legacy single-server resource types, not flexible-server
# configuration parameters. The finding is suppressed in .trivyignore
# as a false positive; this resource is the actual enforcement.
resource "azurerm_postgresql_flexible_server_configuration" "ssl_min_version" {
  name      = "ssl_min_protocol_version"
  server_id = azurerm_postgresql_flexible_server.main.id
  value     = "TLSv1.2"
}

# Useful for application observability — logs queries slower than 1s
resource "azurerm_postgresql_flexible_server_configuration" "log_min_duration" {
  name      = "log_min_duration_statement"
  server_id = azurerm_postgresql_flexible_server.main.id
  value     = "1000"
}

resource "azurerm_postgresql_flexible_server_configuration" "log_connections" {
  name      = "log_connections"
  server_id = azurerm_postgresql_flexible_server.main.id
  value     = "on"
}

resource "azurerm_postgresql_flexible_server_configuration" "log_checkpoints" {
  name      = "log_checkpoints"
  server_id = azurerm_postgresql_flexible_server.main.id
  value     = "on"
}

# ── Audit logging (pgaudit) ───────────────────────────────────────────────────
# pgaudit gives a DDL + role-change audit trail. Azure requires three things:
#   1. allow-list the extension       (azure.extensions)
#   2. preload the library            (shared_preload_libraries — needs restart)
#   3. CREATE EXTENSION in the DB      (done by the db-grant Job, which connects
#      as an azure_pg_admin — see bootstrap/db-grant/grant.sh)
# Audit events go to the standard Postgres log (category PostgreSQLLogs, already
# streamed to Log Analytics below) prefixed "AUDIT:".

# Step 1 — allow-list pgaudit. This parameter is empty by default and nothing
# else in this project uses it, so a plain set is safe (no existing list to
# preserve). Casing follows the Azure portal convention (upper-case names).
resource "azurerm_postgresql_flexible_server_configuration" "azure_extensions" {
  name      = "azure.extensions"
  server_id = azurerm_postgresql_flexible_server.main.id
  value     = "PGAUDIT"
}

# Step 2 — preload the library. STATIC parameter: applying this restarts the
# server (the provider waits for it to come back). Azure takes the COMPLETE
# list, so var.shared_preload_libraries preserves the PG18 default and appends
# pgaudit. depends_on the allow-list keeps the two server-parameter writes
# serialised (Azure rejects concurrent parameter updates).
resource "azurerm_postgresql_flexible_server_configuration" "shared_preload_libraries" {
  name       = "shared_preload_libraries"
  server_id  = azurerm_postgresql_flexible_server.main.id
  value      = var.shared_preload_libraries
  depends_on = [azurerm_postgresql_flexible_server_configuration.azure_extensions]
}

# Step 3 of config — what to audit. DDL captures schema changes; ROLE captures
# CREATE/ALTER ROLE with passwords REDACTED (unlike log_statement=DDL, which
# logs them in clear text). Azure forbids pgaudit's "-" shortcut, so classes are
# listed explicitly. Set after the library is preloaded so the restart doesn't
# race this write.
# NOTE: a Postgres MAJOR-version upgrade drops & recreates pgaudit and does NOT
# preserve this value — the next terraform apply re-asserts it.
resource "azurerm_postgresql_flexible_server_configuration" "pgaudit_log" {
  name       = "pgaudit.log"
  server_id  = azurerm_postgresql_flexible_server.main.id
  value      = "DDL,ROLE"
  depends_on = [azurerm_postgresql_flexible_server_configuration.shared_preload_libraries]
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
