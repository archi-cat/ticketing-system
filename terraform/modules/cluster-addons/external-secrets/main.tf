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
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.0"
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

  # - installCRDs: ship the ESO CRDs with the chart so upgrades are one bump.
  # - serviceAccount annotation: the workload-identity webhook keys off this
  #   to know which UAMI to mint tokens for.
  # - podLabel: tells the webhook to inject the federated token file +
  #   AZURE_* env vars into the controller container.
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
    },
  ]

  depends_on = [
    azurerm_federated_identity_credential.this,
    azurerm_role_assignment.key_vault,
  ]
}

# ── ClusterSecretStore ────────────────────────────────────────────────────────
# Points at the Key Vault using the controller's Workload Identity. Once this
# reports Ready, any ExternalSecret or PushSecret in any namespace can
# reference it. Applied as a kubectl_manifest because the kubernetes_manifest
# resource validates against CRDs at plan time, which would fail on a fresh
# apply where the ESO CRDs are installed by the helm_release above.

resource "kubectl_manifest" "cluster_secret_store" {
  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ClusterSecretStore"
    metadata = {
      name = "keyvault"
    }
    spec = {
      provider = {
        azurekv = {
          authType = "WorkloadIdentity"
          vaultUrl = var.key_vault_uri
          serviceAccountRef = {
            name      = "external-secrets"
            namespace = kubernetes_namespace.this.metadata[0].name
          }
        }
      }
    }
  })

  depends_on = [helm_release.this]
}
