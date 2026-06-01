output "id" {
  description = "Resource ID of the AGC instance. Referenced by Gateway annotations in cluster manifests."
  value       = azurerm_application_load_balancer.this.id
}

output "name" {
  description = "Name of the AGC instance."
  value       = azurerm_application_load_balancer.this.name
}

output "frontend_id" {
  description = "Resource ID of the AGC frontend. Referenced by Gateway annotations in cluster manifests."
  value       = azurerm_application_load_balancer_frontend.this.id
}

output "frontend_name" {
  description = "Name of the AGC frontend."
  value       = azurerm_application_load_balancer_frontend.this.name
}

output "frontend_fqdn" {
  description = "Auto-generated FQDN for the AGC frontend (e.g. xxxxx.fzXXX.alb.azure.com). Resolves to the AGC's public IP — referenced by the DuckDNS A-record update step so the custom domain points at the AGC frontend."
  value       = azurerm_application_load_balancer_frontend.this.fully_qualified_domain_name
}
