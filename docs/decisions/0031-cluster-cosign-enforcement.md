# ADR-0031: Cluster-level Cosign enforcement via Kyverno

Status: Accepted
Date: 2026-06-15

## Context

Phase 3 Tier 2 #7. Every container image is signed in CI with Cosign keyless (Fulcio/Rekor, GitHub OIDC) — service images (`api`/`worker`/`scheduler`) in `_deploy-common.yml`, bootstrap images (`db-grant`, later `db-load-events`) in `build-bootstrap-images.yml`. `db-migrate` reuses the `api` image, so it inherits that signature. ADR-0023 hardened the *supply* of dependencies into CI; this closes the other end — what the *cluster* is allowed to run.

The gap: the only signature **verification** today is a `cosign verify` step inside `_deploy-common.yml`. It runs in the same workflow that just produced the image, and it is trivially bypassed — a manual `kubectl apply`, an `kubectl set image`, a misconfigured or forked workflow, or anything that talks to the API server directly never passes through that check. The cluster itself trusts any image it can pull from ACR.

Goal: move signature verification into the cluster's **admission path**, so an unsigned (or wrong-identity) image is rejected regardless of how the workload is created.

## Decision

### Engine: Kyverno, installed as a Terraform cluster add-on

Kyverno is installed via Helm in `terraform/modules/cluster-addons/kyverno`, mirroring the cert-manager add-on exactly (Terraform-owned `kubernetes_namespace_v1`, `atomic + replace` for the teardown loop, chart version as a variable, one replica per controller for a single-region Burstable cluster).

Kyverno over **Ratify** (the Microsoft-supported, supply-chain-narrow alternative) because Kyverno is a general policy engine — the same install covers later Tier 2/3 policy needs (privileged-container blocks, registry allow-lists, Azure Policy overlaps) without adding a second admission controller.

### Policy: one `ClusterPolicy`, two `verifyImages` rules, scoped to our images

A single `verify-image-signatures` ClusterPolicy with two rules rather than the four the plan sketched (one per image) — less duplication, identical coverage:

- **Service rule** → `*/ticketing-api*`, `*/ticketing-worker*`, `*/ticketing-scheduler*`, keyless subject `…/_deploy-common.yml@refs/heads/main`.
- **Bootstrap rule** → `*/ticketing-db-grant*`, `*/ticketing-db-load-events*`, keyless subject `…/build-bootstrap-images.yml@refs/heads/main`.

Both with issuer `https://token.actions.githubusercontent.com` and `rekor.url https://rekor.sigstore.dev` — exactly the identity `_deploy-common.yml` already verifies against. The subject's repo URL is substituted at apply time via a **scoped** `envsubst '${SIGNER_REPO_URL}'`, keeping the policy fork-portable and leaving every other literal untouched.

The policy matches **only `*/ticketing-*`**. Third-party images (Kyverno, cert-manager, External Secrets, redis tooling) are intentionally **not** required to be signed — we don't control their signing — which also keeps system namespaces unaffected without namespace-level exclusion lists.

Like the cert-pipeline CRDs, the `ClusterPolicy` is **not** applied by Terraform (it needs the apply-time substitution and the engine must exist first). It lives in `k8s/cluster-addons/kyverno-policies/` and is applied by the `infra-uksouth` workflow's post-apply step, after the Terraform apply has installed Kyverno (`atomic` guarantees the webhook is live).

### Rollout: Audit first, then Enforce

The policy ships with `failureAction: Audit` — failing images are recorded in `PolicyReport` objects, not rejected. A deploy loop confirms the real signed images report `pass` before a follow-up PR flips it to `Enforce` (and turns on `mutateDigest`, drops `verifyDigest: false`, and considers `failurePolicy: Fail`). An enforce-from-day-one policy with a subtly wrong subject string would brick every deploy; Audit de-risks that against a real cluster first.

### Negative test: kind e2e proving rejection

