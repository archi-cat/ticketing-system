output "cache_id" {
  description = "Redis cache resource ID"
  value       = azurerm_redis_cache.main.id
}

output "cache_name" {
  description = "Redis cache name"
  value       = azurerm_redis_cache.main.name
}

output "hostname" {
  description = "Redis hostname — resolves to the Private Endpoint IP via the linked DNS zone"
  value       = azurerm_redis_cache.main.hostname
}

output "ssl_port" {
  description = "Redis SSL port (typically 6380)"
  value       = azurerm_redis_cache.main.ssl_port
}

output "primary_access_key" {
  description = "Primary access key — should be stored in Key Vault, never used directly in app config"
  value       = azurerm_redis_cache.main.primary_access_key
  sensitive   = true
}

output "secondary_access_key" {
  description = "Secondary access key — used during key rotation"
  value       = azurerm_redis_cache.main.secondary_access_key
  sensitive   = true
}

output "connection_string_template" {
  description = <<-EOT
    Connection string template (no key embedded). Apps construct the full string at runtime
    after fetching the primary key from Key Vault. Format suitable for redis-py:
    rediss://:{KEY}@{HOSTNAME}:{PORT}/0
  EOT
  value       = "rediss://:{KEY}@${azurerm_redis_cache.main.hostname}:${azurerm_redis_cache.main.ssl_port}/0"
}