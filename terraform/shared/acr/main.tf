terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
  required_version = ">= 1.9.0"
}

provider "azurerm" {
  subscription_id = var.subscription_id
  features {}
  skip_provider_registration = true
}

# ── Resource Group ────────────────────────────────────────────────────────────
# Shared resources live in their own resource group so they can be managed
# independently of the regional environments

resource "azurerm_resource_group" "shared" {
  name     = var.resource_group_name
  location = var.primary_location
  tags     = var.tags
}

# ── Container Registry — Premium with geo-replication ────────────────────────
# Premium tier is required for:
#   - Geo-replication across Azure regions
#   - Private Endpoints (used in Phase 2)
#   - Content trust and image signing (optional, future hardening)

resource "azurerm_container_registry" "main" {
  name                = var.acr_name
  resource_group_name = azurerm_resource_group.shared.name
  location            = azurerm_resource_group.shared.location
  sku                 = "Premium"

  # Disable admin user — we will use Workload Identity / managed identities
  # for authentication. Admin credentials are a long-lived secret to avoid.
  admin_enabled = false

  # Geo-replication target — images pushed to uksouth are replicated
  # automatically to westeurope. AKS clusters in either region pull from
  # the geographically nearest replica.
  georeplications {
    location                = var.secondary_location
    zone_redundancy_enabled = false # zone redundancy not needed at learning scale

    tags = var.tags
  }

  # Disable public network access in Phase 2 — for now, leave on so we can
  # validate the deployment before adding Private Endpoints
  public_network_access_enabled = true

  # Retention policy — automatically delete untagged manifests older than 7 days
  # Keeps the registry tidy as we push many image tags during development
  retention_policy_in_days = 7

  # Trust policy — disabled for now, will enable in Phase 2 hardening
  trust_policy_enabled = false

  tags = var.tags
}