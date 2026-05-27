# ADR-0019: Event data loading via Blob Storage and a K8s Job

Status: Accepted
Date: 2026-05-27

## Context

The application database needs event data before the system can be used.
In Phase 1, events were inserted manually via `scripts/Seed-SampleEvents.ps1`,
which ran `psql` from a developer laptop over a temporary VM inside the VNet.
Phase 2 replaced the temporary VM with in-cluster Kubernetes Jobs (ADR-0018).
The event-seeding step needed the same treatment: a repeatable, automated,
in-cluster operation.

There are two recurring questions for any data-load design:

1. **Where does the data live?** It must be reachable from inside the VNet,
   editable by operators without code changes, and auditable.
2. **How is the load triggered?** It should be idempotent, use the same
   identity model as the other bootstrap Jobs, and not require a privileged
   identity.

## Decision

Store event data as JSON files in an **Azure Blob Storage account** with a
private endpoint, and load them using a **Kubernetes Job** (`db-load-events`)
that runs the `load-events` command from the API image.

### Data storage

A dedicated storage account (`module.storage` in Terraform) holds JSON event
files in a private `events` container. The account has:

- A **private endpoint** inside the VNet — the only path used by the cluster.
- A **public endpoint with an IP allow-list** — for operator uploads via
  `az storage blob upload --auth-mode login`. This is removed in Phase 3
  once an in-cluster upload Job exists.
- **Shared access keys disabled** — Entra ID auth only.

The `db-migrator` UAMI has `Storage Blob Data Reader` on the container (scoped
to the container, not the account). No other identity has standing read access.

### JSON format

Each file is a top-level JSON array. Every object must supply an explicit `id`
(UUID) — this is what makes the operation idempotent (see below):

```json
[
  {
    "id":          "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
    "name":        "Event name",
    "venue":       "Venue, City",
    "starts_at":   "2026-06-10T19:30:00+00:00",
    "total_seats": 200,
    "price_pence": 5000
  }
]
```

`available_seats` is set to `total_seats` on first insert. `created_at` and
`updated_at` are set to the time of the insert. Neither is in the file.

### Idempotency

The `EventsRepository.create()` method uses PostgreSQL's
`INSERT ... ON CONFLICT (id) DO NOTHING`. Running the workflow twice with the
same file inserts nothing on the second run — which is the correct behaviour
for a repeated or accidental re-trigger. The explicit `id` in the JSON is the
idempotency key.

### Identity and privilege

The Job runs as the `db-migrator` UAMI — the same non-admin identity used by
the migration Job. It has DML rights on the events table (granted by the
db-grant Job) and `Storage Blob Data Reader` on the events container. No
elevation is needed and no elevation is performed.

### Image reuse

The Job reuses the API image, overriding the `CMD` with `load-events` (a
`[project.scripts]` entry point registered in `pyproject.toml`). This avoids
a separate image and keeps the pattern consistent with db-migrate, which
overrides `CMD` with `alembic upgrade head`.

The `azure-storage-blob` SDK is added to the API image's dependencies. It is
inert at API runtime — the web server never calls blob storage.

## Rationale

- **Blob Storage as the data source** keeps event data outside the codebase.
  Operators can update events without a code change or a new image build —
  they upload a new file and re-trigger the workflow.
- **Private endpoint** means the cluster reads blobs over a private IP, with
  no public data path for the read operation.
- **Explicit UUIDs in the JSON** make the operation naturally idempotent at
  the database level without any application-layer state. A file can be
  re-loaded safely; only genuinely new events (new UUIDs) are inserted.
- **Reusing the API image** avoids a third bootstrap image. The only cost is
  `azure-storage-blob` in the API image, which is small and unused at runtime.

## Trade-offs accepted

- **`azure-storage-blob` is in the API image.** This is a ~2 MB addition to
  a production image for a dependency that is only used during bootstrap. The
  alternative was a separate image (more maintenance); the trade-off favours
  simplicity.
- **Public endpoint stays open until Phase 3.** Operator uploads require
  reaching the storage account. Until an in-cluster upload Job replaces the
  laptop path, the public endpoint stays open (IP-restricted). Phase 3 closes
  it by setting `public_network_access_enabled = false`.
- **The blob name is a workflow input.** This is flexible but means the caller
  must supply the correct filename. A wrong filename fails at the download
  step with a clear error.

## Operator upload path

Before triggering the workflow, upload the JSON file to the storage account:

```bash
az storage blob upload \
  --account-name <storage-account-name> \
  --container-name events \
  --name sample-events.json \
  --file data/events/sample-events.json \
  --auth-mode login
```

The operator's Entra ID identity needs `Storage Blob Data Contributor` on the
container (or account) to upload. The `db-migrator` UAMI only has reader
rights — it cannot upload.

## Future work

- **Phase 3: in-cluster upload Job** — removes the public endpoint requirement.
- **Auto-trigger from deploy pipeline** — run db-load-events after db-migrate
  on a fresh environment, once the ordering has been validated manually.
