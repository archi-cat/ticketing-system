variable "location" {
  description = "Azure region"
  type        = string
}

variable "resource_group_name" {
  description = "Resource group for the Service Bus namespace"
  type        = string
}

variable "namespace_name" {
  description = "Service Bus namespace name (globally unique, alphanumeric and hyphens, 6-50 chars)"
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9-]{4,48}[a-zA-Z0-9]$", var.namespace_name))
    error_message = "Namespace name must be 6-50 chars, start with a letter, end alphanumeric, contain only letters/digits/hyphens."
  }
}

variable "sku" {
  description = "Service Bus SKU — must be Premium for Private Endpoints and geo-DR"
  type        = string
  default     = "Premium"

  validation {
    condition     = var.sku == "Premium"
    error_message = "This module requires Premium SKU. Standard/Basic do not support Private Endpoints or geo-DR."
  }
}

variable "messaging_units" {
  description = "Premium messaging units (1, 2, 4, 8, 16). Higher units add capacity proportionally."
  type        = number
  default     = 1

  validation {
    condition     = contains([1, 2, 4, 8, 16], var.messaging_units)
    error_message = "Messaging units must be one of: 1, 2, 4, 8, 16."
  }
}

variable "topics" {
  description = <<-EOT
    Map of topic name to topic configuration. The application's event flow lives here.
    Each topic can have multiple subscriptions, each with its own filter.
  EOT
  type = map(object({
    max_size_in_megabytes = optional(number, 1024)

    subscriptions = map(object({
      max_delivery_count                   = optional(number, 10)
      lock_duration                        = optional(string, "PT1M")
      default_message_ttl                  = optional(string, "P14D")
      dead_lettering_on_message_expiration = optional(bool, true)
      sql_filter                           = optional(string, "1=1") # accept all by default
    }))
  }))
}

variable "private_endpoint_subnet_id" {
  description = "Subnet ID for the Private Endpoint NIC"
  type        = string
}

variable "private_dns_zone_id" {
  description = "Private DNS zone ID for servicebus.windows.net"
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

variable "premium_messaging_partitions" {
  description = "Number of premium messaging partitions (1, 2, or 4). Higher values increase parallelism."
  type        = number
  default     = 1

  validation {
    condition     = contains([1, 2, 4], var.premium_messaging_partitions)
    error_message = "premium_messaging_partitions must be 1, 2, or 4."
  }
}