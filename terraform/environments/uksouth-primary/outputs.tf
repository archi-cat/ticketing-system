# ── Resource group ────────────────────────────────────────────────────────────

output "resource_group_name" {
  description = "Regional resource group name"
  value       = azurerm_resource_group.main.name
}

# ── AKS ───────────────────────────────────────────────────────────────────────

output "aks_cluster_name" {
  description = "AKS cluster name — used in az aks get-credentials"
  value       = module.aks.cluster_name
}

output "aks_oidc_issuer_url" {
  description = "AKS OIDC issuer URL"
  value       = module.aks.oidc_issuer_url
}

# ── Identity ──────────────────────────────────────────────────────────────────

output "workload_identity_client_ids" {
  description = "Map of service name to UAMI client ID — annotated on Kubernetes service accounts"
  value       = module.identity.identity_client_ids
}

# ── Data layer ────────────────────────────────────────────────────────────────

output "postgres_fqdn" {
  description = "PostgreSQL server FQDN"
  value       = module.postgres.server_fqdn
}

output "postgres_database_name" {
  description = "Application database name"
  value       = module.postgres.database_name
}

output "redis_hostname" {
  description = "Redis hostname"
  value       = module.redis.hostname
}

output "redis_ssl_port" {
  description = "Redis SSL port"
  value       = module.redis.ssl_port
}

output "servicebus_fqdn" {
  description = "Service Bus fully qualified namespace"
  value       = module.servicebus.fully_qualified_namespace
}

output "keyvault_uri" {
  description = "Key Vault URI"
  value       = module.keyvault.vault_uri
}

# ── Observability ─────────────────────────────────────────────────────────────

output "log_analytics_workspace_id" {
  description = "Log Analytics workspace resource ID"
  value       = module.observability.log_analytics_workspace_id
}

output "application_insights_connection_strings" {
  description = "Map of service name to App Insights connection string"
  value       = module.observability.application_insights_connection_strings
  sensitive   = true
}

# ── Convenience output for app deployment ─────────────────────────────────────

output "service_account_annotations" {
  description = <<-EOT
    Map of service name to the workload identity client-id annotation that should
    be applied to the corresponding Kubernetes service account. The deploy
    workflow consumes this to substitute placeholders in the K8s manifests.
  EOT
  value = {
    for service_name, client_id in module.identity.identity_client_ids :
    service_name => {
      annotation = "azure.workload.identity/client-id"
      value      = client_id
    }
  }
}