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

output "cluster_identity_principal_id" {
  description = "Cluster control plane identity principal ID — used for any role assignments the cluster itself needs"
  value       = azurerm_kubernetes_cluster.main.identity[0].principal_id
}

output "node_resource_group" {
  description = "Auto-generated resource group containing the AKS node pool VMs and supporting resources"
  value       = azurerm_kubernetes_cluster.main.node_resource_group
}

output "kube_config_raw" {
  description = "Raw kubeconfig — sensitive. Prefer az aks get-credentials in operational scenarios."
  value       = azurerm_kubernetes_cluster.main.kube_config_raw
  sensitive   = true
}