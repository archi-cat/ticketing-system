output "namespace_id" {
  description = "Service Bus namespace resource ID"
  value       = azurerm_servicebus_namespace.main.id
}

output "namespace_name" {
  description = "Service Bus namespace name"
  value       = azurerm_servicebus_namespace.main.name
}

output "namespace_endpoint" {
  description = "Service Bus namespace endpoint — used by Azure Service Bus SDK in passwordless mode"
  value       = azurerm_servicebus_namespace.main.endpoint
}

output "fully_qualified_namespace" {
  description = "FQDN of the namespace (e.g. 'sb-ticketing.servicebus.windows.net'). Apps use this in passwordless connections."
  value       = "${azurerm_servicebus_namespace.main.name}.servicebus.windows.net"
}

output "topic_ids" {
  description = "Map of topic name to topic resource ID"
  value       = { for k, v in azurerm_servicebus_topic.this : k => v.id }
}

output "topic_names" {
  description = "List of topic names — used by application code"
  value       = [for k, v in azurerm_servicebus_topic.this : v.name]
}

output "subscription_ids" {
  description = "Map of 'topic/subscription' to subscription resource ID. Used by role assignments."
  value       = { for k, v in azurerm_servicebus_subscription.this : k => v.id }
}