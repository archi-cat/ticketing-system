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

data "azurerm_client_config" "current" {}

# ── Resource group ────────────────────────────────────────────────────────────
# All regional resources land here. The shared ACR has its own resource group
# in its own state — referenced via remote state below.

resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

# ── Reference the shared ACR via remote state ─────────────────────────────────
# We need the ACR's resource ID to grant AcrPull to the AKS kubelet identity,
# but the ACR is managed in its own Terraform configuration. Reading the
# remote state directly is the cleanest way to wire shared resources.

data "terraform_remote_state" "acr" {
  backend = "azurerm"
  config = {
    resource_group_name  = "rg-terraform-state"
    storage_account_name = "stterraformstatefloryda"
    container_name       = "tfstate-ticketing"
    key                  = "shared-acr.tfstate"
  }
}

# ── Network ───────────────────────────────────────────────────────────────────
# Provisions the VNet, subnets (including delegated AGC and PostgreSQL subnets),
# NSGs, and the five Private DNS zones for PaaS services.

module "network" {
  source = "../../modules/network"

  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  vnet_name           = "vnet-ticketing-uksouth"
  address_space       = var.vnet_address_space

  subnet_prefixes = {
    aks_system        = "10.10.1.0/24"
    aks_user          = "10.10.2.0/24"
    agc               = "10.10.3.0/24"
    private_endpoints = "10.10.4.0/24"
    postgres          = "10.10.5.0/24"
  }

  tags = var.tags
}

# ── Observability ─────────────────────────────────────────────────────────────
# Created early so that AKS and the data layer can wire diagnostics into it.

module "observability" {
  source = "../../modules/observability"

  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  name_prefix         = "ticketing-uksouth"

  retention_in_days      = 30
  daily_ingestion_cap_gb = 1

  application_insights_instances = {
    api     = { application_type = "web" }
    workers = { application_type = "web" }
  }

  tags = var.tags
}

# ── AKS cluster ───────────────────────────────────────────────────────────────
# Created before identity because identity needs the cluster's OIDC issuer URL
# to set up federated credentials. The dependency graph handles this.

module "aks" {
  source = "../../modules/aks"

  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  cluster_name        = "aks-ticketing-uksouth"

  system_subnet_id = module.network.subnet_ids.aks_system
  user_subnet_id   = module.network.subnet_ids.aks_user

  log_analytics_workspace_id = module.observability.log_analytics_workspace_id

  tags = var.tags
}

# Grant the AKS kubelet identity AcrPull on the shared ACR.
# Has to live here because both sides (AKS and ACR) span different states.

resource "azurerm_role_assignment" "aks_acr_pull" {
  scope                = data.terraform_remote_state.acr.outputs.acr_id
  role_definition_name = "AcrPull"
  principal_id         = module.aks.kubelet_identity_object_id

  # skip_service_principal_aad_check is needed because the kubelet identity
  # is managed and may not be visible to AAD by the time the assignment runs
  skip_service_principal_aad_check = true
}

# ── Workload Identity ─────────────────────────────────────────────────────────
# Three UAMIs (api, worker, scheduler) federated to Kubernetes service accounts
# in the 'ticketing' namespace. This must come AFTER the AKS module because
# it consumes the cluster's OIDC issuer URL.

module "identity" {
  source = "../../modules/identity"

  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  name_prefix         = "uami-ticketing-uksouth"

  oidc_issuer_url      = module.aks.oidc_issuer_url
  kubernetes_namespace = "ticketing"

  service_accounts = {
    api       = "api-service-account"
    worker    = "worker-service-account"
    scheduler = "scheduler-service-account"
  }

  tags = var.tags
}

# ── Data layer ────────────────────────────────────────────────────────────────

# PostgreSQL — VNet injected, AAD-only auth
module "postgres" {
  source = "../../modules/data/postgres"

  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  server_name         = "psql-ticketing-uksouth-${var.name_suffix}"

  delegated_subnet_id = module.network.subnet_ids.postgres
  private_dns_zone_id = module.network.private_dns_zone_ids.postgres

  entra_admin_principal_id   = var.postgres_entra_admin_object_id
  entra_admin_principal_name = var.postgres_entra_admin_name
  entra_admin_principal_type = var.postgres_entra_admin_principal_type

  log_analytics_workspace_id = module.observability.log_analytics_workspace_id

  tags = var.tags
}

# Redis — Premium with Private Endpoint
module "redis" {
  source = "../../modules/data/redis"

  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  cache_name          = "redis-ticketing-uksouth-${var.name_suffix}"

  private_endpoint_subnet_id = module.network.subnet_ids.private_endpoints
  private_dns_zone_id        = module.network.private_dns_zone_ids.redis

  log_analytics_workspace_id = module.observability.log_analytics_workspace_id

  tags = var.tags
}

# Service Bus — Premium with Private Endpoint, SAS auth disabled
module "servicebus" {
  source = "../../modules/data/servicebus"

  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  namespace_name      = "sb-ticketing-uksouth-${var.name_suffix}"

  topics = {
    "reservation-events" = {
      subscriptions = {
        "seat-decrement" = {}
        "audit-log"      = {}
      }
    }
    "booking-events" = {
      subscriptions = {
        "confirmation-email" = {}
        "audit-log"          = {}
      }
    }
  }

  private_endpoint_subnet_id = module.network.subnet_ids.private_endpoints
  private_dns_zone_id        = module.network.private_dns_zone_ids.servicebus

  log_analytics_workspace_id = module.observability.log_analytics_workspace_id

  tags = var.tags
}

# Key Vault — RBAC, Private Endpoint, bootstrap Redis key
module "keyvault" {
  source = "../../modules/data/keyvault"

  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  vault_name          = "kv-ticketing-uks-${var.name_suffix}"
  tenant_id           = data.azurerm_client_config.current.tenant_id

  private_endpoint_subnet_id = module.network.subnet_ids.private_endpoints
  private_dns_zone_id        = module.network.private_dns_zone_ids.keyvault

  log_analytics_workspace_id = module.observability.log_analytics_workspace_id

  # Bootstrap the Redis access key as a secret
  secrets = {
    "redis-primary-key" = {
      value = module.redis.primary_access_key
    }
  }

  # Application UAMIs read secrets
  secret_reader_principal_ids = {
    api       = module.identity.identity_principal_ids.api
    worker    = module.identity.identity_principal_ids.worker
    scheduler = module.identity.identity_principal_ids.scheduler
  }

  # GitHub Actions SP can manage secrets
  secret_officer_principal_ids = {
    github_actions = var.gh_actions_sp_object_id
  }

  tags = var.tags
}

# ── Service Bus role assignments ──────────────────────────────────────────────
# API publishes events → Sender role
# Worker consumes events → Receiver role
# Scheduler doesn't touch Service Bus directly

resource "azurerm_role_assignment" "api_sb_sender" {
  scope                = module.servicebus.namespace_id
  role_definition_name = "Azure Service Bus Data Sender"
  principal_id         = module.identity.identity_principal_ids.api
}

resource "azurerm_role_assignment" "worker_sb_receiver" {
  scope                = module.servicebus.namespace_id
  role_definition_name = "Azure Service Bus Data Receiver"
  principal_id         = module.identity.identity_principal_ids.worker
}