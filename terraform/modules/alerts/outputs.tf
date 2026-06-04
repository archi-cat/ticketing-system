output "action_group_id" {
  description = "Resource ID of the Action Group — surface for any additional alerts created outside this module that should route to the same email."
  value       = azurerm_monitor_action_group.this.id
}

output "action_group_name" {
  description = "Name of the Action Group."
  value       = azurerm_monitor_action_group.this.name
}
