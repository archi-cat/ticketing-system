# Observability Module

Creates a Log Analytics workspace and Application Insights instances for the regional environment. Other modules consume these outputs to wire up monitoring (AKS Container Insights, PostgreSQL diagnostic logs, etc.) and applications consume the App Insights connection strings for telemetry.

## Usage

```hcl
module "observability" {
  source = "../../modules/observability"

  location            = "uksouth"
  resource_group_name = "rg-ticketing-uksouth"
  name_prefix         = "ticketing-uksouth"

  retention_in_days      = 30
  daily_ingestion_cap_gb = 1

  application_insights_instances = {
    api     = { application_type = "web" }
    workers = { application_type = "web" }
  }

  tags = {
    environment = "primary"
    project     = "ticketing-system"
  }
}
```

## Resources created

| Resource | Quantity | Notes |
|---|---|---|
| Log Analytics workspace | 1 | PerGB2018 SKU, 30-day retention, 1 GB/day cap |
| Application Insights | One per `application_insights_instances` entry | Workspace-based, IPs masked |

## Inputs

| Variable | Type | Required | Default | Description |
|---|---|---|---|---|
| `location` | string | Yes | — | Azure region |
| `resource_group_name` | string | Yes | — | RG for all resources |
| `name_prefix` | string | Yes | — | Prefix for resource names |
| `retention_in_days` | number | No | `30` | Workspace retention (7–730) |
| `daily_ingestion_cap_gb` | number | No | `1` | Daily ingestion cap |
| `application_insights_instances` | map | No | `{api, workers}` | App Insights instances to create |
| `tags` | map(string) | No | `{}` | Tags on all resources |

## Outputs

| Output | Type | Description |
|---|---|---|
| `log_analytics_workspace_id` | string | Resource ID — consumed by Container Insights and diagnostic settings |
| `log_analytics_workspace_name` | string | Workspace name |
| `log_analytics_workspace_customer_id` | string | Workspace ID GUID (different from resource ID) |
| `application_insights_connection_strings` | map (sensitive) | Logical name → connection string |
| `application_insights_instrumentation_keys` | map (sensitive) | Logical name → instrumentation key (legacy) |
| `application_insights_ids` | map | Logical name → App Insights resource ID (for alert rules) |

## Notes

- This module does **not** create alerts. Each resource module owns its own alerts.
- This module does **not** create diagnostic settings on other resources. Each resource module wires its own diagnostics using the `log_analytics_workspace_id` output.
- App Insights instances are workspace-based — telemetry data lives in the Log Analytics workspace. The "classic" App Insights mode (separate storage) was deprecated in 2024.
- The 1 GB/day ingestion cap is a guardrail against runaway costs. Production workloads will need higher caps; raise as needed.
- Use **connection strings** (not instrumentation keys) when configuring application telemetry. Instrumentation keys are exported only for legacy SDK compatibility.