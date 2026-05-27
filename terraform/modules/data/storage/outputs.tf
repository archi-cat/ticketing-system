output "account_name" {
  description = "Storage account name."
  value       = azurerm_storage_account.this.name
}

output "account_id" {
  description = "Storage account resource ID."
  value       = azurerm_storage_account.this.id
}

output "blob_endpoint" {
  description = "Primary blob endpoint URL of the storage account."
  value       = azurerm_storage_account.this.primary_blob_endpoint
}

output "events_container_name" {
  description = "Name of the events blob container."
  value       = azurerm_storage_container.events.name
}
