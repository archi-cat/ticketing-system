terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
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

resource "kubernetes_namespace" "this" {
  metadata {
    name = "external-secrets"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/part-of"    = "ticketing-system"
    }
  }
}

# ── Workload Identity ─────────────────────────────────────────────────────────
# Same federated-credential pattern the application UAMIs use. The subject
# claim binds the federation to the ESO controller's ServiceAccount, so no
# other workload in the cluster can mint Key Vault tokens with this identity.

resource "azurerm_user_assigned_identity" "this" {
  name                = "${var.name_prefix}-external-secrets"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

resource "azurerm_federated_identity_credential" "this" {
  name                = "fic-external-secrets-workload-identity"
  resource_group_name = var.resource_group_name
  parent_id           = azurerm_user_assigned_identity.this.id

  audience = ["api://AzureADTokenExchange"]
  issuer   = var.oidc_issuer_url
  subject  = "system:serviceaccount:${kubernetes_namespace.this.metadata[0].name}:external-secrets"
}

# ── Key Vault role ────────────────────────────────────────────────────────────
# Secrets Officer = read + write. Read alone would suffice for ExternalSecret
# (Key Vault → cluster) but the PushSecret flow (cluster → Key Vault), used
# by the cert pipeline in the next PR, requires write.

resource "azurerm_role_assignment" "key_vault" {
  scope                = var.key_vault_id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = azurerm_user_assigned_identity.this.principal_id
}

# ── Helm release ──────────────────────────────────────────────────────────────
# Installs the external-secrets controller plus its CRDs (SecretStore,
# ClusterSecretStore, ExternalSecret, PushSecret, etc.).

resource "helm_release" "this" {
  name       = "external-secrets"
  repository = "https://charts.external-secrets.io"
  chart      = "external-secrets"
  version    = var.chart_version
  namespace  = kubernetes_namespace.this.metadata[0].name

  # Idempotency safeguards for the teardown/rebuild loop:
  # - atomic: clean up the partial install on failure (also implies wait)
  # - replace: allow re-using the release name if a previous attempt left
  #   the release record behind in a failed state
  atomic  = true
  replace = true

  # - installCRDs: ship the ESO CRDs with the chart so upgrades are one bump.
  # - serviceAccount annotation: the workload-identity webhook keys off this
  #   to know which UAMI to mint tokens for.
  # - podLabel: tells the webhook to inject the federated token file +
  #   AZURE_* env vars into the controller container. Forced to type="string"
  #   because Helm's default "auto" type interprets "true" as a bool, and the
  #   chart drops it straight into metadata.labels — which K8s requires to be
  #   strings, not bools.
  set = [
    {
      name  = "installCRDs"
      value = "true"
    },
    {
      name  = "serviceAccount.annotations.azure\\.workload\\.identity/client-id"
      value = azurerm_user_assigned_identity.this.client_id
    },
    {
      name  = "podLabels.azure\\.workload\\.identity/use"
      value = "true"
      type  = "string"
    },
  ]

  depends_on = [
    azurerm_federated_identity_credential.this,
    azurerm_role_assignment.key_vault,
  ]
}

# ── ClusterSecretStore lives in k8s/cluster-addons/cert-pipeline/ ─────────────
# The ClusterSecretStore that points this controller at the regional Key Vault
# is applied as a YAML manifest by the infra-uksouth workflow's post-apply
# step. The split — Terraform owns the Helm release + Workload Identity wiring,
# YAML owns the CRD-typed resources — sidesteps the alekc/kubectl provider's
# inability to defer configuration when module.aks.host is "(known after apply)"
# on a first-pass deploy.
