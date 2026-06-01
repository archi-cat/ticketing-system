# Fresh deployment runbook

End-to-end deployment from empty Azure subscription to running services.
The order is strict — each phase depends on prior phases being complete.

## Common gotchas

This runbook captures the operational reality of deploying this system,
including subtle issues that are easy to miss:

- **PostgreSQL is VNet-injected** — not reachable from outside the VNet,
  including from Azure Cloud Shell. A temporary VM inside the VNet is
  the canonical bootstrap path. Phase 2 will move this to a Kubernetes
  Job.
- **Two NSG layers** — the subnet-level NSG must allow SSH inbound for
  the temp VM, not just the NIC-level NSG. See Step 2.1a.
- **Roles vs Entra principals** — applications need to be created via
  `pgaadauth_create_principal` (in the `postgres` database), not plain
  `CREATE ROLE`. Otherwise `pg_hba.conf` rejects their tokens despite
  the role existing. See Step 2.4.
- **AGC add-on is preview** — `ApplicationLoadBalancerPreview` and
  `ManagedGatewayAPIPreview` must be registered once per subscription.
  Phase 0.1.

## Phase 0 — Subscription prerequisites (one-time)

These need to be done once per Azure subscription. After they're set,
future deployments don't need to repeat them.

### 0.1 Register AKS preview features

The AGC (Application Gateway for Containers) add-on and the Gateway API
managed installation are behind preview feature flags. Register them once
per subscription:

```powershell
az feature register --namespace Microsoft.ContainerService --name ApplicationLoadBalancerPreview
az feature register --namespace Microsoft.ContainerService --name ManagedGatewayAPIPreview

# Wait 5-15 minutes until both report "Registered"
az feature show --namespace Microsoft.ContainerService --name ApplicationLoadBalancerPreview --query "properties.state"
az feature show --namespace Microsoft.ContainerService --name ManagedGatewayAPIPreview --query "properties.state"

# Propagate to the resource provider
az provider register --namespace Microsoft.ContainerService
```

Reference: https://learn.microsoft.com/en-us/azure/aks/managed-gateway-api

### 0.2 Create the Terraform state storage

The shared ACR module and the regional infrastructure module both write
their state here. See `terraform/bootstrap/README.md` for the exact
commands. Set up once per subscription.

### 0.3 Configure the OIDC federated identity for GitHub Actions

Create the Service Principal `sp-hello-world-github` with federated
credentials for this repo's main branch and PR workflows. See ADR-0001
for context.

### 0.4 DuckDNS prerequisites (Phase 3 Tier 1 #1 — Gateway TLS)

The Gateway terminates TLS using a Let's Encrypt cert issued via the
DuckDNS DNS-01 challenge. The DuckDNS account is set up once and
persists across teardown/redeploy cycles — Terraform never sees the
DuckDNS API token.

