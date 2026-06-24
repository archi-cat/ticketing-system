# ADR-0034: Close the event-data storage public endpoint (Terraform stays out of the VNet)

Status: Accepted
Date: 2026-06-23

## Context

Phase 3 Tier 3 #14. ADR-0032 (#9) moved event *uploading* into an in-cluster Job that writes over the storage **private endpoint**, removing the only reason the event-data storage account kept a **public endpoint** open (the operator's laptop `az storage blob upload`). That account was the **last public-internet surface on the data layer** — Postgres, Service Bus, Redis, and Key Vault's data path are already private.

The literal task was small: set `public_network_access_enabled = false` and drop the `allowed_ip_ranges` / deployer-IP plumbing. The catch is **Terraform's own access**, not the cluster's:

- The `azurerm_storage_account` resource performs a **data-plane** "availability" poll of the blob service endpoint (`GET https://<account>.blob.core.windows.net/?comp=properties&restype=service`, plus queue/static-website property reads) during create/refresh.
- Today that read succeeds only because public access is **on** and the deployer's IP is in `network_rules.ip_rules`. It is the reason the env grants the deployer **Storage Blob Data Reader** and waits for IAM propagation before creating the account.
- With public access **off**, that read — issued from the **out-of-VNet deployer** (laptop or GitHub-hosted runner) — hangs ~2 minutes, then errors. This is a known, still-open `azurerm` limitation ([#30893](https://github.com/hashicorp/terraform-provider-azurerm/issues/30893), [#25978](https://github.com/hashicorp/terraform-provider-azurerm/issues/25978)); `storage_use_azuread` does not avoid it ([#29984](https://github.com/hashicorp/terraform-provider-azurerm/issues/29984)).

The cluster's read/write path is **not** affected — db-load-events and the event-upload Job reach the account over the private endpoint from inside the VNet. The problem is purely that this project runs `terraform apply` from outside the VNet, in a deploy → test → tear-down loop.

## Decision

Set `public_network_access_enabled = false` on the storage account and disable the provider's data-plane path for storage:

```hcl
provider "azurerm" {
  features {
    storage {
      data_plane_available = false
    }
  }
}
```

`data_plane_available = false` makes the `azurerm_storage_account` resource skip the data-plane availability poll and the `queue_properties` / `static_website` reads. The account is then managed with **control-plane (ARM) calls only**, which work from anywhere the deployer can reach Azure Resource Manager — no in-VNet runner, no provider hang.

This is safe here because:

- This is the **only** `azurerm_storage_account` in the configuration, so the provider-wide flag's blast radius is exactly this account.
- The account declares **no** `queue_properties` / `static_website` blocks (the data-plane-dependent features the flag's documentation warns about).
- The events **container** is already managed via the Resource Manager API (`azurerm_storage_container` with `storage_account_id`, not `storage_account_name`), so it needs no data-plane access.
- No `azurerm_storage_blob` / `_queue` / `_share` / `_table` resources exist.

Follow-on cleanups that the closed endpoint makes dead code:

- Removed the deployer **`Storage Blob Data Reader`** role assignment and its `time_sleep` propagation wait — both existed solely for the now-bypassed availability poll.
- Removed the storage module's `allowed_ip_ranges` variable and the env's `allowed_ip_ranges = [chomp(data.http.myip.response_body)]` wiring. `network_rules` keeps `default_action = "Deny"` as defence in depth (fail-closed if public access is ever re-enabled).
- Kept `data.http.myip` / `local.deployer_ip_cidr` — still used by the Key Vault module, which stays public-with-allow-list (it has no private-only Terraform path; see Trade-offs).

## Alternatives considered

- **Run Terraform inside the VNet** (self-hosted runner / ACI / jumpbox). The production-grade answer, and it future-proofs any other private resource that needs a Terraform data-plane path. Rejected for now: it adds standing infrastructure and cost to a cost-minimal, loop-deployed learning project, and `data_plane_available = false` solves *this* resource without it. Noted as the path to revisit if the data layer grows more private data-plane-managed resources.
- **Re-manage the account with the `azapi` provider** (control-plane only by construction). Works, and `azapi` is already in the stack (ACNS). Rejected as heavier than needed: it means hand-writing the ARM body for one resource and a state migration, when an azurerm-native feature flag achieves the same control-plane-only management.
- **Defer #14** until the cluster runs continuously / an in-VNet runner exists. Rejected: it leaves the last public data-layer surface open when a clean, native close is available.
- **`az aks command invoke` (the #13 runner choice) does not help.** It proxies `kubectl` through the AKS API server; it does not put Terraform inside the VNet, so it has no bearing on the storage data-plane read.

## Trade-offs accepted

- **Provider-wide flag for an account-specific need.** `data_plane_available` is set on the provider, not the resource. Acceptable because there is exactly one storage account; if a second account ever needs `queue_properties` / `static_website`, it would need its own provider alias (or moving this account to `azapi`). Documented at the `features` block and in the storage module.
- **Key Vault still has a public endpoint with an IP allow-list.** This ADR closes storage, not Key Vault. KV keeps the deployer-IP allow-list because the Terraform secret-management path needs reachability and there is no equivalent "skip data plane" switch; that is why `data.http.myip` stays. Tightening KV is separate (and largely tied to the same in-VNet-runner question).
- **Defence-in-depth `network_rules` are inert while public access is off.** Kept deliberately so a future re-enable fails closed rather than open.

## Validation

- `terraform validate` passes (only pre-existing deprecation warnings).
- Deploy-time check (next loop): `terraform apply` completes without the blob-service-properties hang; db-load-events and the event-upload Job still read/write over the private endpoint; the account shows `publicNetworkAccess: Disabled` and rejects a public `az storage blob list`.

## References

- `terraform/modules/data/storage/main.tf` — `public_network_access_enabled = false`, `network_rules` deny-by-default
- `terraform/environments/uksouth-primary/main.tf` — provider `features { storage { data_plane_available = false } }`; removed deployer role + `time_sleep` + `allowed_ip_ranges`
- ADR-0032 — the in-cluster upload Job that made the public endpoint unnecessary (the prerequisite, #9)
- ADR-0019 — event-loading design; first noted closing this endpoint as Phase 3 work
- azurerm provider [features block — `data_plane_available`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/guides/features-block)
