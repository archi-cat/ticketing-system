# Teardown runbook

How to tear the project down for a clean rebuild, what gets preserved, and how to recover when a delete hangs.

The teardown itself runs entirely through `.github/workflows/teardown.yml`. This document covers the **operator-side flow around it** — what to do before triggering, what the workflow does step by step, and what to do when something doesn't clean up automatically.

## When to use this

- **Routine deploy-test-rebuild loops** (the project's current cadence). Tear down at end of session, redeploy at start of next.
- **Failed deploy recovery.** When `infra-uksouth.yml` fails partway and leaves a mix of created + half-created + missing resources, a full teardown + rebuild is usually faster than trying to resume.
- **Region migration.** Phase 4 will require tearing down the current uksouth deploy before standing up the multi-region topology.

## Preflight — do these BEFORE triggering teardown

### 1. Export ACME account keys if you want to preserve them

Without this step, the next deploy registers fresh Let's Encrypt accounts (low-stakes per [docs/02-cert-rotation.md](02-cert-rotation.md), but worth doing if you're iterating frequently).

```bash
kubectl get secret -n cert-manager letsencrypt-staging-account-key \
  -o yaml > letsencrypt-staging-account-key.yaml
kubectl get secret -n cert-manager letsencrypt-production-account-key \
  -o yaml > letsencrypt-production-account-key.yaml 2>/dev/null \
  || echo "production key doesn't exist yet — only created on first production issuance"
```

These files are gitignored. Re-apply them on the next deploy after the `cert-manager` namespace exists but before the ClusterIssuers reconcile.

### 2. Anything else worth keeping

| Asset | Default behaviour | Preserve it by |
|---|---|---|
| DuckDNS token | Stays in GitHub Actions repo secrets | No action needed |
| DuckDNS subdomain + account | Lives at duckdns.org, outside Azure | No action needed |
| Postgres data | Deleted with the Flexible Server | (No backup mechanism for this learning project — accepted loss) |
| ACR images | Deleted with the shared RG | (Re-built by `_deploy-common.yml` on next push) |
| Terraform state | Cleared by the workflow (optional input) | Set `delete_state_files=false` to keep |

### 3. Confirm nothing important is mid-flight

The teardown's `concurrency: group: teardown` only protects against parallel teardowns. It doesn't know about other workflows:

```bash
gh run list --workflow infra-uksouth.yml --limit 5 --status in_progress
gh run list --workflow deploy-api.yml --limit 5 --status in_progress
gh run list --workflow deploy-gateway.yml --limit 5 --status in_progress
```

If an apply is mid-flight, wait for it to finish (or cancel it) before starting teardown. Concurrent terraform applies and resource deletions corrupt state.

## Triggering the workflow

Actions tab → **Teardown — destroy regional + shared infra** → **Run workflow**.

Three inputs:

