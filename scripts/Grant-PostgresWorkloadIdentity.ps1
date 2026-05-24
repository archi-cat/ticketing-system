<#
.SYNOPSIS
    Registers application UAMIs as Entra ID principals on the Azure Database
    for PostgreSQL Flexible Server, then grants them database-level access.

.DESCRIPTION
    Azure PostgreSQL Flexible Server uses two layers for Entra-based auth:

    1. Server-side: each Entra principal that can authenticate must be
       registered via pgaadauth_create_principal (or via the portal/CLI's
       'ad-admin create'). This function lives in the 'postgres' management
       database and creates a server-wide role mapped to the Entra principal.

    2. Database-side: GRANT statements give that role specific permissions
       on tables, schemas, and sequences in the application database.

    Plain CREATE ROLE creates a role that pg_hba.conf rejects because the
    Entra-to-role mapping is missing. This script uses pgaadauth_create_principal
    so the roles authenticate correctly.

    Prerequisites:
        - Entra ID auth enabled on the server (authConfig.activeDirectoryAuth = Enabled)
        - You (the caller) registered as an Entra admin on the server
        - psql installed and on PATH
        - az CLI logged in as an Entra admin
        - Tables already exist (run Apply-DatabaseMigrations.ps1 first)

.PARAMETER PostgresHost
    Postgres server FQDN.

.PARAMETER Database
    Application database name.

.PARAMETER ManagementDatabase
    The database where pgaadauth_create_principal lives. Default 'postgres'.

.PARAMETER ApiUamiName
    Display name of the API UAMI. Must match the UAMI's exact name in Entra.

.PARAMETER WorkerUamiName
    Display name of the worker UAMI.

.PARAMETER SchedulerUamiName
    Display name of the scheduler UAMI.

.EXAMPLE
    ./Grant-PostgresWorkloadIdentity.ps1 `
        -PostgresHost "psql-ticketing-uksouth-abc.postgres.database.azure.com" `
        -Database "ticketing" `
        -ApiUamiName "uami-ticketing-uksouth-api" `
        -WorkerUamiName "uami-ticketing-uksouth-worker" `
        -SchedulerUamiName "uami-ticketing-uksouth-scheduler"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PostgresHost,

    [Parameter(Mandatory)]
    [string]$Database,

    [Parameter()]
    [string]$ManagementDatabase = "postgres",

    [Parameter(Mandatory)]
    [string]$ApiUamiName,

    [Parameter(Mandatory)]
    [string]$WorkerUamiName,

    [Parameter(Mandatory)]
    [string]$SchedulerUamiName
)

$ErrorActionPreference = "Stop"

Write-Host "Acquiring Entra ID token for PostgreSQL..." -ForegroundColor Cyan
$tokenJson = az account get-access-token --resource-type oss-rdbms --output json | ConvertFrom-Json
$token = $tokenJson.accessToken

$currentUser = az ad signed-in-user show --query userPrincipalName --output tsv
Write-Host "Connecting as: $currentUser" -ForegroundColor Cyan

# ── Step 1: clean up any pre-existing plain roles (idempotent) ────────────────
# If the roles were created previously via CREATE ROLE (without Entra mapping),
# we need to remove them before pgaadauth_create_principal can recreate them.
# REASSIGN OWNED + DROP OWNED clears their object dependencies first.

$cleanupSql = @"
-- Drop any prior grants. Idempotent because of IF EXISTS in the role check.
DO `$`$
BEGIN
    IF EXISTS (SELECT FROM pg_roles WHERE rolname = '$ApiUamiName') THEN
        EXECUTE 'REASSIGN OWNED BY "$ApiUamiName" TO "$currentUser"';
        EXECUTE 'DROP OWNED BY "$ApiUamiName"';
    END IF;
    IF EXISTS (SELECT FROM pg_roles WHERE rolname = '$WorkerUamiName') THEN
        EXECUTE 'REASSIGN OWNED BY "$WorkerUamiName" TO "$currentUser"';
        EXECUTE 'DROP OWNED BY "$WorkerUamiName"';
    END IF;
    IF EXISTS (SELECT FROM pg_roles WHERE rolname = '$SchedulerUamiName') THEN
        EXECUTE 'REASSIGN OWNED BY "$SchedulerUamiName" TO "$currentUser"';
        EXECUTE 'DROP OWNED BY "$SchedulerUamiName"';
    END IF;
END
`$`$;
"@

Write-Host "Cleaning up any pre-existing roles in '$Database'..." -ForegroundColor Cyan
$env:PGPASSWORD = $token
try {
    $cleanupSql | psql `
        --host $PostgresHost --port 5432 `
        --username $currentUser --dbname $Database `
        --set ON_ERROR_STOP=on
} finally {
    Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
}
if ($LASTEXITCODE -ne 0) { throw "Cleanup phase failed" }

