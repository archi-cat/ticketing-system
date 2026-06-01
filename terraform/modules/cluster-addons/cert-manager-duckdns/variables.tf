variable "cert_manager_namespace" {
  description = "Namespace where cert-manager is installed (the webhook lives here too)"
  type        = string
  default     = "cert-manager"
}

variable "webhook_group_name" {
  description = "ACME webhook groupName. Used by ClusterIssuers to route DNS-01 challenges to this webhook. Free-form but must match between the webhook Helm release here and the ClusterIssuer manifests in k8s/cluster-addons/cert-pipeline/."
  type        = string
  default     = "acme.duckdns.org"
}

variable "webhook_chart_version" {
  description = "cert-manager-webhook-duckdns Helm chart version. Distributed via OCI at oci://ghcr.io/cobexer/charts. Releases: https://github.com/cobexer/cert-manager-webhook-duckdns/releases"
  type        = string
  default     = "2.0.0"
}
