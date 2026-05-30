output "namespace" {
  description = "Namespace where cert-manager is installed"
  value       = kubernetes_namespace.this.metadata[0].name
}

output "release_id" {
  description = "Helm release ID — surfaced as a dependency anchor for downstream resources (issuers, certificates)"
  value       = helm_release.this.id
}
