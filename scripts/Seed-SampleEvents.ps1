<#
.SYNOPSIS
    Seeds the database with a handful of sample events for testing.

.PARAMETER PostgresHost
    Postgres server FQDN.

.PARAMETER Database
    Database name.

.PARAMETER PostgresUser
    The role to authenticate as.

.EXAMPLE
    ./Seed-SampleEvents.ps1 `
        -PostgresHost "psql-ticketing-uksouth-abc.postgres.database.azure.com" `
        -Database "ticketing" `
        -PostgresUser "you@yourdomain.com"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PostgresHost,

    [Parameter(Mandatory)]
    [string]$Database,

    [Parameter(Mandatory)]
    [string]$PostgresUser
)

$ErrorActionPreference = "Stop"

# ── Get an Entra ID token ─────────────────────────────────────────────────────
$token = (az account get-access-token --resource-type oss-rdbms --output json `
            | ConvertFrom-Json).accessToken

# ── Sample events ─────────────────────────────────────────────────────────────
$seedSql = @"
INSERT INTO events (id, name, venue, starts_at, total_seats, available_seats, price_pence)
VALUES
    (gen_random_uuid(), 'Acoustic Sessions',     'Union Chapel, London',          NOW() + INTERVAL '14 days',  120,  120, 3500),
    (gen_random_uuid(), 'Tech Conference 2026',  'ExCeL, London',                 NOW() + INTERVAL '60 days',  500,  500, 15000),
    (gen_random_uuid(), 'Winter Symphony',       'Royal Albert Hall, London',     NOW() + INTERVAL '90 days',  800,  800, 8500),
    (gen_random_uuid(), 'Comedy Night',          'Hackney Empire',                NOW() + INTERVAL '7 days',   400,  400, 2500)
ON CONFLICT DO NOTHING;
"@

$env:PGPASSWORD = $token

try {
    $seedSql | psql `
        --host $PostgresHost `
        --port 5432 `
        --username $PostgresUser `
        --dbname $Database `
        --set ON_ERROR_STOP=on

    if ($LASTEXITCODE -ne 0) {
        throw "Seeding failed"
    }
} finally {
    Remove-Item Env:PGPASSWORD
}

# ── List the seeded events ───────────────────────────────────────────────────
Write-Host "Seeded events:" -ForegroundColor Green
$env:PGPASSWORD = $token
try {
    psql `
        --host $PostgresHost `
        --port 5432 `
        --username $PostgresUser `
        --dbname $Database `
        --command "SELECT id, name, venue, starts_at, available_seats FROM events ORDER BY starts_at;"
} finally {
    Remove-Item Env:PGPASSWORD
}
