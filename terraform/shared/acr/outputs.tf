output "acr_id" {
  description = "ACR resource ID — needed for role assignments from regional environments"
  value       = azurerm_container_registry.main.id
}

output "acr_login_server" {
  description = "ACR login server URL — used by AKS to pull images"
  value       = azurerm_container_registry.main.login_server
}

output "acr_name" {
  description = "ACR name"
  value       = azurerm_container_registry.main.name
}

output "resource_group_name" {
  description = "Shared resource group name"
  value       = azurerm_resource_group.shared.name
}