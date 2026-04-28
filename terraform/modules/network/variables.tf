variable "location" {
  description = "Azure region for the VNet and all subnets"
  type        = string
}

variable "resource_group_name" {
  description = "Resource group where the VNet will be created"
  type        = string
}

variable "vnet_name" {
  description = "Name of the virtual network"
  type        = string
}

variable "address_space" {
  description = "VNet address space (e.g. 10.10.0.0/16)"
  type        = string

  validation {
    condition     = can(cidrhost(var.address_space, 0))
    error_message = "address_space must be a valid CIDR block."
  }
}

variable "subnet_prefixes" {
  description = "Subnet CIDR prefixes — must be subsets of address_space"
  type = object({
    aks_system        = string
    aks_user          = string
    agc               = string
    private_endpoints = string
    postgres          = string
  })
}

variable "tags" {
  description = "Tags applied to all resources in the module"
  type        = map(string)
  default     = {}
}