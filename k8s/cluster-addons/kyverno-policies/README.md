# Kyverno policies

Cluster-level [Kyverno](https://kyverno.io/) `ClusterPolicy` objects. The Kyverno engine itself is installed by Terraform (`terraform/modules/cluster-addons/kyverno`); these CRDs are applied separately by the `infra-uksouth` workflow's post-apply step — the same split used for the cert-pipeline CRDs, because they need a value substituted at apply time.

See **ADR-0031** for the decision record.

## Policies

| File | Policy | Mode | What it does |
|---|---|---|---|
| `01-verify-image-signatures.yaml` | `verify-image-signatures` | **Audit** | Requires every `*/ticketing-*` image to carry a Cosign **keyless** signature from the GitHub Actions workflow that builds it. Service images (`api`/`worker`/`scheduler`, plus `db-migrate` which reuses the api image) must be signed by `_deploy-common.yml`; bootstrap images (`db-grant`, `db-load-events`) by `build-bootstrap-images.yml`. |

## How it's applied

The infra workflow loops the manifests through a **scoped** `envsubst` so only `${SIGNER_REPO_URL}` (= `https://github.com/<owner>/<repo>`) is substituted — the keyless certificate identity — keeping every other literal intact:

```bash
for f in k8s/cluster-addons/kyverno-policies/*.yaml; do
  envsubst '${SIGNER_REPO_URL}' < "$f" | kubectl apply -f -
done
```

## Audit → Enforce

The policy ships in **Audit** mode (records `PolicyReport` entries, doesn't block). To observe what enforcement *would* do:

```bash
kubectl get policyreport -A
kubectl get clusterpolicyreport
```

Once a deploy loop confirms the real signed images report `pass`, promote to enforcement by editing `01-verify-image-signatures.yaml`:

- `failureAction: Audit` → `Enforce` (both rules)
- `mutateDigest: false` → `true` (pin verified images to their digest)
- remove `verifyDigest: false` (let the digest mutation satisfy it)
- consider `failurePolicy: Ignore` → `Fail` (don't admit if Kyverno is down)

The enforcing behaviour is exercised on every PR by `.github/workflows/kyverno-policy-test.yml`, which runs this exact policy (flipped to Enforce) in a kind cluster and asserts an unsigned `ticketing-*` image is denied.

## Scope

The policy matches **only** `*/ticketing-*` images, so third-party images (Kyverno, cert-manager, External Secrets, redis tooling) are never required to be signed, and system namespaces are unaffected.
