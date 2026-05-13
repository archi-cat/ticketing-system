output "id" {
  description = "Resource ID of the Managed Redis instance."
  value       = azurerm_managed_redis.main.id
}

output "name" {
  description = "Name of the Managed Redis instance."
  value       = azurerm_managed_redis.main.name
}

output "hostname" {
  description = "Hostname clients use to connect."
  value       = azurerm_managed_redis.main.hostname
}

output "port" {
  description = "TLS port. Always 10000 for AMR."
  value       = 10000
}

# Note: no more primary_access_key — Entra ID auth means no key to surface.