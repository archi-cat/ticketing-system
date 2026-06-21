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
- **Private-ACR auth (`acr_pull_client_id`).** Image-signature verification pulls manifests + signatures from the private ACR, as a process separate from the pods — so it doesn't inherit the kubelet identity automatically. `AZURE_CLIENT_ID` is set on the verifying controllers (admission/background/reports) to the kubelet identity's client id, which already has `AcrPull`; its azure credential helper then authenticates via IMDS. Without it the helper can't pick an identity and falls back to an anonymous pull → ACR 401, and verification silently fails. This is the prerequisite for promoting the policy from Audit to Enforce.
- When the cluster goes private (Phase 3 Tier 3), the `helm`/`kubernetes` provider auth path changes alongside the other add-ons — see the env `main.tf` provider notes.
