terraform {
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
  }
  required_version = ">= 1.9.0"
}

# ── DuckDNS webhook ───────────────────────────────────────────────────────────
# Community cert-manager webhook that solves ACME DNS-01 challenges by updating
# TXT records via the DuckDNS HTTP API. cert-manager doesn't speak DuckDNS
# natively — webhooks are the official extension mechanism for unsupported
# DNS providers.
#
# We use the cobexer fork, which is the actively maintained successor to the
# original ebrianne/cert-manager-webhook-duckdns (last released 2021). The
# fork distributes its chart via OCI on GHCR rather than a github.io chart
# repo, and supports cert-manager v1.20.x.
#
# Chart source: https://github.com/cobexer/cert-manager-webhook-duckdns

resource "helm_release" "duckdns_webhook" {
  name       = "cert-manager-webhook-duckdns"
  repository = "oci://ghcr.io/cobexer/charts"
  chart      = "cert-manager-webhook-duckdns"
  version    = var.webhook_chart_version
  namespace  = var.cert_manager_namespace

  set = [
    {
      # The ClusterIssuer below references this groupName + solverName pair
      # ('duckdns') to route ACME challenges to this webhook.
      name  = "groupName"
      value = var.webhook_group_name
    },
    {
      # Read the DuckDNS API token from the existing K8s Secret that ESO
      # populates from Key Vault. This is what keeps the token out of
      # Terraform state and out of plan output.
      name  = "duckdns.secret.existingSecret"
      value = "true"
    },
    {
      name  = "duckdns.secret.existingSecretName"
      value = local.token_secret_name
    },
  ]
}

# Single source of truth for the K8s Secret name. Used here by the webhook
# Helm release (as `existingSecretName`), and mirrored — as a hardcoded
# string — by the ExternalSecret in k8s/cluster-addons/cert-pipeline/. The two
# must match for the webhook to find its API token.
locals {
  token_secret_name = "duckdns-api-token"
}

# ── CRD-typed resources live in k8s/cluster-addons/cert-pipeline/ ─────────────
# The ExternalSecret (DuckDNS token sync) and the two ClusterIssuers
# (Let's Encrypt staging + production) are applied as YAML manifests by the
# infra-uksouth workflow's post-apply step. The split — Terraform owns the
# Helm release, YAML owns the CRD-typed resources — sidesteps the
# alekc/kubectl provider's inability to defer configuration when
# module.aks.host is "(known after apply)" on a first-pass deploy.
