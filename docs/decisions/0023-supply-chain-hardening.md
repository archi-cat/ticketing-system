# ADR-0023: Supply-chain hardening — Dependabot and SHA-pinned Actions

Status: Accepted
Date: 2026-06-11

## Context

Phase 3 Tier 1 #4 and #5, delivered together because they're two halves of one posture: #4 (automated dependency updates) keeps the software current, #5 (SHA-pinning GitHub Actions) ensures what runs in CI is exactly what was reviewed. Before this work:

- No automated visibility into outdated Python packages, base images, Actions, or Terraform providers
- Every workflow referenced actions by mutable tag (`actions/checkout@v4`) — a compromised or re-pointed tag would execute unreviewed code with OIDC credentials to the Azure subscription

The two changes interlock: SHA-pinning without Dependabot means pins rot; Dependabot without pinning means updates arrive but the trust anchor stays mutable.

## Decision

### Dependabot: four ecosystems, weekly, minor+patch grouped

`.github/dependabot.yml` covers `pip` (three service lockfiles), `docker` (three service Dockerfiles + db-grant), `github-actions`, and `terraform` (the two state roots). All run weekly (Monday), capped at 5 open PRs per ecosystem, with `chore(deps)` commit prefixes and per-ecosystem labels.

The grouping strategy: **minor + patch updates bundle into one PR per ecosystem per week; majors open individually.** One review for the low-risk bulk, focused scrutiny for breaking changes. Every PR runs the full `pr-validation.yml` gauntlet (type checks, tests, Trivy, kustomize build) before it's mergeable.

Terraform scanning targets only the two state roots — module-level `required_providers` are constraints the env-level versions satisfy, so env-level updates propagate.

### The python base image is pinned to patch-only updates

A hard-won exception. Dependabot's docker ecosystem treats `python:3.13 → 3.14` as an ordinary semver-minor bump, but it's a **language version change** that must be coordinated with each service's `requires-python` constraint and a fresh `uv lock`. An early Dependabot PR bumped the Dockerfiles to 3.14 while `pyproject.toml` stayed `>=3.13,<3.14` — and the breakage was invisible for weeks because uv silently downloaded its own managed Python 3.13 at build time to satisfy the constraint.

The mask came off when the Dockerfiles gained `UV_PYTHON_PREFERENCE=only-system` + `UV_PYTHON_DOWNLOADS=never` (fixing a separate dangling-symlink failure where uv's managed Python lived only in the builder stage). The build then failed honestly: `No interpreter found for Python ==3.13.*`.

Resolution: base image realigned to `python:3.13`, and `dependabot.yml` now ignores `semver-major` and `semver-minor` for the `python` docker dependency. Patch bumps (CVE fixes) still flow. Language-version migrations are deliberate human changes that update `pyproject.toml` + `uv.lock` + Dockerfile in one PR.

### SHA-pinning: every third-party action, tag in comment

All third-party actions across all workflows are pinned to full commit SHAs — 15 unique actions, 68 references across 10 workflows:

```yaml
uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5  # v4
```

The `# v4` comment is load-bearing, not cosmetic: Dependabot reads it to know which release stream to track, and proposes pin updates (new SHA + new comment) when the action releases. Without the comment, pins rot silently.

Local reusable workflows (`uses: ./.github/workflows/_deploy-common.yml`) are not pinned — they're same-repo references already governed by branch protection on `main`.

### Image freshness: cache-busting rebuilds on demand

A later addition in the same posture: the build workflows cache Docker layers in GHA, which freezes `apt-get upgrade` results at whenever the layer last actually ran — so OS package CVEs (flagged by the Trivy gate, which fails builds on fixable CRITICAL/HIGH) can't be fixed by re-running a cached build. All four image-building workflows now take a `no-cache` dispatch input, and every build runs `pull: true` so the base-image tag re-resolves to the latest digest. Push-triggered builds keep the cache (no CI slowdown); the no-cache path is the operator's CVE-response lever.

## Rationale

- **The CI identity is the most privileged credential in the project** — OIDC-federated into the Azure subscription. Mutable action tags were the easiest way for third-party code changes to reach it unreviewed. SHA-pinning reduces that to "code at this exact commit."
- **Weekly grouped updates match a single-operator review budget.** Daily/individual PRs would train the operator to rubber-stamp; weekly bundles with passing CI are a 10-minute review.
- **The python-image exception encodes a real incident,** not a hypothetical. The general lesson — Dependabot has no cross-file consistency view, so language/runtime version bumps need a human — is documented where it's enforced (`dependabot.yml` comments) and in ADR form here.

## Trade-offs accepted

- **SHA pins are unreadable without the comment.** Accepted; the comment convention plus Dependabot keeping both in sync covers the readability and the rot.
- **Pinning doesn't protect against a malicious release that gets reviewed in** — it protects against tag re-pointing and unreviewed drift. Review of Dependabot action-bump PRs (diffing the upstream release) remains a human job.
- **Grouped minor+patch PRs can hide one bad bump among ten good ones.** Mitigated by the CI gauntlet and the ability to revert the group as one commit; majors stay individual.
- **`open-pull-requests-limit: 5` can queue updates** during a busy week. Acceptable; the queue drains as PRs merge.
- **No-cache rebuilds are operator-triggered, not scheduled.** An image nothing rebuilds can sit with a known-fixable CVE until the next build attempt fails on it. A weekly scheduled `no-cache` rebuild is the production-grade upgrade if the gap ever bites.

## Operator path

- **Monday morning:** review the grouped Dependabot PRs per ecosystem — green CI + changelog skim → merge. Majors get individual attention.
- **Base-image bumps (docker ecosystem):** check the language-version constraint before merging anything that isn't a patch (the `ignore` rule should prevent these appearing for `python`, but the lesson generalises to any future language image).
- **Trivy fails a build on a fixable OS CVE:** dispatch the relevant build workflow with `no-cache` ticked.
- **New workflow or action:** pin to SHA with the tag comment from day one; Dependabot picks it up automatically.

## Future work

- Scheduled (weekly) no-cache image rebuilds, closing the operator-triggered gap.
- Digest-pinned `FROM` lines (`debian:bookworm-slim@sha256:...`) so base-image updates become explicit Dependabot PRs — the image-level analogue of action SHA-pinning.
- The Debian 13 (Trixie) migration is queued behind the Dependabot PR backlog; like Python versions, distro codename bumps are deliberate human changes.
- Tier 2 candidates: artifact attestation/SLSA provenance for the service images (cosign signing already exists), `pip-audit` or equivalent in pr-validation.

## References

- `.github/dependabot.yml` — config with inline strategy comments
- `.github/workflows/*` — SHA-pinned actions; `_deploy-common.yml` + `build-bootstrap-images.yml` for the no-cache input
- ADR-0012 — deploy pipeline design these workflows extend
- Incident write-up in commit history: `fix(images): force uv to use system Python`, `fix(images): align Docker base image with project's required Python`, `chore(deps): pin python base image to patch-only updates in dependabot`
