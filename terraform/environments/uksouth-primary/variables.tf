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
# Most TLS-related values (DUCKDNS_FQDN, ACME_EMAIL, DUCKDNS_API_TOKEN) are
# applied to the cluster directly by the infra-uksouth workflow as repo
# secrets — see k8s/cluster-addons/cert-pipeline/. The duckdns_fqdn IS also
# needed at Terraform plan-time for the alerts module's URL ping test, so
# it's surfaced here from the same DUCKDNS_FQDN secret.

variable "duckdns_fqdn" {
  description = "Full DuckDNS FQDN for the Gateway, e.g. ticketing-floryda.duckdns.org. Used by the alerts module to construct the URL ping test target."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]+\\.duckdns\\.org$", var.duckdns_fqdn))
    error_message = "duckdns_fqdn must look like '<subdomain>.duckdns.org' (lowercase alphanumeric + hyphens in the subdomain)."
  }
}

# ── Alerting (Phase 3 Tier 1 #3) ──────────────────────────────────────────────

variable "alert_email_address" {
  description = "Email address that receives all baseline alerts. Reuses the ACME_EMAIL secret for this learning project — in real production this would be a separate operations distribution list."
  type        = string

  validation {
    condition     = can(regex("^[^@]+@[^@]+\\.[^@]+$", var.alert_email_address))
    error_message = "alert_email_address must look like an email address."
  }
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
