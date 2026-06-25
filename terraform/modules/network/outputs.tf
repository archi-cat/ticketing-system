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

output "aks_api_dns_zone_id" {
  description = "BYO private DNS zone ID for the private AKS API server (privatelink.<region>.azmk8s.io). Passed to the AKS module as private_dns_zone_id, and granted to the cluster identity."
  value       = azurerm_private_dns_zone.aks_api.id
}

output "aks_api_dns_zone_name" {
  description = "BYO private DNS zone name for the private AKS API server — used to link the zone to the hub VNet."
  value       = azurerm_private_dns_zone.aks_api.name
}
