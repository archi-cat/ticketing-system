terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
  required_version = ">= 1.9.0"
}

# ── Key Vault ─────────────────────────────────────────────────────────────────

resource "azurerm_key_vault" "main" {
  name                = var.vault_name
  location            = var.location
  resource_group_name = var.resource_group_name
  tenant_id           = var.tenant_id
  sku_name            = "standard"

  # ── Authorisation model ─────────────────────────────────────────────────────
  # RBAC, not access policies. Consistent with the rest of the project.
  enable_rbac_authorization = true

  # ── Soft delete and purge protection ────────────────────────────────────────
  # Soft delete is on by default and cannot be disabled. Purge protection is
  # opt-in and irreversible once enabled — it prevents permanent deletion
  # within the soft-delete retention window even by Key Vault Administrators.
  soft_delete_retention_days = var.soft_delete_retention_days
  purge_protection_enabled   = false

  # ── Network access ──────────────────────────────────────────────────────────
  # Public access is enabled but tightly controlled by network_acls.
  # The Private Endpoint provides primary access from the VNet; the IP
  # allow-list lets Terraform/CLI calls reach the vault from outside the VNet
  # for secret management.
  public_network_access_enabled = true

  network_acls {
    default_action = "Deny"
    bypass         = "AzureServices"
    ip_rules       = var.allowed_ip_ranges
  }

  tags = var.tags
}

# ── RBAC role assignments ─────────────────────────────────────────────────────
# Application UAMIs get 'Key Vault Secrets User' (read-only).
# CI/operator principals get 'Key Vault Secrets Officer' (read-write).
# No principal here gets 'Key Vault Administrator' — that should be assigned
# manually to the human operator when needed for break-glass access.

resource "azurerm_role_assignment" "secret_reader" {
  for_each = var.secret_reader_principal_ids

  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = each.value
}

resource "azurerm_role_assignment" "secret_officer" {
  for_each = var.secret_officer_principal_ids

  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = each.value
}

# ── Private Endpoint ──────────────────────────────────────────────────────────

resource "azurerm_private_endpoint" "keyvault" {
  name                = "pe-${var.vault_name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.private_endpoint_subnet_id

  private_service_connection {
    name                           = "psc-${var.vault_name}"
    private_connection_resource_id = azurerm_key_vault.main.id
    is_manual_connection           = false
    subresource_names              = ["vault"]
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [var.private_dns_zone_id]
  }

  tags = var.tags
}

# ── Bootstrap secrets ─────────────────────────────────────────────────────────
# Secrets sourced from Terraform-managed resources (e.g. Redis keys) flow
# through this resource. Application/operational secrets should be created
# separately via `az keyvault secret set` rather than passed through Terraform.
#
# `depends_on` on the role assignment because creating a secret requires the
# CI principal to have Secrets Officer rights — without explicit dependency,
# Terraform may try to create the secret before the role assignment lands,
# causing a transient permission error.

resource "azurerm_key_vault_secret" "bootstrap" {
  for_each = nonsensitive(toset(keys(var.secrets)))

  name         = each.value
  value        = var.secrets[each.value].value
  content_type = var.secrets[each.value].content_type
  key_vault_id = azurerm_key_vault.main.id

  depends_on = [
    azurerm_role_assignment.secret_officer,
  ]
}

# ── Diagnostic settings ───────────────────────────────────────────────────────

resource "azurerm_monitor_diagnostic_setting" "keyvault" {
  name                       = "diag-${var.vault_name}"
  target_resource_id         = azurerm_key_vault.main.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "AuditEvent"
  }

  enabled_log {
    category = "AzurePolicyEvaluationDetails"
  }

  metric {
    category = "AllMetrics"
  }
}