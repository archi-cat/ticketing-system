variable "location" {
  description = "Azure region"
  type        = string
}

variable "resource_group_name" {
  description = "Resource group for the AKS cluster"
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

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default     = {}
}