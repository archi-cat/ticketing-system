output "identity_ids" {
  description = "Map of service name to UAMI resource ID"
  value       = { for k, v in azurerm_user_assigned_identity.this : k => v.id }
}

output "identity_principal_ids" {
  description = "Map of service name to UAMI principal ID — used in role assignments"
  value       = { for k, v in azurerm_user_assigned_identity.this : k => v.principal_id }
}

output "identity_client_ids" {
  description = "Map of service name to UAMI client ID — annotated on Kubernetes service accounts"
  value       = { for k, v in azurerm_user_assigned_identity.this : k => v.client_id }
}

output "identity_names" {
  description = "Map of service name to UAMI name"
  value       = { for k, v in azurerm_user_assigned_identity.this : k => v.name }
}

output "service_account_names" {
  description = "Map of service name to its Kubernetes binding (namespace + service account name). Passthrough of var.service_accounts."
  value       = var.service_accounts
}
