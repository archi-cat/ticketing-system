variable "location" {
  description = "Azure region for the UAMIs"
  type        = string
}

variable "resource_group_name" {
  description = "Resource group where the UAMIs will be created"
  type        = string
}

variable "name_prefix" {
  description = "Prefix applied to all UAMI names (e.g. 'uami-ticketing-uksouth')"
  type        = string
}

variable "oidc_issuer_url" {
  description = "OIDC issuer URL of the AKS cluster — used as the issuer in federated credentials"
  type        = string
}

variable "service_accounts" {
  description = <<-EOT
    Map of workload identity key to its Kubernetes binding.

    The key is the logical name (e.g. "api", "worker", "scheduler", "alb").
    Each entry specifies the Kubernetes namespace AND service account name
    the UAMI is federated to.

    Example:
      service_accounts = {
        api = {
          namespace       = "ticketing"
          service_account = "api-service-account"
        }
        alb = {
          namespace       = "kube-system"
          service_account = "alb-controller-sa"
        }
      }
  EOT
  type = map(object({
    namespace       = string
    service_account = string
  }))
}

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default     = {}
}
