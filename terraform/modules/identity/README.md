# Identity Module

Creates User-Assigned Managed Identities (UAMIs) and federates them to Kubernetes service accounts in an AKS cluster, enabling Workload Identity for application pods.

One UAMI is created per logical service. Each UAMI is bound to exactly one Kubernetes service account — pods running as that service account can obtain Azure AD tokens for the corresponding UAMI.

## Usage

```hcl
module "identity" {
  source = "../../modules/identity"

  location            = "uksouth"
  resource_group_name = "rg-ticketing-uksouth"
  name_prefix         = "uami-ticketing-uksouth"

  oidc_issuer_url      = module.aks.oidc_issuer_url

  service_accounts = {
    api       = {
      namespace = "ticketing",
      service_account = "api-service-account"
    }
    worker    = {
      namespace = "ticketing",
      service_account = "worker-service-account"
    }
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
| User-Assigned Managed Identity | One per `service_accounts` entry | Independent identities per service |
| Federated Identity Credential | One per `service_accounts` entry | Trusts the AKS OIDC issuer for the matching service account |

## Inputs

| Variable | Type | Required | Default | Description |
|---|---|---|---|---|
| `location` | string | Yes | — | Azure region |
| `resource_group_name` | string | Yes | — | Resource group for UAMIs |
| `name_prefix` | string | Yes | — | Prefix for UAMI names |
| `oidc_issuer_url` | string | Yes | — | AKS cluster OIDC issuer URL |
| `service_accounts` | `map(object({ namespace = string, service_account = string }))` | Map of logical identity key to its Kubernetes binding. Each entry specifies both the namespace AND the service account name. |
| `tags` | map(string) | No | `{}` | Tags applied to all resources |

## Service accounts Example

```hcl
module "identity" {
  source = "../../modules/identity"

  # ... other inputs

  service_accounts = {
    api = {
      namespace       = "ticketing"
      service_account = "api-service-account"
    }
    alb = {
      namespace       = "kube-system"
      service_account = "alb-controller-sa"
    }
  }
}
```

## Outputs

| Output | Type | Description |
|---|---|---|
| `identity_ids` | map | Service name → UAMI resource ID |
| `identity_principal_ids` | map | Service name → principal ID (for RBAC role assignments) |
| `identity_client_ids` | map | Service name → client ID (for K8s SA annotations) |
| `identity_names` | map | Service name → UAMI name |
| `service_account_names` | map | Passthrough of the `service_accounts` input |

## Notes

- This module does **not** create role assignments. Granting these identities access to specific Azure resources (PostgreSQL, Service Bus, Redis, Key Vault, ACR) is the responsibility of the modules that own those resources, or the environment composition.
- The `subject` field in federated credentials is case-sensitive. Mistakes here cause silent token exchange failures. The module constructs it from inputs to eliminate manual error.
- `principal_id` and `client_id` are different values for the same UAMI. Use `principal_id` for RBAC, `client_id` for service account annotations.
