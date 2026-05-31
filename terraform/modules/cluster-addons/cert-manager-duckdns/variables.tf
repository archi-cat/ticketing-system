variable "cert_manager_namespace" {
  description = "Namespace where cert-manager is installed (the webhook lives here too)"
  type        = string
  default     = "cert-manager"
}

variable "cluster_secret_store_name" {
  description = "Name of the ESO ClusterSecretStore pointing at Key Vault — typically the output of the external-secrets module"
  type        = string
}

variable "duckdns_token_kv_secret_name" {
  description = "Name of the Key Vault secret containing the DuckDNS API token (set manually with `az keyvault secret set`)"
  type        = string
  default     = "duckdns-api-token"
}

variable "acme_email" {
  description = "Email registered with Let's Encrypt — receives expiry-warning notifications"
  type        = string

  validation {
    condition     = can(regex("^[^@]+@[^@]+\\.[^@]+$", var.acme_email))
    error_message = "acme_email must look like an email address."
  }
}

variable "webhook_group_name" {
  description = "ACME webhook groupName. Used by ClusterIssuers to route DNS-01 challenges to this webhook. Free-form but must match between webhook and issuer."
  type        = string
  default     = "acme.duckdns.org"
}

variable "webhook_chart_version" {
  description = "cert-manager-webhook-duckdns Helm chart version. Distributed via OCI at oci://ghcr.io/cobexer/charts. Releases: https://github.com/cobexer/cert-manager-webhook-duckdns/releases"
  type        = string
  default     = "2.0.0"
}
