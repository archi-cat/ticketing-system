# ADR-0022: Baseline alerting via Azure Monitor

Status: Accepted
Date: 2026-06-11

## Context

Phase 3 Tier 1 #3: until this work, the platform had observability (Log Analytics + App Insights, ADR-0006) but no alerting — nothing would tell an operator that the API was returning 5xx, the scheduler had died, or Postgres was saturating. For a learning project deployed in teardown/redeploy loops the gap is tolerable; for the production posture the project demonstrates, it is not.

The goals:

1. One notification channel, minimal set of high-signal alerts across the data and application layers
2. Everything in Terraform — alerts are part of the regional platform, recreated identically on every deploy loop
3. Keep the Azure Monitor cost profile proportionate to a learning project

## Decision

A `terraform/modules/alerts` module provisioning one Action Group (single email receiver), eight alerts, and one URL ping test, instantiated by the uksouth-primary environment.

### Alert inventory

| Layer | Alert | Mechanism |
|---|---|---|
| Postgres | CPU > 80% (15-min avg) | Metric alert |
| Postgres | Connections > 80% of `max_connections` | Metric alert |
| Service Bus | Any DLQ message on the namespace | Metric alert (aggregation `Maximum`) |
| AKS | Node CPU > 80% | KQL alert against `InsightsMetrics` |
| AKS | Node memory working-set > 85% | KQL alert against `InsightsMetrics` |
| API | ≥ 5 5xx responses in 15 min | KQL alert against App Insights |
| API | p99 latency > 2000 ms | KQL alert against App Insights |
| Scheduler | No traces in 15 min ("stalled") | KQL alert against App Insights |
| Edge | HTTPS ping fails in 3 of 5 locations | Standard web test + metric alert |

All alerts evaluate every 15 minutes over a 15-minute window — the cadence is the main cost lever (scheduled-query alerts bill per evaluation; 15-min keeps each at roughly $1.50/month versus the 5-min Azure default).

### KQL alerts where metric alerts can't reach

Three lessons forced the mechanism choices, all discovered as deploy-time failures:

- **AKS node CPU/memory are not Azure Monitor metrics.** The portal shows them under an `Insights.Container/nodes` namespace, but `azurerm_monitor_metric_alert` cannot target it — the data only exists in the Log Analytics `InsightsMetrics` table (populated by Container Insights / the `oms_agent` block). Hence scheduled-query alerts for the node signals.
- **`scheduled_query_rules_alert_v2` requires `metric_measure_column`** whenever the time aggregation isn't `Count` — and the KQL must alias its aggregation to a named column (`count_5xx`, `p99_duration_ms`, `trace_count`) for the column reference to resolve.
- **Service Bus DLQ depth is a gauge** — `Total` aggregation is invalid; `Maximum` is the correct way to ask "were there ever dead-lettered messages in the window."

### Per-service identity in App Insights: `OTEL_SERVICE_NAME`

The scheduler-stalled alert queries traces by `cloud_RoleName == "ticketing-scheduler"`. The Azure Monitor OpenTelemetry SDK populates `cloud_RoleName` from the standard `OTEL_SERVICE_NAME` env var — not from the project's pre-existing custom `SERVICE_NAME`. Before this work all three services reported as `unknown_service:python`, making per-service queries impossible. All three deployments now set `OTEL_SERVICE_NAME=ticketing-<service>`; renaming a service requires updating the deployment YAML *and* the KQL in this module.

### Cert expiry: implicit via the ping test, not an explicit 30-day warning

The phase plan asked for a cert-expiry alert at 30 days remaining. Decision: skip it and let the HTTPS ping test catch cert failure when it happens — a TLS handshake failure (expired cert, bad chain, hostname mismatch) fails the ping and fires `alert-https-ping-failure`. The lost 30-day heads-up window is mitigated by cert-manager auto-renewing at day ~60 of 90; the failure mode an early warning would catch (renewal silently failing for a month) also surfaces in cert-manager logs. Real production with stricter SLOs would add the explicit warning (kube-prometheus-stack against cert-manager's expiration metric, or a scheduled Logic App).

### Web test locations

Azure standard web tests run from a fixed set of probe locations, and not every region listed in older docs is valid — `emea-ie-dub-azr` (Dublin) is rejected at deploy time. The test uses five working locations (four EMEA + `us-va-ash-azr`), alerting on 3-of-5 failures to tolerate single-probe flakiness.

### CI failures stay in GitHub

GitHub Actions failures notify via GitHub's native repo notifications, not the Action Group. The Action Group surface stays narrowly "what is happening to the running platform"; CI health is a different audience and cadence.

## Rationale

- **Eight alerts is deliberately small.** Each one maps to a question the operator genuinely needs answered (is the edge up, is the API healthy, is the data layer saturating, did the scheduler die). A bigger catalogue would mostly generate noise against a single-user platform.
- **Single email receiver matches the project's posture** — one operator. The Action Group is the abstraction point: adding Slack/PagerDuty/SMS later is receiver config, not alert rework.
- **Everything is module variables** (thresholds, windows) so tuning happens at the environment level without editing the module.

## Trade-offs accepted

- **No explicit cert-expiry warning** (see above) — accepted loss of the 30-day window.
- **15-minute granularity.** An outage can burn up to 15 minutes before the first email. Acceptable here; production would run 1–5 min evaluation on the customer-facing signals and pay for it.
- **Email as the only channel.** No paging, no escalation. The Action Group makes upgrading trivial when needed.
- **The alert email reuses `ACME_EMAIL`.** One fewer secret to manage; a real deployment would use an operations distribution list.
- **KQL alerts are coupled to App Insights schema and service naming.** The `OTEL_SERVICE_NAME` ↔ KQL coupling is documented in the module README; it's the price of querying traces instead of metrics.

## Operator path

- **Fresh deploy:** module rides `infra-uksouth.yml`; the only inputs beyond Terraform outputs are `alert_email_address` and `duckdns_fqdn` (both workflow `-var`s).
- **Verify:** `az monitor action-group test-notifications create` sends a test email; the module README has the full verification sequence.
- **Tune:** thresholds are documented per-alert in the module README with reasoning for each default.

## Future work

- Re-evaluate evaluation frequency for the edge + API alerts if the platform ever serves real users.
- Add the explicit cert-expiry warning if/when kube-prometheus-stack lands (it also unlocks alerting on cert-manager, Cilium, and node-level Kubernetes signals the Azure-native path can't see).
- Phase 4 multi-region: the module is region-agnostic by construction (everything keyed off resource IDs) — instantiate per region, plus a global availability alert at the Front Door layer.

## References

- `terraform/modules/alerts/` — module + README (inventory, thresholds, verification)
- ADR-0006 — observability design this builds on (single workspace, split App Insights)
- ADR-0020 — Gateway TLS; the ping test is the cert pipeline's production monitor
