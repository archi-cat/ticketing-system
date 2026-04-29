terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
  required_version = ">= 1.9.0"
}

resource "azurerm_kubernetes_cluster" "main" {
  name                = var.cluster_name
  location            = var.location
  resource_group_name = var.resource_group_name
  dns_prefix          = var.cluster_name
  kubernetes_version  = var.kubernetes_version

  # ── Workload Identity ───────────────────────────────────────────────────────
  # OIDC issuer must be enabled so Azure AD can validate tokens issued by the
  # cluster. workload_identity_enabled installs the mutating webhook that
  # injects projected tokens into pods.
  workload_identity_enabled = true
  oidc_issuer_enabled       = true

  # ── System node pool ────────────────────────────────────────────────────────
  # Tainted to repel application pods. Hosts kube-system, ALB Controller,
  # Workload Identity webhook, and other cluster-critical components.
  default_node_pool {
    name           = "system"
    node_count     = var.system_node_count
    vm_size        = var.vm_size
    vnet_subnet_id = var.system_subnet_id

    # The CriticalAddonsOnly taint repels pods that don't tolerate it.
    # Cluster-critical Microsoft components have this toleration built in.
    only_critical_addons_enabled = true

    upgrade_settings {
      max_surge = "33%"
    }

    tags = var.tags
  }

  # ── Cluster identity ────────────────────────────────────────────────────────
  # System-assigned identity for the cluster control plane. This identity
  # manages Azure resources on behalf of the cluster (load balancers, disks).
  # Application pod authentication uses Workload Identity, not this identity.
  identity {
    type = "SystemAssigned"
  }

  # ── Networking ──────────────────────────────────────────────────────────────
  # Azure CNI Overlay — node IPs from VNet, pod IPs from overlay address space.
  # Cilium for NetworkPolicy enforcement.
  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_policy      = "cilium"
    network_data_plane  = "cilium"
    pod_cidr            = "10.244.0.0/16"
    service_cidr        = "10.0.0.0/16"
    dns_service_ip      = "10.0.0.10"
    outbound_type       = "loadBalancer"
  }

  # ── Observability ───────────────────────────────────────────────────────────
  # Container Insights — sends node and pod metrics/logs to Log Analytics.
  oms_agent {
    log_analytics_workspace_id      = var.log_analytics_workspace_id
    msi_auth_for_monitoring_enabled = true
  }

  # ── Misc cluster settings ───────────────────────────────────────────────────
  # Image cleaner — periodically removes vulnerable container images from nodes.
  image_cleaner_enabled        = true
  image_cleaner_interval_hours = 48

  # Auto-upgrade — opt into the stable channel so patch versions update
  # automatically. Major.minor stays pinned to var.kubernetes_version.
  automatic_upgrade_channel = "patch"
  node_os_upgrade_channel   = "NodeImage"

  tags = var.tags

  lifecycle {
    # Default node pool changes (e.g. node_count from autoscaler) should not
    # trigger a Terraform diff during normal operation.
    ignore_changes = [
      default_node_pool[0].node_count,
    ]
  }
}

# ── User node pool ────────────────────────────────────────────────────────────
# Hosts application workloads. Separate node pool means application pods
# cannot starve cluster-critical services of resources.

resource "azurerm_kubernetes_cluster_node_pool" "user" {
  name                  = "user"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.main.id
  vm_size               = var.vm_size
  node_count            = var.user_node_count
  vnet_subnet_id        = var.user_subnet_id

  upgrade_settings {
    max_surge = "33%"
  }

  tags = var.tags

  lifecycle {
    ignore_changes = [node_count]
  }
}