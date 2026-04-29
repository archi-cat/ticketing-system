variable "location" {
  description = "Azure region"
  type        = string
}

variable "resource_group_name" {
  description = "Resource group for the Key Vault"
  type        = string
}

variable "vault_name" {
  description = "Key Vault name (globally unique, alphanumeric and hyphens, 3-24 chars, must start with a letter)"
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9-]{1,22}[a-zA-Z0-9]$", var.vault_name))
    error_message = "Vault name must be 3-24 chars, start with a letter, end alphanumeric, contain only letters/digits/hyphens."
  }
}

variable "tenant_id" {
  description = "Azure AD tenant ID — typically passed as data.azurerm_client_config.current.tenant_id"
  type        = string
}

variable "soft_delete_retention_days" {
  description = "Soft delete retention period (7-90 days)"
  type        = number
  default     = 7

  validation {
    condition     = var.soft_delete_retention_days >= 7 && var.soft_delete_retention_days <= 90
    error_message = "Soft delete retention must be between 7 and 90 days."
  }
}

variable "private_endpoint_subnet_id" {
  description = "Subnet ID for the Private Endpoint NIC"
  type        = string
}

variable "private_dns_zone_id" {
  description = "Private DNS zone ID for vaultcore.azure.net"
  type        = string
}

variable "log_analytics_workspace_id" {
  description = "Log Analytics workspace ID for diagnostic settings"
  type        = string
}

variable "secrets" {
  description = <<-EOT
    Map of secret name to value to bootstrap into the vault. Used for cases where
    Terraform receives a value from another resource (e.g. Redis primary key) that
    needs to become a Key Vault secret.

    For application secrets that humans manage (API keys for third-party services,
    etc.), prefer setting them via the Azure CLI or portal rather than passing
    them through Terraform inputs.

    Note: secret VALUES are treated as sensitive at the resource level. The map
    KEYS are not sensitive — they appear in resource addresses (which is required
    by Terraform's for_each). Choose secret names that don't themselves leak
    information.
  EOT
  type = map(object({
    value        = string
    content_type = optional(string, "text/plain")
  }))
  default = {}
}

variable "secret_reader_principal_ids" {
  description = <<-EOT
    Map of logical name to principal ID for principals that should receive
    'Key Vault Secrets User' on the vault. Logical names (the map keys) must
    be plan-time-known strings — they form part of the resource address.
  EOT
  type        = map(string)
  default     = {}
}

variable "secret_officer_principal_ids" {
  description = <<-EOT
    Map of logical name to principal ID for principals that should receive
    'Key Vault Secrets Officer' on the vault. Typically the GitHub Actions
    service principal so CI can manage secrets.
  EOT
  type        = map(string)
  default     = {}
}

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default     = {}
}

variable "allowed_ip_ranges" {
  description = <<-EOT
    Public IP ranges allowed to access the vault, in addition to Private Endpoint
    access. Used to allow Terraform/CLI calls to manage secrets from outside the
    VNet. Empty list means only Private Endpoint access (which prevents Terraform
    from managing secret values).

    Format: list of CIDRs, e.g. ["203.0.113.5/32", "198.51.100.0/24"]
  EOT
  type        = list(string)
  default     = []
}