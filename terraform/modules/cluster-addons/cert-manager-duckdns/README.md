# cert-manager-duckdns module

Installs the [cobexer/cert-manager-webhook-duckdns](https://github.com/cobexer/cert-manager-webhook-duckdns) webhook as a Helm release. The webhook teaches cert-manager how to solve ACME DNS-01 challenges by updating TXT records via the DuckDNS HTTP API.

This module installs the **controller only**. The CRD-typed resources that drive the cert flow — the `ExternalSecret` syncing the DuckDNS API token, the two Let's Encrypt `ClusterIssuer`s, the `Certificate`, and the `PushSecret` — live as YAML in [`k8s/cluster-addons/cert-pipeline/`](../../../../k8s/cluster-addons/cert-pipeline/) and are applied by the `infra-uksouth` workflow after Terraform completes.

## Why a DNS-01 solver

cert-manager doesn't speak DuckDNS natively. Its standard built-in solvers cover Cloudflare, Route 53, Azure DNS, Google CloudDNS, and a few others. For DuckDNS we use an out-of-tree webhook that turns ACME DNS-01 challenges into TXT-record updates via the DuckDNS HTTP API.

DNS-01 (over HTTP-01) is chosen because it doesn't couple cert renewal to HTTP listener health on the Gateway, and because it works without an HTTP route being configured beforehand.

## Which webhook fork

We use the [cobexer/cert-manager-webhook-duckdns](https://github.com/cobexer/cert-manager-webhook-duckdns) fork. The original ebrianne project hasn't shipped a release since 2021 and its `github.io` chart repository is offline. The cobexer fork is actively maintained, distributes its chart via OCI on GHCR (`oci://ghcr.io/cobexer/charts/cert-manager-webhook-duckdns`), and targets recent cert-manager versions.

## What gets installed

| Resource | Purpose |
|---|---|
| `helm_release.duckdns_webhook` | The cobexer webhook deployment + APIService registration |

The webhook is configured to read the DuckDNS API token from a K8s Secret named `duckdns-api-token` in the cert-manager namespace — the same Secret that the `ExternalSecret` in [`k8s/cluster-addons/cert-pipeline/`](../../../../k8s/cluster-addons/cert-pipeline/) populates from Key Vault.

## Usage

```hcl
module "cert_manager_duckdns" {
  source = "../../modules/cluster-addons/cert-manager-duckdns"

  cert_manager_namespace = module.cert_manager.namespace

  # Sensible defaults — override only if needed:
  # webhook_group_name    = "acme.duckdns.org"
  # webhook_chart_version = "2.0.0"
}
```

The `helm` provider must be configured at the environment level.

## Inputs

| Variable | Type | Required | Default | Description |
|---|---|---|---|---|
| `cert_manager_namespace` | string | No | `cert-manager` | Namespace where cert-manager is installed (the webhook lives here too) |
| `webhook_group_name` | string | No | `acme.duckdns.org` | ACME webhook groupName — must match the value used in the ClusterIssuer manifests in `k8s/cluster-addons/cert-pipeline/` |
| `webhook_chart_version` | string | No | `2.0.0` | cobexer chart version |

## Outputs

This module exposes no outputs. The static identifiers (`letsencrypt-staging`, `letsencrypt-production`, `duckdns-api-token`) used by the cert pipeline are written directly in the YAML manifests that consume them.

## Operating notes

- **The webhook + ClusterIssuer share a `groupName`.** The Helm chart sets it via `--set groupName=...`; the ClusterIssuer manifests reference it under `solvers.dns01.webhook.groupName`. They must match exactly — a typo here silently breaks issuance with a confusing "no group" error from cert-manager.
- **Start every cert against the staging issuer.** Let's Encrypt's production rate limits (50 certs per registered domain per week, 5 duplicates per week) are easy to blow through when iterating. Staging has no rate limits but issues certs from a CA browsers don't trust.
- **Account keys are persistent.** When cert-manager registers with Let's Encrypt for the first time, it stores the account key in `letsencrypt-{staging,production}-account-key`. Don't delete these between deploys — re-registering generates a fresh ACME account.
- **One DuckDNS token, many subdomains.** DuckDNS issues one token per account; it can update TXT records on any subdomain under that account. The same KV secret + webhook covers additional subdomains if needed later.

## Failure modes

- **`Certificate` stuck in `Pending`** — usually the webhook can't reach DuckDNS or the token is wrong. Check `kubectl logs -n cert-manager -l app=cert-manager-webhook-duckdns` for HTTP errors against `www.duckdns.org/update`.
- **`ExternalSecret` reports `SecretSyncedError`** — usually the KV secret doesn't exist yet or the KV name in the ClusterSecretStore is wrong. `kubectl describe externalsecret -n cert-manager duckdns-api-token` shows the reason.
- **ACME challenge fails validation** — check `kubectl describe challenge -n cert-manager` for the propagation timeout. DuckDNS TXT records propagate within ~30s but Let's Encrypt validates after a delay; cert-manager handles the retry loop automatically.
