# Platform config — hub VNet + self-hosted runner

Durable "ops" layer for the private-cluster deploy path (Phase 3 #13 / **ADR-0035**). Holds a **hub VNet** and a single **self-hosted GitHub Actions runner**. Once the AKS API server is private, the regional deploy must run from inside the VNet — `az aks command invoke` proxies the kubectl CLI but **cannot** carry Terraform's helm/kubernetes providers. This runner is that in-VNet execution context.

## Lifecycle

- **Own state** (`platform.tfstate`) and **own resource group** (`rg-ticketing-platform`), both **ignored by the regional `teardown.yml`** — the runner survives the deploy/test/teardown loop.
- Deploy with **`platform.yml`** (`workflow_dispatch`). Tear down deliberately with **`platform-teardown.yml`** (typed `destroy` confirmation).
- The hub↔spoke **peering** is created from the *spoke* side (`uksouth-primary`), so it comes and goes with each regional loop while the hub persists.

## Manual prerequisites (one-time)

1. **GitHub App** installed on **this repo only**, with **Administration: Read & write** (the minimum GitHub exposes for repo-scoped runner registration — see ADR-0035). Download its private key.
2. **GitHub Actions secrets:**
   - `RUNNER_APP_ID` — the App's ID
   - `RUNNER_APP_PRIVATE_KEY` — the App's private key (PEM)
   - `RUNNER_SSH_PUBLIC_KEY` — an SSH public key for the VM admin user (routine access is `az vm run-command`; the key satisfies the VM resource and is there for break-glass)

   The App private key never lands in Azure — `platform.yml` / `platform-teardown.yml` mint short-lived (1-hour) tokens from it.

## Cost

`Standard_B2s` runner. **Deallocate between loops** (`az vm deallocate`) to drop the bill to disk only (~£2–4/mo); the systemd runner service reconnects automatically on `az vm start`. See [docs/04-private-cluster-access.md](../../docs/04-private-cluster-access.md).

## Inputs / Outputs

See `variables.tf` / `outputs.tf`. Key output: `hub_vnet_id`, consumed by `uksouth-primary` via remote state to wire the peering + API DNS-zone link.
