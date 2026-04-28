output "log_analytics_workspace_id" {
  description = "Log Analytics workspace resource ID — consumed by AKS Container Insights and resource diagnostic settings"
  value       = azurerm_log_analytics_workspace.main.id
}

output "log_analytics_workspace_name" {
  description = "Log Analytics workspace name"
  value       = azurerm_log_analytics_workspace.main.name
}

output "log_analytics_workspace_customer_id" {
  description = "Log Analytics workspace customer ID (workspace ID GUID, not resource ID)"
  value       = azurerm_log_analytics_workspace.main.workspace_id
}

output "application_insights_connection_strings" {
  description = "Map of logical name to App Insights connection string — injected as environment variable into the corresponding pod"
  value       = { for k, v in azurerm_application_insights.this : k => v.connection_string }
  sensitive   = true
}

output "application_insights_instrumentation_keys" {
  description = "Map of logical name to instrumentation key — provided for legacy SDK compatibility; prefer connection strings"
  value       = { for k, v in azurerm_application_insights.this : k => v.instrumentation_key }
  sensitive   = true
}

output "application_insights_ids" {
  description = "Map of logical name to App Insights resource ID — needed for alert rule scoping"
  value       = { for k, v in azurerm_application_insights.this : k => v.id }
}