`.github/workflows/kyverno-policy-test.yml` spins up a kind cluster on every PR touching the policy or module, installs Kyverno, applies the **real** policy flipped to `Enforce`, and asserts that (a) an unsigned `*/ticketing-*` Pod is **denied** at admission and (b) an unrelated image (`busybox`) is **admitted** (scope check). The shipped policy stays Audit; the test exercises the enforcing behaviour in isolation so the control is proven without risking the live cluster.

## Rationale

- **Admission-time is the only un-bypassable place.** A CI-side verify protects the CI-side deploy path only; the cluster has many other write paths. Enforcement has to live where the API server admits Pods.
- **Per-rule `failureAction`, not spec `validationFailureAction`.** The latter is deprecated in current Kyverno; the policy uses the supported per-rule field so it doesn't rot.
- **Audit-first matches the project's "prove against a real cluster before trusting it" habit** (same as how the network policies and alerts were validated), while the kind test still gives a hard, automated proof of the deny behaviour every PR.
- **Scope-by-image, not by-namespace.** Requiring signatures only on `*/ticketing-*` is both the correct trust boundary (we only sign our own images) and the simplest way to avoid blocking system workloads.

## Trade-offs accepted

- **Audit mode enforces nothing until promoted.** An Audit policy left un-flipped is theatre; the promotion is tracked in the plan (#7) and the policy/README call it out explicitly.
- **A second admission controller in the path.** Kyverno adds latency and a failure domain to Pod admission. Mitigated in Audit by `failurePolicy: Ignore` (a Kyverno outage doesn't wedge admission); the Enforce promotion must weigh `Fail` (secure) vs `Ignore` (available).
- **Keyless trust depends on the public Sigstore good-instance** (Fulcio/Rekor) being reachable from the cluster at admission. Same trust root cosign already uses to sign; an air-gapped posture would run a private Sigstore.
- **Four Kyverno controllers at 1 replica each** cost cluster resources on a Burstable node pool. Accepted for the security value; HA is a deliberate non-goal here.
- **The kind test proves denial of unsigned images, not that our real signed images pass** — that positive check needs ACR images signed by the real workflow identity and is the Audit-phase deploy-time verification, not something kind can reproduce.

## Operator path

- **Fresh deploy:** Kyverno installs with the Terraform apply; the policy applies in the post-apply step. No new inputs.
- **Observe (Audit):** `kubectl get policyreport -A` / `kubectl get clusterpolicyreport` — confirm `*/ticketing-*` images report `pass`.
- **Promote to Enforce:** edit `k8s/cluster-addons/kyverno-policies/01-verify-image-signatures.yaml` per its README (`Audit`→`Enforce`, `mutateDigest: true`, drop `verifyDigest: false`, consider `failurePolicy: Fail`); the kind test gates the change.
- **New signed image:** add its `*/ticketing-<name>*` glob to the matching rule (service vs bootstrap identity).

## Future work

- Promote to `Enforce` once a deploy loop validates the Audit reports (the immediate follow-up to this ADR).
- Additional Kyverno baselines now that the engine exists: disallow privileged containers, restrict image registries to ACR, require resource limits (overlaps with Tier 2 #11).
- SLSA provenance / attestation verification (`verifyImages > attestations`) layered on the same policy once the build workflows emit provenance.
- Revisit Ratify vs Kyverno if Azure Policy's Gatekeeper add-on (Tier 3 #15) lands and policy duplication becomes a concern.

## References

- `terraform/modules/cluster-addons/kyverno/` — engine install (Helm) + README
- `k8s/cluster-addons/kyverno-policies/` — the ClusterPolicy + README (Audit→Enforce guide)
- `.github/workflows/kyverno-policy-test.yml` — kind e2e negative test
- `.github/workflows/_deploy-common.yml`, `build-bootstrap-images.yml` — where images are signed (the identities the policy verifies)
- ADR-0023 — supply-chain hardening (the dependency-supply half of this posture)
- ADR-0012 — deploy pipeline these workflows extend
