# ADR-0018: In-cluster Jobs for database bootstrap, with human-gated grants

Status: Accepted
Date: 2026-05-23

## Context

The application database needs three bootstrap operations:

1. **Migrations** — `alembic upgrade head` creates and evolves the schema.
2. **Grants** — registering the application UAMIs as Entra principals on
   PostgreSQL (`pgaadauth_create_principal`) and granting them
   database-level privileges.
3. **Data load** — loading event data into the database.

PostgreSQL Flexible Server is VNet-injected and has no public endpoint, so
none of these can be run from a developer laptop or Cloud Shell. The
earlier approach used a temporary VM created inside the VNet — manual,
slow, and error-prone, created and destroyed by hand each time.

The three operations have different privilege requirements:

- Migrations and data load need DDL/DML on the application database — a
  non-admin level of access.
- Grants need to call `pgaadauth_create_principal`, which requires
  PostgreSQL Entra **admin** rights and runs in the `postgres` management
  database.

A single identity covering all three would therefore have to be a
standing Postgres admin — a permanent, high-value credential federated to
a Kubernetes service account, which is a large attack surface for an
operation that runs rarely.

## Decision

Replace the temporary VM with **in-cluster Kubernetes Jobs**. Jobs run
inside the VNet, so the network problem is solved for all three
operations.

Use **two identities**, not one:

- **`db-migrator` UAMI** — a non-admin Postgres Entra principal with DDL +
  DML on the application database. Runs the migration and data-load Jobs.
  Never elevated; its privilege level never changes.
- **`db-grant` UAMI** — has **no standing Postgres rights**. Runs the
  grant Job only. For a grant run, a human elevates it to a Postgres
  Entra admin; the triggering workflow revokes that elevation afterwards.

The grant Job is **human-gated and time-boxed**:

1. A human elevates `db-grant` to a Postgres Entra admin (one `az`
   command — the deliberate human decision point).
2. The `db-grant` workflow runs: it confirms the elevation (pre-flight
   check), applies the grant Job, waits for it, and then — in an
   `if: always()` step — revokes the elevation, whether the Job
   succeeded, failed, or timed out.

## Rationale

- **The network problem and the privilege problem are separable.** A Job
  solves the network problem unconditionally. Only the grant step has a
  privilege problem, so only it carries the elevation machinery.
- **The frequently-run Jobs use a never-privileged identity.** Migrations
  run on every schema change; the data-load Job runs operationally. These
  must be friction-free and safe — `db-migrator` is fixed, non-admin, and
  never changes state, so there is nothing to elevate or revoke and
  nothing to get wrong.
- **The privileged identity has no standing rights.** `db-grant` is inert
  unless a human has elevated it. A compromise of the cluster does not
  yield a Postgres admin, because `db-grant` is not one — except during
  the few minutes of a deliberately-opened, workflow-closed window.
- **The revoke is structural, not a matter of memory.** The original idea
  was for a human to elevate and revoke manually. Manual revocation that
  depends on human memory fails silently — a forgotten revoke leaves a
  standing admin and nobody notices. Putting the revoke in an
  `if: always()` workflow step makes it run unless GitHub Actions itself
  dies mid-run — a far smaller failure surface. A forgotten revoke becomes
  a loud failed workflow, not a silent omission.
- **Auditability.** `db-migrator` must never appear as a Postgres admin —
  if it does, that is an alarm. `db-grant` appearing as an admin is
  expected only transiently. Two identities with two clear expected
  states are easier to audit than one identity whose correct state
  depends on the time of day.

## Trade-offs accepted

- **The grant step is not fully automated.** It requires one human action
  (the elevation). This is deliberate — creating database principals
  should require a human decision. Everything after that gate is
  automated and self-cleaning.
- **`db-grant`'s elevated window is full Postgres Entra admin.**
  `pgaadauth_create_principal` is invoked with admin rights because that
  is known to work. Whether a narrower role suffices is unresolved — see
  Open question below.
- **The grant Job must run before the migration Job on a fresh
  environment.** The grant Job is what registers the `db-migrator`
  principal; until it has run, the migration Job's identity cannot
  authenticate. This ordering is documented in the runbook.

## Build / run ordering

The grant Job registers all four principals — `api`, `worker`,
`scheduler`, and `db-migrator` itself. On a fresh environment:

1. Bootstrap images are built and pushed (`build-bootstrap-images`).
2. A human elevates `db-grant`.
3. The `db-grant` workflow runs — registers principals, grants privileges,
   revokes the elevation.
4. The migration Job can now run (its identity exists as a principal).
5. The data-load Job can run.

## Default privileges — a correctness note

The grant SQL sets `ALTER DEFAULT PRIVILEGES FOR ROLE "<db-migrator>"`.
Because grants run **before** migrations on a fresh database, the
application tables do not yet exist when the grant Job runs. The
`FOR ROLE` clause ties the default privileges to `db-migrator` as the
future table creator: when `db-migrator` later creates a table, the
application roles automatically receive their privileges on it. Omitting
`FOR ROLE` would tie the defaults to whoever ran the grant script, and
the application roles would receive nothing on the migrator-created
tables.

## Open question — minimum privilege for the grant

`db-grant` is elevated to full Postgres Entra admin because that
definitely permits `pgaadauth_create_principal`. The minimum required
privilege has not been determined. If `pgaadauth_create_principal` is a
`SECURITY DEFINER` function, a caller may need substantially less than
full admin. To be investigated by inspecting `\df+
pgaadauth_create_principal` on a live server; if a narrower role works,
the elevation step should be narrowed accordingly.

## Future work

- Narrow the `db-grant` elevation per the open question above.
- Auto-trigger the migration Job from the deploy pipeline once it has run
  cleanly a few times manually (currently `workflow_dispatch`).
- Consider Azure PIM for the elevation, so the privileged window is
  time-boxed by Azure itself rather than by the workflow's revoke step.
