# ADR-0032: In-cluster event upload via a Kubernetes Job

Status: Accepted
Date: 2026-06-16

## Context

Phase 3 Tier 2 #9. ADR-0019 moved event *loading* (blob → database) into an in-cluster Job, but left event *uploading* (repo JSON → blob) as a manual `az storage blob upload --auth-mode login` run from an operator's laptop. That manual step is the **last human-from-laptop operation** in the deployment, and it forces the event-data storage account to keep a **public endpoint** (IP-allow-listed) open so the laptop can reach it — the only remaining public surface on the data layer.

Goal: replace the laptop upload with an in-cluster Job that writes over the **private endpoint** via Workload Identity. This removes the manual step and unblocks Tier 3 #14 (set `public_network_access_enabled = false` on the storage account).

## Decision

An `event-upload` Kubernetes Job, triggered by a manual-dispatch `event-upload.yml` workflow, uploads every `data/events/*.json` file to the events container.

### Dedicated identity (least privilege)

A new **`event-uploader`** UAMI federated to an `event-uploader-service-account`, whose **only** privilege is **Storage Blob Data Contributor** on the events container (via the storage module's new `blob_writer_principal_ids`). It is deliberately **not** the `db-migrator` identity: writing event files and changing the database schema are different blast radii, and the migrator is read-only on this container. The uploader has no Postgres rights at all.

### Image and file delivery

The Job reuses the **API image**, overriding `CMD` with a new `upload-events` console-script (mirroring how db-load-events overrides with `load-events`). `azure-storage-blob` is already in the image, so no new image or dependency. The command authenticates with `DefaultAzureCredential` and uploads with `overwrite=True`.

The event files reach the pod via a **ConfigMap** the workflow builds from the repo checkout (`kubectl create configmap event-data --from-file=data/events/`), mounted read-only at `/events`. This keeps event data out of the image while still feeding the in-cluster Job from the repo.

### Network path

The Job writes over the storage **private endpoint** (in-VNet). DNS and Azure AD egress are already allowed namespace-wide (`endpointSelector: {}` in `01-dns-egress`/`02-azure-ad-egress`); a new `22-event-upload-storage-egress` CiliumNetworkPolicy adds the storage `443` allow, scoped by `job-name: event-upload` (mirrors `21-db-load-events-storage-egress`).

## Rationale

- **In-cluster + private endpoint is the whole point.** A GitHub runner can't reach the private endpoint, and uploading over the public endpoint would keep that surface open. Running the upload as a pod uses the same private path db-load-events already reads over — and is the prerequisite for closing the public endpoint (#14).
- **Dedicated identity, not db-migrator reuse.** The production-grade default is least privilege: the uploader writes blobs and nothing else. The cost is modest identity plumbing (one `service_accounts` entry auto-creates the UAMI + federated credential), which the project already does per service.
- **Reuse the API image + a new console-script.** Consistent with ADR-0019 / db-migrate; avoids a third bootstrap image. The `upload-events` command is storage-only (no Settings/DB), so the Job manifest is lean.
- **ConfigMap delivery** is the simplest repo→pod path that needs no registry, no extra image, and no repo access from the cluster.

## Trade-offs accepted

- **ConfigMap 1 MiB limit.** Fine for the sample catalogue; a much larger event set would need a different delivery (e.g. an init container that pulls the files, or chunked ConfigMaps). Documented in the workflow and command.
- **A new identity to maintain.** One more UAMI + federated credential + service account than reusing db-migrator. Accepted for the least-privilege separation.
- **The public endpoint is still open after this change.** #9 makes the public path *unnecessary*; #14 actually removes it (`public_network_access_enabled = false`). Sequenced so the in-cluster path is proven before the public one is withdrawn.
- **Synchronous file reads in an async command.** The upload command reads files with blocking I/O inside `asyncio.run`; negligible for a one-shot bootstrap of small files.

## Operator path

- **Fresh deploy:** trigger `Event Upload` (`event-upload.yml`) before `DB Load Events`. Order: repo JSON → blob (this Job) → database (db-load-events).
- **Update the catalogue:** edit/add files under `data/events/`, re-run the workflow (uploads overwrite; the downstream load is idempotent on the event `id`).
- **Verify:** the workflow waits on Job completion and prints the upload log (one line per file); storage `StorageWrite` diagnostics also record the writes.

## Future work

- **Tier 3 #14:** now unblocked — set `public_network_access_enabled = false` and drop `allowed_ip_ranges` / the deployer-IP detection on the storage account.
- **Auto-trigger from the deploy pipeline:** chain event-upload → db-load-events after a fresh db-migrate, once the ordering is validated manually.
- **Larger catalogues:** revisit ConfigMap delivery if event data outgrows 1 MiB.

## References

- `app/api/src/ticketing_api/commands/upload_events.py` — the `upload-events` command
- `k8s/bootstrap/event-upload/` — Job + service account
- `k8s/cluster-addons/network-policies/22-event-upload-storage-egress.yaml` — egress
- `.github/workflows/event-upload.yml` — the dispatch workflow
- `terraform/modules/data/storage/` — `blob_writer_principal_ids` (Contributor)
- ADR-0019 — event *loading* design this extends (the upload half it deferred to Phase 3)
- ADR-0018 — database bootstrap Jobs pattern
