# Phase 3 — Production Hardening

Production hardening sits between Phase 2 (deployable end-to-end) and Phase 4 (cross-region DR). Goal: close the gap between "works" and "works safely under real production conditions."

Items are ranked by **risk reduction per unit of effort**. Tier 1 is the recommended starting batch — independent, high value. Tier 2 layers important defenses. Tier 3 is foundation work with prerequisites or larger blast radius. Tier 4 validates.

**Defaults:** production-grade approach unless explicitly noted. Items marked 🔀 have a big enough production-vs-learning-mode delta to surface as a decision.

**Status legend:** `[ ]` todo · `[-]` in progress · `[x]` done

---

## Tier 1 — High impact, low/medium effort

### 🔀 1. Gateway TLS termination

- [x] HTTPS listener on the Gateway
- [x] Cert provisioned and referenced from Key Vault
- [x] HTTP → HTTPS redirect (Gateway-level)
- [x] Cert rotation documented (runbook entry — [docs/02-cert-rotation.md](docs/02-cert-rotation.md))
- [x] ADR-0020 — full design captured ([docs/decisions/0020-gateway-tls-termination.md](docs/decisions/0020-gateway-tls-termination.md))

**Why:** Gateway is HTTP-only on port 80 today — most visible production gap.
**Effort:** medium

**🔀 Decision — cert authority:**

- **Production:** Azure-managed cert directly on AGC, fully managed rotation. Paid (per cert / month).
- **Learning:** Let's Encrypt via cert-manager → stored in Key Vault → referenced by AGC. Zero cost, auto-rotating, demonstrates the same Key Vault integration pattern.
- **Recommendation:** Let's Encrypt — same architectural pattern at zero cost, slightly more moving parts (cert-manager + DNS-01 solver).

**Follow-up — automate ACME account-key persistence across teardown cycles:**

- [ ] One-time bootstrap: after a successful deploy, push the two account-key Secrets (`letsencrypt-staging-account-key`, `letsencrypt-production-account-key`) from `cert-manager` namespace into Key Vault
- [ ] Add two `ExternalSecret` manifests in `k8s/cluster-addons/cert-pipeline/` (numbered to apply before the ClusterIssuers reconcile) that sync KV → K8s Secret
- [ ] Verify: on the next teardown/rebuild, cert-manager finds the existing accounts and skips re-registration (avoids hitting Let's Encrypt's new-account rate limits and keeps account history continuous)
- [ ] Until this lands, the YAMLs in `k8s/cluster-addons/cert-pipeline/letsencrypt-*-account-key.yaml` are gitignored and re-applied manually before each redeploy

Tracked here because the pattern (Push once, sync via ESO) mirrors the DuckDNS-token flow we already have — implementation is mostly copy-paste once PR 3 lands.

---

### 2. Default-deny NetworkPolicy + per-component allow rules

- [x] Namespace-level default-deny (ingress + egress)
- [x] Allow gateway → api
- [x] Allow api → postgres, redis, service bus, key vault
- [x] Allow worker → postgres, redis, service bus
- [x] Allow scheduler → postgres, redis
- [x] Allow bootstrap pods → postgres, storage
- [x] DNS egress allowed cluster-wide
- [x] Validation: a pod with no policy attached cannot reach anything
- [x] Runbook: how to add a NetworkPolicy for a new component

**Why:** Cilium is installed but enforces nothing today. Any pod can talk to anything.
**Effort:** medium

---

### 🔀 3. Baseline alerts

- [x] Action group wired to chosen target
- [x] Metric alert: API 5xx rate
- [x] Metric alert: API p99 latency
- [x] Log alert: scheduler has not logged a successful sweep in N minutes
- [x] Metric alert: Postgres CPU
- [x] Metric alert: Postgres active connections
- [x] Metric alert: Service Bus DLQ depth
- [x] Metric alert: cert expiry ≤ 30 days
- [x] Metric alert: AKS node pool capacity
- [x] Workflow failure notification routes to the same action group

**Why:** Telemetry lands in Log Analytics today but nothing watches it.
**Effort:** small-medium

**🔀 Decision — paging target:**

- **Production:** PagerDuty / Opsgenie / Teams via webhook + Logic App; rotations and escalation paths.
- **Learning:** Email to a single address.
- **Recommendation:** Email is sufficient for the project. Webhook integration would be a portfolio bonus if interesting later.

---

### 4. Dependabot

