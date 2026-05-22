# 12. Deploy pipeline design — per-service workflows with a reusable common workflow

Date: 2026-04-27
Status: Accepted

## Context

Three services need to deploy independently to the cluster. Their build
and deploy steps are nearly identical — Docker build with the same uv
patterns, Trivy scan, ACR push, kubectl apply against the same cluster
with rendered manifests. The differences fit on one line each: service
name, image name, deployment to wait on.

## Decision drivers

- Each service must deploy independently (changing API code should not
  redeploy the worker)
- The deploy logic must not be duplicated three times — one place to fix
  bugs, one place to add features
- Secrets and Azure credentials must be plumbed cleanly from caller to
  reusable workflow
- Image tags and rendered manifests must be reproducible from the git SHA

## Considered options

### Three independent deploy workflows
Each ~150 lines, 90% identical. Bug fixes need to be applied in three
places. Easy to write, painful to maintain.

### One monolithic deploy workflow with a service input
One workflow, takes a service name. Doesn't auto-trigger on path filters
per service — would need separate trigger workflows that all call the
same one.

### Per-service workflows + reusable common workflow
Each per-service workflow is ~15 lines (trigger + delegate to common).
Common workflow holds the deploy logic. Per-service path filters drive
independent triggering.

## Decision

Use the **per-service workflow + reusable common workflow** pattern:

- `_deploy-common.yml` contains the deploy logic
- `deploy-{service}.yml` is a thin wrapper per service: path filters,
  concurrency group, delegate to common with `service` and `image_tag`
  inputs

Image tags are the full git SHA. ACR retention deletes untagged
manifests after 7 days; the tagged ones persist indefinitely for
rollback.

## Consequences

### Positive
- Bug fixes and feature additions land in one place
- Each service is independently deployable
- Concurrency groups prevent overlapping deploys of the same service
- Image tags are auditable to a specific commit
- Trivy scan gates each deploy on CRITICAL/HIGH CVEs

### Negative
- Secrets must be re-declared in every per-service workflow (GitHub
  Actions doesn't inherit secrets to reusable workflows automatically)
- The two-step ACR login (placeholder, then real token) is awkward —
  driven by Docker login action not supporting OIDC tokens directly
- envsubst is a thin templating layer that Kustomize doesn't natively
  understand. ADR-0011 already captured this; it's a re-affirmation here
