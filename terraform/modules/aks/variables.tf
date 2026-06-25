variable "location" {
  description = "Azure region"
  type        = string
}

variable "resource_group_name" {
  description = "Resource group for the AKS cluster"
  type        = string
}

variable "node_resource_group" {
  description = <<-EOT
    Name of the AKS-managed node resource group (VMSS, kubelet identity,
    add-on identities, NSGs, disks). Azure requires this to differ from
    the cluster's own resource group. Setting it explicitly makes the
    name predictable for downstream lookups.
  EOT
  type        = string
}

variable "cluster_name" {
  description = "AKS cluster name"
  type        = string
}

variable "kubernetes_version" {
  description = <<-EOT
    Kubernetes major.minor version (e.g. '1.35'). Patches are managed by Azure.
    Avoid versions that have moved to LTS-only — they require Premium tier.
    Run `az aks get-versions --location <region>` to see currently supported versions.
  EOT
  type        = string
  default     = "1.35"
}

variable "system_subnet_id" {
  description = "Subnet ID for the system node pool"
  type        = string
}

variable "user_subnet_id" {
  description = "Subnet ID for the user node pool"
  type        = string
}

variable "system_node_count" {
  description = "Number of nodes in the system pool"
  type        = number
  default     = 2

  validation {
    condition     = var.system_node_count >= 2
    error_message = "System node pool must have at least 2 nodes for high availability of cluster-critical pods."
  }
}

variable "user_node_count" {
  description = "Number of nodes in the user pool"
  type        = number
  default     = 2
}

variable "vm_size" {
  description = "VM size for both node pools (B-series chosen to fit default subscription quotas)"
  type        = string
  default     = "Standard_B2s"
}

variable "log_analytics_workspace_id" {
  description = "Log Analytics workspace ID for AKS monitoring (Container Insights)"
  type        = string
}

# ── Private cluster (Phase 3 Tier 3 #13 / ADR-0035) ───────────────────────────

variable "cluster_identity_id" {
  description = <<-EOT
    Resource ID of the user-assigned identity used as the cluster's control
    plane identity. A user-assigned (not system-assigned) identity is required
    because a BYO private DNS zone must be granted to the identity BEFORE the
    cluster is created — which a system-assigned identity, not existing until
    creation, cannot satisfy. The caller pre-grants this identity Network
    Contributor on the node subnets' VNet and Private DNS Zone Contributor on
    private_dns_zone_id.
  EOT
  type        = string
}

variable "private_dns_zone_id" {
  description = <<-EOT
    Resource ID of the BYO private DNS zone (privatelink.<region>.azmk8s.io)
    where the private API server's A record is registered. Owned by the caller
    (the network module) so it can be linked to the hub VNet too — letting the
    in-VNet runner resolve the API FQDN. The cluster identity must hold Private
    DNS Zone Contributor on it.
  EOT
  type        = string
}

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default     = {}
}
