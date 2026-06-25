output "hub_vnet_id" {
  description = "Hub VNet resource ID — consumed by uksouth-primary (remote state) to create the hub↔spoke peering and link the API private DNS zone."
  value       = azurerm_virtual_network.hub.id
}

output "hub_vnet_name" {
  description = "Hub VNet name."
  value       = azurerm_virtual_network.hub.name
}

output "hub_resource_group_name" {
  description = "Platform resource group name — needed to scope the hub→spoke peering and DNS-zone link created from the spoke apply."
  value       = azurerm_resource_group.platform.name
}

output "runner_vm_id" {
  description = "Runner VM resource ID — used by workflows for `az vm run-command` (register) and `az vm start`/`deallocate` (cost control)."
  value       = azurerm_linux_virtual_machine.runner.id
}

output "runner_vm_name" {
  description = "Runner VM name."
  value       = azurerm_linux_virtual_machine.runner.name
}

output "runner_egress_ip" {
  description = "Runner's stable outbound public IP — this is the deployer IP the regional apply self-allow-lists on the Key Vault firewall."
  value       = azurerm_public_ip.runner.ip_address
}
