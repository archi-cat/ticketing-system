# Security scanning

This project uses [Trivy](https://trivy.dev) for security scanning across two
surfaces: container images and infrastructure-as-code (Terraform). Scanning
runs at two distinct points in the delivery pipeline, each with a different
purpose.

## Two-tier approach

### Tier 1 — PR enforcement gate

Trivy runs on every pull request that touches relevant code, and blocks the
merge if findings are present:

| Trigger | Surface | Workflow |
|---|---|---|
| PR touching `terraform/` | IaC misconfigurations | `pr-validation.yml` (`terraform` job) |
| Push to `main` (service deploy) | Container image CVEs | `_deploy-common.yml` (`Scan image with Trivy` step) |

These scans use `exit-code: 1` — a finding at `HIGH` or `CRITICAL` severity
fails the workflow and prevents the change from being merged or deployed.

### Tier 2 — Weekly scheduled monitor

A separate workflow (`trivy-scheduled.yml`) runs every Monday at 07:00 UTC
against the `main` branch. It covers the same two surfaces but serves a
different purpose: catching vulnerabilities that emerge **after** code is
merged or images are built.

| Job | Surface | What it catches |
|---|---|---|
| `scan-iac` | `terraform/` | New Trivy IaC rules published since the last PR |
| `scan-images` | `:latest` image for each service in ACR | CVEs published after the images were built |

These scans use `exit-code: 0` — findings are uploaded as SARIF to the GitHub
Security tab rather than failing the workflow. A new CVE published overnight
should not produce a permanently red scheduled run when there is nothing to
immediately act on; it should produce a tracked alert.

## Viewing findings

SARIF results from the scheduled scan appear in
**Security → Code scanning** on GitHub. Each surface has its own category so
findings are tracked independently:

| Category | Surface |
|---|---|
| `trivy-iac` | Terraform IaC |
| `trivy-image-api` | `ticketing-api` image |
| `trivy-image-worker` | `ticketing-worker` image |
| `trivy-image-scheduler` | `ticketing-scheduler` image |

Findings persist across runs. GitHub marks a finding as resolved
automatically when it disappears from a subsequent scan — either because the
image was rebuilt with a patched dependency or because the IaC configuration
was fixed.

## Suppressing a finding (.trivyignore)

Some findings are false positives or represent accepted risks. These are
suppressed in `.trivyignore` at the repo root. Trivy reads this file
automatically during both PR and scheduled scans.

**Every entry must have a written justification.** The format used in this
project:

```
# <AVD-ID> — <short description of the rule>
# <One of:>
#   FALSE POSITIVE — <explain why the control IS in place and why Trivy can't see it>
#   Accepted: <explain the risk, why it is acceptable, and when it will be revisited>
AVD-XXX-NNNN
```

Before adding a suppression, ask:

1. **Is this a false positive?** If Trivy can't detect a control that is
   genuinely in place (e.g. because it uses a resource type the rule doesn't
   cover), document the gap with a `FALSE POSITIVE` note and a reference to
   where the control actually lives.
2. **Is this an accepted risk?** If the finding is real but the risk is
   accepted, document why it is acceptable, what the mitigating factors are,
   and — if applicable — which phase or condition would prompt revisiting it.
3. **Is this just inconvenient?** If neither of the above applies, fix the
   finding rather than suppressing it.

See `.trivyignore` for the current set of suppressions and their reasoning.

## Image signing (Cosign)

All container images are signed after push using
[Cosign](https://docs.sigstore.dev/cosign/overview/) with keyless signing.
The signature is cryptographically bound to the GitHub Actions workflow
identity that produced the image — no private key is managed or stored.

### How it works

Keyless signing uses GitHub's OIDC token to obtain a short-lived certificate
from Sigstore's certificate authority (Fulcio). The certificate binds the
signature to the specific workflow URL and branch that ran the signing step.
The signature and certificate are stored as OCI artifacts alongside the image
in ACR, indexed by the image digest.

Because signatures are indexed by digest (the content hash), a signature
attached via the SHA-tagged reference is found when verifying by any other tag
that resolves to the same digest — including `:latest`.

### Where signing happens

| Workflow | Images signed |
|---|---|
| `_deploy-common.yml` | `ticketing-api`, `ticketing-worker`, `ticketing-scheduler` |
| `build-bootstrap-images.yml` | `ticketing-db-grant` |

### Where verification happens

Every workflow that applies a Kubernetes Job or Deployment verifies the image
signature before running `kubectl apply`. If the image has no valid signature
from the expected workflow on `main`, the verification step fails and nothing
is deployed.

| Workflow | Image verified | Expected signing workflow |
|---|---|---|
| `_deploy-common.yml` | `ticketing-<unit>` | `_deploy-common.yml@main` |
| `db-grant.yml` | `ticketing-db-grant` | `build-bootstrap-images.yml@main` |
| `db-migrate.yml` | `ticketing-api` | `_deploy-common.yml@main` |
| `db-load-events.yml` | `ticketing-api` | `_deploy-common.yml@main` |

### Verifying an image locally

To verify an image from your workstation (requires `cosign` installed):

```bash
cosign verify \
  --certificate-identity \
    "https://github.com/<org>/ticketing-system/.github/workflows/_deploy-common.yml@refs/heads/main" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  <acr-login-server>/ticketing-api:latest
```

A successful verification prints the signing certificate details including the
workflow URL, the commit SHA, and the run ID.

### Phase 3 — cluster-level enforcement

The current implementation enforces signing at the CI/CD level: workflows
verify before deploying. A future phase will add cluster-level enforcement via
an admission controller (Ratify or Kyverno with a Cosign policy), which
prevents any unsigned image from being scheduled in the cluster regardless of
how it was applied.
