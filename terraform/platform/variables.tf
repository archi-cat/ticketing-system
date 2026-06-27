variable "subscription_id" {
  description = "Azure subscription ID."
  type        = string
}

variable "location" {
  description = "Azure region for the platform (hub) resources."
  type        = string
  default     = "uksouth"
}

variable "resource_group_name" {
  description = <<-EOT
    Resource group for the durable platform resources (hub VNet + self-hosted
    runner). Lives on its own lifecycle — NOT touched by the regional
    teardown.yml loop. Tear it down deliberately via platform-teardown.yml.
  EOT
  type        = string
  default     = "rg-ticketing-platform"
}

variable "hub_vnet_address_space" {
  description = <<-EOT
    Address space for the hub VNet. Must NOT overlap the regional spoke VNet
    (10.10.0.0/16) so the two can be peered. 10.20.0.0/16 by default.
  EOT
  type        = string
  default     = "10.20.0.0/16"
}

variable "runner_subnet_prefix" {
  description = "Subnet prefix for the runner VM inside the hub VNet."
  type        = string
  default     = "10.20.1.0/24"
}

variable "runner_vm_size" {
  description = <<-EOT
    VM size for the self-hosted runner. Standard_B2s (2 vCPU / 4 GiB,
    burstable) is enough to run terraform + kubectl for this project and is
    the cheapest size that comfortably builds the plan. Deallocate between
    deploy loops to cut the bill to disk only — see docs/04-private-cluster-access.md.
  EOT
  type        = string
  default     = "Standard_B2s"
}

variable "admin_username" {
  description = "Admin username on the runner VM (SSH only; no password auth)."
  type        = string
  default     = "azureuser"
}

variable "admin_ssh_public_key" {
  description = <<-EOT
    SSH public key (OpenSSH format) for the runner VM's admin user. Required by
    the VM resource even though routine access is via `az vm run-command`
    (control-plane, no inbound). Supply your own public key so the private key
    never touches Terraform state.
  EOT
  type        = string
}

variable "admin_ssh_cidr" {
  description = <<-EOT
    Optional source CIDR allowed to SSH (22/tcp) to the runner VM's public IP.
    Default null = no inbound SSH rule (run-command only — the recommended
    path). Set to your IP (e.g. "203.0.113.4/32") only if you need a shell.
  EOT
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to all platform resources."
  type        = map(string)
  default = {
    project     = "ticketing-system"
    managed_by  = "terraform"
    environment = "platform"
  }
}
