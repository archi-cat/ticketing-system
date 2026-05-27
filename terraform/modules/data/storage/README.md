# Storage module

Provisions a storage account for event-data files — the JSON files the
db-load-events bootstrap Job loads into the database.

## Network model

- A **private endpoint** (blob sub-resource) gives the cluster an in-VNet
  path. The db-load-events Job reads files this way.
- The **public endpoint** stays enabled with an IP allow-list, for the
  operator upload path, while no in-cluster upload Job exists.
- **Phase 3**: set `public_network_access_enabled = false` and empty
  `allowed_ip_ranges` once an in-cluster upload Job replaces laptop uploads.

Auth is Entra-only — `shared_access_key_enabled = false`. Consumers read
via the `Storage Blob Data Reader` role; operators upload with
`az storage blob upload --auth-mode login`.

## Usage

```hcl
module "storage" {
  source = "../../modules/data/storage"

  name                = "stticketinguksoutheventsXXXX"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name

  private_endpoint_subnet_id = module.network.subnet_ids.private_endpoints
  private_dns_zone_id        = module.network.private_dns_zone_ids.blob

  allowed_ip_ranges = [chomp(data.http.myip.response_body)]  # no /32

  blob_reader_principal_ids = {
    db-migrator = module.identity.identity_principal_ids["db-migrator"]
  }

  log_analytics_workspace_id = module.observability.log_analytics_workspace_id

  tags = var.tags
}
```

## Inputs / Outputs

See variables.tf and outputs.tf.
