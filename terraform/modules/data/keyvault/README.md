# Key Vault Sub-module

Creates an Azure Key Vault with RBAC authorisation, Private Endpoint access, soft delete and purge protection, and optional bootstrap secrets and role assignments.

## Usage

```hcl
module "keyvault" {
  source = "../../modules/data/keyvault"

  location            = "uksouth"
  resource_group_name = "rg-ticketing-uksouth"
  vault_name          = "kv-ticketing-uks"      # must be 3-24 chars
  tenant_id           = data.azurerm_client_config.current.tenant_id

  private_endpoint_subnet_id = module.network.subnet_ids.private_endpoints
  private_dns_zone_id        = module.network.private_dns_zone_ids.keyvault
  log_analytics_workspace_id = module.observability.log_analytics_workspace_id

  # Bootstrap secrets — sourced from other Terraform-managed resources
  secrets = {
    "redis-primary-key" = {
      value = module.redis.primary_access_key
    }
  }

  # Application UAMIs get read access
  secret_reader_principal_ids = [
    module.identity.identity_principal_ids.api,
    module.identity.identity_principal_ids.worker,
    module.identity.identity_principal_ids.scheduler,
  ]

  # GitHub Actions SP gets read-write access
  secret_officer_principal_ids = [
    var.github_actions_sp_object_id,
  ]

  tags = {
    environment = "primary"
    project     = "ticketing-system"
  }
}
```

## Resources created

| Resource | Quantity | Notes |
|---|---|---|
| Key Vault | 1 | Standard SKU, RBAC mode, public access disabled, purge protection on |
| Role assignments | One per reader/officer principal | RBAC scoped to the vault |
| Private Endpoint | 1 | NIC in private-endpoints subnet |
| Bootstrap secrets | One per `var.secrets` entry | Created with explicit dependency on the officer role |
| Diagnostic setting | 1 | AuditEvent + metrics to Log Analytics |

## Inputs

See `variables.tf`. Particularly note:

- `secrets` is sensitive at the variable level — values are suppressed from plan output
- `secret_reader_principal_ids` and `secret_officer_principal_ids` are separate lists rather than a role-mapped object — this matches the most common usage pattern

## Outputs

| Output | Sensitive | Description |
|---|---|---|
| `vault_id` | No | Vault resource ID |
| `vault_name` | No | Vault name |
| `vault_uri` | No | Vault URI for SDK clients |
| `secret_ids` | Yes | Map of bootstrap secret name → versioned ID |

## Authorisation model

This module uses **RBAC**, not access policies. The relevant role assignments are:

| Role | Granted via | Typical principal |
|---|---|---|
| Key Vault Secrets Officer | `secret_officer_principal_ids` | Terraform/CI service principal |
| Key Vault Secrets User | `secret_reader_principal_ids` | Application UAMIs |
| Key Vault Administrator | Not granted by this module | Human operator (assign manually for break-glass) |

`Key Vault Administrator` is intentionally not granted by this module. Granting full admin via Terraform code creates a privilege escalation path through the Terraform pipeline; the operator should assign this role manually when needed for break-glass.

## How application code reads secrets

```python
# Python application code (sketch)
from azure.identity.aio import DefaultAzureCredential
from azure.keyvault.secrets.aio import SecretClient

credential = DefaultAzureCredential()  # uses Workload Identity
client     = SecretClient(vault_url=os.environ["KEY_VAULT_URI"], credential=credential)

redis_key = await client.get_secret("redis-primary-key")
# build the redis connection string with the key value
```

The `KEY_VAULT_URI` is injected as a pod environment variable from this module's `vault_uri` output. The pod authenticates as its UAMI, which has been granted `Key Vault Secrets User` via this module's role assignments.

## Notes

- **Purge protection is irreversible**. Once enabled on a vault, the only way to remove it is to delete the vault, wait out the soft-delete window, and recreate. This is intentional — it makes accidental data loss extremely difficult.
- The `network_acls` block plus `public_network_access_enabled = false` provides defence in depth — the network ACLs deny public traffic at the API level even if some future change accidentally re-enables public network access.
- Bootstrap secrets in the `secrets` input are intended for values produced by other Terraform-managed resources (Redis keys, etc.). For human-managed secrets (third-party API keys), set them via `az keyvault secret set` after the vault exists, and reference them by name from application code.
- The `depends_on` between bootstrap secrets and the Secrets Officer role assignment is required to avoid a parallel-execution race condition on first apply.