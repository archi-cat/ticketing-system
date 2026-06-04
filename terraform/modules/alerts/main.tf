terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
  required_version = ">= 1.9.0"
}

# ── Action Group ─────────────────────────────────────────────────────────────
# Single landing target for every alert in this module. Uses the modern common
# alert schema for cleaner, structured emails. Phase 3 #3 chose email as the
# learning-mode paging target — in real production this would be a webhook to
# PagerDuty / Opsgenie / Teams, but the action group shape doesn't change.

resource "azurerm_monitor_action_group" "this" {
  name                = "ag-ticketing-baseline"
  resource_group_name = var.resource_group_name
  short_name          = "ticketing"

  email_receiver {
    name                    = "primary"
    email_address           = var.alert_email_address
    use_common_alert_schema = true
  }

  tags = var.tags
}

# ── PostgreSQL CPU ───────────────────────────────────────────────────────────

resource "azurerm_monitor_metric_alert" "postgres_cpu" {
  name                = "alert-postgres-cpu-high"
  resource_group_name = var.resource_group_name
  scopes              = [var.postgres_server_id]
  description         = "PostgreSQL CPU > ${var.postgres_cpu_threshold}% over a 10-minute window."
  severity            = 2 # warning
  frequency           = "PT15M"
  window_size         = "PT15M"

  criteria {
    metric_namespace = "Microsoft.DBforPostgreSQL/flexibleServers"
    metric_name      = "cpu_percent"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = var.postgres_cpu_threshold
  }

  action {
    action_group_id = azurerm_monitor_action_group.this.id
  }

  tags = var.tags
}

# ── PostgreSQL active connections ────────────────────────────────────────────
# 80% of max_connections — threshold computed from the variable rather than
# hardcoded so SKU changes don't silently leave the alert dormant.

resource "azurerm_monitor_metric_alert" "postgres_connections" {
  name                = "alert-postgres-connections-high"
  resource_group_name = var.resource_group_name
  scopes              = [var.postgres_server_id]
  description         = "PostgreSQL active connections > 80% of max_connections (${var.postgres_max_connections}) over a 10-minute window."
  severity            = 2
  frequency           = "PT15M"
  window_size         = "PT15M"

  criteria {
    metric_namespace = "Microsoft.DBforPostgreSQL/flexibleServers"
    metric_name      = "active_connections"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = floor(var.postgres_max_connections * 0.8)
  }

  action {
    action_group_id = azurerm_monitor_action_group.this.id
  }

  tags = var.tags
}

# ── Service Bus DLQ depth ────────────────────────────────────────────────────
# Any message in any DLQ pages. For a healthy system DLQ should always be 0;
# in this learning project's threat model, a single DLQ message is worth
# investigating immediately.

resource "azurerm_monitor_metric_alert" "servicebus_dlq" {
  name                = "alert-servicebus-dlq-nonzero"
  resource_group_name = var.resource_group_name
  scopes              = [var.servicebus_namespace_id]
  description         = "Service Bus deadletter queue has > ${var.servicebus_dlq_threshold} messages."
  severity            = 2
  frequency           = "PT15M"
  window_size         = "PT15M"

  criteria {
    metric_namespace = "Microsoft.ServiceBus/namespaces"
    metric_name      = "DeadletteredMessages"
    # DLQ depth is a gauge (point-in-time count), not a counter — Total isn't
    # a valid aggregation. Maximum gives "highest DLQ count seen in this
    # window", which is the right semantic for "any DLQ message warrants
    # attention."
    aggregation = "Maximum"
    operator    = "GreaterThan"
    threshold   = var.servicebus_dlq_threshold
  }

  action {
    action_group_id = azurerm_monitor_action_group.this.id
  }

  tags = var.tags
}

