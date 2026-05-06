<#
.SYNOPSIS
    Creates PostgreSQL database roles for application UAMIs and grants them
    appropriate permissions.

.DESCRIPTION
    Runs as the Entra ID admin (typically the human operator). For each UAMI:
        - Creates a role named after the UAMI's display name
        - Grants CONNECT on the database
        - Grants USAGE on the public schema
        - Grants table-level privileges based on the role's purpose

    The script is idempotent — running it twice is safe.

.PARAMETER PostgresHost
    Postgres server FQDN (e.g. psql-ticketing-uksouth-abc.postgres.database.azure.com).

.PARAMETER Database
    Application database name.

.PARAMETER ApiUamiName
    Display name of the API UAMI (the role gets the same name).

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

    [Parameter(Mandatory)]
    [string]$ApiUamiName,

    [Parameter(Mandatory)]
    [string]$WorkerUamiName,

    [Parameter(Mandatory)]
    [string]$SchedulerUamiName
)

$ErrorActionPreference = "Stop"

# ── Get an Entra ID access token for PostgreSQL ───────────────────────────────
Write-Host "Acquiring Entra ID token for PostgreSQL..." -ForegroundColor Cyan

$tokenJson = az account get-access-token `
    --resource-type oss-rdbms `
    --output json | ConvertFrom-Json

$token = $tokenJson.accessToken

# Get the current signed-in user's UPN — this is the role name for the
# Entra admin connecting to PostgreSQL.
$currentUser = az ad signed-in-user show --query userPrincipalName --output tsv

Write-Host "Connecting as: $currentUser" -ForegroundColor Cyan

# ── Build SQL ─────────────────────────────────────────────────────────────────
# DO blocks are used to make the role creation idempotent — CREATE ROLE
# fails if the role already exists, but DO blocks let us check first.

$grantSql = @"
-- API role — read/write reservations, events, bookings, idempotency
DO `$`$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '$ApiUamiName') THEN
        CREATE ROLE "$ApiUamiName" WITH LOGIN;
    END IF;
END
`$`$;

GRANT azure_pg_admin TO "$ApiUamiName";
GRANT CONNECT ON DATABASE $Database TO "$ApiUamiName";
GRANT USAGE ON SCHEMA public TO "$ApiUamiName";
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO "$ApiUamiName";
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO "$ApiUamiName";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO "$ApiUamiName";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO "$ApiUamiName";

-- Worker role — read/write reservations, bookings, processed_messages, decrement events
DO `$`$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '$WorkerUamiName') THEN
        CREATE ROLE "$WorkerUamiName" WITH LOGIN;
    END IF;
END
`$`$;

GRANT azure_pg_admin TO "$WorkerUamiName";
GRANT CONNECT ON DATABASE $Database TO "$WorkerUamiName";
GRANT USAGE ON SCHEMA public TO "$WorkerUamiName";
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO "$WorkerUamiName";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO "$WorkerUamiName";

-- Scheduler role — read/update reservations only (sweep expired reservations)
DO `$`$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '$SchedulerUamiName') THEN
        CREATE ROLE "$SchedulerUamiName" WITH LOGIN;
    END IF;
END
`$`$;

GRANT azure_pg_admin TO "$SchedulerUamiName";
GRANT CONNECT ON DATABASE $Database TO "$SchedulerUamiName";
GRANT USAGE ON SCHEMA public TO "$SchedulerUamiName";
GRANT SELECT, UPDATE ON reservations, events TO "$SchedulerUamiName";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, UPDATE ON TABLES TO "$SchedulerUamiName";
"@

# ── Connect via psql with token-as-password ───────────────────────────────────
Write-Host "Granting database permissions to UAMIs..." -ForegroundColor Cyan

$env:PGPASSWORD = $token

try {
    $grantSql | psql `
        --host $PostgresHost `
        --port 5432 `
        --username $currentUser `
        --dbname $Database `
        --set ON_ERROR_STOP=on
} finally {
    Remove-Item Env:PGPASSWORD
}

if ($LASTEXITCODE -ne 0) {
    throw "Failed to apply role grants"
}

Write-Host "Roles granted successfully." -ForegroundColor Green
Write-Host "  API: $ApiUamiName"
Write-Host "  Worker: $WorkerUamiName"
Write-Host "  Scheduler: $SchedulerUamiName"