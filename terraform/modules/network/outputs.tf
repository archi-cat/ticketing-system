output "vnet_id" {
  description = "Virtual network resource ID"
  value       = azurerm_virtual_network.main.id
}

output "vnet_name" {
  description = "Virtual network name"
  value       = azurerm_virtual_network.main.name
}

output "subnet_ids" {
  description = "Map of subnet name to subnet ID"
  value = {
    aks_system        = azurerm_subnet.aks_system.id
    aks_user          = azurerm_subnet.aks_user.id
    agc               = azurerm_subnet.agc.id
    private_endpoints = azurerm_subnet.private_endpoints.id
    postgres          = azurerm_subnet.postgres.id
  }
}

output "private_dns_zone_ids" {
  description = "Map of service name to Private DNS zone resource ID — used by PaaS modules to wire up Private Endpoints"
  value       = { for k, v in azurerm_private_dns_zone.this : k => v.id }
}

output "private_dns_zone_names" {
  description = "Map of service name to Private DNS zone name"
  value       = { for k, v in azurerm_private_dns_zone.this : k => v.name }
}