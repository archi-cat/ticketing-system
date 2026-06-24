variable "name" {
  description = <<-EOT
    Storage account name. Must be globally unique, 3-24 chars, lowercase
    letters and digits only (Azure storage account naming rules).
  EOT
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{3,24}$", var.name))
    error_message = "Storage account name must be 3-24 lowercase alphanumeric characters."
  }
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group for the storage account."
  type        = string
}

variable "events_container_name" {
  description = "Name of the blob container that holds event-data files."
  type        = string
  default     = "events"
}

variable "private_endpoint_subnet_id" {
  description = "Subnet ID for the blob private endpoint. Use module.network.subnet_ids.private_endpoints."
  type        = string
}

variable "private_dns_zone_id" {
  description = "Private DNS zone ID for blob (privatelink.blob.core.windows.net). Use module.network.private_dns_zone_ids.blob."
  type        = string
}

variable "blob_reader_principal_ids" {
  description = <<-EOT
    Map of logical name to principal (object) ID granted Storage Blob
    Data Reader on the events container. Keyed for readable role
    assignments. e.g. { db-migrator = "<principal id>" }.
  EOT
  type        = map(string)
  default     = {}
}

variable "blob_writer_principal_ids" {
  description = <<-EOT
    Map of logical name to principal (object) ID granted Storage Blob
    Data Contributor (write) on the events container. Used by the
    in-cluster event-upload Job's identity. e.g. { event-uploader = "<principal id>" }.
  EOT
  type        = map(string)
  default     = {}
}

variable "log_analytics_workspace_id" {
  description = "Log Analytics workspace ID for diagnostic settings."
  type        = string
}

variable "tags" {
  description = "Tags applied to all resources in this module."
  type        = map(string)
  default     = {}
}