1. Sign up at [duckdns.org](https://www.duckdns.org/) (Google login).
2. Reserve a subdomain. Note the **full FQDN** (e.g.
   `ticketing-floryda.duckdns.org`).
3. Copy your DuckDNS token from the dashboard. The token is per-account,
   not per-subdomain.
4. Add three GitHub Actions repository secrets:

   | Secret | Value | Notes |
   |---|---|---|
   | `DUCKDNS_FQDN` | full FQDN from step 2 | e.g. `ticketing-floryda.duckdns.org` |
   | `ACME_EMAIL` | your email | Let's Encrypt sends expiry-warning notices here |
   | `DUCKDNS_API_TOKEN` | token from step 3 | Set in Key Vault by the infra-uksouth workflow — not passed to Terraform |

None of the three values are Terraform variables. `DUCKDNS_FQDN` and
`ACME_EMAIL` are substituted into the YAML manifests in
`k8s/cluster-addons/cert-pipeline/` via `envsubst` during the infra-uksouth
workflow's post-apply step. `DUCKDNS_API_TOKEN` is set directly in Key Vault
by the same post-apply step. None of them appear in Terraform state or plan
output; ESO retrieves the API token from Key Vault at runtime via Workload
Identity.

## Phase 1 — Infrastructure deployment

### 1.1 Deploy the shared ACR

```powershell
gh workflow run infra-shared.yml
```

Wait for completion (~5 minutes).

### 1.2 Deploy the regional infrastructure

```powershell
gh workflow run infra-uksouth.yml
```

This single apply (~20-25 minutes) creates everything: VNet, AKS, the AGC
add-on (enabled via the azapi provider), AGC itself, the data layer, and
all role assignments. There is no separate manual add-on step — see
ADR-0016.

The apply includes a ~3-minute wait after the AGC add-on is enabled,
allowing the AKS-managed ALB Controller UAMI to materialise before the
AGC role assignments are created against it.

## Phase 2 — Database bootstrap

The application database is bootstrapped by in-cluster Kubernetes Jobs —
there is no temporary VM. See ADR-0018 for the design.

Three operations, run in order on a fresh environment:

1. **Grant** — registers the application UAMIs as PostgreSQL Entra
   principals and grants them privileges. Human-gated.
2. **Migrate** — `alembic upgrade head`. Creates the schema.
3. **Data load** — downloads a JSON file from Blob Storage and inserts
   events into the database.

All three steps are covered in this section.

### 2.0 Prerequisites

- The regional infrastructure is deployed (`infra-uksouth` has run) — the
  two bootstrap UAMIs (`db-migrator`, `db-grant`) exist.
- The `ticketing` namespace exists in the cluster (created by the first
  application deploy, or the `shared` Kustomize unit).
- The bootstrap images have been built and pushed:
  `build-bootstrap-images` has run at least once. On a brand-new
  environment, confirm `ticketing-db-grant:latest` exists in ACR before
  proceeding — otherwise the grant Job fails with `ImagePullBackOff`.

### 2.1 Step 1 — Elevate the db-grant identity (human action)

The grant Job runs as the `db-grant` UAMI, which has no standing
PostgreSQL rights. Before triggering the workflow, a human must elevate
it to a PostgreSQL Entra admin.

Gather the values:

```bash
# From the regional Terraform state
cd terraform/environments/uksouth-primary

PG_SERVER=$(terraform output -raw postgres_fqdn | cut -d. -f1)
DB_GRANT_NAME=$(terraform output -json workload_identity_names | jq -r '."db-grant"')
DB_GRANT_OBJECT_ID=$(terraform output -json workload_identity_principal_ids | jq -r '."db-grant"')
```

Elevate:

```bash
az postgres flexible-server microsoft-entra-admin create \
  --resource-group rg-ticketing-uksouth \
  --server-name "$PG_SERVER" \
  --display-name "$DB_GRANT_NAME" \
  --object-id "$DB_GRANT_OBJECT_ID" \
  --type ServicePrincipal
```

This is the one deliberate manual action — it is the human decision to
permit a privileged database operation. Everything after this is
automated.

### 2.2 Step 2 — Run the grant workflow

Trigger the `DB Grant` workflow (`db-grant.yml`) from the GitHub Actions
UI (`workflow_dispatch`).

The workflow will:

1. **Pre-flight** — confirm `db-grant` is in fact an elevated admin. If
   Step 1 was skipped, the workflow fails here with a clear message
   rather than letting the Job fail obscurely.
2. Apply the `db-grant` ServiceAccount and Job.
3. Wait for the Job, polling for completion. On failure or timeout it
   dumps the Job description and pod logs.
4. **Revoke** the `db-grant` elevation — in an `if: always()` step, so it
   runs whether the Job succeeded or not.

### 2.3 Step 3 — Confirm the outcome

After the workflow completes:

- The workflow's revoke step should report the elevation removed. Confirm
  `db-grant` is no longer an admin:

```bash
  az postgres flexible-server microsoft-entra-admin list \
    --resource-group rg-ticketing-uksouth \
    --server-name "$PG_SERVER" \
    --query "[].displayName" -o tsv
```

  `db-grant` should NOT appear. If it does — for example the workflow was
  cancelled before the revoke — remove it manually with
  `az postgres flexible-server microsoft-entra-admin delete` (see the elevation
  command above for the parameters).

- The grant Job's logs (in the workflow output) end with the registered
  principals: `api`, `worker`, `scheduler`, `db-migrator`.

### 2.4 If the grant Job fails

The workflow dumps `kubectl describe job` and pod logs on failure. Common
causes:

- **`ImagePullBackOff`** — the `db-grant` image is not in ACR. Run
  `build-bootstrap-images` first.
- **Authentication failure connecting to PostgreSQL** — the pre-flight
  check should catch a missing elevation, but if the elevation was
  removed between Step 1 and the Job running, re-elevate and re-run.
- **`az login` permission errors in the pod** — the workload-identity
  wiring (the `azure.workload.identity/use` pod label, the
  ServiceAccount's client-id annotation) is misconfigured.

The workflow is safe to re-run: it deletes any stale Job first, and the
grant SQL is idempotent. Re-running requires `db-grant` to be elevated
again (the previous run revoked it) — repeat Step 1, then Step 2.

### 2.5 When to re-run the grant

The grant only needs re-running when the **set of principals changes** —
e.g. a new application service with its own UAMI is added. It does **not**
need re-running for ordinary code deploys or schema migrations. On a
fully fresh environment (new PostgreSQL server) it must be run once before
migrations.

---

### 2.6 Step 2 — Run the migration workflow

**Dependency:** the grant Job (Step 1) must have completed successfully.
The migration Job connects as the `db-migrator` UAMI; until db-grant has
registered that identity as a PostgreSQL Entra principal, the connection
will be rejected.

Trigger the `DB Migrate` workflow (`db-migrate.yml`) from the GitHub Actions
UI (`workflow_dispatch`). You can optionally specify an image tag; the
default is `latest`.

The workflow will:

1. Read Terraform outputs to resolve the AKS cluster name, the db-migrator
   UAMI name, and the ACR login server.
2. Apply the `db-migrator-service-account` ServiceAccount (idempotent — safe
   to run even if a previous `db-migrate` or `db-load-events` run already
   created it).
3. Delete any stale `db-migrate` Job from a prior run, then render and apply
   the Job manifest with `envsubst`.
4. Poll until the Job completes or fails (5-minute timeout), then print the
   pod logs.

On success the logs will end with Alembic reporting
`Running upgrade -> 20260427_1200, initial schema`.

### 2.7 If the migration Job fails

The workflow dumps `kubectl describe job` and pod logs on failure. Common
causes:

- **`ImagePullBackOff`** — the API image is not in ACR. Run `deploy-api.yml`
  at least once first, or trigger a build manually.
- **Authentication failure connecting to PostgreSQL** — the db-grant Job has
  not run yet, or it failed. Check that `db-migrator` is listed in the
  output of `az postgres flexible-server microsoft-entra-admin list` (it should NOT appear
  — it is a non-admin Entra principal registered by `pgaadauth_create_principal`,
  not an AD admin). If the grant Job never succeeded, re-run Phase 2 Step 1.
- **Workload Identity token failure** — the pod label
  `azure.workload.identity/use: "true"` or the ServiceAccount's
  `azure.workload.identity/client-id` annotation is wrong. Check the
  `migrator_client_id` Terraform output matches the annotation on the
  ServiceAccount.
- **Alembic finds no migrations** — the alembic directory was not copied
  into the image. Verify the Dockerfile copies `alembic.ini` and `alembic/`.

The workflow is safe to re-run: it deletes the stale Job first, and
`alembic upgrade head` is idempotent (it skips already-applied revisions).

---

### 2.8 Step 3 — Upload the events JSON file

**Dependency:** the migration Job (Step 2) must have completed successfully.
The events table must exist before the load Job can insert into it.

The load-events Job reads its input from a JSON blob in the event-data
storage account. Upload the file before triggering the workflow:

```bash
# From the regional Terraform state
cd terraform/environments/uksouth-primary
STORAGE_ACCOUNT=$(terraform output -raw storage_blob_endpoint | \
  sed 's|https://||;s|\.blob\.core\.windows\.net.*||')

az storage blob upload \
  --account-name "$STORAGE_ACCOUNT" \
  --container-name events \
  --name sample-events.json \
  --file data/events/sample-events.json \
  --auth-mode login
```

Your Entra ID identity needs `Storage Blob Data Contributor` on the events
container (or account) to upload. The `db-migrator` UAMI only has reader
rights.

The JSON file is a top-level array. Each object must have an explicit `id`
(UUID) so the operation is idempotent — see `data/events/sample-events.json`
for the format and `docs/decisions/0019-db-load-events-design.md` for the
full schema.

### 2.9 Step 4 — Run the load-events workflow

Trigger the `DB Load Events` workflow (`db-load-events.yml`) from the GitHub
Actions UI (`workflow_dispatch`). Supply the blob filename as the
`blob_name` input (e.g. `sample-events.json`). The `image_tag` input
defaults to `latest`.

The workflow will:

1. Read Terraform outputs to resolve the AKS cluster, the db-migrator UAMI
   name, the storage account blob endpoint, and the events container name.
2. Apply the `db-migrator-service-account` ServiceAccount (idempotent).
3. Delete any stale `db-load-events` Job, then render and apply the Job
   manifest with the storage URL, container name, and blob name substituted.
4. Poll until the Job completes or fails (5-minute timeout), then print the
   pod logs.

On success the logs will end with a line like:
`Done — inserted 4 event(s), skipped 0 duplicate(s)`.

Running the workflow again with the same blob is safe — the second run
inserts nothing (all IDs already exist) and exits with
`inserted 0 event(s), skipped 4 duplicate(s)`.

### 2.10 If the load-events Job fails

The workflow dumps `kubectl describe job` and pod logs on failure. Common
causes:

- **`ImagePullBackOff`** — the API image is not in ACR.
- **Blob not found** — the blob name supplied to the workflow doesn't exist
  in the storage account. Verify the upload (Step 3) completed and that the
  filename matches exactly (case-sensitive).
- **Authentication failure on Storage** — the `db-migrator` UAMI does not
  have `Storage Blob Data Reader` on the events container. The Terraform
  `storage` module should have assigned this — check the role assignment
  exists in the Azure portal or with `az role assignment list`.
- **Authentication failure on PostgreSQL** — see the same cause in 2.7.
- **JSON parse error** — the blob content is not valid JSON, or the array
  elements are missing required fields (`id`, `name`, `venue`, `starts_at`,
  `total_seats`, `price_pence`). Fix the file, re-upload, and re-run.

The workflow is safe to re-run after fixing the root cause: it deletes the
stale Job first, and the insert is idempotent.

### 2.11 When to re-run the data load

The load-events workflow can be re-run any time:

- To load a new set of events (upload a new JSON file, supply its name).
- To reload the same file after a fix — duplicate IDs are silently skipped,
  so only genuinely new events are inserted.

It does **not** need re-running for code deploys or schema migrations.

---

## Phase 3 — Application deployment

```powershell
gh workflow run deploy-api.yml
gh workflow run deploy-worker.yml
gh workflow run deploy-scheduler.yml
```

Each takes 5-8 minutes. They run in parallel.

Verify after completion:

```powershell
az aks get-credentials -g rg-ticketing-uksouth -n (az aks list -g rg-ticketing-uksouth --query '[0].name' -o tsv)
kubectl get pods -n ticketing
```

All six pods (api × 2, worker × 2, scheduler × 2) should be `1/1 Running`.

## Phase 4 — End-to-end smoke test

```powershell
# Port-forward to the API
kubectl port-forward -n ticketing svc/api 8000:80
```

In another shell:

```powershell
curl http://localhost:8000/events
$EVENT_ID = (curl -s http://localhost:8000/events | ConvertFrom-Json).items[0].id
$RES = curl -X POST "http://localhost:8000/events/$EVENT_ID/reservations" `
    -H "Content-Type: application/json" `
    -d '{"customer_email":"smoke@example.com","seat_count":2}' | ConvertFrom-Json
curl -X POST "http://localhost:8000/reservations/$($RES.id)/confirm" `
    -H "Content-Type: application/json" `
    -d '{"card_last_four":"1234"}'
```

If the reservation creates and confirms, the system is end-to-end working.

## Troubleshooting

### Pods CrashLoopBackOff with PostgreSQL auth errors

`pg_hba.conf rejects connection for host ... user "uami-ticketing-uksouth-api"`
means the UAMI isn't a registered Entra principal on the server. Re-run
Phase 2.4 (the grant script).

### Pods CrashLoopBackOff with Redis errors

Most likely the access policy assignment hasn't propagated. Wait 5-10
minutes and the pods will retry on their own. If still failing after
that, verify `kubectl get pods -n ticketing -o yaml | Select-String REDIS_USERNAME`
matches the UAMI principal IDs from Terraform outputs.

### Gateway has no ADDRESS

The ALB Controller needs an `ApplicationLoadBalancer` Kubernetes resource
or a BYO AGC instance to provision the public frontend. See
`docs/runbooks/02-gateway-setup.md` (TODO — being written).
