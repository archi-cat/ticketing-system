# ADR-0020: Gateway TLS termination

Status: Accepted
Date: 2026-06-03

## Context

The Gateway listening on port 80 over plain HTTP was the most visible production gap left at the end of Phase 2. Phase 3 Tier 1 #1 (the highest-impact, lowest-effort item in the production-hardening plan) closes it.

The goals for the work were:

1. Serve traffic on HTTPS with a browser-trusted certificate
2. Redirect HTTP to HTTPS so plaintext bookmarks don't break
3. Make the cert flow auto-renewing and resilient across the project's deploy-tear-down loop
4. Demonstrate the production-grade pattern even where the **specific implementations** are learning-mode compromises (free DNS provider, single-user cluster)

The flow needed to land cleanly in this project's architecture:

- Workload Identity everywhere — no stored credentials
- IaC discipline — everything Terraform or YAML, no manual portal clicks
- Deploy-tear-down loop — every redeploy bootstraps from empty Azure resources
- Public repo — no secrets in code or in Terraform state where avoidable

The plan was implemented across three PRs over a week of iteration: PR 1 (cluster add-ons), PR 2 (cert issuance), PR 3 (Gateway TLS + redirect + HSTS).

## Decision

Layered architecture spanning Terraform, in-cluster YAML, and a single bootstrap workflow:

```
                    ┌─────────────────────────────────────────────┐
                    │ infra-uksouth.yml (one workflow, one        │
                    │ bootstrap path)                             │
                    └─────────────────────────────────────────────┘
                                       │
                                       ▼
        ┌──────────────────────────────────────────────────┐
        │ Terraform:                                        │
        │   • AKS, AGC, Key Vault, Workload Identity        │
        │   • Helm releases: cert-manager, ESO, DuckDNS     │
        │     webhook (atomic + replace for idempotency)    │
        │   • az keyvault secret set duckdns-api-token      │
        └──────────────────────────────────────────────────┘
                                       │
                                       ▼
        ┌──────────────────────────────────────────────────┐
        │ envsubst + kubectl apply for                      │
        │ k8s/cluster-addons/cert-pipeline/:                │
        │   00 webhook secret RBAC                          │
        │   01 ClusterSecretStore (ESO ↔ KV)                │
        │   02 ExternalSecret  (KV → cert-manager Secret)   │
        │   03 ClusterIssuer (staging)                      │
        │   04 ClusterIssuer (production)                   │
        │   05 Certificate (against production)             │
        │   06 PushSecret  (cert → KV archive)              │
        │   07 ReferenceGrant (Gateway → cert Secret)       │
        └──────────────────────────────────────────────────┘
                                       │
                                       ▼
        ┌──────────────────────────────────────────────────┐
        │ kubectl kustomize | envsubst | kubectl apply for  │
        │ k8s/overlays/uksouth/gateway/                     │
        │   • Gateway with HTTP + HTTPS listeners           │
        │   • httproute-redirect (HTTP→HTTPS 301)           │
        │   • api HTTPRoute with HSTS filter on HTTPS       │
        └──────────────────────────────────────────────────┘
                                       │
                                       ▼
        ┌──────────────────────────────────────────────────┐
        │ kubectl wait Gateway Programmed                   │
        │ → read status.addresses[0].value                  │
        │ → resolve to IP via dig                           │
        │ → DuckDNS A record SET (idempotent)               │
        └──────────────────────────────────────────────────┘
```

### Cluster add-on installation: Terraform Helm

cert-manager, External Secrets Operator (ESO), and the cobexer DuckDNS webhook are installed by Terraform's Helm provider rather than kubectl-apply in a workflow. Add-on lifecycle, version pinning, and drift detection live in the same state as the rest of the infrastructure.

