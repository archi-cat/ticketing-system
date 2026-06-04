variable "resource_group_name" {
  description = "Resource group for the action group and alert rules"
  type        = string
}

variable "location" {
  description = "Azure region (action group is global, but standard web tests need a location)"
  type        = string
}

variable "alert_email_address" {
  description = "Email address that receives all alert notifications"
  type        = string

  validation {
    condition     = can(regex("^[^@]+@[^@]+\\.[^@]+$", var.alert_email_address))
    error_message = "alert_email_address must look like an email address."
  }
}

# ── App Insights ─────────────────────────────────────────────────────────────

variable "app_insights_api_id" {
  description = "App Insights resource ID for the API service — scope for the API 5xx and latency alerts, parent for the URL ping test"
  type        = string
}

variable "app_insights_workers_id" {
  description = "App Insights resource ID for the worker+scheduler instance — scope for the scheduler stalled alert"
  type        = string
}

# ── Data layer ───────────────────────────────────────────────────────────────

variable "postgres_server_id" {
  description = "PostgreSQL Flexible Server resource ID — scope for the Postgres metric alerts"
  type        = string
}

variable "postgres_max_connections" {
  description = "Postgres max_connections setting — used to compute the connections-threshold (defaults to the B_Standard_B1ms default of 50)"
  type        = number
  default     = 50
}

variable "servicebus_namespace_id" {
  description = "Service Bus namespace resource ID — scope for the DLQ depth alert"
  type        = string
}

# ── AKS ──────────────────────────────────────────────────────────────────────

variable "aks_cluster_id" {
  description = "AKS managed cluster resource ID — reserved (currently no metric alerts scoped to the cluster; node CPU / memory alerts query Log Analytics instead because Insights.Container/nodes percentage metrics are not exposed as Azure Monitor Metrics)"
  type        = string
}

variable "log_analytics_workspace_id" {
  description = "Log Analytics workspace resource ID — scope for the AKS node CPU / memory scheduled query alerts (Container Insights InsightsMetrics table)"
  type        = string
}

# ── URL ping test ────────────────────────────────────────────────────────────

variable "ping_target_url" {
  description = "Full URL the standard web test pings — typically https://<duckdns-fqdn>/health"
  type        = string
}

# ── Thresholds (tunable defaults) ────────────────────────────────────────────

variable "api_5xx_threshold" {
  description = "Number of API 5xx responses in a 10-minute window that triggers the alert"
  type        = number
  default     = 5
}

variable "api_p99_latency_ms_threshold" {
  description = "p99 API latency (milliseconds) over a 10-minute window that triggers the alert"
  type        = number
  default     = 2000
}

variable "scheduler_stalled_window_minutes" {
  description = "If the scheduler hasn't emitted any traces in this many minutes, alert. The scheduler should log its sweep activity at least every few minutes."
  type        = number
  default     = 15
}

variable "postgres_cpu_threshold" {
  description = "Postgres CPU % (10-min average) that triggers the alert"
  type        = number
  default     = 80
}

variable "servicebus_dlq_threshold" {
  description = "Service Bus deadletter queue depth that triggers the alert (>0 means any DLQ message pages)"
  type        = number
  default     = 0
}

variable "aks_node_cpu_threshold" {
  description = "AKS per-node CPU usage % (10-min average) that triggers the alert"
  type        = number
  default     = 80
}

variable "aks_node_memory_threshold" {
  description = "AKS per-node memory working-set % (10-min average) that triggers the alert"
  type        = number
  default     = 85
}

variable "tags" {
  description = "Tags applied to all alert resources"
  type        = map(string)
  default     = {}
}
