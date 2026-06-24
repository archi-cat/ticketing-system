# Storage module

Provisions a storage account for event-data files — the JSON files the
db-load-events bootstrap Job loads into the database.

## Network model

- **Private-endpoint only.** `public_network_access_enabled = false` — there
  is no public path. A **private endpoint** (blob sub-resource) gives the
  cluster the only in-VNet path: db-load-events reads and the event-upload
  Job (ADR-0032) writes over it.
- `network_rules` stays `default_action = "Deny"` as defence in depth, so an
  accidental re-enable of public access still fails closed.

Auth is Entra-only — `shared_access_key_enabled = false`. Consumers read/write
via container-scoped role assignments (`blob_reader_principal_ids` /
`blob_writer_principal_ids`).

> **Terraform / deployer note.** With public access off, the out-of-VNet
> deployer cannot run the provider's data-plane availability poll, so the
> environment sets the provider feature `storage { data_plane_available =
> false }`. Consequently this module declares **no** `queue_properties` /
> `static_website` blocks (both data-plane), and the container is managed via
> the Resource Manager API (`storage_account_id`, control-plane). This is the
> azurerm-native alternative to running Terraform inside the VNet or moving the
> account to `azapi` — see ADR-0034.

## Usage

```hcl
module "storage" {
  source = "../../modules/data/storage"

  name                = "stticketinguksoutheventsXXXX"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name

  private_endpoint_subnet_id = module.network.subnet_ids.private_endpoints
  private_dns_zone_id        = module.network.private_dns_zone_ids.blob

  blob_reader_principal_ids = {
    db-migrator = module.identity.identity_principal_ids["db-migrator"]
  }

  blob_writer_principal_ids = {
    event-uploader = module.identity.identity_principal_ids["event-uploader"]
  }

  log_analytics_workspace_id = module.observability.log_analytics_workspace_id

  tags = var.tags
}
```

> Requires the environment's `azurerm` provider to set
> `features { storage { data_plane_available = false } }` (the account is
> public-access-off; see the Terraform note above).

## Inputs / Outputs

See variables.tf and outputs.tf.
