output "namespace" {
  description = "Namespace where external-secrets is installed"
  value       = kubernetes_namespace.this.metadata[0].name
}

output "cluster_secret_store_name" {
  description = "Name of the ClusterSecretStore pointing at Key Vault — referenced by ExternalSecret / PushSecret resources"
  value       = "keyvault"
}

output "uami_client_id" {
  description = "ESO UAMI client ID"
  value       = azurerm_user_assigned_identity.this.client_id
}

output "uami_principal_id" {
  description = "ESO UAMI principal (object) ID — for any additional role assignments outside this module"
  value       = azurerm_user_assigned_identity.this.principal_id
}
