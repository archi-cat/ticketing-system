output "namespace" {
  description = "Namespace where external-secrets is installed"
  value       = kubernetes_namespace_v1.this.metadata[0].name
}

output "uami_client_id" {
  description = "ESO UAMI client ID"
  value       = azurerm_user_assigned_identity.this.client_id
}

output "uami_principal_id" {
  description = "ESO UAMI principal (object) ID — for any additional role assignments outside this module"
  value       = azurerm_user_assigned_identity.this.principal_id
}