- [x] Config: pip — api, worker, scheduler
- [x] Config: github-actions
- [x] Config: docker (api, worker, scheduler, db-grant base images)
- [x] Config: terraform providers
- [x] Updates grouped weekly, labelled `dependencies`

**Why:** urllib3 CVE was caught reactively. Dependabot opens PRs proactively and keeps SHA pins (#5) fresh.
**Effort:** small

*Note: Renovate is the more configurable alternative; Dependabot is chosen for native GitHub integration. Worth revisiting if the project ever needs monorepo-style grouping rules.*

---

### 5. SHA-pin all GitHub Actions

- [x] Replace `@v4` / `@v3` with `@<sha>` (tag kept in a comment) across every workflow — 15 unique actions, 68 replacements across 10 workflow files
- [x] Dependabot maintains the SHAs going forward — the `github-actions` ecosystem in `.github/dependabot.yml` reads the `# <tag>` comments to track upstream releases

**Why:** Floating tags can be hijacked by a compromised publisher. OpenSSF / CIS baseline.
**Effort:** small
**Depends on:** ideally after #4 so Dependabot keeps SHAs fresh.

---

### 6. Key Vault purge protection — DEFERRED

- [-] DEFERRED for the duration of the deploy-tear-down loop. Revisit once the project stops tearing down regularly.
- [ ] `purge_protection_enabled = true` in the Key Vault module
- [ ] Remove `AVD-AZU-0016` from `.trivyignore`

**Why:** Suppression was originally deferred from Phase 2 to here.
**Effort:** small
**Why deferred (again):** Irreversible — a soft-deleted vault blocks recreating one with the same name. The current deploy → test → tear-down rhythm would either require a unique vault name each cycle (cosmetic churn) or a soft-delete purge step before each fresh deploy (operational friction). Acceptable trade-off while iterating; flip once the cluster runs continuously.

---

## Tier 2 — Important defenses, medium effort

### 7. Cluster-level Cosign enforcement (Kyverno)

- [x] Install Kyverno via Helm (Terraform cluster-addon module + env wiring)
- [x] ClusterPolicy: `ticketing-api` signed by `_deploy-common.yml@main` (consolidated service rule; covers `db-migrate`, which reuses the api image)
- [x] ClusterPolicy: `ticketing-worker` signed by `_deploy-common.yml@main`
- [x] ClusterPolicy: `ticketing-scheduler` signed by `_deploy-common.yml@main`
- [x] ClusterPolicy: `ticketing-db-grant` signed by `build-bootstrap-images.yml@main` (bootstrap rule; `db-load-events` glob pre-added)
- [x] Negative test in CI: apply an unsigned manifest, expect rejection (`kyverno-policy-test.yml` — kind e2e, policy in Enforce)
- [x] **Private-ACR auth for Kyverno** (deploy-time finding): the verifier pulled the private ACR anonymously → `UNAUTHORIZED`, so verification failed (Audit-first prevented an outage). Fixed by setting `AZURE_CLIENT_ID` = kubelet identity client id on the Kyverno controllers (reuses its `AcrPull` via IMDS) — `kyverno` module `acr_pull_client_id`
- [-] Verify Kyverno policy reports appear (deploy-time check; shipped in **Audit** mode → `kubectl get policyreport -n ticketing`; needs the ACR-auth fix above to report `pass`)
- [ ] **Follow-up:** promote `failureAction: Audit` → `Enforce` after a deploy loop confirms real signed images report `pass` (now unblocked by the ACR-auth fix)
- [x] ADR-0031 — full decision captured ([docs/decisions/0031-cluster-cosign-enforcement.md](docs/decisions/0031-cluster-cosign-enforcement.md))

**Why:** Today's CI verification can be bypassed by a manual `kubectl apply` or a misconfigured workflow.
**Effort:** medium
**Note:** Ratify is the Microsoft-supported alternative focused narrowly on supply-chain. Kyverno is preferred here because it also covers later policy needs (privileged container blocks, image registry allow-lists, etc.).
**Status:** Shipped **Audit-first** — policy observes and reports; one follow-up PR flips it to Enforce. The kind e2e proves the Enforce behaviour on every PR.

---

### 8. PostgreSQL `pgaudit`

- [x] Enable `pgaudit` extension in Terraform config (allow-list + preload) and `CREATE EXTENSION` in db-grant Job
- [x] `pgaudit.log = 'DDL,ROLE'` — catches schema changes and privilege changes (ROLE redacts passwords)
- [-] Confirm logs flow through existing diagnostic setting → Log Analytics (deploy-time check)
- [x] Document the query for "show me all DDL in the last 24h"
- [x] ADR-0030 — full decision captured ([docs/decisions/0030-postgres-audit-logging.md](docs/decisions/0030-postgres-audit-logging.md))

**Why:** Privileged DDL/DML (db-grant, db-migrator) isn't auditable today.
**Effort:** small

---

### 9. Automated event upload K8s Job

- [x] `event-upload` Job manifest (mirrors `db-load-events` pattern) + dedicated `event-uploader` UAMI (Storage Blob Data Contributor, least-privilege)
- [x] `event-upload.yml` workflow (manual dispatch)
- [x] Reads JSON from repo checkout (ConfigMap from `data/events/`), uploads via Workload Identity over the private endpoint
- [x] Runbook updated to remove the manual `az storage blob upload` step
- [x] ADR-0032 — full decision captured ([docs/decisions/0032-event-upload-job.md](docs/decisions/0032-event-upload-job.md))

**Why:** Removes the only "human-from-laptop" step. Unblocks #14.
**Effort:** medium
**Status:** Shipped. #14 (close storage public endpoint) is now unblocked.

---

### 10. PodDisruptionBudgets

- [x] PDB for api (`minAvailable: 1`)
- [x] PDB for worker (`minAvailable: 1`)
- [x] PDB for scheduler (`maxUnavailable: 1` — 2 replicas + leader election; maxUnavailable avoids deadlocking a drain)
- [x] Document the rollout / node-drain expectations (ADR-0033 "Operator path")

**Why:** AKS auto-upgrade or node patching can take the service fully down today.
**Effort:** small

---

### 11. `LimitRange` + `ResourceQuota`

- [x] `LimitRange` on `ticketing` namespace (default + max/min requests/limits per container)
- [x] `ResourceQuota` on `ticketing` namespace (total CPU / memory ceiling; guardrail, not bin-packing)
- [x] Confirm existing deployments still admit under the new constraints (kustomize build verified; LimitRange defaults keep the resource-less bootstrap Jobs admittable)

**Why:** Prevents a misconfigured pod from exhausting a node.
**Effort:** small

---

### 12. HPA on the API

- [x] HPA: 2–5 replicas, CPU target 70% (`replicas` removed from the api Deployment so the HPA owns the count)
- [x] Memory target — deliberately skipped (flaps on a stateless API; CPU-only)
- [x] Scheduler explicitly NOT autoscaled (leader election)
- [x] Worker: decided — fixed 2 replicas for now (CPU-HPA is the wrong signal for a queue consumer; KEDA queue-depth scaling deferred to its own item)
- [x] ADR-0033 — full decision captured ([docs/decisions/0033-workload-resilience-resource-governance.md](docs/decisions/0033-workload-resilience-resource-governance.md))

**Why:** API currently can't scale under load.
**Effort:** small (HPA only) / medium (with KEDA for the worker)
**Status:** #10–#12 shipped as one batch (ADR-0033). KEDA for the worker is the remaining optional follow-up.

---

## Tier 3 — Foundation work, large or with prerequisites

### 🔀 13. Private AKS cluster

- [x] `private_cluster_enabled = true` (no public FQDN; BYO `privatelink.<region>.azmk8s.io` zone + user-assigned control-plane identity)
- [x] Runner-access path chosen and implemented — **standing self-hosted runner in a durable hub VNet** (not `command invoke`: it can't carry Terraform's helm/kubernetes providers). New `terraform/platform` layer + `platform.yml` / `platform-teardown.yml` / `runner-power.yml` / `_ensure-runner.yml`; GitHub App registration
- [x] Every workflow that calls `kubectl` updated — `infra-uksouth` split (PR plan hosted / apply self-hosted), `db-migrate` / `db-grant` / `db-load-events` / `event-upload` / `deploy-gateway` / `teardown` → self-hosted with an auto-start pre-job
- [x] Remove `AVD-AZU-0041` and `AVD-AZU-0065` from `.trivyignore`
- [x] Runbook for the new access path ([docs/04-private-cluster-access.md](docs/04-private-cluster-access.md))
- [x] ADR-0035 — full decision captured ([docs/decisions/0035-private-aks-cluster.md](docs/decisions/0035-private-aks-cluster.md))
- [ ] **Deploy-time:** one-time GitHub App + secrets setup, run `platform.yml`, then deploy and confirm the cluster is private + add-ons reconcile via the runner

**Why:** Removes the public API server. Single biggest architectural lesson in this phase.
**Effort:** large (cascades into every kubectl-using workflow)
**Status:** Shipped as 3 PRs (platform + runner / private cluster + peering / workflows + docs). Auth unchanged (cert/key) — network path only; AAD + local-account-disable is a separate follow-up.

**🔀 Decision — runner access (BIG delta):** Chose **self-hosted runner in the VNet** over `az aks command invoke`. The plan originally leaned toward `command invoke`, but it proxies only the kubectl/helm CLI — it cannot carry Terraform's `helm`/`kubernetes` providers, which a private-cluster apply depends on. The runner is standing (deallocated between sessions for cost) in a durable hub, peered to the per-deploy spoke. See ADR-0035 for the rejected alternatives (authorized IP ranges, ephemeral two-phase, PAT).

---

### 14. Storage account: public endpoint off

- [x] `public_network_access_enabled = false` in the storage module
- [x] Remove `allowed_ip_ranges` plumbing (storage module var + env wiring); deployer-IP detection (`data.http.myip`) **kept** — still used by Key Vault
- [x] **Terraform data-plane gotcha:** with public off, the provider's blob-service availability poll hangs from the out-of-VNet deployer (azurerm #30893). Fixed with `features { storage { data_plane_available = false } }` — control-plane-only management, no in-VNet runner/azapi. Removed the now-dead deployer `Storage Blob Data Reader` grant + `time_sleep` (existed only for that poll)
- [x] ADR-0034 — full decision + rejected alternatives (in-VNet runner, azapi, defer) captured ([docs/decisions/0034-storage-public-endpoint-off.md](docs/decisions/0034-storage-public-endpoint-off.md))
- [ ] Deploy-time check: `terraform apply` completes without the data-plane hang; db-load-events + event-upload Job still read/write over the private endpoint; account shows `publicNetworkAccess: Disabled`

**Why:** Last public-internet surface on the data layer.
**Effort:** small
**Depends on:** #9 (done)
**Status:** Shipped. Closing the endpoint surfaced a Terraform-access gotcha (data-plane poll) solved natively via the provider feature flag — see ADR-0034.

---

### 15. Azure Policy / Gatekeeper add-on

- [ ] Enable `azure_policy_enabled = true` on AKS
- [ ] Assign the Kubernetes baseline initiative
- [ ] Triage policy violations (some may fail expected workloads)
- [ ] Remove `AVD-AZU-0066` from `.trivyignore`

**Why:** Governance layer; catches future misconfigurations across the cluster.
**Effort:** small–medium

---

### 16. PostgreSQL PITR restore drill

- [ ] Script: restore latest backup into a throwaway server
- [ ] Smoke check: row count + recent transaction visible + schema sanity
- [ ] Auto-delete the restored server on completion
- [ ] Runbook entry with a dated record of the drill
- [ ] Document measured RPO / RTO

**Why:** Backups exist; that they actually restore is unverified.
**Effort:** medium

---

## Tier 4 — Validation

### 17. Chaos drills

- [ ] Pod kill (api, worker, scheduler) — confirm PDBs hold
- [ ] Node drain — confirm pods reschedule, alerts fire as expected
- [ ] Postgres forced HA failover — observe app behaviour through the connection blip
- [ ] Service Bus throttling injection (optional)
- [ ] Each drill: dated runbook entry with what happened

**Why:** Validates #10, #12, alerts, and the system's actual resilience claims.
**Effort:** small

---

## Dependencies between items

- **#14 depends on #9** — storage public can close only after the upload Job exists.
- **#5 depends on #4** — let Dependabot maintain SHAs from the start.
- **#13 cascades** — every `kubectl`-using workflow needs editing.
- **#2 needs staging** — applying default-deny without per-service allow rules first breaks the cluster.

## Out of scope (Phase 4)

- Second region + Front Door + active-passive failover
- Cross-region DR automation
- Front Door as public-facing front-end (may change the cert story for #1)

## Where to start

- **Tier 1 in order** is a natural batch — independent items, low cumulative risk, good momentum.
- If a specific concern dominates: **#3 (alerts)** for ops visibility · **#1 (TLS)** for public posture · **#13 (private cluster)** for the biggest architectural lesson.
