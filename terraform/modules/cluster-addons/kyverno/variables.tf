variable "chart_version" {
  description = "Kyverno Helm chart version. Chart: https://artifacthub.io/packages/helm/kyverno/kyverno — releases: https://github.com/kyverno/kyverno/releases"
  type        = string
  default     = "3.8.1"
}

variable "acr_pull_client_id" {
  description = <<-EOT
    Client ID of a managed identity that holds AcrPull on the registry Kyverno
    must read to verify image signatures. Set as AZURE_CLIENT_ID on the Kyverno
    controllers so its (default-enabled) azure registry credential helper
    authenticates to the PRIVATE ACR via that identity over IMDS — without an
    explicit client id the helper can't disambiguate the node's managed
    identities and falls back to an anonymous pull, which ACR rejects. In this
    project it's the AKS kubelet identity, which already has AcrPull, so no
    separate identity/federation is needed.
  EOT
  type        = string
}
