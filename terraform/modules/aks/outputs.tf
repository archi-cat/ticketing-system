output "cluster_id" {
  description = "AKS cluster resource ID"
  value       = azurerm_kubernetes_cluster.main.id
}

output "cluster_name" {
  description = "AKS cluster name"
  value       = azurerm_kubernetes_cluster.main.name
}

output "oidc_issuer_url" {
  description = "OIDC issuer URL — used as the issuer in Workload Identity federated credentials"
  value       = azurerm_kubernetes_cluster.main.oidc_issuer_url
}

output "kubelet_identity_object_id" {
  description = "Kubelet identity object ID — used to grant AcrPull on the container registry"
  value       = azurerm_kubernetes_cluster.main.kubelet_identity[0].object_id
}

output "kubelet_identity_client_id" {
  description = "Kubelet identity client ID — used by cluster add-ons (e.g. Kyverno) to authenticate to ACR via IMDS managed identity, reusing its AcrPull grant"
  value       = azurerm_kubernetes_cluster.main.kubelet_identity[0].client_id
}

# Surface the ingress_profile resource so consumers can depend on it —
# the add-on UAMI doesn't exist until this has been applied.
output "ingress_profile_id" {
  description = "ID of the azapi ingress_profile update — used as a dependency anchor."
  value       = azapi_update_resource.ingress_profile.id
}
output "node_resource_group" {
  description = <<-EOT
    Name of the AKS-managed node resource group. The AGC add-on's UAMI
    (applicationloadbalancer-<cluster-name>) is created here once the
    ingress_profile resource has been applied.
  EOT
  value       = azurerm_kubernetes_cluster.main.node_resource_group
}

output "kube_config_raw" {
  description = "Raw kubeconfig — sensitive. Prefer az aks get-credentials in operational scenarios."
  value       = azurerm_kubernetes_cluster.main.kube_config_raw
  sensitive   = true
}

# ── Pieces of kube_config the Terraform Helm/Kubernetes/kubectl providers
# consume directly. Exposed as discrete outputs (rather than the providers
# parsing kube_config_raw) so provider config in the environment stays simple
# and the sensitive scope is explicit per attribute.

output "host" {
  description = "AKS API server endpoint URL"
  value       = azurerm_kubernetes_cluster.main.kube_config[0].host
  sensitive   = true
}

output "cluster_ca_certificate" {
  description = "Base64-encoded cluster CA certificate"
  value       = azurerm_kubernetes_cluster.main.kube_config[0].cluster_ca_certificate
  sensitive   = true
}

output "client_certificate" {
  description = "Base64-encoded client certificate"
  value       = azurerm_kubernetes_cluster.main.kube_config[0].client_certificate
  sensitive   = true
}

output "client_key" {
  description = "Base64-encoded client key"
  value       = azurerm_kubernetes_cluster.main.kube_config[0].client_key
  sensitive   = true
}
