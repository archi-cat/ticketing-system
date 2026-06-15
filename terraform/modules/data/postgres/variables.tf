variable "location" {
  description = "Azure region"
  type        = string
}

variable "resource_group_name" {
  description = "Resource group for the PostgreSQL server"
  type        = string
}

variable "server_name" {
  description = "PostgreSQL server name (globally unique, lowercase alphanumeric and hyphens, 3-63 chars)"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", var.server_name))
    error_message = "Server name must be 3-63 characters, lowercase alphanumeric and hyphens, starting and ending with alphanumeric."
  }
}

variable "postgres_version" {
  description = "PostgreSQL major version"
  type        = string
  default     = "18"
}

variable "sku_name" {
  description = "SKU name (e.g. 'B_Standard_B1ms' for Burstable B1ms)"
  type        = string
  default     = "B_Standard_B1ms"
}

variable "storage_mb" {
  description = "Storage size in MB. Minimum 32768 (32 GB) on Burstable."
  type        = number
  default     = 32768
}

variable "backup_retention_days" {
  description = "Backup retention in days (7-35). Minimum 7 on Burstable."
  type        = number
  default     = 7

  validation {
    condition     = var.backup_retention_days >= 7 && var.backup_retention_days <= 35
    error_message = "Backup retention must be between 7 and 35 days."
  }
}

variable "delegated_subnet_id" {
  description = "Subnet ID for VNet injection. Must be delegated to Microsoft.DBforPostgreSQL/flexibleServers."
  type        = string
}

variable "private_dns_zone_id" {
  description = "Private DNS zone ID for postgres.database.azure.com. The network module exports this."
  type        = string
}

variable "entra_admin_principal_id" {
  description = "Object ID of the Entra ID principal that will be the initial admin (typically the human operator setting up the system)"
  type        = string
}

variable "entra_admin_principal_name" {
  description = "Display name or UPN of the Entra ID admin (used as the friendly name in Azure)"
  type        = string
}

variable "entra_admin_principal_type" {
  description = "Principal type — 'User', 'Group', or 'ServicePrincipal'"
  type        = string
  default     = "User"

  validation {
    condition     = contains(["User", "Group", "ServicePrincipal"], var.entra_admin_principal_type)
    error_message = "Principal type must be 'User', 'Group', or 'ServicePrincipal'."
  }
}

variable "database_name" {
  description = "Name of the application database to create on the server"
  type        = string
  default     = "ticketing"
}

variable "shared_preload_libraries" {
  description = <<-EOT
    Complete value for the shared_preload_libraries server parameter. This is a
    STATIC parameter — changing it restarts the server. Azure writes the whole
    list (no append), so the value must include the version's default libraries
    plus any extension that needs preloading. The default preserves the
    documented PG18 default (pg_cron,pg_stat_statements) and appends pgaudit for
    audit logging. Query Store / HA libraries (pg_qs, pgms_wait_sampling,
    pg_availability) are managed by Azure outside this parameter and are
    unaffected. If Azure's default for your version/SKU differs, the apply fails
    validation loudly — capture the live value with
    'az postgres flexible-server parameter show -n shared_preload_libraries' and
    set it here.
  EOT
  type        = string
  default     = "pg_cron,pg_stat_statements,pgaudit"
}

variable "log_analytics_workspace_id" {
  description = "Log Analytics workspace ID for diagnostic settings"
  type        = string
}

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default     = {}
}
