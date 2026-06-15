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

- [ ] Install Kyverno via Helm
- [ ] ClusterPolicy: `ticketing-api` signed by `_deploy-common.yml@main`
- [ ] ClusterPolicy: `ticketing-worker` signed by `_deploy-common.yml@main`
- [ ] ClusterPolicy: `ticketing-scheduler` signed by `_deploy-common.yml@main`
- [ ] ClusterPolicy: `ticketing-db-grant` signed by `build-bootstrap-images.yml@main`
- [ ] Negative test in CI: apply an unsigned manifest, expect rejection
- [ ] Verify Kyverno policy reports appear in cluster events

**Why:** Today's CI verification can be bypassed by a manual `kubectl apply` or a misconfigured workflow.
**Effort:** medium
**Note:** Ratify is the Microsoft-supported alternative focused narrowly on supply-chain. Kyverno is preferred here because it also covers later policy needs (privileged container blocks, image registry allow-lists, etc.).

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

- [ ] `event-upload` Job manifest (mirrors `db-load-events` pattern)
- [ ] `event-upload.yml` workflow (manual dispatch)
- [ ] Reads JSON from repo checkout, uploads via Workload Identity
- [ ] Runbook updated to remove the manual `az storage blob upload` step

**Why:** Removes the only "human-from-laptop" step. Unblocks #14.
**Effort:** medium

---

### 10. PodDisruptionBudgets

- [ ] PDB for api (`minAvailable: 1`)
- [ ] PDB for worker (`minAvailable: 1`)
- [ ] PDB for scheduler (`maxUnavailable: 1` — single-replica with leader election)
- [ ] Document the rollout / node-drain expectations

**Why:** AKS auto-upgrade or node patching can take the service fully down today.
**Effort:** small

---

### 11. `LimitRange` + `ResourceQuota`

- [ ] `LimitRange` on `ticketing` namespace (default + max requests/limits per pod)
- [ ] `ResourceQuota` on `ticketing` namespace (total CPU / memory ceiling)
- [ ] Confirm existing deployments still admit under the new constraints

**Why:** Prevents a misconfigured pod from exhausting a node.
**Effort:** small

---

### 12. HPA on the API

- [ ] HPA: 2–5 replicas, CPU target 70%
- [ ] Memory target (if available on this metrics-server version)
- [ ] Scheduler explicitly NOT autoscaled (single-replica, leader election)
- [ ] Worker: decide whether to autoscale based on queue depth (KEDA?) or leave at fixed replicas

**Why:** API currently can't scale under load.
**Effort:** small (HPA only) / medium (with KEDA for the worker)

---

## Tier 3 — Foundation work, large or with prerequisites

### 🔀 13. Private AKS cluster

- [ ] `private_cluster_enabled = true`
- [ ] Runner-access path chosen and implemented (see decision)
- [ ] Every workflow that calls `kubectl` updated
- [ ] Remove `AVD-AZU-0041` and `AVD-AZU-0065` from `.trivyignore`
- [ ] Runbook updated for the new access path

**Why:** Removes the public API server. Single biggest architectural lesson in this phase.
**Effort:** large (cascades into every kubectl-using workflow)

**🔀 Decision — runner access (BIG delta):**

- **Production:** Self-hosted runners inside the VNet (VM scale set or container apps). Real infra, runner lifecycle to maintain, runner image to keep patched.
- **Learning:** `az aks command invoke` — Microsoft's CLI-proxied kubectl. No extra infra. Adds a few seconds per kubectl call, fine for our cadence.
- **Public jumphost:** rejected — adds back a public surface.
- **Recommendation:** `az aks command invoke` — demonstrates the private-cluster pattern without the ongoing operations of self-hosted runners. Note the production alternative in the runbook.

---

### 14. Storage account: public endpoint off

- [ ] `public_network_access_enabled = false` in the storage module
- [ ] Remove `allowed_ip_ranges` plumbing and the deployer IP detection where unused
- [ ] Confirm db-load-events still works via the private endpoint

**Why:** Last public-internet surface on the data layer.
**Effort:** small
**Depends on:** #9

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
