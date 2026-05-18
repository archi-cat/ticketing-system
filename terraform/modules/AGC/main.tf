# ─── Application Gateway for Containers ──────────────────────────────────────
# AGC sits in front of the AKS cluster, provisioned via Terraform (BYO mode)
# rather than via the ALB Controller's managed mode. See ADR-0014 for the
# rationale.
#
# AGC has three resources that all need to exist together:
# - The traffic controller itself (the data plane)
# - A frontend (the public IP / DNS endpoint)
# - An association (binds the frontend to the AKS subnet)

resource "azurerm_application_load_balancer" "this" {
  name                = var.name
  location            = var.location
  resource_group_name = var.resource_group_name

  tags = var.tags
}

# The frontend is the public-facing entry point. AGC manages the public IP
# automatically — no separate azurerm_public_ip resource needed. The IP is
# exposed via the FQDN output once provisioning completes (~3-5 minutes).
resource "azurerm_application_load_balancer_frontend" "this" {
  name                         = "frontend"
  application_load_balancer_id = azurerm_application_load_balancer.this.id

  tags = var.tags
}

# The subnet association binds AGC to the dedicated AGC subnet in the AKS
# VNet, giving it network reachability to pods in the cluster.
resource "azurerm_application_load_balancer_subnet_association" "this" {
  name                         = "subnet-association"
  application_load_balancer_id = azurerm_application_load_balancer.this.id
  subnet_id                    = var.subnet_id

  tags = var.tags
}

# ─── Role assignments for the ALB Controller ─────────────────────────────────
# The controller (running in-cluster, federated to the UAMI created by the
# identity module) needs two roles to do its job:
# - AppGw for Containers Configuration Manager on the AGC resource
# - Network Contributor on the AGC subnet
#
# Both scoped narrowly — not on the whole resource group.

resource "azurerm_role_assignment" "alb_controller_config_manager" {
  scope                = azurerm_application_load_balancer.this.id
  role_definition_name = "AppGw for Containers Configuration Manager"
  principal_id         = var.alb_controller_principal_id
}

resource "azurerm_role_assignment" "alb_controller_subnet_network_contributor" {
  scope                = var.subnet_id
  role_definition_name = "Network Contributor"
  principal_id         = var.alb_controller_principal_id
}