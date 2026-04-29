# Service Bus Sub-module

Creates an Azure Service Bus Premium namespace with Private Endpoint, Entra-ID-only authentication (SAS disabled), and a configurable set of topics and subscriptions.

## Usage

```hcl
module "servicebus" {
  source = "../../modules/data/servicebus"

  location            = "uksouth"
  resource_group_name = "rg-ticketing-uksouth"
  namespace_name      = "sb-ticketing-uksouth"

  sku             = "Premium"
  messaging_units = 1

  topics = {
    "reservation-events" = {
      subscriptions = {
        "seat-decrement" = {}
        "audit-log"      = {}
      }
    }

    "booking-events" = {
      subscriptions = {
        "confirmation-email" = {}
        "audit-log"          = {}
      }
    }
  }

  private_endpoint_subnet_id = module.network.subnet_ids.private_endpoints
  private_dns_zone_id        = module.network.private_dns_zone_ids.servicebus

  log_analytics_workspace_id = module.observability.log_analytics_workspace_id

  tags = {
    environment = "primary"
    project     = "ticketing-system"
  }
}
```

## Resources created

| Resource | Quantity | Notes |
|---|---|---|
| Service Bus namespace | 1 | Premium, public access disabled, SAS auth disabled |
| Topic | One per `var.topics` entry | Partitioning disabled |
| Subscription | One per subscription within a topic | Dead-lettering on TTL and filter errors enabled |
| Subscription rule (SQL filter) | One per subscription | Default `1=1` accepts all messages |
| Private Endpoint | 1 | NIC in private-endpoints subnet |
| Diagnostic setting | 1 | Streams logs and metrics to Log Analytics |

## Inputs

See `variables.tf`. The `topics` variable is the most substantial — it captures the full topic + subscription topology in one input.

## Outputs

| Output | Description |
|---|---|
| `namespace_id` | Namespace resource ID |
| `namespace_name` | Namespace name |
| `namespace_endpoint` | Service Bus endpoint URL |
| `fully_qualified_namespace` | FQDN — what apps pass to the SDK in passwordless mode |
| `topic_ids` | Map of topic name → resource ID |
| `topic_names` | List of topic names |
| `subscription_ids` | Map of `topic/subscription` → resource ID — used by role assignments |

## How authentication works

SAS authentication is **disabled at the namespace level** (`local_auth_enabled = false`). All authentication flows through Entra ID:

1. Application pods run with Workload Identity, presenting their UAMI's identity to Azure AD.
2. The pod requests a token for `https://servicebus.azure.net`.
3. Azure AD issues the token after validating the UAMI's RBAC role assignments on the namespace.
4. The Service Bus SDK presents the token; Service Bus validates it.

Required RBAC roles (assigned at the namespace, topic, or subscription level depending on scope):

- `Azure Service Bus Data Sender` — for publishers (the API service)
- `Azure Service Bus Data Receiver` — for consumers (the worker service)

Role assignments are not part of this module — they live with the consumer (typically the environment composition or the identity module).

## Notes

- This module requires **Premium** SKU. Standard/Basic do not support Private Endpoints or geo-DR pairing (needed in Phase 4).
- Disabling SAS auth (`local_auth_enabled = false`) is irreversible at the data plane in the sense that any code attempting to authenticate with a connection string will fail. This is intentional and aligned with the project's Workload Identity pattern.
- Subscription filters default to `1=1` (accept all). Override per subscription to filter messages by topic-level metadata.
- The flattening trick in `locals.subscriptions_flattened` allows nested input structures while keeping resource definitions flat, satisfying Terraform's `for_each` requirements.