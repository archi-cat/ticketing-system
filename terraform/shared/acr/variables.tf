variable "subscription_id" {
  description = "Azure subscription ID"
  type        = string
}

variable "primary_location" {
  description = "Primary Azure region (where ACR is provisioned)"
  type        = string
  default     = "uksouth"
}

variable "secondary_location" {
  description = "Secondary Azure region (geo-replication target)"
  type        = string
  default     = "westeurope"
}

variable "resource_group_name" {
  description = "Resource group for shared resources"
  type        = string
  default     = "rg-ticketing-shared"
}

variable "acr_name" {
  description = "Container Registry name (globally unique, alphanumeric only, 5-50 chars)"
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9]{5,50}$", var.acr_name))
    error_message = "ACR name must be 5-50 alphanumeric characters with no hyphens or underscores."
  }
}

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default = {
    project     = "ticketing-system"
    managed_by  = "terraform"
    environment = "shared"
  }
}