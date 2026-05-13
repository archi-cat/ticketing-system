variable "name" {
  description = "Name of the Managed Redis instance."
  type        = string

  validation {
    condition     = length(var.name) >= 1 && length(var.name) <= 63
    error_message = "name must be between 1 and 63 characters."
  }

  validation {
    condition     = can(regex("^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$", var.name))
    error_message = "name must contain only letters, digits, and hyphens, and must start and end with a letter or digit."
  }

  validation {
    condition     = !can(regex("--", var.name))
    error_message = "name must not contain consecutive hyphens."
  }
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "resource_group_name" {
  description = "Name of the resource group."
  type        = string
}

variable "sku_name" {
  description = "AMR SKU. Balanced_B0 is the smallest. Balanced_B1, B3, B5, B10 are larger."
  type        = string
  default     = "Balanced_B0"

  validation {
    condition     = can(regex("^Balanced_B[0-9]+$", var.sku_name))
    error_message = "sku_name must be of the form Balanced_Bn (e.g. Balanced_B0, Balanced_B1)."
  }
}

variable "high_availability_enabled" {
  description = "Whether the Redis cluster should be highly available across availability zones."
  type        = bool
  default     = true
}

variable "private_endpoints_subnet_id" {
  description = "Subnet ID for the Private Endpoint."
  type        = string
}

variable "private_dns_zone_id" {
  description = "Private DNS zone ID for AMR (must be the region-specific zone)."
  type        = string
}

variable "consumer_object_ids" {
  description = <<-EOT
    Map of consumer name → principal object ID of the UAMI that needs
    Entra ID access to the cache. Each entry results in one access policy
    assignment on the default database.
  EOT
  type        = map(string)
  default     = {}
}

variable "diagnostic_settings_enabled" {
  description = "Whether to create the diagnostic setting that streams to Log Analytics."
  type        = bool
  default     = true
}

variable "log_analytics_workspace_id" {
  description = "Log Analytics workspace ID for diagnostic settings"
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default     = {}
}