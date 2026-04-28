# Network Module

Creates a regional virtual network with subnets for AKS, AGC, Private Endpoints, and PostgreSQL Flexible Server. Also provisions and links the Private DNS zones needed by the PaaS services in this project.

## Usage

```hcl
module "network" {
  source = "../../modules/network"

  location            = "uksouth"
  resource_group_name = "rg-ticketing-uksouth"
  vnet_name           = "vnet-ticketing-uksouth"
  address_space       = "10.10.0.0/16"

  subnet_prefixes = {
    aks_system        = "10.10.1.0/24"
    aks_user          = "10.10.2.0/24"
    agc               = "10.10.3.0/24"
    private_endpoints = "10.10.4.0/24"
    postgres          = "10.10.5.0/24"
  }

  tags = {
    environment = "primary"
    project     = "ticketing-system"
  }
}
```

## Resources created

| Resource | Quantity | Notes |
|---|---|---|
| Virtual network | 1 | The regional VNet |
| Subnets | 5 | aks-system, aks-user, agc (delegated), private-endpoints, postgres (delegated) |
| Network Security Groups | 2 | One for AKS subnets, one for Private Endpoints |
| Private DNS zones | 5 | postgres, redis, servicebus, keyvault, acr |
| Private DNS zone VNet links | 5 | Links each DNS zone to the VNet |

## Inputs

| Variable | Type | Required | Description |
|---|---|---|---|
| `location` | string | Yes | Azure region |
| `resource_group_name` | string | Yes | Resource group for all created resources |
| `vnet_name` | string | Yes | Virtual network name |
| `address_space` | string | Yes | VNet CIDR (e.g. `10.10.0.0/16`) |
| `subnet_prefixes` | object | Yes | Map of subnet name to CIDR |
| `tags` | map(string) | No | Tags applied to all resources |

## Outputs

| Output | Type | Description |
|---|---|---|
| `vnet_id` | string | Virtual network resource ID |
| `vnet_name` | string | Virtual network name |
| `subnet_ids` | map | Subnet name → subnet ID |
| `private_dns_zone_ids` | map | Service name → Private DNS zone ID |
| `private_dns_zone_names` | map | Service name → Private DNS zone name |

## Notes

- Subnet delegations on AGC and PostgreSQL subnets are required by those services; do not attach NSGs to delegated subnets.
- Private DNS zones are created in the same resource group as the VNet for simplicity. In multi-VNet scenarios, consider centralising DNS zones in a hub.