Each Helm release has `atomic = true` (clean up partial installs on failure) and `replace = true` (allow re-using a release name if a previous attempt left a failed-state record). The `replace = true` is the explicit trade-off in [ADR-style trade-offs](#trade-offs-accepted) — in real production it would be off, but for this project's deploy-tear-down loop, redeploy resilience matters more than the silent-overwrite risk.

### Cluster ↔ Key Vault: External Secrets Operator

ESO is the bidirectional sync between K8s Secrets and Azure Key Vault. Two directions are in play:

- **KV → cluster** via `ExternalSecret`: the DuckDNS API token (set by Terraform in KV from a repo secret) is synced into a K8s Secret that the webhook reads.
- **Cluster → KV** via `PushSecret`: the issued TLS cert is mirrored into KV as `ticketing-tls-crt` + `ticketing-tls-key`. This is an archive — AGC reads the K8s Secret directly, not from KV. The KV copy persists past cluster teardown and positions for Phase 4 Front Door consumption.

ESO authenticates to Key Vault via Workload Identity (the project's everywhere-pattern). The federated credential's subject claim binds the UAMI specifically to the `external-secrets:external-secrets` ServiceAccount, so no other workload in the cluster can mint Key Vault tokens with this identity. The UAMI has `Key Vault Secrets Officer` — read + write — because PushSecret needs write.

CSI Driver was considered as an alternative for the KV-side handle. CSI is the more Azure-native pattern but is one-way (KV → workload) and would have required a separate mechanism for the PushSecret direction. Operating two sync stacks for the same Key Vault is more complexity than running one bidirectional ESO. CSI Driver may be the better answer in the future for any **application** that needs to read a KV secret at runtime — none does today.

### Cert issuance: cert-manager + Let's Encrypt + DuckDNS DNS-01

cert-manager handles certificate lifecycle. Let's Encrypt is the ACME CA — free, auto-rotating, browser-trusted, demonstrates exactly the same Key Vault integration pattern an Azure-managed cert would (but at zero cost).

**DNS-01** over HTTP-01 because:

- DNS-01 doesn't couple cert renewal to HTTP listener health on the Gateway
- DNS-01 works without an HTTP route being configured beforehand (no chicken-and-egg on first issuance)
- DNS-01 supports wildcards (future-proof)

DuckDNS is the DNS provider — chosen to avoid the cost of a real domain while keeping the cert-management architecture intact. The DNS provider being free is incidental; the demonstrable pattern is "cert-manager + ACME + DNS-01 + Workload Identity + Key Vault sync." Swapping DuckDNS for Azure DNS (a real production answer) is one config change in the webhook + ClusterIssuer.

The webhook is the **cobexer fork** of `cert-manager-webhook-duckdns`. The original ebrianne project hasn't shipped a release since 2021 and its GitHub Pages chart repo is offline. The cobexer fork is actively maintained, distributes via OCI on GHCR, and targets recent cert-manager versions.

### Split between Terraform and YAML

The cluster add-on Helm releases stay in Terraform. The CRD-typed resources (ClusterSecretStore, ExternalSecret, ClusterIssuer, Certificate, PushSecret, ReferenceGrant) live as YAML in `k8s/cluster-addons/cert-pipeline/`, applied by the workflow with `envsubst | kubectl apply`.

The split exists because the `alekc/kubectl` Terraform provider — which is the only viable option for managing CRD-typed resources without hitting the `kubernetes_manifest` "CRD must exist at plan time" limitation — can't gracefully handle `module.aks.host` being `(known after apply)` on a first-pass deploy. The error surfaces as "no configuration has been provided," and the workflow then can't apply the resulting incomplete plan.

The fix also turned out to be the cleaner architectural split: Terraform owns Azure resources and "installing software" via Helm; YAML owns application-level cluster configuration. The same split that the rest of the project's K8s config already uses (apps in `k8s/base`, overlays in `k8s/overlays/<region>`).

### Cross-namespace cert reference: Gateway API ReferenceGrant

The cert is issued into `cert-manager/ticketing-tls` (cert-manager's natural namespace for cert-typed resources). The Gateway is in `ticketing` namespace because the application HTTPRoutes attach to it. Gateway API requires explicit cross-namespace consent via a `ReferenceGrant` for `certificateRefs` to span namespaces — the standard, narrow, auditable pattern.

The ReferenceGrant lives in `cert-manager` namespace (Gateway API's rule: ReferenceGrant goes in the target namespace), scoped to `from: Gateway in ticketing` and `to: Secret named ticketing-tls`. Anything broader would be over-permission.

### HSTS for returning visitors

HSTS is set via `ResponseHeaderModifier` filter on the api HTTPRoute (Gateway-layer, not application-layer):

```yaml
- type: ResponseHeaderModifier
  responseHeaderModifier:
    set:
      - name: Strict-Transport-Security
        value: max-age=31536000; includeSubDomains
```

Gateway-layer rather than FastAPI middleware because:

- Same header for all routes through this Gateway — one place to verify
- The app stays infrastructure-agnostic (doesn't need to know it's behind TLS)
- Easier to audit "is HSTS on for everything?" by looking at the HTTPRoute

Full `max-age=31536000; includeSubDomains` (one year) rather than the cautious-rollout `max-age=300` — the cert pipeline is now stable and HTTPS isn't going to flip off mid-cycle. The trade-off is that browsers that have ever seen the HSTS header refuse to fall back to plaintext for a year; for a deploy-tear-down loop on the same DuckDNS subdomain this is fine since HTTPS always returns valid.

### BYO frontend binding for AGC

AGC supports two deployment strategies: **ALB-managed** (the ALB Controller provisions the AGC instance and frontend) and **BYO** (Terraform provisions both, the controller binds the Gateway to them). This project uses BYO so the AGC lifecycle stays Terraform-tracked.

The BYO binding requires:

- Annotation `alb.networking.azure.io/alb-id: <AGC ARM resource ID>` on the Gateway
- `spec.addresses[].value = <frontend NAME>` (not ID) pointing at the specific frontend

The early implementation used a non-standard `alb.networking.azure.io/alb-frontend` annotation that the ALB Controller silently ignored — it bound the Gateway to some default frontend rather than the Terraform-managed one. PR 3 fixed this by moving to `spec.addresses` per the documented BYO pattern.

### Workflow architecture: one bootstrap, one ad-hoc

The full bootstrap path lives in `infra-uksouth.yml`:

1. Terraform apply (Azure resources + Helm releases)
2. Set DuckDNS API token in KV
3. Get AKS credentials + kubelogin
4. Apply cert-pipeline manifests
5. Apply Gateway overlay
6. Wait for Gateway `Programmed`
7. Read Gateway `status.addresses[0].value` → resolve to IP → DuckDNS A record SET

The DuckDNS update reads from the **Gateway's status**, not from a Terraform output, so it's truthful regardless of which AGC frontend the ALB Controller actually bound to. The DuckDNS update API is a SET operation (idempotent — same IP repeated returns OK with no change).

`deploy-gateway.yml` is retained for ad-hoc Gateway edits between full bootstraps — listener changes, HTTPRoute tweaks, annotation updates. It applies the same overlay but doesn't touch DuckDNS (the Gateway's address doesn't change just because you re-apply the same manifest).

## Rationale

- **Production-first posture with cost-minimal substitutions.** The architecture demonstrates the patterns a real production team would use (Workload Identity, KV-backed cert store, ACME for auto-rotation, Gateway API + ReferenceGrant for cross-namespace certs, HSTS). The specific implementations that compromise on cost (DuckDNS over a real domain, community webhook over Azure-native DNS) are isolated to one swap point each — they don't change the surrounding shape.
- **The DuckDNS token never enters Terraform state.** It lives in a GitHub Actions repo secret and is written directly to Key Vault by a workflow step. ESO syncs it from there into the cluster. Even with a leaked tfstate, the cert pipeline is recoverable.
- **The deploy-tear-down loop is cheap.** `atomic + replace` on Helm releases, idempotent DuckDNS update, externalised account-key handling (gitignored YAMLs that can be re-applied), and bootstrap-in-one-workflow mean a fresh deploy is one trigger and a tear-down is `terraform destroy`. The cert pipeline self-converges within 5–10 minutes of apply finishing.
- **Failure modes are explicit, not hidden.** Each Helm release has clean failure semantics (atomic), the cert pipeline writes its diagnostic state into K8s status fields, and the workflow fails loudly on any non-`OK` DuckDNS response. The cert rotation runbook ([docs/02-cert-rotation.md](../02-cert-rotation.md)) maps every stuck-state to its likely cause.

## Trade-offs accepted

- **`replace = true` on all three cluster-addons Helm releases.** Documented as "unsafe in production" because it allows silent overwrites of failed releases. For this learning project with explicit teardown-and-rebuild loops, redeploy resilience is the goal and the silent-overwrite risk doesn't apply (single user, no parallel deploys). In a real production posture this flag would be off and failed releases would alert ops; recovery would be manual `helm uninstall` after diagnosing the failure mode.
- **DuckDNS rather than a real domain.** Free, sufficient to demonstrate the architecture, but the DNS provider is a community webhook rather than the first-party Azure DNS solver cert-manager has built in. Swapping is a config change.
- **PushSecret is currently an archive.** AGC consumes the K8s Secret directly via Gateway API `certificateRefs`. The KV copy isn't load-bearing today, but it positions Phase 4 (Front Door) to consume from KV directly and persists the cert across teardown.
- **ACME account keys are exported manually before teardown.** Until the planned follow-up automates Push-once + ExternalSecret-sync of the account keys, redeploys generate fresh ACME accounts. Low-stakes given Let's Encrypt's rate-limit structure, but operationally a paper-cut.
- **HSTS is sticky.** Browsers that have visited successfully refuse plaintext for a year. If HTTPS ever fully breaks on this domain (cert expiry + renewal failure), there's no graceful fallback for returning users. Acceptable for the deploy-tear-down loop on a single DuckDNS subdomain that always returns on HTTPS.

## Operator path

- **First-time setup (one-time per project lifetime):** DuckDNS account, reserved subdomain, API token, three GitHub Actions repo secrets (`DUCKDNS_FQDN`, `ACME_EMAIL`, `DUCKDNS_API_TOKEN`). See [docs/01-fresh-deployment.md](../01-fresh-deployment.md) §0.4.
- **Each fresh deploy:** trigger `infra-uksouth.yml`. Workflow brings up the regional platform, including a publicly-trusted cert and the DuckDNS A record pointed at the new AGC frontend. 5–10 minutes for the cert pipeline to converge after Terraform apply finishes.
- **Cert rotation:** automatic at day ~60. Operator monitoring is two long-running signals (Tier 1 #3 cert-expiry alert + Let's Encrypt expiry email). See [docs/02-cert-rotation.md](../02-cert-rotation.md) for forcing manual renewal and recovering from a failed one.
- **Gateway tweaks between deploys:** `deploy-gateway.yml` (workflow_dispatch) re-applies the Gateway overlay without re-running Terraform.

## Future work

- **Tier 1 #3 baseline alerts** include a cert expiry alert at 30 days remaining. Until that lands, the only automatic signal of a stuck renewal is the Let's Encrypt expiry email.
- **ACME account-key persistence via ESO + KV** — drop the manual export/re-apply step. Pattern mirrors the DuckDNS token flow. Tracked under Tier 1 #1 in `phase_3_plan.md`.
- **Phase 4: Front Door** introduces a CDN/edge layer. The cert flow described here largely persists — AGC's role changes from "public TLS edge" to "origin TLS between Front Door and AGC," and the KV cert copy becomes load-bearing (Front Door consumes from KV). The DuckDNS A record may be replaced by a CNAME to the Front Door endpoint.
- **Tier 1 #13 private AKS cluster.** Changes how the workflow reaches the API server (the kubectl + kustomize + helm provider steps), but the cert pipeline architecture is unchanged.

## References

- PR 1: foundation — cert-manager + ESO via Terraform Helm
- PR 2: cert issuance — DuckDNS webhook + Let's Encrypt staging + KV push
- PR 3: Gateway TLS — HTTPS listener, redirect, HSTS, production issuer
- Follow-up commits: chart-source swap to cobexer fork, label-coercion fix, CRD-ordering fix, `name in use` idempotency fix, webhook RBAC fix, CRD extraction from Terraform, BYO frontend binding fix
- Runbook: [docs/02-cert-rotation.md](../02-cert-rotation.md)
- ADR-0019: precedent for the one-ADR-per-feature pattern this document follows
