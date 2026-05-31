# cert-manager-duckdns module

Adds the DuckDNS DNS-01 ACME solver to a cluster that already has cert-manager and External Secrets Operator installed. Issues TLS certificates for DuckDNS subdomains via Let's Encrypt.

## Why a DNS-01 solver

cert-manager doesn't speak DuckDNS natively. The standard cert-manager built-in solvers cover Cloudflare, Route 53, Azure DNS, Google CloudDNS, and a few others. For DuckDNS we use an out-of-tree webhook that turns ACME DNS-01 challenges into TXT-record updates via the DuckDNS HTTP API.

DNS-01 (over HTTP-01) is chosen because it doesn't couple cert renewal to HTTP listener health on the Gateway, and because it works without an HTTP route being configured beforehand.

## Components

```
┌───────────────────────────────┐
│ ClusterIssuer (staging | prod)│  — refers to webhook by groupName + solverName
└────────┬──────────────────────┘
         │ DNS-01 challenge
         ▼
┌───────────────────────────────┐         ┌────────────────────┐
│ DuckDNS webhook (this module) │ ──API──▶│ DuckDNS HTTP API   │
└────────┬──────────────────────┘         └────────────────────┘
         │ reads token from
         ▼
┌───────────────────────────────┐
│ K8s Secret: duckdns-api-token │  ◀── ESO ExternalSecret ──── Key Vault
└───────────────────────────────┘
```

## What gets installed

| Resource | Purpose |
|---|---|
| `helm_release.duckdns_webhook` | Community webhook that translates ACME DNS-01 to DuckDNS TXT-record updates |
| `kubectl_manifest.duckdns_token` | `ExternalSecret` syncing the DuckDNS API token from Key Vault into the cert-manager namespace |
| `kubectl_manifest.cluster_issuer["staging"]` | Let's Encrypt staging `ClusterIssuer` — for iteration without rate limits |
| `kubectl_manifest.cluster_issuer["production"]` | Let's Encrypt production `ClusterIssuer` — switch to this once staging is verified |

## Prerequisites

These all happen **outside Terraform** and persist across teardown/redeploy cycles:

1. Sign up at [duckdns.org](https://www.duckdns.org/) (Google login).
2. Reserve a subdomain — note the full FQDN (e.g. `ticketing-floryda.duckdns.org`).
3. Copy your DuckDNS API token from the dashboard.
4. Once Key Vault exists, set the token as a KV secret:
   ```bash
   az keyvault secret set \
     --vault-name <kv-name> \
     --name duckdns-api-token \
     --value <duckdns-token>
   ```

The KV secret name (`duckdns-api-token` by default) is passed into the module via `duckdns_token_kv_secret_name`. The token value itself is never seen by Terraform — ESO retrieves it at runtime via Workload Identity.

## Usage

```hcl
module "cert_manager_duckdns" {
  source = "../../modules/cluster-addons/cert-manager-duckdns"

  cluster_secret_store_name = module.external_secrets.cluster_secret_store_name
  acme_email                = var.acme_email

  # Defaults are sensible — override only if needed
  # cert_manager_namespace       = "cert-manager"
  # duckdns_token_kv_secret_name = "duckdns-api-token"
  # webhook_group_name           = "acme.duckdns.org"
  # webhook_chart_version        = "1.5.0"
}
```

The `helm` and `kubectl` providers must be configured at the environment level.

## Inputs

| Variable | Type | Required | Default | Description |
|---|---|---|---|---|
| `cluster_secret_store_name` | string | Yes | — | Name of the ESO `ClusterSecretStore` pointing at Key Vault (from the external-secrets module's output) |
| `acme_email` | string | Yes | — | Email registered with Let's Encrypt — receives expiry-warning notifications |
| `cert_manager_namespace` | string | No | `cert-manager` | Namespace where cert-manager is installed |
| `duckdns_token_kv_secret_name` | string | No | `duckdns-api-token` | Name of the Key Vault secret holding the DuckDNS API token |
| `webhook_group_name` | string | No | `acme.duckdns.org` | ACME webhook groupName — used by ClusterIssuers to route challenges to this webhook |
| `webhook_chart_version` | string | No | `1.5.0` | cert-manager-webhook-duckdns Helm chart version |

## Outputs

| Output | Description |
|---|---|
| `staging_issuer_name` | `letsencrypt-staging` — use this from a `Certificate` while iterating |
| `production_issuer_name` | `letsencrypt-production` — switch a `Certificate` to this once staging passes |

## Operating notes

- **Start every cert against staging.** Let's Encrypt's production rate limits (50 certs per registered domain per week, 5 duplicates per week) are easy to blow through when iterating on issuer / webhook config. Staging has the same flow, no rate limits, but issues a cert signed by a CA that browsers don't trust.
- **Account keys are persistent.** When the staging or production ClusterIssuer is created, cert-manager registers an account with Let's Encrypt and stores the account key in `letsencrypt-{staging,production}-account-key`. Don't delete these between deploys — re-registering generates a fresh account.
- **Webhook + ClusterIssuer share a groupName.** The webhook chart sets it via Helm values; the ClusterIssuer references it under `solvers.dns01.webhook.groupName`. They must match exactly — typo there silently breaks issuance with a confusing "no group" error from cert-manager.
- **One DuckDNS token, many subdomains.** DuckDNS issues one token per account; it can update TXT records on any subdomain under that account. The same KV secret + webhook covers additional subdomains if needed later.

## Failure modes

- **`Certificate` stuck in `Pending`** — usually the webhook can't reach DuckDNS or the token is wrong. Check `kubectl logs -n cert-manager -l app=cert-manager-webhook-duckdns` for HTTP errors against `www.duckdns.org/update`.
- **`ExternalSecret` reports `SecretSyncedError`** — usually the KV secret doesn't exist yet or the KV name in the ClusterSecretStore is wrong. `kubectl describe externalsecret -n cert-manager duckdns-api-token` shows the reason.
- **ACME challenge fails validation** — check `kubectl describe challenge -n cert-manager` for the propagation timeout. DuckDNS TXT records propagate within ~30s but Let's Encrypt validates after a delay; cert-manager handles the retry loop automatically.
