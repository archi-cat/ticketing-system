variable "location" {
  description = "Azure region for all observability resources"
  type        = string
}

variable "resource_group_name" {
  description = "Resource group for the workspace and App Insights instances"
  type        = string
}

variable "name_prefix" {
  description = "Prefix applied to resource names (e.g. 'ticketing-uksouth')"
  type        = string
}

variable "retention_in_days" {
  description = "Log retention period for the Log Analytics workspace"
  type        = number
  default     = 30

  validation {
    condition     = var.retention_in_days >= 7 && var.retention_in_days <= 730
    error_message = "Retention must be between 7 and 730 days."
  }
}

variable "daily_ingestion_cap_gb" {
  description = "Daily ingestion cap in GB. Prevents runaway costs from accidental log volume spikes."
  type        = number
  default     = 1
}

variable "application_insights_instances" {
  description = <<-EOT
    Map of logical name to App Insights instance. One instance is created per entry.
    The 'api' instance is typically separate from worker/scheduler so that user-facing
    latency telemetry can be sampled and alerted independently from background work.
  EOT
  type = map(object({
    application_type = string
  }))
  default = {
    api     = { application_type = "web" }
    workers = { application_type = "web" }
  }
}

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default     = {}
}