terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
  required_version = ">= 1.9.0"
}

# ── Log Analytics workspace ───────────────────────────────────────────────────
# Single workspace receives logs and metrics from all resources in this region:
#   - AKS Container Insights
#   - Application Insights (workspace-based mode)
#   - Diagnostic settings on PostgreSQL, Service Bus, Redis, Key Vault
#
# Centralising in one workspace means cross-resource queries work without
# union'ing across multiple workspaces.

resource "azurerm_log_analytics_workspace" "main" {
  name                = "log-${var.name_prefix}"
  location            = var.location
  resource_group_name = var.resource_group_name

  sku               = "PerGB2018"
  retention_in_days = var.retention_in_days
  daily_quota_gb    = var.daily_ingestion_cap_gb

  tags = var.tags
}

# ── Application Insights instances ────────────────────────────────────────────
# Workspace-based App Insights — telemetry ingestion endpoint sits in front of
# the Log Analytics workspace. The 'classic' App Insights (separate storage)
# was deprecated in 2024.

resource "azurerm_application_insights" "this" {
  for_each = var.application_insights_instances

  name                = "appi-${var.name_prefix}-${each.key}"
  location            = var.location
  resource_group_name = var.resource_group_name
  workspace_id        = azurerm_log_analytics_workspace.main.id
  application_type    = each.value.application_type

  # Disable IP masking — useful for distinguishing legitimate user IPs from
  # bot traffic in incident investigations. Has no PII implications when the
  # application doesn't log IPs as part of business events.
  disable_ip_masking = false

  tags = var.tags
}