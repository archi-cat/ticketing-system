terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.3"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.2"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.2"
    }
  }
  required_version = ">= 1.9.0"
}

provider "azurerm" {
  subscription_id = var.subscription_id

  features {
    # The event-data storage account runs private-endpoint-only
    # (public_network_access_enabled = false — Phase 3 #14). With public
    # access off, the provider's post-create data-plane "availability" poll of
    # the blob service endpoint can't reach the account from the out-of-VNet
    # deployer — it hangs ~2 min, then errors (azurerm #30893). This account
    # uses no queue_properties/static_website blocks and its container is
    # managed via the Resource Manager API (storage_account_id), so turning the
    # data-plane path off lets terraform manage the fully-private account with
    # control-plane calls only. It is the only storage account in this config.
    storage {
      data_plane_available = false
    }
  }

  skip_provider_registration = true
  storage_use_azuread        = true
}

provider "azapi" {
  # Inherits auth from the same Azure CLI / OIDC context as azurerm.
  # No explicit config needed.
}

# ── Kubernetes-adjacent providers ─────────────────────────────────────────────
# helm + kubernetes both authenticate against the AKS API server using the
# client cert/key from kube_config (the cluster keeps local accounts enabled).
# CRD-typed manifests (ClusterSecretStore, ClusterIssuer, Certificate,
# ExternalSecret, PushSecret) are NOT applied via Terraform — they live in
# k8s/cluster-addons/cert-pipeline/ and are applied by the infra-uksouth
# workflow's post-apply step with `envsubst | kubectl apply`. That split keeps
# Terraform's resource graph clean of CRDs whose provider can't defer config
# until apply time.
#
# The cluster is PRIVATE (ADR-0035): module.aks.host is the private API FQDN,
# which only resolves and routes from inside the VNet. Both this apply (these
# providers) and the post-apply kubectl steps therefore run on the in-VNet
# self-hosted runner — see infra-uksouth.yml. Auth is unchanged: #13 changed the
# network PATH, not the auth model (AAD / local-account-disable is a separate
# future item), so cert/key auth from kube_config still applies.

provider "helm" {
  kubernetes = {
    host                   = module.aks.host
    cluster_ca_certificate = base64decode(module.aks.cluster_ca_certificate)
    client_certificate     = base64decode(module.aks.client_certificate)
    client_key             = base64decode(module.aks.client_key)
  }
}

