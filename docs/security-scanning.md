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
