# Kyverno Cluster Add-on

Installs [Kyverno](https://kyverno.io/) via Helm. Kyverno is the admission-control engine that enforces **cluster-level Cosign signature verification** on the project's container images — moving the supply-chain check from the deploy workflow (bypassable by a manual `kubectl apply`) into the cluster's admission path.

This module installs **only the engine + CRDs**. The image-signature `ClusterPolicy` objects live in [`k8s/cluster-addons/kyverno-policies/`](../../../../k8s/cluster-addons/kyverno-policies/) and are applied by the `infra-uksouth` workflow's post-apply step — the same Terraform-installs-the-engine / workflow-applies-the-CRDs split used for cert-manager and the cert-pipeline.

See **ADR-0031** for the full decision (why Kyverno, Audit-first rollout, scope).

## Usage

```hcl
module "kyverno" {
  source = "../../modules/cluster-addons/kyverno"
}
```

Requires the `helm` and `kubernetes` providers configured against the target cluster (the `uksouth-primary` environment configures both from the AKS kubeconfig).

## Resources created

| Resource | Notes |
|---|---|
| `kubernetes_namespace_v1.this` | `kyverno` namespace, Terraform-owned |
| `helm_release.this` | Kyverno chart (admission, background, cleanup, reports controllers + CRDs) |

## Notes

- **One replica per controller.** This is a single-region learning cluster on Burstable nodes; the chart's HA profile would run 3× admission controllers. The reports controller stays enabled because it produces the `PolicyReport` objects that make the **Audit-mode** rollout observable (`kubectl get policyreport -A`).
- **`atomic` + `replace`** mirror the cert-manager module — they make the Helm release converge cleanly through the deploy/teardown loop, and `atomic` (which implies `--wait`) guarantees the admission webhook is live before the workflow applies the `ClusterPolicy` CRDs.
- **Chart version** is pinned in `variables.tf`. Like cert-manager's `chart_version`, this is a **manual** bump — Dependabot's `terraform` ecosystem tracks provider versions, not `helm_release` chart versions. The kind e2e workflow pins the same version (`KYVERNO_CHART_VERSION`); keep the two in sync.
- When the cluster goes private (Phase 3 Tier 3), the `helm`/`kubernetes` provider auth path changes alongside the other add-ons — see the env `main.tf` provider notes.
