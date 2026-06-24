# ─── Storage account for event-data files ────────────────────────────────────
# Holds the JSON event files consumed by the db-load-events bootstrap Job.
#
# Network model (see ADR-0019, ADR-0032):
#  - Private-endpoint only. public_network_access_enabled = false — there is
#    no public path in or out. The cluster reaches the account via the blob
#    private endpoint below (db-load-events read; event-upload Job write).
#  - The operator laptop-upload path is gone: the in-cluster event-upload Job
#    (ADR-0032) writes over the same private endpoint, so closing the public
#    endpoint (Phase 3 #14) removed the last public surface on the data layer.
#
# Terraform note: with public access off, the deployer (out-of-VNet) can't run
# the provider's data-plane availability poll, so the env sets the provider
# feature storage.data_plane_available = false. The account therefore declares
# no queue_properties/static_website blocks (data-plane), and the container is
# managed via the Resource Manager API (storage_account_id) — control-plane.
#
# Auth is Entra-only — shared access keys are disabled. Consuming UAMIs read/
# write blobs via their container-scoped role assignments below.

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
  public_network_access_enabled     = false # Private-endpoint only (Phase 3 #14)
  infrastructure_encryption_enabled = true

  # ── Network rules ──────────────────────────────────────────────────────────
  # Defence in depth: deny by default. With public_network_access_enabled =
  # false above, no public traffic reaches the account regardless — but keeping
  # default_action = "Deny" means an accidental re-enable of public access
  # still fails closed. The cluster reaches the account via the private
  # endpoint below, not these rules.
  network_rules {
    default_action = "Deny"
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

# Storage Blob Data Contributor (write) on the events container, for the
# in-cluster event-upload Job's identity. Scoped to the container, like the
# reader assignment above. This is what replaces the operator's laptop
# `az storage blob upload` — see ADR-0032.
resource "azurerm_role_assignment" "blob_writer" {
  for_each = var.blob_writer_principal_ids

  scope                = azurerm_storage_container.events.resource_manager_id
  role_definition_name = "Storage Blob Data Contributor"
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
