terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
  required_version = ">= 1.9.0"
}

# ── Virtual Network ───────────────────────────────────────────────────────────

resource "azurerm_virtual_network" "main" {
  name                = var.vnet_name
  location            = var.location
  resource_group_name = var.resource_group_name
  address_space       = [var.address_space]
  tags                = var.tags
}

# ── Subnets ───────────────────────────────────────────────────────────────────

resource "azurerm_subnet" "aks_system" {
  name                 = "snet-aks-system"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.subnet_prefixes.aks_system]
}

resource "azurerm_subnet" "aks_user" {
  name                 = "snet-aks-user"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.subnet_prefixes.aks_user]
}

# AGC subnet — delegated to the ServiceNetworking provider
resource "azurerm_subnet" "agc" {
  name                 = "snet-agc"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.subnet_prefixes.agc]

  delegation {
    name = "agc-delegation"
    service_delegation {
      name = "Microsoft.ServiceNetworking/trafficControllers"
    }
  }
}

# Private Endpoints subnet — Network Policies enabled so NSGs apply to the
# Private Endpoint NICs (default in newer API versions but worth being explicit)
resource "azurerm_subnet" "private_endpoints" {
  name                              = "snet-private-endpoints"
  resource_group_name               = var.resource_group_name
  virtual_network_name              = azurerm_virtual_network.main.name
  address_prefixes                  = [var.subnet_prefixes.private_endpoints]
  private_endpoint_network_policies = "Enabled"
}

# PostgreSQL subnet — delegated to the DBforPostgreSQL provider for VNet injection
resource "azurerm_subnet" "postgres" {
  name                 = "snet-postgres"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.subnet_prefixes.postgres]

  delegation {
    name = "postgres-delegation"
    service_delegation {
      name = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action"
      ]
    }
  }
}

# ── Network Security Groups ───────────────────────────────────────────────────
# One NSG per subnet — applies the principle of least privilege.
# Phase 1 uses permissive defaults to ease initial deployment;
# Phase 2 will tighten these significantly.

resource "azurerm_network_security_group" "aks" {
  name                = "nsg-aks-${var.location}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_subnet_network_security_group_association" "aks_system" {
  subnet_id                 = azurerm_subnet.aks_system.id
  network_security_group_id = azurerm_network_security_group.aks.id
}

resource "azurerm_subnet_network_security_group_association" "aks_user" {
  subnet_id                 = azurerm_subnet.aks_user.id
  network_security_group_id = azurerm_network_security_group.aks.id
}

resource "azurerm_network_security_group" "private_endpoints" {
  name                = "nsg-pe-${var.location}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_subnet_network_security_group_association" "private_endpoints" {
  subnet_id                 = azurerm_subnet.private_endpoints.id
  network_security_group_id = azurerm_network_security_group.private_endpoints.id
}

# Note: AGC and Postgres subnets do not get NSGs because they are delegated
# subnets — Azure manages the necessary network rules for the delegated service

# ── Private DNS Zones ─────────────────────────────────────────────────────────
# These resolve PaaS service hostnames to private IPs when accessed via
# Private Endpoints. They are global resources but linked to the regional VNet.

locals {
  private_dns_zones = {
    postgres   = "privatelink.postgres.database.azure.com"
    redis      = "privatelink.redis.cache.windows.net"
    servicebus = "privatelink.servicebus.windows.net"
    keyvault   = "privatelink.vaultcore.azure.net"
    acr        = "privatelink.azurecr.io"
  }
}

resource "azurerm_private_dns_zone" "this" {
  for_each = local.private_dns_zones

  name                = each.value
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "this" {
  for_each = local.private_dns_zones

  name                  = "${each.key}-vnet-link"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.this[each.key].name
  virtual_network_id    = azurerm_virtual_network.main.id
  registration_enabled  = false
  tags                  = var.tags
}