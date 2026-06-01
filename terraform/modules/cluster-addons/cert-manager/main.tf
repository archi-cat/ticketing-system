terraform {
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
  }
  required_version = ">= 1.9.0"
}

# ── Namespace ─────────────────────────────────────────────────────────────────
# Terraform owns the namespace lifecycle rather than relying on Helm's
# create_namespace, so removing the chart cleanly removes the namespace too.

resource "kubernetes_namespace" "this" {
  metadata {
    name = "cert-manager"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/part-of"    = "ticketing-system"
    }
  }
}

# ── Helm release ──────────────────────────────────────────────────────────────
# Installs cert-manager plus its CRDs (Certificate, Issuer, ClusterIssuer,
# CertificateRequest, etc.). Subsequent PRs add the DuckDNS webhook + issuers.

resource "helm_release" "this" {
  name       = "cert-manager"
  repository = "https://charts.jetstack.io"
  chart      = "cert-manager"
  version    = var.chart_version
  namespace  = kubernetes_namespace.this.metadata[0].name

  # Idempotency safeguards for the teardown/rebuild loop:
  # - atomic: clean up the partial install on failure (also implies wait)
  # - replace: allow re-using the release name if a previous attempt left
  #   the release record behind in a failed state
  atomic  = true
  replace = true

  # cert-manager CRDs ship with the chart — bundled here keeps the upgrade
  # path as a single helm_release version bump. Leader-election pinned to the
  # install namespace so cert-manager doesn't try to claim a lease in kube-system.
  set = [
    {
      name  = "installCRDs"
      value = "true"
    },
    {
      name  = "global.leaderElection.namespace"
      value = kubernetes_namespace.this.metadata[0].name
    },
  ]
}
