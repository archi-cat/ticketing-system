# ADR-0035: Private AKS cluster reached via a standing in-VNet self-hosted runner

Status: Accepted
Date: 2026-06-26

## Context

Phase 3 Tier 3 #13. The AKS API server was **public** (no `private_cluster_enabled`, no authorized IP ranges) — the last open control-plane surface after #14 closed the data layer. The goal is a fully private API server (no public endpoint).

The flag is trivial; **access** is the hard part. Once the API server is private it is reachable only from inside the VNet, and that breaks two things that run from outside it today:

1. **Terraform's `helm`/`kubernetes` providers.** Five modules (`cert-manager`, `cert-manager-duckdns`, `external-secrets`, `kyverno`, and the env's provider blocks) talk to the API server during `terraform apply`. `az aks command invoke` proxies the kubectl/helm **CLI** but cannot carry a Go API client — so it does **not** solve this.
2. **The post-apply `kubectl` block** in `infra-uksouth.yml` plus the `db-*`, `event-upload`, and `deploy-gateway` workflows.

`teardown.yml` `az group delete`s the entire regional resource group (VNet included) and wipes state every loop, so the execution context can't live in the per-deploy VNet.

## Decision

Run everything that touches the API server on a **standing self-hosted GitHub Actions runner in a durable hub VNet**, peered to the per-deploy spoke.

### Topology — hub/spoke

A new **`terraform/platform`** config (own state `platform.tfstate`, own `rg-ticketing-platform`) holds a **hub VNet** and one **runner VM**. It is a **foundational layer** — durable across the regional deploy/teardown loop (like the shared ACR and the TF state account), with its own `platform.yml` / `platform-teardown.yml` lifecycle. The regional `teardown.yml` never touches it.

Each regional deploy peers the spoke to the hub (both directions, managed from the spoke so they come and go with the loop) and links the BYO API private DNS zone to the hub. The runner pre-exists, so the per-deploy apply has **no chicken-and-egg**: cluster creation is control-plane (ARM, no API needed); only the add-ons need the API, and they `depends_on` the peering + DNS link.

### Private cluster mechanics

`private_cluster_enabled = true`, no public FQDN, with a **BYO private DNS zone** (`privatelink.<region>.azmk8s.io`) owned by the network module so it can be linked to both VNets. BYO DNS forces a **user-assigned control-plane identity** (it must hold *Private DNS Zone Contributor* on the zone *before* the cluster exists, which a system-assigned identity can't) — pre-granted *Network Contributor* on the spoke VNet and *Private DNS Zone Contributor* on the zone.

Auth is **unchanged**: the cluster keeps local accounts, so the providers and kubectl use the `kube_config` cert/key. #13 changes the network **path**, not the auth model — AAD / local-account-disable is a separate future item.

### Runner registration — GitHub App

The runner registers via a **GitHub App** (installed on this repo only, *Administration: read & write* — the minimum GitHub exposes for repo-scoped runner registration; there is no narrower repo permission). `platform.yml` mints a 1-hour registration token from the App and feeds it to the VM with `az vm run-command`; the App private key stays a GitHub Actions secret and never lands in Azure. `platform-teardown.yml` deregisters server-side by name.

### Workflow split + cost model

- `infra-uksouth.yml`: PR `plan` on a **hosted** runner (`-refresh=false`, so opening a PR never needs the runner); push `apply` + the post-apply kubectl block on the **self-hosted** runner.
- `db-migrate`, `db-grant`, `db-load-events`, `event-upload`, `deploy-gateway`, and `teardown`'s graceful destroy run on the **self-hosted** runner. (`kyverno-policy-test` uses kind — unaffected. The image-build/deploy-* workflows push to the public ACR — unaffected.) The runner carries docker for the cosign `docker login` step.
- **Cost:** the runner is deallocated between sessions (`runner-power.yml`) — disk-only billing. A reusable `_ensure-runner.yml` pre-job **auto-starts** it before any self-hosted job so a deallocated runner never leaves a job queued. There is deliberately **no auto-stop** (it would race with a concurrent job); deallocation is a session action.

## Rejected alternatives

- **Authorized IP ranges (restricted-public API).** Smaller change, keeps the loop, but leaves a public (firewalled) endpoint and clears only `AVD-AZU-0041`, not `AVD-AZU-0065`. Rejected: #13's goal is a genuinely private cluster.
- **Ephemeral two-phase runner** (bootstrap config builds the runner per-deploy on a hosted runner, then the cluster applies from it). No standing cost, but moves the network module into a bootstrap state and adds real workflow orchestration (registration/online-wait/dereg). Rejected for complexity.
- **`az aks command invoke` for everything.** Can't carry the Terraform providers at all, and turns every kubectl interaction into a clunky `--file`/poll rewrite. Rejected.
- **PAT for runner registration.** A long-lived stored credential; the App mints short-lived tokens instead.

## Trade-offs accepted

- **Standing infra + cost.** A B2s VM (deallocated ≈ disk + static IP, ~£6/mo; compute only while deploying). The static public IP gives a stable egress for the Key Vault firewall self-allow-list.
- **The platform is a hard dependency of the regional env** (`data.terraform_remote_state.platform`). Tearing the platform down red-lines regional terraform plans — the same coupling the env already has on the shared ACR. The platform is therefore treated as durable: keep it, deallocate the VM; only `platform-teardown` it for long idles / rebuilds.
- **The GitHub App key is the one stored secret**, and *Administration: write* is broad (also governs repo settings). Contained by a single-repo install + 1-hour tokens. A narrower runner-only permission exists only at org scope (would require moving the repo into an org).
- **Docker on the runner** for the cosign `docker login` step — standard for a CI runner; keeps the image-verification path byte-identical.

## Operator path

- **Start of a session:** run `runner-power.yml` → `start` (or just trigger a workflow — `_ensure-runner` starts it). Merge/deploy as usual; the apply lands on the runner.
- **Human kubectl:** start the runner and SSH / `az vm run-command`, or use `az aks command invoke` for one-off commands.
- **End of a session:** `runner-power.yml` → `deallocate` (data + registration survive).
- **One-time setup:** create the GitHub App + add `RUNNER_APP_ID`, `RUNNER_APP_PRIVATE_KEY`, `RUNNER_SSH_PUBLIC_KEY`; run `platform.yml`; confirm the runner is Online. See [docs/04-private-cluster-access.md](../04-private-cluster-access.md).

## Future work

- **AAD + Azure RBAC, `local_account_disabled = true`** — the auth-model hardening this ADR deliberately scoped out.
- **VMSS / ephemeral runners** — the production-grade autoscaling runner story, if the cadence ever justifies it.
- **Scheduled idle deallocation** — a cron safety net so a forgotten runner doesn't bill compute overnight.

## References

- `terraform/platform/` — hub VNet + runner (config + cloud-init)
- `.github/workflows/platform.yml` / `platform-teardown.yml` / `runner-power.yml` / `_ensure-runner.yml`
- `terraform/modules/aks/` — `private_cluster_enabled`, BYO DNS, user-assigned identity
- `terraform/environments/uksouth-primary/main.tf` — platform remote state, peering, hub DNS link, control-plane UAMI + grants
- ADR-0034 — closing the storage public endpoint (the data-layer counterpart, #14)
- ADR-0005 — original AKS cluster design
