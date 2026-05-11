# 11. Kubernetes manifests with Kustomize — base + per-region overlays

Date: 2026-04-27
Status: Accepted

## Context

The project deploys the same three services to multiple regions. The
manifests need to be DRY across regions while supporting per-region
configuration (image tags, identity client IDs, connection strings, AGC
binding).

## Decision drivers

- The same application code runs in every region — manifests should
  reflect this without copy-paste between regions
- Region-specific values must come from Terraform outputs cleanly
- Kubernetes-native tooling preferred over external templating systems
- Secrets and non-secret config must be cleanly separated

## Considered options

### Plain YAML duplicated per region
Simplest to read but multiplies maintenance — every base change must be
made N times. Inevitably drifts.

### Helm chart
Powerful templating and a packaging story, but the Go-template-in-YAML
syntax is hostile to read, and the chart packaging story is overkill for
a single-tenant deployment.

### Kustomize with base + overlays
Patch-based, no templating language, native kubectl support
(`kubectl apply -k`), straightforward debugging via `kubectl kustomize`.

## Decision

Use **Kustomize** with a `base/` for region-agnostic manifests and one
overlay per region (`overlays/uksouth/`, `overlays/westeurope/` in
Phase 4).

Region-specific values are templated with `${VARIABLE}` placeholders and
filled in by the deploy workflow via `envsubst`. The values come from
Terraform outputs.

## Consequences

### Positive
- Base manifests describe the application shape once
- Adding a region means writing a new overlay (one kustomization.yaml,
  one configmap, a handful of patches)
- `kubectl kustomize` produces inspectable YAML — easy to verify what
  will be applied before applying
- No new templating language to learn

### Negative
- `${VARIABLE}` placeholders are a thin layer of templating that
  Kustomize doesn't natively understand — `kubectl apply -k` alone
  won't substitute them, so we need an `envsubst` step in the workflow
- Patches can become repetitive across regions (each region needs a
  near-identical patch with different variable references)

## Future revisits

When Phase 4 adds the second region, evaluate whether the overlay
duplication is causing pain. If yes, consider a small templating
preprocessor or moving to Helm — but the bar is high; the current
approach is simple and works.