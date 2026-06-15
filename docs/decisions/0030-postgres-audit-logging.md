# ADR-0030: PostgreSQL audit logging via pgaudit

Status: Accepted
Date: 2026-06-15

## Context

Phase 3 Tier 2 #8. The platform has a deliberately privileged, automated path into the database:

- **db-grant** (ADR-0018) connects as an `azure_pg_admin` and rewrites roles, ownership, and grants on every deploy.
- **db-migrate** runs Alembic — arbitrary DDL (`CREATE`/`ALTER`/`DROP`) — as the migrator role.

These are the highest-blast-radius operations in the system, and until this work they were **unauditable**: once a statement ran it left no record of who ran it or what it touched. The existing Postgres logging (`log_min_duration_statement`, `log_connections`, ADR-0007) is *operational* — it answers "what is slow / who connected", deliberately not "who changed the schema or who was granted access". Azure's platform logs (Activity Log) capture control-plane changes to the server resource but are blind to in-database DDL and privilege changes.

For a single-operator learning project deployed in teardown/redeploy loops the gap is tolerable; for the production posture the project demonstrates — where DDL/privilege audit trails are table-stakes for SOC 2 / PCI-DSS / ISO 27001 — it is not.

## Decision

Enable the [`pgaudit`](https://www.pgaudit.org/) extension on the Flexible Server with **`pgaudit.log = DDL,ROLE`** — session audit logging scoped to schema changes and role/privilege changes only.

Azure requires three steps, two in the Terraform module and one in the bootstrap Job:

1. **Allow-list** — `azure.extensions = PGAUDIT` (server parameter, previously empty here).
2. **Preload** — append `pgaudit` to `shared_preload_libraries`. This is a **static** parameter, so applying it **restarts the server** (the provider waits for it). The value is exposed as `var.shared_preload_libraries`, defaulting to the documented PG18 default plus pgaudit (`pg_cron,pg_stat_statements,pgaudit`).
3. **Create** — `CREATE EXTENSION IF NOT EXISTS pgaudit;` runs inside the `ticketing` database from db-grant's grant phase, which already connects as an `azure_pg_admin` (the privilege Azure requires to create an allow-listed extension). Idempotent.

Audit events are emitted to the standard Postgres log prefixed `AUDIT:`, which already flows to Log Analytics via the `PostgreSQLLogs` diagnostic category (ADR-0006) — no new telemetry plumbing.

## Rationale

### pgaudit over the built-in `log_statement = ddl`

Postgres can log DDL natively without an extension, but `log_statement = ddl` logs raw statement text — so `CREATE ROLE ... WITH PASSWORD '...'` lands in Log Analytics **in clear text**. pgaudit's `ROLE` class logs the same event with the **password redacted**, and gives a consistent, machine-readable format with finer-grained class control. Password redaction alone is decisive given db-grant manages roles on every deploy.

### Scope `DDL,ROLE`, not `WRITE`/`ALL`

pgaudit can audit row-touching statements (`READ`/`WRITE`) or everything (`ALL`), but that floods the log with high-volume, low-value events and drives Log Analytics ingestion cost (billed per GB). `DDL,ROLE` captures the rare, high-value, security-relevant events — the ones the privileged automated paths actually produce — at near-zero volume and cost. Widening scope is a deliberate cost/coverage decision, not a default to drift into.

### `shared_preload_libraries` is an absolute, static parameter

Azure writes the **whole** comma-separated list (no append), and a change restarts the server. The value therefore preserves the version default and appends pgaudit. Query Store and HA libraries (`pg_qs`, `pgms_wait_sampling`, `pg_availability`) are managed by Azure **outside** this parameter, so they are not clobbered. Exposing it as a variable means an environment whose default differs can override it; an invalid list fails the apply loudly (Azure validates), which is a safe, non-silent failure mode.

## Trade-offs accepted

- **A server restart on first apply** when `shared_preload_libraries` changes. Acceptable in the deploy-loop model; on a continuously-running server it is a planned maintenance event.
- **No DML/query auditing.** `READ`/`WRITE` are intentionally excluded; if data-access auditing is ever needed it is a conscious scope change with a known ingestion-cost impact.
- **`pgaudit.log` is not preserved across a Postgres major-version upgrade** — the upgrade drops and recreates the extension. The next `terraform apply` re-asserts the parameter and the db-grant Job recreates the extension; documented in the module README.
- **Ordering coupling.** The `CREATE EXTENSION` step in db-grant requires the Terraform allow-list + preload (and restart) to have been applied first. This holds in the normal deploy order (Terraform → bootstrap Jobs); running db-grant against a server without the parameters set fails the Job loudly rather than silently skipping audit.

## Operator path

- **Fresh deploy:** parameters ride the existing `infra-uksouth.yml`; the `CREATE EXTENSION` rides the existing db-grant Job. No new inputs.
- **Verify (deploy-time):** after a deploy, run the module README's KQL query — DDL from db-migrate and role changes from db-grant appear as `AUDIT:` lines; confirm `CREATE/ALTER ROLE` rows show the password redacted.
- **Query "all DDL/role changes in the last 24h":** see the README audit-logging section (`AzureDiagnostics | ... Category == "PostgreSQLLogs" | where Message contains "AUDIT:"`).

## Future work

- Re-evaluate scope if the platform ever needs data-access (`READ`/`WRITE`) auditing — paired with a Log Analytics ingestion/retention review.
- A scheduled-query alert on specific audited events (e.g. unexpected `DROP`/`GRANT` outside a deploy window) once there is a baseline of normal activity (builds on ADR-0022).
- Phase 4 multi-region: the parameters and the db-grant step are region-agnostic — they instantiate per region with the rest of the data layer.

## References

- `terraform/modules/data/postgres/` — module + README (audit-logging section, KQL query, major-version caveat)
- `bootstrap/db-grant/grant.sh` — the `CREATE EXTENSION` step
- ADR-0007 — Postgres design this extends (TLS, AAD-only auth, operational logging)
- ADR-0018 — database bootstrap Jobs; db-grant carries the extension creation
- ADR-0006 — observability design; the `PostgreSQLLogs` diagnostic stream pgaudit reuses