provider "kubernetes" {
  host                   = module.aks.host
  cluster_ca_certificate = base64decode(module.aks.cluster_ca_certificate)
  client_certificate     = base64decode(module.aks.client_certificate)
  client_key             = base64decode(module.aks.client_key)
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

# ── Reference the durable platform layer via remote state ─────────────────────
# The hub VNet + self-hosted runner (terraform/platform). We need the hub VNet
# ID to peer the spoke to it and to link the private API DNS zone to the hub so
# the runner resolves the API FQDN. The platform is a FOUNDATIONAL layer (like
# the shared ACR and the TF state account) — it must be deployed before this
# environment can plan or apply. See ADR-0035.

data "terraform_remote_state" "platform" {
  backend = "azurerm"
  config = {
    resource_group_name  = "rg-terraform-state"
    storage_account_name = "stterraformstatefloryda"
    container_name       = "tfstate-ticketing"
    key                  = "platform.tfstate"
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

# ── Hub ↔ spoke peering + API DNS link (Phase 3 Tier 3 #13 / ADR-0035) ─────────
# The private API server is reachable only from inside the VNet. The self-hosted
# runner that runs this apply lives in the durable HUB VNet, so we peer the
# per-deploy spoke to the hub (both directions, managed from here so they're
# created/destroyed with each regional loop) and link the private API DNS zone
# to the hub — together these let the runner resolve and reach the API FQDN.
# The cluster add-ons depend on these being in place (see their depends_on).

resource "azurerm_virtual_network_peering" "spoke_to_hub" {
  name                         = "peer-spoke-to-hub"
  resource_group_name          = azurerm_resource_group.main.name
  virtual_network_name         = module.network.vnet_name
  remote_virtual_network_id    = data.terraform_remote_state.platform.outputs.hub_vnet_id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
}

resource "azurerm_virtual_network_peering" "hub_to_spoke" {
  name                         = "peer-hub-to-spoke"
  resource_group_name          = data.terraform_remote_state.platform.outputs.hub_resource_group_name
  virtual_network_name         = data.terraform_remote_state.platform.outputs.hub_vnet_name
  remote_virtual_network_id    = module.network.vnet_id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
}

# Link the private API DNS zone (in the spoke) to the hub VNet so the runner
# resolves the API server's A record to its private IP.
resource "azurerm_private_dns_zone_virtual_network_link" "aks_api_hub" {
  name                  = "aks-api-hub-link"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = module.network.aks_api_dns_zone_name
  virtual_network_id    = data.terraform_remote_state.platform.outputs.hub_vnet_id
  registration_enabled  = false
  tags                  = var.tags
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

# ── AKS control-plane identity (Phase 3 Tier 3 #13 / ADR-0035) ────────────────
# User-assigned identity for the private cluster's control plane. Pre-created
# (not system-assigned) so it can be granted the BYO private DNS zone and the
# node VNet BEFORE the cluster is created. Network Contributor on the spoke VNet
# lets AKS manage the node subnets + load balancer; Private DNS Zone Contributor
# on the API zone lets it register the API server's A record. The kubelet
# identity stays auto-managed by AKS (which handles its own Managed Identity
# Operator grant). A short wait lets the role assignments propagate before the
# cluster create consumes them.

resource "azurerm_user_assigned_identity" "aks_control_plane" {
  name                = "uami-aks-ticketing-uksouth-cp"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags
}

resource "azurerm_role_assignment" "aks_cp_network_contributor" {
  scope                = module.network.vnet_id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.aks_control_plane.principal_id
}

resource "azurerm_role_assignment" "aks_cp_private_dns" {
  scope                = module.network.aks_api_dns_zone_id
  role_definition_name = "Private DNS Zone Contributor"
  principal_id         = azurerm_user_assigned_identity.aks_control_plane.principal_id
}

resource "time_sleep" "aks_cp_role_propagation" {
  depends_on = [
    azurerm_role_assignment.aks_cp_network_contributor,
    azurerm_role_assignment.aks_cp_private_dns,
  ]
  create_duration = "60s"
}

# ── AKS cluster ───────────────────────────────────────────────────────────────
# Created before identity because identity needs the cluster's OIDC issuer URL
# to set up federated credentials. The dependency graph handles this.

module "aks" {
  source = "../../modules/aks"

  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  node_resource_group = "${var.resource_group_name}-aks-nodes"
  cluster_name        = "aks-ticketing-uksouth"

  system_subnet_id = module.network.subnet_ids.aks_system
  user_subnet_id   = module.network.subnet_ids.aks_user

  # Private cluster (ADR-0035): user-assigned control-plane identity + BYO
  # private DNS zone, both wired above and pre-granted before this applies.
  cluster_identity_id = azurerm_user_assigned_identity.aks_control_plane.id
  private_dns_zone_id = module.network.aks_api_dns_zone_id

  log_analytics_workspace_id = module.observability.log_analytics_workspace_id

  tags = var.tags

  depends_on = [time_sleep.aks_cp_role_propagation]
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

# Look up the ALB Controller UAMI auto-provisioned by the AGC add-on.
#
# This data source depends on the AKS module's ingress_profile output.
# Because that output comes from a resource created during apply, Terraform
# defers this data read to apply time — after the add-on is enabled and
# the UAMI exists.
#
# The add-on creates this UAMI in the node resource group with a
# deterministic name: 'applicationloadbalancer-<cluster-name>'.
data "azurerm_user_assigned_identity" "alb_controller_addon" {
  name                = "applicationloadbalancer-${module.aks.cluster_name}"
  resource_group_name = module.aks.node_resource_group

  depends_on = [module.aks]
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

  oidc_issuer_url = module.aks.oidc_issuer_url

  service_accounts = {
    api = {
      namespace       = "ticketing",
      service_account = "api-service-account"
    }
    worker = {
      namespace       = "ticketing",
      service_account = "worker-service-account"
    }
    scheduler = {
      namespace       = "ticketing",
      service_account = "scheduler-service-account"
    }
    # ── Database bootstrap identities ──────────────────────────────────────
    # db-migrator: runs the migration and event-load Jobs. A non-admin
    # Postgres Entra principal with DDL + DML rights on the ticketing DB.
    # Never elevated, never changes state.
    db-migrator = {
      namespace       = "ticketing"
      service_account = "db-migrator-service-account"
    }

    # db-grant: runs the grant Job only. Has NO standing Postgres rights —
    # a human elevates it to a Postgres Entra admin for a single grant run,
    # and the grant Job self-revokes that elevation as its final step.
    db-grant = {
      namespace       = "ticketing"
      service_account = "db-grant-service-account"
    }

    # event-uploader: runs the event-upload Job only. Its ONLY privilege is
    # Storage Blob Data Contributor on the events container (granted via the
    # storage module's blob_writer_principal_ids) — no Postgres rights at all.
    # Deliberately separate from db-migrator: writing event files is a distinct
    # blast radius from changing the database schema. See ADR-0032.
    event-uploader = {
      namespace       = "ticketing"
      service_account = "event-uploader-service-account"
    }
  }

  tags = var.tags
}

# ── AGC ───────────────────────────────────────────────────────────────────────
module "agc" {
  source = "../../modules/AGC"

  name                = "agc-ticketing-${var.name_suffix}"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name

  subnet_id                   = module.network.subnet_ids.agc
  vnet_id                     = module.network.vnet_id
  alb_controller_principal_id = data.azurerm_user_assigned_identity.alb_controller_addon.principal_id

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

# Redis — Azure managed Redis
module "redis" {
  source = "../../modules/data/redis"

  name                = "redis-ticketing-uksouth-${var.name_suffix}"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name

  sku_name                  = "Balanced_B0"
  high_availability_enabled = true

  private_endpoints_subnet_id = module.network.subnet_ids.private_endpoints
  private_dns_zone_id         = module.network.private_dns_zone_ids.managed_redis

  # Grant each application UAMI Entra ID access on the default database.
  # These are the principal object IDs, NOT the client IDs — Redis's
  # access policy assignment is identity-based, not OIDC-token-issuer-based.
  consumer_object_ids = {
    api       = module.identity.identity_principal_ids.api
    worker    = module.identity.identity_principal_ids.worker
    scheduler = module.identity.identity_principal_ids.scheduler
  }

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

# ── Detect the IP running terraform apply ─────────────────────────────────────
# Used to allow Terraform-controlled access to the Key Vault, which otherwise
# would be unreachable from outside the VNet.

data "http" "myip" {
  url = "https://api.ipify.org"
}

locals {
  deployer_ip_cidr = "${chomp(data.http.myip.response_body)}/32"
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

  allowed_ip_ranges = [
    local.deployer_ip_cidr,
    # Add GitHub Actions runner ranges if running from CI:
    # "4.148.0.0/16", etc. — see https://api.github.com/meta
  ]

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

# ── Event-data storage ────────────────────────────────────────────────────────
# Storage account holding the JSON event files the db-load-events bootstrap
# Job loads into the database. Private-endpoint only — public_network_access is
# disabled (Phase 3 #14). The cluster reads over the blob private endpoint, and
# the in-cluster event-upload Job (ADR-0032) replaced the operator laptop
# upload, so no public path is needed. Terraform manages the account with
# control-plane calls only (provider features: storage.data_plane_available =
# false), which is why the deployer no longer needs a Storage Blob Data Reader
# grant here — the old availability poll that required it is turned off.
module "storage" {
  source = "../../modules/data/storage"

  name                = "stticketinguks${var.name_suffix}"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name

  private_endpoint_subnet_id = module.network.subnet_ids.private_endpoints
  private_dns_zone_id        = module.network.private_dns_zone_ids.blob

  # db-migrator reads event files from the events container.
  blob_reader_principal_ids = {
    db-migrator = module.identity.identity_principal_ids["db-migrator"]
  }

  # event-uploader writes event files (the in-cluster upload Job — ADR-0032).
  blob_writer_principal_ids = {
    event-uploader = module.identity.identity_principal_ids["event-uploader"]
  }

  log_analytics_workspace_id = module.observability.log_analytics_workspace_id

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

# ── Cluster add-ons ───────────────────────────────────────────────────────────
# cert-manager, External Secrets Operator, and Kyverno. All installed via
# Terraform's Helm provider rather than kubectl-apply in a workflow — keeps
# add-on lifecycle, version pinning, and drift detection in the same state as
# the rest of the infrastructure.

module "cert_manager" {
  source = "../../modules/cluster-addons/cert-manager"

  # The helm/kubernetes providers can only reach the PRIVATE API server once the
  # spoke↔hub peering and the hub API-DNS link exist — order every add-on that
  # talks to the API after them (ADR-0035).
  depends_on = [
    azurerm_virtual_network_peering.spoke_to_hub,
    azurerm_virtual_network_peering.hub_to_spoke,
    azurerm_private_dns_zone_virtual_network_link.aks_api_hub,
  ]
}

# Kyverno — cluster-level Cosign signature enforcement (Phase 3 Tier 2 #7).
# Installs the engine + CRDs only; the image-signature ClusterPolicies live in
# k8s/cluster-addons/kyverno-policies/ and are applied by the infra-uksouth
# workflow's post-apply step. See ADR-0031.
module "kyverno" {
  source = "../../modules/cluster-addons/kyverno"

  # Kyverno verifies image signatures by pulling from the private ACR. Give it
  # the kubelet identity's client id (already holds AcrPull) so its azure
  # credential helper authenticates via IMDS — no separate identity needed.
  acr_pull_client_id = module.aks.kubelet_identity_client_id

  # Reach the private API only after the in-VNet path is up (ADR-0035).
  depends_on = [
    azurerm_virtual_network_peering.spoke_to_hub,
    azurerm_virtual_network_peering.hub_to_spoke,
    azurerm_private_dns_zone_virtual_network_link.aks_api_hub,
  ]
}

module "external_secrets" {
  source = "../../modules/cluster-addons/external-secrets"

  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  name_prefix         = "uami-ticketing-uksouth"
  oidc_issuer_url     = module.aks.oidc_issuer_url

  key_vault_id = module.keyvault.vault_id

  tags = var.tags

  # Reach the private API only after the in-VNet path is up (ADR-0035).
  depends_on = [
    azurerm_virtual_network_peering.spoke_to_hub,
    azurerm_virtual_network_peering.hub_to_spoke,
    azurerm_private_dns_zone_virtual_network_link.aks_api_hub,
  ]
}

# ── Gateway TLS — cert flow (Phase 3 Tier 1 #1) ───────────────────────────────
# This module installs the DuckDNS cert-manager webhook (Helm release only).
# The CRD-typed resources for the cert pipeline — ClusterSecretStore,
# ExternalSecret (DuckDNS token sync), ClusterIssuers (staging + production),
# Certificate, and PushSecret — live in k8s/cluster-addons/cert-pipeline/
# and are applied by the infra-uksouth workflow's post-apply step.

module "cert_manager_duckdns" {
  source = "../../modules/cluster-addons/cert-manager-duckdns"

  cert_manager_namespace = module.cert_manager.namespace

  # The cobexer chart's templates include cert-manager Certificate and Issuer
  # resources (for the webhook's own self-signed TLS), so the cert-manager
  # CRDs must be registered AND its admission webhook must be operational
  # before this release applies. The implicit dependency via the namespace
  # input only orders against kubernetes_namespace_v1, not against the
  # helm_release that installs the CRDs — hence the explicit depends_on.
  depends_on = [module.cert_manager]
}

# ── Baseline alerts (Phase 3 Tier 1 #3) ───────────────────────────────────────
# Action group + 8 alerts + 1 URL ping test, all routed to alert_email_address.
# See the alerts module README for the per-alert thresholds and rationale.

module "alerts" {
  source = "../../modules/alerts"

  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
  alert_email_address = var.alert_email_address

  app_insights_api_id     = module.observability.application_insights_ids.api
  app_insights_workers_id = module.observability.application_insights_ids.workers

  postgres_server_id      = module.postgres.server_id
  servicebus_namespace_id = module.servicebus.namespace_id
  aks_cluster_id          = module.aks.cluster_id

  log_analytics_workspace_id = module.observability.log_analytics_workspace_id

  ping_target_url = "https://${var.duckdns_fqdn}/health"

  tags = var.tags
}
