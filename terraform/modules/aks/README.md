# AKS Module

Creates an AKS cluster with two node pools (system and user), Workload Identity enabled, Container Insights wired to a Log Analytics workspace, and Cilium-based NetworkPolicy enforcement.

## Usage

```hcl
module "aks" {
  source = "../../modules/aks"

  location            = "uksouth"
  resource_group_name = "rg-ticketing-uksouth"
  cluster_name        = "aks-ticketing-uksouth"
  kubernetes_version  = "1.30"

  system_subnet_id = module.network.subnet_ids.aks_system
  user_subnet_id   = module.network.subnet_ids.aks_user

  system_node_count = 2
  user_node_count   = 2
  vm_size           = "Standard_B2s"

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
| AKS cluster | 1 | Workload Identity + OIDC + Cilium NetworkPolicy + Container Insights |
| User node pool | 1 | Untainted application workload pool, separate from system |

## Inputs

| Variable | Type | Required | Default | Description |
|---|---|---|---|---|
| `location` | string | Yes | — | Azure region |
| `resource_group_name` | string | Yes | — | RG for the cluster |
| `cluster_name` | string | Yes | — | Cluster name |
| `kubernetes_version` | string | No | `1.30` | Major.minor version |
| `system_subnet_id` | string | Yes | — | Subnet for the system node pool |
| `user_subnet_id` | string | Yes | — | Subnet for the user node pool |
| `system_node_count` | number | No | `2` | Minimum 2 (validation enforced) |
| `user_node_count` | number | No | `2` | Application pool size |
| `vm_size` | string | No | `Standard_B2s` | B-series fits default vCPU quota |
| `log_analytics_workspace_id` | string | Yes | — | Workspace for Container Insights |
| `tags` | map(string) | No | `{}` | Tags on all resources |

## Outputs

| Output | Type | Description |
|---|---|---|
| `cluster_id` | string | AKS cluster resource ID |
| `cluster_name` | string | Cluster name |
| `oidc_issuer_url` | string | Required by the identity module for Workload Identity federation |
| `kubelet_identity_object_id` | string | Used to grant AcrPull on the container registry |
| `cluster_identity_principal_id` | string | Cluster control plane identity (rarely needed) |
| `node_resource_group` | string | Auto-generated RG for node VMs |
| `kube_config_raw` | string (sensitive) | Prefer `az aks get-credentials` instead |

## Notes

- The module does **not** install the ALB Controller. That happens via Helm in the GitHub Actions workflow after the cluster is created.
- The module does **not** create role assignments. The kubelet identity needs `AcrPull` on the container registry — that role assignment is the responsibility of the environment composition or the ACR module.
- `node_count` is excluded from drift detection because the cluster autoscaler (added in Phase 2) will change it dynamically.
- The Kubernetes version is pinned to major.minor (e.g. `1.30`) — Azure handles patch versions via the `automatic_upgrade_channel = "patch"` setting.