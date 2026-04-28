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
  description = "Kubernetes version (e.g. '1.30'). Use major.minor only — patches are managed by Azure."
  type        = string
  default     = "1.30"
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