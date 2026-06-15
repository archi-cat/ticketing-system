# PostgreSQL Sub-module

Creates an Azure Database for PostgreSQL Flexible Server with VNet injection, Entra-ID-only authentication, the application database, secure transport enforced, and diagnostic logs streaming to Log Analytics.

## Usage

```hcl
module "postgres" {
  source = "../../modules/data/postgres"

  location            = "uksouth"
  resource_group_name = "rg-ticketing-uksouth"
  server_name         = "psql-ticketing-uksouth"
  postgres_version    = "16"
  sku_name            = "B_Standard_B1ms"
  storage_mb          = 32768

  delegated_subnet_id = module.network.subnet_ids.postgres
  private_dns_zone_id = module.network.private_dns_zone_ids.postgres

  entra_admin_principal_id   = data.azurerm_client_config.current.object_id
  entra_admin_principal_name = "alice@example.com"
  entra_admin_principal_type = "User"

  database_name              = "ticketing"
  log_analytics_workspace_id = module.observability.log_analytics_workspace_id

  tags = {
    environment = "primary"
    project     = "ticketing-system"
  }
}
```

## Resources created

| Resource | Quantity | Notes |
|---|---|---|
| PostgreSQL Flexible Server | 1 | VNet-injected, AAD-only auth, public access disabled |
| Active Directory administrator | 1 | The bootstrap Entra admin |
| Database | 1 | The application database (default name `ticketing`) |
| Server configurations | 8 | TLS (`require_secure_transport`, `ssl_min_protocol_version`); logging (`log_min_duration_statement`, `log_connections`, `log_checkpoints`); audit (`azure.extensions`, `shared_preload_libraries`, `pgaudit.log`) |
| Diagnostic setting | 1 | Streams logs and metrics to Log Analytics |

## Inputs

See `variables.tf` — each variable is documented inline.

## Outputs

| Output | Description |
|---|---|
| `server_id` | PostgreSQL server resource ID |
| `server_name` | Server name |
| `server_fqdn` | Server FQDN (resolves to private IP via the linked DNS zone) |
| `database_name` | Application database name |
| `connection_string_template` | Template string for SQLAlchemy connections (user populated at runtime) |

## How authentication works

1. The bootstrap Entra admin (typically the human operator) is set via the `entra_admin_principal_id` input.
2. This admin runs `Grant-PostgresWorkloadIdentity.ps1` in CI to create database users for each UAMI:

```sql
   CREATE ROLE "uami-ticketing-uksouth-api" WITH LOGIN;
   GRANT azure_pg_admin TO "uami-ticketing-uksouth-api";
   GRANT CONNECT ON DATABASE ticketing TO "uami-ticketing-uksouth-api";
   GRANT USAGE ON SCHEMA public TO "uami-ticketing-uksouth-api";
   GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO "uami-ticketing-uksouth-api";
```

3. Pods running with the corresponding service account obtain Azure AD tokens via Workload Identity and authenticate as the UAMI's display name.

## Audit logging (pgaudit)

DDL and role changes are audited via the [`pgaudit`](https://www.pgaudit.org/) extension. Azure enables it in three steps, two of them in this module and one in the bootstrap Job:

1. **Allow-list** — `azure.extensions = PGAUDIT`.
2. **Preload** — `pgaudit` is appended to `shared_preload_libraries` (see `var.shared_preload_libraries`). This is a **static** parameter, so applying it **restarts the server**.
3. **Create** — `CREATE EXTENSION IF NOT EXISTS pgaudit;` runs inside the `ticketing` database from the db-grant Job (`bootstrap/db-grant/grant.sh`), which connects as an `azure_pg_admin`.

`pgaudit.log = DDL,ROLE`. `DDL` captures schema changes; `ROLE` captures `CREATE/ALTER ROLE` with **passwords redacted** — unlike `log_statement = DDL`, which would log them in clear text. Audit events are emitted to the standard Postgres log (the `PostgreSQLLogs` diagnostic category, already streamed to Log Analytics) prefixed `AUDIT:`.

**Query — all audited DDL/role changes in the last 24h:**

```kusto
AzureDiagnostics
| where Resource =~ "<server-name>" and Category == "PostgreSQLLogs"
| where TimeGenerated > ago(1d) and Message contains "AUDIT:"
| project TimeGenerated, Message
| order by TimeGenerated desc
```

> **Caveat:** a Postgres **major-version upgrade** automatically drops and recreates `pgaudit` and does **not** preserve `pgaudit.log`. The next `terraform apply` re-asserts the parameter; re-run the db-grant Job if the extension needs recreating.

## Notes

- This module uses **VNet injection**, not a Private Endpoint. PostgreSQL Flexible Server doesn't support Private Endpoint mode — it's either fully public (with firewall rules) or fully private (inside a delegated subnet).
- The `lifecycle.ignore_changes` block on `administrator_login` and `administrator_password` is required when using AAD-only auth — without it, every plan shows phantom diffs.
- The HA configuration block is intentionally absent. Burstable tier doesn't support HA, and the AzureRM provider errors out if the block is present (even with `mode = "Disabled"`).
- Cross-region redundancy is provided in Phase 4 via a read replica in westeurope, not via geo-redundant backups.
