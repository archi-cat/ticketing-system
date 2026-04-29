terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
  required_version = ">= 1.9.0"
}

# ── Service Bus namespace ─────────────────────────────────────────────────────
# Premium SKU is required for Private Endpoints and geo-DR pairing (Phase 4).
# SAS-based authentication is disabled at the namespace level, forcing all
# clients to authenticate via Entra ID and removing connection strings as
# an attack vector.

resource "azurerm_servicebus_namespace" "main" {
  name                = var.namespace_name
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = var.sku
  capacity            = var.messaging_units

  # ── Public access disabled ──────────────────────────────────────────────────
  public_network_access_enabled = false

  # ── SAS auth disabled ───────────────────────────────────────────────────────
  # Force all authentication through Entra ID. Eliminates connection string
  # leaks as a threat vector. Application pods authenticate as their UAMI
  # via Workload Identity.
  local_auth_enabled = false

  # ── Minimum TLS ─────────────────────────────────────────────────────────────
  minimum_tls_version = "1.2"

  tags = var.tags
}

# ── Topics ────────────────────────────────────────────────────────────────────
# One per entry in var.topics. The application's event flow lives here.

resource "azurerm_servicebus_topic" "this" {
  for_each = var.topics

  name         = each.key
  namespace_id = azurerm_servicebus_namespace.main.id

  max_size_in_megabytes = each.value.max_size_in_megabytes

  # No partitioning — Premium SKU doesn't support partitioning, and our
  # throughput is well within a single partition's capacity.
  partitioning_enabled = false

  # No duplicate detection at the topic level — application-level idempotency
  # is handled by the processed_messages table in PostgreSQL.

  # Sessions disabled — no flows require ordered processing within a session.
  requires_duplicate_detection = false
}

# ── Subscriptions ─────────────────────────────────────────────────────────────
# Flatten {topic → {subscription → config}} into a single map keyed by
# "topic/subscription" so that for_each can iterate over all subscriptions
# in one pass.

locals {
  subscriptions_flattened = merge([
    for topic_name, topic_cfg in var.topics : {
      for sub_name, sub_cfg in topic_cfg.subscriptions :
      "${topic_name}/${sub_name}" => merge(sub_cfg, {
        topic_name = topic_name
        sub_name   = sub_name
      })
    }
  ]...)
}

resource "azurerm_servicebus_subscription" "this" {
  for_each = local.subscriptions_flattened

  name     = each.value.sub_name
  topic_id = azurerm_servicebus_topic.this[each.value.topic_name].id

  max_delivery_count                   = each.value.max_delivery_count
  lock_duration                        = each.value.lock_duration
  default_message_ttl                  = each.value.default_message_ttl
  dead_lettering_on_message_expiration = each.value.dead_lettering_on_message_expiration

  # Always dead-letter on filter evaluation errors — these indicate a
  # malformed message that no consumer can process.
  dead_lettering_on_filter_evaluation_error = true

  # No sessions, no batched operations
  requires_session = false
}

# ── Subscription rules (SQL filters) ──────────────────────────────────────────
# Service Bus auto-creates a "$Default" rule on each subscription that accepts
# all messages. We replace it with the configured SQL filter so that
# subscription filtering can be customised per consumer (e.g. an analytics
# subscription that only wants high-value events).

resource "azurerm_servicebus_subscription_rule" "this" {
  for_each = local.subscriptions_flattened

  name            = "filter"
  subscription_id = azurerm_servicebus_subscription.this[each.key].id
  filter_type     = "SqlFilter"
  sql_filter      = each.value.sql_filter
}

# ── Private Endpoint ──────────────────────────────────────────────────────────

resource "azurerm_private_endpoint" "servicebus" {
  name                = "pe-${var.namespace_name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.private_endpoint_subnet_id

  private_service_connection {
    name                           = "psc-${var.namespace_name}"
    private_connection_resource_id = azurerm_servicebus_namespace.main.id
    is_manual_connection           = false
    subresource_names              = ["namespace"]
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [var.private_dns_zone_id]
  }

  tags = var.tags
}

# ── Diagnostic settings ───────────────────────────────────────────────────────

resource "azurerm_monitor_diagnostic_setting" "servicebus" {
  name                       = "diag-${var.namespace_name}"
  target_resource_id         = azurerm_servicebus_namespace.main.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "OperationalLogs"
  }

  enabled_log {
    category = "VNetAndIPFilteringLogs"
  }

  enabled_log {
    category = "RuntimeAuditLogs"
  }

  enabled_log {
    category = "ApplicationMetricsLogs"
  }

  metric {
    category = "AllMetrics"
  }
}