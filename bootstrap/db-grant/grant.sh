#!/usr/bin/env bash
#
# Registers application UAMIs as Entra ID principals on Azure PostgreSQL
# Flexible Server and grants them database-level permissions.
#
# Runs as a Kubernetes Job, connecting as the db-grant UAMI — which a human
# has elevated to a Postgres Entra admin before this Job is triggered, and
# which the triggering workflow revokes afterwards.
#
# Two layers of Entra auth on PG Flexible Server:
#   1. Server-side: each Entra principal must be registered via
#      pgaadauth_create_principal (lives in the 'postgres' DB) so pg_hba.conf
#      accepts its token.
#   2. Database-side: GRANT statements give the role specific privileges.
#
# Required environment (injected by the Job manifest):
#   PGHOST            - Postgres server FQDN
#   APP_DATABASE      - application database name (e.g. ticketing)
#   MGMT_DATABASE     - management database where pgaadauth_* lives (postgres)
#   GRANT_PRINCIPAL   - the db-grant UAMI's own name (connects + REASSIGN target)
#   API_UAMI          - api UAMI name
#   WORKER_UAMI       - worker UAMI name
#   SCHEDULER_UAMI    - scheduler UAMI name
#   MIGRATOR_UAMI     - db-migrator UAMI name
#
# The Entra token for PGPASSWORD is acquired by the Job's init/entrypoint
# from the workload identity — see the Job manifest.

set -euo pipefail

# ── PGPASSWORD must already be set to a Postgres Entra access token ──────────
if [[ -z "${PGPASSWORD:-}" ]]; then
  echo "ERROR: PGPASSWORD is not set — expected a Postgres Entra access token." >&2
  exit 1
fi

PSQL_COMMON=(psql --host "$PGHOST" --port 5432 --username "$GRANT_PRINCIPAL" --set ON_ERROR_STOP=on -v ON_ERROR_STOP=1)

echo "==> Phase 1: cleanup of any pre-existing roles in '$APP_DATABASE'"
# If these roles were created before (plain CREATE ROLE, or a prior run),
# clear their object dependencies before pgaadauth_create_principal recreates
# them. Reassign owned objects to the db-grant principal (the admin running
# this), then drop privileges. Idempotent — guarded by IF EXISTS.
"${PSQL_COMMON[@]}" --dbname "$APP_DATABASE" <<SQL
DO \$\$
DECLARE
  r text;
BEGIN
  FOREACH r IN ARRAY ARRAY[
    '${API_UAMI}', '${WORKER_UAMI}', '${SCHEDULER_UAMI}', '${MIGRATOR_UAMI}'
  ]
  LOOP
    IF EXISTS (SELECT FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REASSIGN OWNED BY %I TO %I', r, '${GRANT_PRINCIPAL}');
      EXECUTE format('DROP OWNED BY %I', r);
    END IF;
  END LOOP;
END
\$\$;
SQL

echo "==> Phase 2: create Entra-mapped roles in '$MGMT_DATABASE'"
# pgaadauth_create_principal lives only in the management database. Roles are
# server-wide once created. db-migrator is registered alongside the three
# application UAMIs — the migration Job runs as db-migrator and cannot
# authenticate until this registration exists.
"${PSQL_COMMON[@]}" --dbname "$MGMT_DATABASE" <<SQL
DROP ROLE IF EXISTS "${API_UAMI}";
DROP ROLE IF EXISTS "${WORKER_UAMI}";
DROP ROLE IF EXISTS "${SCHEDULER_UAMI}";
DROP ROLE IF EXISTS "${MIGRATOR_UAMI}";

SELECT * FROM pgaadauth_create_principal('${API_UAMI}',       false, false);
SELECT * FROM pgaadauth_create_principal('${WORKER_UAMI}',    false, false);
SELECT * FROM pgaadauth_create_principal('${SCHEDULER_UAMI}', false, false);
SELECT * FROM pgaadauth_create_principal('${MIGRATOR_UAMI}',  false, false);

SELECT rolname, principaltype, isadmin FROM pgaadauth_list_principals(false);
SQL

echo "==> Phase 3: grant database-level permissions in '$APP_DATABASE'"
# Note on ALTER DEFAULT PRIVILEGES: on a fresh database the tables do not yet
# exist (migrations run AFTER this Job). ALTER DEFAULT PRIVILEGES FOR ROLE
# "<migrator>" means "when db-migrator creates a table, automatically grant
# the named privileges". db-migrator is the role that runs alembic, so the
# defaults must be tied FOR ROLE to it — not to whoever runs this script.
"${PSQL_COMMON[@]}" --dbname "$APP_DATABASE" <<SQL
-- ── db-migrator: DDL + DML. CREATE on the schema is the migrator's
--    distinguishing privilege — it is what lets alembic create tables.
GRANT CONNECT ON DATABASE "${APP_DATABASE}" TO "${MIGRATOR_UAMI}";
GRANT USAGE, CREATE ON SCHEMA public TO "${MIGRATOR_UAMI}";
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO "${MIGRATOR_UAMI}";
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO "${MIGRATOR_UAMI}";

-- ── api: full CRUD on tables + sequences
GRANT CONNECT ON DATABASE "${APP_DATABASE}" TO "${API_UAMI}";
GRANT USAGE ON SCHEMA public TO "${API_UAMI}";
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO "${API_UAMI}";
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO "${API_UAMI}";

-- ── worker: full CRUD on tables (no sequence access — does not generate IDs)
GRANT CONNECT ON DATABASE "${APP_DATABASE}" TO "${WORKER_UAMI}";
GRANT USAGE ON SCHEMA public TO "${WORKER_UAMI}";
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO "${WORKER_UAMI}";

-- ── scheduler: read + update only (sweeps expired reservations)
GRANT CONNECT ON DATABASE "${APP_DATABASE}" TO "${SCHEDULER_UAMI}";
GRANT USAGE ON SCHEMA public TO "${SCHEDULER_UAMI}";
GRANT SELECT, UPDATE ON ALL TABLES IN SCHEMA public TO "${SCHEDULER_UAMI}";

-- ── Default privileges, tied to the migrator. When db-migrator creates a
--    table in future, these grants apply automatically.
ALTER DEFAULT PRIVILEGES FOR ROLE "${MIGRATOR_UAMI}" IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO "${API_UAMI}";
ALTER DEFAULT PRIVILEGES FOR ROLE "${MIGRATOR_UAMI}" IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO "${API_UAMI}";

ALTER DEFAULT PRIVILEGES FOR ROLE "${MIGRATOR_UAMI}" IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO "${WORKER_UAMI}";

ALTER DEFAULT PRIVILEGES FOR ROLE "${MIGRATOR_UAMI}" IN SCHEMA public
  GRANT SELECT, UPDATE ON TABLES TO "${SCHEDULER_UAMI}";

-- db-migrator also needs default privileges on its OWN future tables —
-- without this, after creating a table it would (in some PG versions /
-- ownership setups) need explicit re-grant. Owner always retains rights,
-- so this is belt-and-braces for the DML grants above on pre-existing tables.
SQL

echo "==> Done. Registered and granted: api, worker, scheduler, db-migrator."