# ── AKS node CPU / memory ────────────────────────────────────────────────────
# Container Insights writes per-node CPU and memory percentages into the
# InsightsMetrics table in Log Analytics, but those metrics are NOT exposed
# under Azure Monitor Metrics (despite the `Insights.Container/nodes`
# namespace looking like one). The metric_alert form returns
# "metric not found" at apply time. The fix: scheduled query alerts against
# Log Analytics, returning one row per node (Computer) so the alert can
# fire per-node via the dimension below.

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "aks_node_cpu" {
  name                = "alert-aks-node-cpu-high"
  resource_group_name = var.resource_group_name
  location            = var.location
  scopes              = [var.log_analytics_workspace_id]
  description         = "AKS node CPU usage > ${var.aks_node_cpu_threshold}% (15-min max) on at least one node."
  severity            = 2

  evaluation_frequency = "PT15M"
  window_duration      = "PT15M"

  criteria {
    query = <<-KQL
      InsightsMetrics
      | where Namespace == "container.azm.ms/nodes"
      | where Name == "cpuUsagePercentage"
      | summarize cpuPct = max(todouble(Val)) by Computer
    KQL

    operator                = "GreaterThan"
    threshold               = var.aks_node_cpu_threshold
    time_aggregation_method = "Maximum"
    metric_measure_column   = "cpuPct"

    dimension {
      name     = "Computer"
      operator = "Include"
      values   = ["*"]
    }

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  action {
    action_groups = [azurerm_monitor_action_group.this.id]
  }

  tags = var.tags
}

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "aks_node_memory" {
  name                = "alert-aks-node-memory-high"
  resource_group_name = var.resource_group_name
  location            = var.location
  scopes              = [var.log_analytics_workspace_id]
  description         = "AKS node memory working-set > ${var.aks_node_memory_threshold}% (15-min max) on at least one node."
  severity            = 2

  evaluation_frequency = "PT15M"
  window_duration      = "PT15M"

  criteria {
    query = <<-KQL
      InsightsMetrics
      | where Namespace == "container.azm.ms/nodes"
      | where Name == "memoryWorkingSetPercentage"
      | summarize memPct = max(todouble(Val)) by Computer
    KQL

    operator                = "GreaterThan"
    threshold               = var.aks_node_memory_threshold
    time_aggregation_method = "Maximum"
    metric_measure_column   = "memPct"

    dimension {
      name     = "Computer"
      operator = "Include"
      values   = ["*"]
    }

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  action {
    action_groups = [azurerm_monitor_action_group.this.id]
  }

  tags = var.tags
}

# ── API 5xx rate (scheduled query against App Insights) ──────────────────────

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "api_5xx_rate" {
  name                = "alert-api-5xx-rate"
  resource_group_name = var.resource_group_name
  location            = var.location
  scopes              = [var.app_insights_api_id]
  description         = "API 5xx response count > ${var.api_5xx_threshold} in a 15-minute window."
  severity            = 2

  evaluation_frequency = "PT15M"
  window_duration      = "PT15M"

  criteria {
    # Alias the count to a named column so metric_measure_column can reference
    # it. With time_aggregation_method = "Total" the scheduled query alert
    # requires a metric_measure_column.
    query = <<-KQL
      requests
      | where toint(resultCode) >= 500
      | summarize count_5xx = count()
    KQL

    operator                = "GreaterThan"
    threshold               = var.api_5xx_threshold
    time_aggregation_method = "Total"
    metric_measure_column   = "count_5xx"

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  action {
    action_groups = [azurerm_monitor_action_group.this.id]
  }

  tags = var.tags
}

# ── API p99 latency (scheduled query against App Insights) ───────────────────

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "api_p99_latency" {
  name                = "alert-api-p99-latency"
  resource_group_name = var.resource_group_name
  location            = var.location
  scopes              = [var.app_insights_api_id]
  description         = "API p99 request duration > ${var.api_p99_latency_ms_threshold}ms over a 15-minute window."
  severity            = 2

  evaluation_frequency = "PT15M"
  window_duration      = "PT15M"

  criteria {
    query = <<-KQL
      requests
      | summarize p99_duration_ms = percentile(duration, 99)
    KQL

    operator                = "GreaterThan"
    threshold               = var.api_p99_latency_ms_threshold
    time_aggregation_method = "Average"
    metric_measure_column   = "p99_duration_ms"

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  action {
    action_groups = [azurerm_monitor_action_group.this.id]
  }

  tags = var.tags
}

# ── Scheduler stalled ────────────────────────────────────────────────────────
# Fires when the scheduler hasn't emitted any traces in the configured window.
# Relies on cloud_RoleName == "ticketing-scheduler" — set by the OpenTelemetry
# SDK from the OTEL_SERVICE_NAME env var on the scheduler Deployment.

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "scheduler_stalled" {
  name                = "alert-scheduler-stalled"
  resource_group_name = var.resource_group_name
  location            = var.location
  scopes              = [var.app_insights_workers_id]
  description         = "Scheduler has not emitted any traces in ${var.scheduler_stalled_window_minutes} minutes."
  severity            = 1 # error — scheduler stall is service-impacting

  evaluation_frequency = "PT15M"
  window_duration      = "PT${var.scheduler_stalled_window_minutes}M"

  criteria {
    query = <<-KQL
      traces
      | where cloud_RoleName == "ticketing-scheduler"
      | summarize trace_count = count()
    KQL

    operator                = "LessThan"
    threshold               = 1
    time_aggregation_method = "Total"
    metric_measure_column   = "trace_count"

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  action {
    action_groups = [azurerm_monitor_action_group.this.id]
  }

  tags = var.tags
}

# ── URL ping test (Application Insights standard web test) ────────────────────
# Pings the public endpoint from 5 EMEA locations every 10 minutes. A TLS
# handshake failure (including an expired cert) is reported as a ping failure
# — covering both availability AND cert health under one alert. Standalone
# cert-expiry alerting was deferred per the dual-lens decision in #3's plan.

resource "azurerm_application_insights_standard_web_test" "https_ping" {
  name                    = "wt-ticketing-https-ping"
  resource_group_name     = var.resource_group_name
  location                = var.location
  application_insights_id = var.app_insights_api_id

  # Confirmed-valid web test agent IDs. Dublin (`emea-ie-dub-azr`) isn't
  # a supported location despite the naming pattern suggesting it would be
  # Other potentially-tempting EMEA IDs to avoid: `emea-ru-msa-edge` (Russia, retired);
  # `emea-au-syd-edge` (despite the name, that's Asia-Pacific).
  geo_locations = [
    "emea-nl-ams-azr",  # West Europe (Amsterdam)
    "emea-fr-pra-edge", # France South (Paris)
    "emea-se-sto-edge", # Sweden Central (Stockholm)
    "emea-gb-db3-azr",  # UK West
    "us-va-ash-azr",    # East US (Virginia) — transatlantic anchor
  ]

  frequency     = 900 # 15 minutes — matches the cadence of every other alert
  timeout       = 30
  enabled       = true
  retry_enabled = true

  request {
    url                              = var.ping_target_url
    http_verb                        = "GET"
    parse_dependent_requests_enabled = false
    follow_redirects_enabled         = true
  }

  validation_rules {
    expected_status_code = 200
    ssl_check_enabled    = true
  }

  tags = var.tags

  # The web test attaches itself to App Insights via a hidden link tag — the
  # azurerm provider often round-trips these tags noisily on plan. ignore_changes
  # on tags would also hide intentional tag changes, so we leave them alone.
}

# ── URL ping test alert ──────────────────────────────────────────────────────
# Fires when the web test fails in 3 or more of its 5 geo locations within the
# evaluation window. 3/5 catches real outages without paging on a single
# location's transient issue.

resource "azurerm_monitor_metric_alert" "https_ping_failure" {
  name                = "alert-https-ping-failure"
  resource_group_name = var.resource_group_name
  scopes = [
    azurerm_application_insights_standard_web_test.https_ping.id,
    var.app_insights_api_id,
  ]
  description = "HTTPS ping to ${var.ping_target_url} failed in 3 of 5 locations — site down, cert invalid/expired, or DNS broken."
  severity    = 1
  frequency   = "PT15M"
  window_size = "PT15M"

  application_insights_web_test_location_availability_criteria {
    web_test_id           = azurerm_application_insights_standard_web_test.https_ping.id
    component_id          = var.app_insights_api_id
    failed_location_count = 3
  }

  action {
    action_group_id = azurerm_monitor_action_group.this.id
  }

  tags = var.tags
}
