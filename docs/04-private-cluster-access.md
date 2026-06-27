# Runbook — Private AKS cluster access

The AKS API server is **private** (no public endpoint). Everything that talks to it — `terraform apply` (helm/kubernetes providers), the post-apply `kubectl` block, and the `db-*` / `event-upload` / `deploy-gateway` workflows — runs on a **self-hosted runner inside a durable hub VNet**, peered to the per-deploy spoke. Full design: **ADR-0035**.

This runbook covers the one-time setup, the day-to-day runner lifecycle, and how a human reaches the cluster.

## Mental model

- **`terraform/platform`** (state `platform.tfstate`, RG `rg-ticketing-platform`) is a **foundational layer** — durable across the regional deploy/teardown loop, like the shared ACR and the TF state account. It holds the hub VNet + the runner VM.
- The regional `teardown.yml` **never** touches it. Tear it down deliberately with `platform-teardown.yml`.
- Because the regional env reads `platform.tfstate`, **the platform must be deployed before any regional terraform plan/apply** — keep it up; deallocate the VM to save money.

## One-time setup

1. **Create a GitHub App**, installed on **this repo only**, with the **Administration: Read & write** repository permission (the minimum GitHub allows for repo-scoped runner registration). Download its private key.
2. Add GitHub Actions secrets:
   - `RUNNER_APP_ID`
   - `RUNNER_APP_PRIVATE_KEY` (the PEM)
   - `RUNNER_SSH_PUBLIC_KEY` (an SSH public key for break-glass VM access)
3. Run **`platform.yml`** (Actions → *Platform — hub VNet + self-hosted runner (deploy)* → Run workflow). It applies the platform and registers the runner.
4. Confirm the runner shows **Online** under *Settings → Actions → Runners* with labels `self-hosted, vnet, uksouth`.

## Day-to-day: runner lifecycle (the cost model)

The runner VM is a `Standard_B2s`. **Deallocate it between sessions** — you then pay disk + static IP only (~£6/mo); compute is billed only while it runs.

| Action | How |
|---|---|
| Start (begin a session) | `runner-power.yml` → `start` — or just trigger any cluster workflow; `_ensure-runner` auto-starts it |
| Deallocate (end a session) | `runner-power.yml` → `deallocate` (VM data + GitHub registration survive) |

`_ensure-runner.yml` runs as a pre-job on every self-hosted workflow: it checks the power state and starts the VM only if needed, so a deallocated runner never leaves a job queued. There is **no auto-stop** (it would race with a concurrent job) — deallocation is always deliberate.

## Running kubectl as a human

The cluster API has no public endpoint, so `az aks get-credentials` + `kubectl` from your laptop won't connect. Two options:

1. **`az aks command invoke`** (no runner needed for one-offs):
   ```sh
   az aks command invoke -g rg-ticketing-uksouth -n aks-ticketing-uksouth \
     --command "kubectl get pods -n ticketing"
   ```
2. **From the runner** (for an interactive session): `runner-power.yml` → `start`, then either `az vm run-command invoke ... --scripts "kubectl ..."`, or SSH in if you set `admin_ssh_cidr` on the platform VM. The runner already has `az`, `kubectl`, and `kubelogin`.

## Deploy / teardown ordering

- **Fresh start:** `platform.yml` (once) → confirm runner Online → normal regional deploy (`infra-uksouth`, `db-migrate`, …). The cluster workflows auto-start the runner.
- **Regional teardown:** `teardown.yml` as usual — its graceful `terraform destroy` runs on the runner (auto-started) to remove the cluster add-ons cleanly; the platform/runner survive.
- **Long idle / platform rebuild:** `platform-teardown.yml` (type `destroy`). To come back, run `platform.yml` again *before* any regional terraform.

## GitHub App key rotation

Generate a new private key in the App settings, update the `RUNNER_APP_PRIVATE_KEY` secret, and delete the old key. No redeploy needed — the key is used only at (de)registration time.

## Troubleshooting

- **A self-hosted job is stuck "Queued".** The runner is offline/deallocated and `_ensure-runner` didn't start it (or you triggered a job that has no ensure-runner). Run `runner-power.yml` → `start`.
- **`platform.yml` apply succeeds but the runner never goes Online.** Check `az vm run-command` output in the *Register the runner* step; cloud-init may still be installing (it waits up to ~10 min for `/opt/.runner-bootstrap-complete`). Re-run the workflow to re-register.
- **Regional terraform plan fails reading `hub_vnet_id`.** The platform isn't deployed (or was torn down). Run `platform.yml`.
- **Image-verification step fails on the runner** (`docker login`). The runner carries docker via cloud-init; if the VM predates that, re-create it (`platform-teardown` → `platform`).

## Production alternative

This uses a single standing runner (deallocated between sessions). At higher cadence the production pattern is a **VM scale set / ephemeral runners** (e.g. Actions Runner Controller) inside the VNet — autoscaling, no manual power management — at the cost of more infrastructure to maintain.
