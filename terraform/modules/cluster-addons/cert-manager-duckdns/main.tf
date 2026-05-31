terraform {
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.0"
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

# Single source of truth for the K8s Secret name. Used by the ExternalSecret
# (target name), the webhook chart values (existingSecretName), and the
# ClusterIssuer manifests (apiTokenSecretRef.name).
locals {
  token_secret_name = "duckdns-api-token"
}

# ── DuckDNS API token sync ────────────────────────────────────────────────────
# Pulls the DuckDNS API token from Key Vault (set there manually with
# `az keyvault secret set --name <var.duckdns_token_kv_secret_name>`) into a
# K8s Secret in the cert-manager namespace. The ClusterIssuer's webhook config
# references this Secret by name.

resource "kubectl_manifest" "duckdns_token" {
  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "duckdns-api-token"
      namespace = var.cert_manager_namespace
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        kind = "ClusterSecretStore"
        name = var.cluster_secret_store_name
      }
      target = {
        name           = local.token_secret_name
        creationPolicy = "Owner"
      }
      data = [
        {
          secretKey = "token"
          remoteRef = {
            key = var.duckdns_token_kv_secret_name
          }
        },
      ]
    }
  })
}

# ── ClusterIssuers ────────────────────────────────────────────────────────────
# Two issuers: staging for iteration (no rate limits), production for the real
# cert. The Certificate resource in the env switches between them by changing
# its issuerRef. Both issuers register with Let's Encrypt under the same email
# but use independent ACME accounts (different privateKeySecretRefs).

locals {
  issuers = {
    staging = {
      acme_server = "https://acme-staging-v02.api.letsencrypt.org/directory"
      account_key = "letsencrypt-staging-account-key"
    }
    production = {
      acme_server = "https://acme-v02.api.letsencrypt.org/directory"
      account_key = "letsencrypt-production-account-key"
    }
  }
}

resource "kubectl_manifest" "cluster_issuer" {
  for_each = local.issuers

  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata = {
      name = "letsencrypt-${each.key}"
    }
    spec = {
      acme = {
        server = each.value.acme_server
        email  = var.acme_email
        privateKeySecretRef = {
          name = each.value.account_key
        }
        solvers = [
          {
            dns01 = {
              webhook = {
                groupName  = var.webhook_group_name
                solverName = "duckdns"
                config = {
                  # cobexer webhook expects apiTokenSecretRef with
                  # { name, key } pointing at the K8s Secret ESO populated.
                  apiTokenSecretRef = {
                    name = local.token_secret_name
                    key  = "token"
                  }
                }
              }
            }
          },
        ]
      }
    }
  })

  depends_on = [
    helm_release.duckdns_webhook,
    kubectl_manifest.duckdns_token,
  ]
}