# ── Step 2: create Entra-mapped roles in the management database ──────────────
# pgaadauth_create_principal lives only in 'postgres', so we must connect there.
# Roles are server-wide once created and visible from every database.

$createSql = @"
DROP ROLE IF EXISTS "$ApiUamiName";
DROP ROLE IF EXISTS "$WorkerUamiName";
DROP ROLE IF EXISTS "$SchedulerUamiName";

SELECT * FROM pgaadauth_create_principal('$ApiUamiName',       false, false);
SELECT * FROM pgaadauth_create_principal('$WorkerUamiName',    false, false);
SELECT * FROM pgaadauth_create_principal('$SchedulerUamiName', false, false);

-- Print final state for verification
SELECT rolname, principaltype, isadmin FROM pgaadauth_list_principals(false);
"@

Write-Host "Creating Entra-mapped roles in '$ManagementDatabase'..." -ForegroundColor Cyan
$env:PGPASSWORD = $token
try {
    $createSql | psql `
        --host $PostgresHost --port 5432 `
        --username $currentUser --dbname $ManagementDatabase `
        --set ON_ERROR_STOP=on
} finally {
    Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
}
if ($LASTEXITCODE -ne 0) { throw "Role creation phase failed" }

# ── Step 3: grant database-level permissions in the application database ─────

$grantSql = @"
-- API: full CRUD on all tables and sequences in public schema
GRANT CONNECT ON DATABASE $Database TO "$ApiUamiName";
GRANT USAGE ON SCHEMA public TO "$ApiUamiName";
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO "$ApiUamiName";
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO "$ApiUamiName";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO "$ApiUamiName";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO "$ApiUamiName";

-- Worker: full CRUD on tables (no sequence access — workers don't generate IDs)
GRANT CONNECT ON DATABASE $Database TO "$WorkerUamiName";
GRANT USAGE ON SCHEMA public TO "$WorkerUamiName";
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO "$WorkerUamiName";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO "$WorkerUamiName";

-- Scheduler: read + update only (sweeps expired reservations)
GRANT CONNECT ON DATABASE $Database TO "$SchedulerUamiName";
GRANT USAGE ON SCHEMA public TO "$SchedulerUamiName";
GRANT SELECT, UPDATE ON ALL TABLES IN SCHEMA public TO "$SchedulerUamiName";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, UPDATE ON TABLES TO "$SchedulerUamiName";
"@

Write-Host "Granting database-level permissions in '$Database'..." -ForegroundColor Cyan
$env:PGPASSWORD = $token
try {
    $grantSql | psql `
        --host $PostgresHost --port 5432 `
        --username $currentUser --dbname $Database `
        --set ON_ERROR_STOP=on
} finally {
    Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
}
if ($LASTEXITCODE -ne 0) { throw "Grant phase failed" }

Write-Host ""
Write-Host "Done. Entra-mapped roles created and granted:" -ForegroundColor Green
Write-Host "  API:       $ApiUamiName"
Write-Host "  Worker:    $WorkerUamiName"
Write-Host "  Scheduler: $SchedulerUamiName"
