<#
.SYNOPSIS
    Applies Alembic migrations against the regional PostgreSQL.

.DESCRIPTION
    Sets the environment variables the API expects, then invokes
    `alembic upgrade head`. Uses Workload Identity if the deployment role
    has been granted access; otherwise the operator's own Entra credentials.

.PARAMETER PostgresHost
    Postgres server FQDN.

.PARAMETER Database
    Database name.

.PARAMETER PostgresUser
    The role to authenticate as. Typically the operator's UPN or a dedicated
    migrations role.

.EXAMPLE
    ./Apply-DatabaseMigrations.ps1 `
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

$projectRoot = Resolve-Path "$PSScriptRoot/../app/api"
Push-Location $projectRoot

try {
    $env:POSTGRES_HOST                     = $PostgresHost
    $env:POSTGRES_PORT                     = "5432"
    $env:POSTGRES_DATABASE                 = $Database
    $env:POSTGRES_USER                     = $PostgresUser
    $env:POSTGRES_USE_WORKLOAD_IDENTITY    = "true"
    $env:LOG_FORMAT                        = "console"

    Write-Host "Running migrations against $PostgresHost..." -ForegroundColor Cyan
    uv run alembic upgrade head

    if ($LASTEXITCODE -ne 0) {
        throw "Migration failed"
    }

    Write-Host "Migrations applied successfully." -ForegroundColor Green
} finally {
    Pop-Location

    Remove-Item Env:POSTGRES_HOST -ErrorAction SilentlyContinue
    Remove-Item Env:POSTGRES_PORT -ErrorAction SilentlyContinue
    Remove-Item Env:POSTGRES_DATABASE -ErrorAction SilentlyContinue
    Remove-Item Env:POSTGRES_USER -ErrorAction SilentlyContinue
    Remove-Item Env:POSTGRES_USE_WORKLOAD_IDENTITY -ErrorAction SilentlyContinue
    Remove-Item Env:LOG_FORMAT -ErrorAction SilentlyContinue
}