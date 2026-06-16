output "namespace" {
  description = "Namespace Kyverno is installed into"
  value       = kubernetes_namespace_v1.this.metadata[0].name
}
