# Alerts module

Baseline alerting for the ticketing platform ([Phase 3 Tier 1 #3](../../../phase_3_plan.md)). Provisions one Action Group, eight alerts spanning the data and application layers, and one URL ping test against the public Gateway endpoint.

All alerts route to the same `alert_email_address` — for this learning project that reuses the `ACME_EMAIL` secret. In real production it would be a separate operations distribution list.

## What gets created

| Resource | Kind | What it watches |
|---|---|---|
| `azurerm_monitor_action_group.this` | Action Group | Email receiver using the modern common-alert schema |
| `azurerm_monitor_metric_alert.postgres_cpu` | Metric alert | Postgres CPU > threshold (15-min average) |
| `azurerm_monitor_metric_alert.postgres_connections` | Metric alert | Postgres `active_connections` > 80% of `max_connections` |
| `azurerm_monitor_metric_alert.servicebus_dlq` | Metric alert | Any deadletter messages on the Service Bus namespace |
| `azurerm_monitor_metric_alert.aks_node_cpu` | Metric alert | Per-node CPU > threshold (Container Insights metric) |
| `azurerm_monitor_metric_alert.aks_node_memory` | Metric alert | Per-node memory working-set > threshold |
| `azurerm_monitor_scheduled_query_rules_alert_v2.api_5xx_rate` | KQL alert | Count of 5xx responses in 15 min |
| `azurerm_monitor_scheduled_query_rules_alert_v2.api_p99_latency` | KQL alert | p99 request duration in 15 min |
| `azurerm_monitor_scheduled_query_rules_alert_v2.scheduler_stalled` | KQL alert | No traces from `ticketing-scheduler` in N minutes |
| `azurerm_application_insights_standard_web_test.https_ping` | Web test | HTTPS GET to the configured target URL from 5 EMEA locations |
| `azurerm_monitor_metric_alert.https_ping_failure` | Metric alert | Ping fails in 3 of 5 locations |

## Cadence

Every alert evaluates **every 15 minutes** over a **15-minute window**. The scheduler-stalled alert uses a longer window (`scheduler_stalled_window_minutes`, default 15) since the scheduler emits traces periodically rather than continuously. Scheduled-query alerts are ~$1.50/month per query at this cadence — kept manageable by the 15-min evaluation frequency rather than the Azure default of 5.

## Cert expiry — implicit, not explicit

Phase 3 #3's plan asked for a 30-day-warning cert-expiry alert. The decision for this project's posture was to skip the explicit warning and rely on the URL ping test to catch cert failures *when they actually happen* — a TLS handshake failure (invalid CA, expired cert, hostname mismatch) is reported as a ping failure, so `alert-https-ping-failure` fires.

The trade-off accepted: the operator loses the head's-up window (30-days-before-expiry) that a Prometheus rule against cert-manager's `certmanager_certificate_expiration_timestamp_seconds` metric would provide. Mitigated because cert-manager auto-renews at day ~60; the failure mode this would catch (renewal silently failing for 60 days) is rare and would also show up in the cert-manager Helm release's pod logs.

In real production with stricter SLOs you'd add the explicit warning — either via a Logic App that runs daily and parses cert-manager events, or by adding kube-prometheus-stack and an `AlertManager` rule against cert-manager's metrics.

## Workflow failure notifications

GitHub Actions failures go through GitHub's native repo notifications (emails repo watchers by default). Not wired through the Azure Action Group — keeps the action-group surface narrowly scoped to "what's happening to the running platform" rather than "what's happening to CI."

## Required Terraform / AKS context

- App Insights instances must exist with the names `api` and `workers` (the keys used in `module.observability.application_insights_instances`).
- Container Insights must be enabled on AKS — already done via the `oms_agent` block in the AKS module. The `Insights.Container/nodes` metric namespace depends on it.
- The scheduler's `cloud_RoleName` in App Insights must be `ticketing-scheduler` for the stalled alert to find its traces. The Azure Monitor OpenTelemetry SDK populates `cloud_RoleName` from the **`OTEL_SERVICE_NAME`** env var (not the project's custom `SERVICE_NAME`). All three app deployments (api, worker, scheduler) set `OTEL_SERVICE_NAME=ticketing-<service>` to make App Insights data legible per-service. If you ever rename a service in code, update both env vars in its deployment YAML AND the KQL in this module.

## Usage

```hcl
module "alerts" {
  source = "../../modules/alerts"

  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
  alert_email_address = var.alert_email_address

  app_insights_api_id     = module.observability.application_insights_ids.api
  app_insights_workers_id = module.observability.application_insights_ids.workers

  postgres_server_id      = module.postgres.server_id
  servicebus_namespace_id = module.servicebus.namespace_id
  aks_cluster_id          = module.aks.cluster_id

  ping_target_url = "https://${var.duckdns_fqdn}/health"

  tags = var.tags
}
```

## Inputs

| Variable | Type | Required | Default | Description |
|---|---|---|---|---|
| `resource_group_name` | string | Yes | — | Resource group for the action group + alert rules |
| `location` | string | Yes | — | Azure region (web test needs a location even though action group is global) |
| `alert_email_address` | string | Yes | — | Email that receives every alert |
| `app_insights_api_id` | string | Yes | — | App Insights resource ID for the API service |
| `app_insights_workers_id` | string | Yes | — | App Insights resource ID for the worker+scheduler instance |
| `postgres_server_id` | string | Yes | — | Flexible Server resource ID |
| `postgres_max_connections` | number | No | 50 | Postgres `max_connections` setting — used to compute the connections threshold |
| `servicebus_namespace_id` | string | Yes | — | Service Bus namespace resource ID |
| `aks_cluster_id` | string | Yes | — | AKS managed cluster resource ID |
| `ping_target_url` | string | Yes | — | Full URL the web test pings (e.g. `https://<fqdn>/health`) |
| `api_5xx_threshold` | number | No | 5 | 5xx count in 15 min |
| `api_p99_latency_ms_threshold` | number | No | 2000 | p99 latency in ms |
| `scheduler_stalled_window_minutes` | number | No | 15 | Look-back window for the scheduler stall check |
| `postgres_cpu_threshold` | number | No | 80 | Postgres CPU % |
| `servicebus_dlq_threshold` | number | No | 0 | DLQ message count |
| `aks_node_cpu_threshold` | number | No | 80 | Node CPU % |
| `aks_node_memory_threshold` | number | No | 85 | Node memory working-set % |
| `tags` | map(string) | No | `{}` | Applied to every resource |

## Outputs

| Output | Description |
|---|---|
| `action_group_id` | Resource ID of the Action Group — reference if you add alerts outside this module |
| `action_group_name` | Friendly name of the Action Group |

## Verification after deploy

```bash
# 1. Confirm the action group exists and has the right receiver
az monitor action-group show \
  --resource-group rg-ticketing-uksouth \
  --name ag-ticketing-baseline \
  --query "emailReceivers[0].emailAddress" -o tsv

# 2. List all alert rules — should be 8 metric alerts + 3 scheduled query alerts
az monitor metrics alert list \
  --resource-group rg-ticketing-uksouth \
  --query "[].name" -o table
az monitor scheduled-query list \
  --resource-group rg-ticketing-uksouth \
  --query "[].name" -o table

# 3. Trigger a test email to confirm the receiver works
az monitor action-group test-notifications create \
  --resource-group rg-ticketing-uksouth \
  --action-group ag-ticketing-baseline \
  --notification-type Email \
  --receivers Email/primary \
  --alert-type Servicehealth

# 4. The URL ping test should report Success in the AI portal within ~15 min
```

## Tuning thresholds

Defaults are conservative starting points; tune as you learn the real traffic shape:

- **API 5xx > 5 in 15 min** — assumes < 1 5xx/minute is acceptable noise. For a busier service, raise.
- **API p99 > 2000 ms** — generous; FastAPI + asyncpg should comfortably sit under 500 ms in steady state.
- **Postgres CPU > 80%** — leaves headroom for the alert to fire before the DB saturates.
- **Postgres connections > 80% of max** — `floor(50 * 0.8) = 40` for the default B_Standard_B1ms.
- **DLQ > 0** — any DLQ message is suspicious. Tune up if normal operation generates expected dead-letters (e.g. retried-then-dropped poison messages).
- **Node CPU > 80% / memory > 85%** — slightly tighter on memory because the working-set metric is less spiky than CPU.

All thresholds are module variables — override at the env level rather than editing the module.
