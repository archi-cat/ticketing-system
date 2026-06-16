terraform {
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.2"
    }
  }
  required_version = ">= 1.9.0"
}

# ── Namespace ─────────────────────────────────────────────────────────────────
# Terraform owns the namespace lifecycle (not Helm's create_namespace) so that
# removing the chart cleanly removes the namespace too. kubernetes_namespace_v1
# (not the deprecated un-suffixed name) per provider v3 — see the cert-manager
# add-on module for the same pattern and the destroy/recreate caveat.

resource "kubernetes_namespace_v1" "this" {
  metadata {
    name = "kyverno"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/part-of"    = "ticketing-system"
    }
  }
}

# ── Helm release ──────────────────────────────────────────────────────────────
# Installs Kyverno (admission/background/cleanup/reports controllers + CRDs,
# including the ClusterPolicy CRD the image-signature policies use). The
# ClusterPolicy objects themselves are NOT applied here — they live in
# k8s/cluster-addons/kyverno-policies/ and are applied by the infra-uksouth
# workflow's post-apply step (they need the signer repo URL substituted at
# apply time, the same split used for the cert-pipeline CRDs).

resource "helm_release" "this" {
  name       = "kyverno"
  repository = "https://kyverno.github.io/kyverno/"
  chart      = "kyverno"
  version    = var.chart_version
  namespace  = kubernetes_namespace_v1.this.metadata[0].name

  # Idempotency safeguards for the teardown/rebuild loop (same as cert-manager):
  # - atomic: roll back a partial install on failure (also implies wait, so the
  #   webhook is live before the workflow applies ClusterPolicies)
  # - replace: re-use the release name if a prior attempt left a failed record
  atomic  = true
  replace = true

  # One replica per controller. This is a single-region learning cluster on
  # Burstable nodes, not an HA control plane — the chart's HA profile would run
  # 3x admission controllers. Pinned explicitly so a chart default change can't
  # silently scale the footprint. The reports controller stays enabled: it
  # produces the PolicyReports that make Audit mode observable.
  set = [
    {
      name  = "admissionController.replicas"
      value = "1"
    },
    {
      name  = "backgroundController.replicas"
      value = "1"
    },
    {
      name  = "cleanupController.replicas"
      value = "1"
    },
    {
      name  = "reportsController.replicas"
      value = "1"
    },
  ]
}
