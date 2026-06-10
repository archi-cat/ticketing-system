terraform {
  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
    }
    azapi = {
      source = "Azure/azapi"
    }
    time = {
      source = "hashicorp/time"
    }
  }
}

resource "azurerm_kubernetes_cluster" "main" {
  name                = var.cluster_name
  location            = var.location
  resource_group_name = var.resource_group_name
  node_resource_group = var.node_resource_group
  dns_prefix          = var.cluster_name
  kubernetes_version  = var.kubernetes_version

  # RBAC is enabled by default on AKS and cannot be disabled; stating it
  # explicitly documents the intent and satisfies static analysis.
  role_based_access_control_enabled = true

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

# Brief settle window after the cluster reports ready, before we PATCH it.
# Reduces the chance of colliding with AKS post-provisioning operations.
resource "time_sleep" "cluster_settle" {
  depends_on      = [azurerm_kubernetes_cluster.main, azurerm_kubernetes_cluster_node_pool.user]
  create_duration = "60s"
}

# ─── AGC and Gateway API add-ons ──────────────────────────────────────────────
# The azurerm provider doesn't surface the ingressProfile settings that
# enable the Application Gateway for Containers add-on and the managed
# Gateway API installation. We use the azapi provider to PATCH these onto
# the cluster.
#
# This installs:
# - The ALB Controller into kube-system
# - The Gateway API CRDs
# - The AKS-managed UAMI 'applicationloadbalancer-<cluster-name>' in the
#   node resource group, with role assignments scoped to the node RG

resource "azapi_update_resource" "ingress_profile" {
  type        = "Microsoft.ContainerService/managedClusters@2025-09-02-preview"
  resource_id = azurerm_kubernetes_cluster.main.id

  body = {
    properties = {
      ingressProfile = {
        applicationLoadBalancer = {
          enabled = true
        }
        gatewayAPI = {
          installation = "Standard"
        }
      }
    }
  }

  # AKS allows only one mutating operation on a cluster at a time. The
  # cluster can finish creating (provisioningState=Succeeded) while
  # internal post-provisioning operations are still settling. A PATCH
  # landing in that window is rejected with AKSOperationPreempted.
  # Retry on that specific error — it clears once the prior op finishes.
  retry = {
    error_message_regex  = ["AKSOperationPreempted", "OperationNotAllowed"]
    interval_seconds     = 30
    max_interval_seconds = 300
  }

  depends_on = [time_sleep.cluster_settle]

  timeouts {
    update = "30m"
  }
}

# In the aks module, after azapi_update_resource.ingress_profile
resource "time_sleep" "ingress_profile_settle" {
  depends_on      = [azapi_update_resource.ingress_profile]
  create_duration = "180s"
}

# ─── Advanced Container Networking Services (ACNS) ───────────────────────────
# Enables:
# - Cilium network policy enforcement (security.enabled) — eBPF L3/L4
# - Cilium FQDN-based egress filtering (security.advancedNetworkPolicies =
#   "FQDN") — deploys the DNS proxy needed by the CiliumNetworkPolicy
#   `toFQDNs` rules in k8s/cluster-addons/network-policies/ for egress to
#   login.microsoftonline.com and *.in.applicationinsights.azure.com.
#   NB: security.enabled alone does NOT enable this.
# - Hubble observability (observability.enabled) — flow visibility for
#   debugging policy drops
#
# Not surfaced via the azurerm provider's network_profile block as of writing,
# so we PATCH via azapi the same way we enable the AGC ingress profile above.
# Sequential on top of the ingress_profile_settle to avoid AKSOperationPreempted.

resource "azapi_update_resource" "acns" {
  type        = "Microsoft.ContainerService/managedClusters@2025-09-02-preview"
  resource_id = azurerm_kubernetes_cluster.main.id

  body = {
    properties = {
      networkProfile = {
        advancedNetworking = {
          enabled = true
          observability = {
            enabled = true
          }
          security = {
            enabled = true
            # security.enabled alone only turns on eBPF L3/L4 policy
            # enforcement — it does NOT deploy the DNS proxy that populates
            # the FQDN cache behind `toFQDNs` rules. Without this setting,
            # FQDN egress silently matches nothing, and policies carrying an
            # explicit `rules.dns` block are rejected by the Cilium agent
            # with "L7 policy is not supported since L7 proxy is not enabled".
            # "FQDN" = DNS proxy + FQDN filtering (what our network policies
            # need). "L7" would additionally enable Envoy-based HTTP/gRPC/
            # Kafka rules — not needed, heavier footprint.
            advancedNetworkPolicies = "FQDN"
          }
        }
      }
    }
  }

  depends_on = [time_sleep.ingress_profile_settle]

  retry = {
    error_message_regex  = ["AKSOperationPreempted", "OperationNotAllowed"]
    interval_seconds     = 30
    max_interval_seconds = 300
  }

  timeouts {
    update = "30m"
  }
}
