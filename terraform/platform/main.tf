terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
  required_version = ">= 1.9.0"
}

provider "azurerm" {
  subscription_id = var.subscription_id
  features {}
  skip_provider_registration = true
}

# ─────────────────────────────────────────────────────────────────────────────
# Platform / ops layer — durable across the regional deploy/teardown loop.
#
# Holds the HUB VNet and a single self-hosted GitHub Actions runner. Once the
# AKS API server is private (Phase 3 #13 / ADR-0035), the regional deploy must
# run from inside the VNet: `az aks command invoke` proxies the kubectl CLI but
# CANNOT carry Terraform's helm/kubernetes providers (direct TLS to the API
# server). This runner is that in-VNet execution context.
#
# It lives in its own state (platform.tfstate) and its own resource group, both
# IGNORED by the regional teardown.yml. Tear it down deliberately with
# platform-teardown.yml. The hub is peered to the per-deploy spoke VNet from the
# spoke side (uksouth-primary), so the peering is created/destroyed with each
# regional loop while the hub itself persists.
#
# Note on role assignments: the GitHub Actions deploy SP that runs every apply
# in this project is already privileged enough to create resource groups and
# role assignments subscription-wide, so it needs no extra grant here to manage
# the runner VM (run-command / start / deallocate) or to create the hub↔spoke
# peering from the spoke apply. No self-grant is added — it would be redundant.
# ─────────────────────────────────────────────────────────────────────────────

resource "azurerm_resource_group" "platform" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

# ── Hub VNet + runner subnet ──────────────────────────────────────────────────
resource "azurerm_virtual_network" "hub" {
  name                = "vnet-ticketing-hub"
  location            = azurerm_resource_group.platform.location
  resource_group_name = azurerm_resource_group.platform.name
  address_space       = [var.hub_vnet_address_space]
  tags                = var.tags
}

resource "azurerm_subnet" "runner" {
  name                 = "snet-runner"
  resource_group_name  = azurerm_resource_group.platform.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [var.runner_subnet_prefix]
}

# ── NSG ───────────────────────────────────────────────────────────────────────
# Self-hosted runners are outbound-only — they long-poll GitHub, nothing
# connects IN. Azure's default rules already deny inbound from the internet, so
# the only inbound rule here is an OPTIONAL SSH allow for break-glass shell
# access (disabled by default; routine access is `az vm run-command`, which is
# control-plane and needs no inbound).
resource "azurerm_network_security_group" "runner" {
  name                = "nsg-runner"
  location            = azurerm_resource_group.platform.location
  resource_group_name = azurerm_resource_group.platform.name
  tags                = var.tags

  dynamic "security_rule" {
    for_each = var.admin_ssh_cidr == null ? [] : [var.admin_ssh_cidr]
    content {
      name                       = "allow-ssh-admin"
      priority                   = 300
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "22"
      source_address_prefix      = security_rule.value
      destination_address_prefix = "*"
    }
  }
}

resource "azurerm_subnet_network_security_group_association" "runner" {
  subnet_id                 = azurerm_subnet.runner.id
  network_security_group_id = azurerm_network_security_group.runner.id
}

# ── Outbound public IP ────────────────────────────────────────────────────────
# A Standard static public IP gives the runner a STABLE egress address. Two
# reasons it matters: (1) Azure is retiring default outbound access, so an
# explicit egress is the durable choice; (2) the regional apply runs on this
# runner and self-allow-lists its egress IP on the Key Vault firewall via
# data.http.myip — a stable IP keeps that deterministic. Cheaper than a NAT
# gateway (which we deliberately skip at this scale).
resource "azurerm_public_ip" "runner" {
  name                = "pip-runner"
  location            = azurerm_resource_group.platform.location
  resource_group_name = azurerm_resource_group.platform.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_network_interface" "runner" {
  name                = "nic-runner"
  location            = azurerm_resource_group.platform.location
  resource_group_name = azurerm_resource_group.platform.name
  tags                = var.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.runner.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.runner.id
  }
}

# ── Runner VM ─────────────────────────────────────────────────────────────────
# cloud-init installs the toolchain (az, terraform, kubectl, kubelogin) and the
# GitHub Actions runner agent, but does NOT register it. Registration is done
# out-of-band by platform.yml via `az vm run-command`, which feeds a freshly
# minted, short-lived registration token — so no GitHub credential is ever
# baked into the VM model, custom_data, or Terraform state.
resource "azurerm_linux_virtual_machine" "runner" {
  name                = "vm-ticketing-runner"
  location            = azurerm_resource_group.platform.location
  resource_group_name = azurerm_resource_group.platform.name
  size                = var.runner_vm_size
  admin_username      = var.admin_username

  network_interface_ids = [azurerm_network_interface.runner.id]

  # System-assigned identity — not required for the OIDC-based deploy auth
  # (workflows still `azure/login` as the GitHub Actions SP), but kept for
  # future use (e.g. an MI-authenticated bootstrap) at no cost.
  identity {
    type = "SystemAssigned"
  }

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.admin_ssh_public_key
  }

  os_disk {
    name                 = "osdisk-runner"
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 64
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  custom_data = base64encode(file("${path.module}/cloud-init.yaml"))

  tags = var.tags
}
