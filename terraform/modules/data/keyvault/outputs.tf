output "vault_id" {
  description = "Key Vault resource ID"
  value       = azurerm_key_vault.main.id
}

output "vault_name" {
  description = "Key Vault name"
  value       = azurerm_key_vault.main.name
}

output "vault_uri" {
  description = "Key Vault URI — used by SDK clients (e.g. azure-keyvault-secrets) to construct the endpoint"
  value       = azurerm_key_vault.main.vault_uri
}

output "secret_ids" {
  description = "Map of bootstrap secret name to versioned secret ID"
  value       = { for k, v in azurerm_key_vault_secret.bootstrap : k => v.id }
  sensitive   = true
}