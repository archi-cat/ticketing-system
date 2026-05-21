# AGC module

Provisions Azure Application Gateway for Containers (AGC) with the ALB
Controller identity wired up for Workload Identity, ready to receive
Gateway resources from the AKS cluster.

## Usage

This module is called from a regional composition. It depends on the
network module (for the AGC subnet) and the identity module (for the
ALB Controller UAMI principal ID).

```hcl
# Required: network module provides the AGC subnet, identity module
# provides the controller's UAMI

module "network" {
  source = "../../modules/network"

  # ... other inputs

  subnet_prefixes = {
    aks_system        = "10.10.1.0/24"
    aks_user          = "10.10.2.0/24"
    agc               = "10.10.3.0/24"
    private_endpoints = "10.10.4.0/24"
    postgres          = "10.10.5.0/24"
  }
}

module "identity" {
  source = "../../modules/identity"

  # ... other inputs

  oidc_issuer_url = module.aks.oidc_issuer_url

  service_accounts = {
    api = {
      namespace       = "ticketing"
      service_account = "api-service-account"
    }
    worker = {
      namespace       = "ticketing"
      service_account = "worker-service-account"
    }
    scheduler = {
      namespace       = "ticketing"
      service_account = "scheduler-service-account"
    }
    # The ALB Controller's UAMI lives here too, federated to the
    # service account installed by the AKS managed add-on in kube-system.
    alb = {
      namespace       = "kube-system"
      service_account = "alb-controller-sa"
    }
  }
}

# This module — creates AGC and grants the ALB Controller UAMI access

module "agc" {
  source = "../../modules/agc"

  name                = "agc-ticketing-uksouth"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name

  subnet_id                   = module.network.subnet_ids.agc
  alb_controller_principal_id = module.identity.identity_principal_ids.alb

  tags = var.tags
}
```

### Downstream consumers

After `terraform apply`, three outputs from this module need to flow into
the cluster manifests (typically via `envsubst` in the deploy workflow):

| Output | Where it's consumed |
|---|---|
| `module.agc.id` | Gateway annotation `alb.networking.azure.io/alb-id` |
| `module.agc.frontend_id` | Gateway annotation `alb.networking.azure.io/alb-frontend` |
| `module.agc.name` | Gateway annotation `alb.networking.azure.io/alb-name` |

The ALB Controller's client ID (needed for the controller's service
account annotation in `kube-system`) is exposed by the identity module
at `module.identity.identity_client_ids.alb` — not by this module.

### Apply order

Terraform infers the right order from the dependency graph:

```
network → identity → agc
```

The network module creates the AGC subnet first (since the AGC subnet's
delegation has to exist before any AGC resource references it). The
identity module creates the ALB Controller UAMI (no dependency on
AGC). The agc module then references both — the subnet ID and the
principal ID — and creates AGC plus its role assignments.

A clean `terraform apply` from a fresh state takes ~5-10 minutes for
the AGC resources specifically (the data plane provisioning is the
longest step).

## What this module creates

| Resource | Purpose |
|---|---|
| `azurerm_application_load_balancer` | The AGC instance itself |
| `azurerm_application_load_balancer_frontend` | Public-facing endpoint with managed public IP |
| `azurerm_application_load_balancer_subnet_association` | Binds AGC to the AKS VNet via the AGC subnet |
| `azurerm_role_assignment` × 2 | Grants the ALB Controller UAMI the permissions it needs on the AGC resource and the AGC vnet |

## Inputs

| Name | Description |
|---|---|
| `name` | AGC resource name (1-80 chars, alphanumeric + hyphens) |
| `location` | Azure region |
| `resource_group_name` | Target resource group |
| `subnet_id` | AGC subnet — must have the Microsoft.ServiceNetworking/trafficControllers delegation. Use `module.network.subnet_ids.agc`. |
| `vnet_id` | AGC vnet. Use `module.network.vnet_ids`. |
| `alb_controller_principal_id` | Principal ID of the ALB Controller UAMI (created by the identity module). Use `module.identity.identity_principal_ids.alb`. |
| `tags` | Resource tags |

## Outputs

| Name | Description |
|---|---|
| `id` | AGC resource ID — referenced by Gateway `alb.networking.azure.io/alb-id` annotation |
| `name` | AGC resource name — referenced by Gateway `alb.networking.azure.io/alb-name` annotation |
| `frontend_id` | AGC frontend ID — referenced by Gateway `alb.networking.azure.io/alb-frontend` annotation |
| `frontend_name` | AGC frontend name (informational) |

## Wiring up the Gateway

Once this module is applied, the cluster's Gateway resource needs two
annotations pointing at the AGC instance and its frontend:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ticketing
  namespace: ticketing
  annotations:
    alb.networking.azure.io/alb-name: "<output: name>"
    alb.networking.azure.io/alb-id: "<output: id>"
    alb.networking.azure.io/alb-frontend: "<output: frontend_id>"
spec:
  gatewayClassName: azure-alb-external
  ...
```

The ALB Controller in-cluster watches for Gateway resources, sees these
annotations, and programs the AGC accordingly. The Gateway's `ADDRESS`
field is populated with the AGC's FQDN within 2-3 minutes of apply.

## Relationship to the identity module

The ALB Controller's UAMI and federated credential are created by the
identity module, not by this one. This matches the codebase convention
that **identities live in the identity module** but **role assignments
live alongside the resource being protected**.

To use this module:

1. The identity module creates a UAMI for the ALB Controller (via a key
   like `alb` in its `service_accounts` input)
2. This module receives the UAMI's principal ID via
   `alb_controller_principal_id`
3. This module creates the role assignments granting that principal
   access to its AGC resource and subnet

The ALB Controller's client ID (needed for the service account annotation
in the cluster) is exposed by the identity module, not this one.

## See also

- [ADR-0014: AGC deployment pattern (BYO vs Managed)](../../../docs/decisions/0014-agc-deployment-pattern.md)
- [Microsoft docs: AGC architecture](https://learn.microsoft.com/en-us/azure/application-gateway/for-containers/overview)