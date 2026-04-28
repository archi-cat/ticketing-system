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

variable "kubernetes_namespace" {
  description = "Kubernetes namespace where the application service accounts live"
  type        = string
  default     = "ticketing"
}

variable "service_accounts" {
  description = <<-EOT
    Map of logical service name to its Kubernetes service account name.
    A UAMI is created for each entry, federated to that service account.
  EOT
  type        = map(string)
  default = {
    api       = "api-service-account"
    worker    = "worker-service-account"
    scheduler = "scheduler-service-account"
  }
}

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default     = {}
}