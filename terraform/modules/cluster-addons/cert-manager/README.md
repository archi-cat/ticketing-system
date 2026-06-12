# Cert-manager module

Installs [cert-manager](https://cert-manager.io) into the AKS cluster via Helm. cert-manager handles the lifecycle of TLS certificates — provisioning, renewal, revocation — through Kubernetes CRDs (`Certificate`, `Issuer`, `ClusterIssuer`, `CertificateRequest`).

This module is the foundation for Gateway TLS termination. It installs the controller only — the actual ACME issuers, DNS-01 webhook, and `Certificate` resources are added in subsequent PRs.

## What gets installed

| Resource | Purpose |
|---|---|
| `kubernetes_namespace_v1.cert-manager` | Terraform-owned namespace so removal cleans up |
| `helm_release.cert-manager` (chart `cert-manager`) | Controller + cainjector + webhook + CRDs |

CRDs are bundled into the chart install (`installCRDs = true`) rather than installed separately, so a chart upgrade is a single `helm_release` version bump.

## Usage

```hcl
module "cert_manager" {
  source = "../../modules/cluster-addons/cert-manager"

  # Override only when bumping the chart version; default is current stable.
  # chart_version = "v1.16.1"
}
```

The `helm` and `kubernetes` providers must be configured at the environment level — see `terraform/environments/uksouth-primary/main.tf` for the cluster client-cert auth pattern.

## Inputs

| Variable | Type | Required | Default | Description |
|---|---|---|---|---|
| `chart_version` | string | No | `v1.16.1` | cert-manager Helm chart version |

## Outputs

| Output | Description |
|---|---|
| `namespace` | The namespace cert-manager is installed in (`cert-manager`) |
| `release_id` | Helm release ID — surfaced as a dependency anchor for downstream `Issuer` / `Certificate` resources |

## Notes

- **Leader election** is pinned to the install namespace via `global.leaderElection.namespace` so cert-manager doesn't try to claim a lease in `kube-system`. This matters once we add additional controllers (e.g. the DuckDNS webhook) that share leader-election semantics.
- **CRD upgrades** are sometimes breaking. Read the [release notes](https://github.com/cert-manager/cert-manager/releases) before bumping `chart_version`. A breaking CRD change can leave `Certificate` resources in a stuck state until the new schema is applied.
- **No issuers ship by default.** Out of the box, cert-manager controllers run but won't issue anything. PR 2 (Phase 3 #1) installs the DuckDNS webhook and creates `ClusterIssuer` resources for Let's Encrypt staging + production.