| Input | Default | Effect |
|---|---|---|
| `confirm` | (required) | Must be exactly the string `destroy`. Anything else aborts before Azure login. Intentionally not a checkbox — typing the word is friction that prevents accidental triggers. |
| `purge_soft_deleted` | `true` | Purges any soft-deleted Key Vault matching `kv-ticketing*` so the same vault name can be reused immediately. Relevant while [Phase 3 Tier 1 #6](../phase_3_plan.md#6-key-vault-purge-protection--deferred) (purge protection) stays deferred. Set to `false` if you're investigating a Key Vault issue and want the 7-day recovery window. |
| `delete_state_files` | `true` | Clears `uksouth-primary.tfstate`, `shared-acr.tfstate`, and any `.tflock` companions in the state storage account. Set to `false` if you want to keep state for any reason (e.g. you're going to manually edit state, or you want a record of what existed). |

## What the workflow does, in order

End-to-end takes ~25–40 minutes on a fully-deployed cluster (AKS teardown dominates).

### Phase 1 — Confirm intent (`guard` job)

Runs **before** Azure login. If `confirm != "destroy"`, fails immediately. This is why a typo can't cause damage.

### Phase 2 — Pre-flight listing

Lists every resource currently in `rg-ticketing-uksouth`, `rg-ticketing-uksouth-aks-nodes`, and `rg-ticketing-shared`. This is the last chance to see what's about to disappear.

### Phase 3 — Delete the regional RG

`az group delete -n rg-ticketing-uksouth --yes` then wait. **15–25 minutes** on a fully-deployed cluster:

- AKS control plane teardown
- VMSS node pool deletion
- Network resource cleanup (load balancers, NICs, private endpoints)
- Cascading deletes for everything inside the RG

### Phase 4 — Verify regional + chase orphans

After the regional RG is gone, the workflow looks for three classes of orphan:

| Orphan | What it means | Workflow action |
|---|---|---|
| Regional RG still present | `az group delete` returned but the RG is still in subscription view | Fail the job |
| AKS node RG `rg-ticketing-uksouth-aks-nodes` still present | AKS sometimes leaves it behind with stranded NICs or disks | Explicit delete |
| Other `rg-ticketing-uksouth*` RG | Unexpected — possibly from a prior failed deploy | Surface in log, don't auto-delete |
| Subscription-wide resources still named `ticketing-uksouth*` | Diagnostic only — would be a sign of strange leakage | Surface in log, don't auto-delete |

### Phase 5 — Purge soft-deleted Key Vaults (optional)

Iterates `az keyvault list-deleted` matching `kv-ticketing*` and purges each. Without this, the same vault name is unavailable for 7 days.

### Phase 6 — Delete the shared RG

`az group delete -n rg-ticketing-shared --yes` then wait. **2–5 minutes** typically — ACR (even with geo-replication) deletes quickly compared to AKS.

### Phase 7 — Verify shared RG is gone

Same shape as Phase 4 but only for the shared RG.

### Phase 8 — Delete state blobs (optional)

For each of `uksouth-primary.tfstate` and `shared-acr.tfstate` (plus any `.tflock` companions): check if the blob exists in the state container, delete if so. The **state storage account itself** lives in `TF_STATE_RESOURCE_GROUP` (separate) and is never touched by this workflow.

### Phase 9 — Summary

Prints which RGs were deleted, whether soft-deleted KVs were purged, and whether state was cleared.

## What's preserved across teardowns

The workflow deliberately doesn't touch:

- **The Terraform state resource group** — bootstrap infrastructure, identified by the `TF_STATE_RESOURCE_GROUP` secret. Holds the state storage account.
- **The GitHub OIDC service principal and federated credentials** — subscription-scope; removing them would break every workflow.
- **Any RG outside the explicit list** — the diagnostic listing at Phase 4 surfaces strays but won't auto-delete them.
- **Repo secrets** — including `DUCKDNS_FQDN`, `ACME_EMAIL`, `DUCKDNS_API_TOKEN`, `NAME_SUFFIX`, etc. These persist on GitHub.
- **DuckDNS account, subdomain, A record** — lives at duckdns.org. The A record will point at the *previous* AGC frontend IP until the next deploy updates it; harmless because there's no AGC behind that IP anymore.

## Recovery — when something doesn't clean up

### A delete step hangs past its expected window

`az group delete` is async; the workflow waits for it inline. If AKS is taking dramatically longer than 25 minutes:

1. Don't cancel the workflow — the delete continues server-side regardless of the workflow run.
2. From your local CLI or the portal, check what's still in the RG:
   ```bash
   az resource list -g rg-ticketing-uksouth -o table
   ```
3. The usual stuck resource is a private endpoint with a dangling DNS record, or a VMSS instance that didn't drain cleanly. Both can be force-deleted from the portal.
4. Once unstuck, re-run the workflow — it's idempotent. Each delete step checks `az group show` first and skips if the RG is already gone.

### A Resource Lock blocks deletion

If someone (or some policy) put a `CanNotDelete` lock on a resource, `az group delete` fails with `ScopeLockedForDeletion`. Locks aren't created by this project's IaC, so this usually means a subscription-level policy.

```bash
# Find locks
az lock list --resource-group rg-ticketing-uksouth -o table

# Remove (if you have Owner / lock-removing permission)
az lock delete --name <lock-name> --resource-group rg-ticketing-uksouth
```

Then re-run the teardown workflow.

### Soft-deleted KV purge failed

The `Purge soft-deleted Key Vaults` step emits a `::warning::` on individual failures (so one bad purge doesn't fail the whole job). If a vault is stuck soft-deleted after a manual retry:

```bash
# Try the explicit purge
az keyvault purge --name <vault-name> --location uksouth

# If still failing, the SP may lack purge permission. Add it temporarily:
az role assignment create \
  --role "Key Vault Administrator" \
  --assignee <sp-object-id> \
  --scope "/subscriptions/<sub-id>"
```

Or just let the 7-day soft-delete window expire and pick a different vault name on the next deploy.

### State blob deletion fails with 403

The OIDC SP needs `Storage Blob Data Contributor` on the state container (set up during Phase 0.2 of [fresh deployment](01-fresh-deployment.md)). If this role assignment ever goes missing the step fails with a 403. Restore with:

```bash
az role assignment create \
  --role "Storage Blob Data Contributor" \
  --assignee <sp-object-id> \
  --scope "/subscriptions/<sub-id>/resourceGroups/<state-rg>/providers/Microsoft.Storage/storageAccounts/<state-account>/blobServices/default/containers/<state-container>"
```

### The next deploy still sees old resources

This shouldn't happen if `delete_state_files=true`, because the next `terraform plan` runs against empty state and proposes creating everything from scratch. If you skipped that input and the next plan shows confusing diffs:

```bash
cd terraform/environments/uksouth-primary
terraform init -backend-config=... # same as the workflow
terraform state list
# If anything's there, the state is referencing already-deleted resources
terraform state rm <each.address>
```

Or just re-run the teardown workflow with `delete_state_files=true`.

## After teardown — preparing for the next deploy

Nothing else is required between teardown and the next deploy beyond what's already in [docs/01-fresh-deployment.md](01-fresh-deployment.md). The workflow leaves the project in the same state as a clean clone of the repo, with the bootstrap infrastructure (state RG, OIDC SP) still in place.

Specifically:

- `infra-uksouth.yml` can run immediately. It'll create the regional RG from scratch.
- `infra-shared.yml` should run first if the shared RG was destroyed too. ACR creation is fast (~2 min).
- The DuckDNS A record will point at nothing until `infra-uksouth.yml`'s post-apply step updates it.
- If you exported ACME account keys in the preflight, re-apply them after `infra-uksouth.yml` creates the `cert-manager` namespace and before the ClusterIssuers reconcile.

## When to revisit this workflow

The workflow is intentionally hardcoded for the current two-RG topology. It'll need updating when:

- **Phase 3 Tier 1 #6 (Key Vault purge protection)** is un-deferred. Soft-delete behaviour changes; the purge step becomes irreversible-and-mandatory.
- **Phase 3 Tier 1 #13 (private AKS cluster)** lands. Possible new subnet-level dependencies that affect delete order.
- **Phase 4 multi-region**. A second regional RG joins the list, and the order question gets interesting (delete both regions in parallel? sequentially? cross-region replicas first?).
