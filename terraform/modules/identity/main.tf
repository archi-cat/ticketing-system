terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
  required_version = ">= 1.9.0"
}

# ── User-Assigned Managed Identities ──────────────────────────────────────────
# One UAMI per application service. Each is independently grantable, so
# the API can access the database without the worker also gaining access.

resource "azurerm_user_assigned_identity" "this" {
  for_each = var.service_accounts

  name                = "${var.name_prefix}-${each.key}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

# ── Federated Identity Credentials ────────────────────────────────────────────
# Each UAMI trusts tokens from the AKS cluster's OIDC issuer, but only when
# the token's `sub` claim matches the specific Kubernetes service account.
# This is what makes Workload Identity secure — a different service account
# in the same cluster cannot impersonate this UAMI.

resource "azurerm_federated_identity_credential" "this" {
  for_each = var.service_accounts

  name                = "fic-${each.key}-workload-identity"
  resource_group_name = var.resource_group_name
  parent_id           = azurerm_user_assigned_identity.this[each.key].id

  audience = ["api://AzureADTokenExchange"]
  issuer   = var.oidc_issuer_url
  subject  = "system:serviceaccount:${var.kubernetes_namespace}:${each.value}"
}