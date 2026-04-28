output "server_id" {
  description = "PostgreSQL server resource ID"
  value       = azurerm_postgresql_flexible_server.main.id
}

output "server_name" {
  description = "PostgreSQL server name"
  value       = azurerm_postgresql_flexible_server.main.name
}

output "server_fqdn" {
  description = "PostgreSQL server FQDN — used in connection strings"
  value       = azurerm_postgresql_flexible_server.main.fqdn
}

output "database_name" {
  description = "Application database name (passthrough)"
  value       = azurerm_postgresql_flexible_server_database.ticketing.name
}

output "connection_string_template" {
  description = <<-EOT
    Connection string template with placeholders. The actual user is determined at runtime
    via Workload Identity. Format suitable for SQLAlchemy 'postgresql+asyncpg://...' URLs.
  EOT
  value       = "postgresql+asyncpg://{user}@${azurerm_postgresql_flexible_server.main.fqdn}:5432/${azurerm_postgresql_flexible_server_database.ticketing.name}?sslmode=require"
}