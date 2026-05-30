variable "subscription_id" {
  description = "Azure subscription ID"
  type        = string
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "uksouth"
}

variable "resource_group_name" {
  description = "Resource group for all regional resources"
  type        = string
  default     = "rg-ticketing-uksouth"
}

variable "name_suffix" {
  description = "Short suffix for globally-unique resource names (e.g. your initials or org code)"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{2,8}$", var.name_suffix))
    error_message = "Name suffix must be 2-8 lowercase alphanumeric characters."
  }
}

# ── Network ───────────────────────────────────────────────────────────────────

variable "vnet_address_space" {
  description = "VNet CIDR. Non-overlapping with westeurope (10.20.0.0/16)."
  type        = string
  default     = "10.10.0.0/16"
}

# ── Identity ──────────────────────────────────────────────────────────────────

variable "gh_actions_sp_object_id" {
  description = "Object ID of the GitHub Actions service principal (sp-hello-world-github). Granted Key Vault Secrets Officer."
  type        = string
}

# ── PostgreSQL ────────────────────────────────────────────────────────────────

variable "postgres_entra_admin_object_id" {
  description = "Object ID of the Entra ID principal that becomes the bootstrap PostgreSQL admin (typically your user)"
  type        = string
}

variable "postgres_entra_admin_name" {
  description = "Display name or UPN of the PostgreSQL bootstrap admin"
  type        = string
}

variable "postgres_entra_admin_principal_type" {
  description = "Principal type — User, Group, or ServicePrincipal"
  type        = string
  default     = "User"
}

# ── Gateway TLS (Phase 3 Tier 1 #1) ───────────────────────────────────────────

variable "duckdns_fqdn" {
  description = "Full DuckDNS FQDN for the Gateway, e.g. ticketing-floryda.duckdns.org. The subdomain must already be reserved on duckdns.org."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]+\\.duckdns\\.org$", var.duckdns_fqdn))
    error_message = "duckdns_fqdn must look like '<subdomain>.duckdns.org' (lowercase alphanumeric + hyphens in the subdomain)."
  }
}

variable "acme_email" {
  description = "Email registered with Let's Encrypt — receives expiry-warning notifications"
  type        = string

  validation {
    condition     = can(regex("^[^@]+@[^@]+\\.[^@]+$", var.acme_email))
    error_message = "acme_email must look like an email address."
  }
}

variable "duckdns_token_kv_secret_name" {
  description = "Name of the Key Vault secret holding the DuckDNS API token. Set the value manually with `az keyvault secret set` after the vault exists."
  type        = string
  default     = "duckdns-api-token"
}

# ── Tags ──────────────────────────────────────────────────────────────────────

variable "tags" {
  description = "Tags applied to all resources in this environment"
  type        = map(string)
  default = {
    project     = "ticketing-system"
    environment = "primary"
    region      = "uksouth"
    managed_by  = "terraform"
  }
}
