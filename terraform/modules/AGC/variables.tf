variable "name" {
  description = "Name of the Application Gateway for Containers resource."
  type        = string

  validation {
    condition     = length(var.name) >= 1 && length(var.name) <= 80
    error_message = "name must be between 1 and 80 characters."
  }

  validation {
    condition     = can(regex("^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$", var.name))
    error_message = "name must contain only letters, digits, and hyphens, and must start and end with a letter or digit."
  }
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group to deploy AGC into."
  type        = string
}

variable "vnet_id" {
  description = <<-EOT
    Resource ID of the VNet containing the AGC subnet. The ALB Controller
    UAMI is granted Network Contributor at this scope — its subnet
    reconciliation touches the VNet, so subnet scope is insufficient.

    Use module.network.vnet_id.
  EOT
  type        = string
}

variable "subnet_id" {
  description = <<-EOT
    Resource ID of the AGC subnet. The subnet must have the
    Microsoft.ServiceNetworking/trafficControllers delegation. Use
    module.network.subnet_ids.agc.
  EOT
  type        = string
}

variable "alb_controller_principal_id" {
  description = <<-EOT
    Principal (object) ID of the ALB Controller UAMI. Used in role
    assignments scoped to this module's AGC resource and the AGC subnet.

    The UAMI is created by the identity module — wire this via
    module.identity.identity_principal_ids.alb.
  EOT
  type        = string
}

variable "tags" {
  description = "Tags applied to all resources in this module."
  type        = map(string)
  default     = {}
}