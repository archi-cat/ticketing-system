variable "location" {
  description = "Azure region"
  type        = string
}

variable "resource_group_name" {
  description = "Resource group for the Redis cache"
  type        = string
}

variable "cache_name" {
  description = "Redis cache name (globally unique, lowercase alphanumeric and hyphens, 1-63 chars)"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,61}[a-z0-9]$", var.cache_name))
    error_message = "Cache name must be 1-63 chars, lowercase alphanumeric and hyphens, starting and ending with alphanumeric."
  }
}

variable "sku_name" {
  description = "Redis SKU — must be Premium for Private Endpoints"
  type        = string
  default     = "Premium"

  validation {
    condition     = var.sku_name == "Premium"
    error_message = "This module requires Premium SKU. Lower SKUs do not support Private Endpoints."
  }
}

variable "capacity" {
  description = "Premium SKU capacity (1, 2, 3, 4, 5 corresponding to P1, P2, P3, P4, P5)"
  type        = number
  default     = 1

  validation {
    condition     = contains([1, 2, 3, 4, 5], var.capacity)
    error_message = "Premium capacity must be 1-5."
  }
}

variable "private_endpoint_subnet_id" {
  description = "Subnet ID for the Private Endpoint NIC"
  type        = string
}

variable "private_dns_zone_id" {
  description = "Private DNS zone ID for redis.cache.windows.net"
  type        = string
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