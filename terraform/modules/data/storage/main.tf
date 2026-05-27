# ─── Storage account for event-data files ────────────────────────────────────
# Holds the JSON event files consumed by the db-load-events bootstrap Job.
#
# Network model (see ADR):
#  - A private endpoint gives the cluster a private, in-VNet path. This is
#    how the db-load-events Job (db-migrator identity) reads the files.
#  - The public endpoint stays enabled with an IP allow-list, for the
#    operator upload path, while no in-cluster upload exists.
#  - Phase 3: set public_network_access_enabled = false (allowed_ip_ranges
#    empties) once an in-cluster upload Job replaces laptop uploads.
#
# Auth is Entra-only — shared access keys are disabled. The db-migrator
# UAMI reads blobs via its Storage Blob Data Reader role; operators upload
# with `az storage blob upload --auth-mode login`.

resource "azurerm_storage_account" "this" {
  name                = var.name
  location            = var.location
  resource_group_name = var.resource_group_name

  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"

  # ── Security posture ───────────────────────────────────────────────────────
  min_tls_version                   = "TLS1_2"
  https_traffic_only_enabled        = true
  allow_nested_items_to_be_public   = false
  shared_access_key_enabled         = false # Entra-only auth
  public_network_access_enabled     = true  # Phase 3: flip to false
  infrastructure_encryption_enabled = true

  # ── Network rules ──────────────────────────────────────────────────────────
  # Deny by default; admit only the operator IP allow-list. The cluster
  # does NOT rely on these rules — it reaches the account via the private
  # endpoint below.
  network_rules {
    default_action = "Deny"
    ip_rules       = var.allowed_ip_ranges
    bypass         = ["AzureServices"]
  }

  tags = var.tags
}

# ── Events container ──────────────────────────────────────────────────────────
resource "azurerm_storage_container" "events" {
  name                  = var.events_container_name
  storage_account_id    = azurerm_storage_account.this.id
  container_access_type = "private"
}

# ── Private endpoint (blob) ───────────────────────────────────────────────────
# Gives the cluster an in-VNet path to the account. The db-load-events Job
# resolves the account's blob FQDN to a private IP via the linked DNS zone.
resource "azurerm_private_endpoint" "blob" {
  name                = "pe-${var.name}-blob"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.private_endpoint_subnet_id

  private_service_connection {
    name                           = "psc-${var.name}-blob"
    private_connection_resource_id = azurerm_storage_account.this.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "blob"
    private_dns_zone_ids = [var.private_dns_zone_id]
  }

  tags = var.tags
}

# ── Role assignments ──────────────────────────────────────────────────────────
# Storage Blob Data Reader on the events container, per consuming principal.
# Scoped to the container (not the account) — least privilege. The module
# owns its own access policy, matching the keyvault/redis pattern.
resource "azurerm_role_assignment" "blob_reader" {
  for_each = var.blob_reader_principal_ids

  scope                = azurerm_storage_container.events.resource_manager_id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = each.value
}

# ── Diagnostics ───────────────────────────────────────────────────────────────
resource "azurerm_monitor_diagnostic_setting" "this" {
  name                       = "diag-${var.name}"
  target_resource_id         = "${azurerm_storage_account.this.id}/blobServices/default"
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "StorageRead"
  }
  enabled_log {
    category = "StorageWrite"
  }

  metric {
    category = "Transaction"
  }
}
