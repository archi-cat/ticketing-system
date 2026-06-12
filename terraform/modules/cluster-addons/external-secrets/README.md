# external-secrets module

Installs [External Secrets Operator (ESO)](https://external-secrets.io) into the AKS cluster via Helm, wires it to the Key Vault with Workload Identity, and creates a `ClusterSecretStore` that any namespace can reference.

This module is the foundation for Gateway TLS termination. ESO is the sync mechanism between Kubernetes Secrets and Azure Key Vault — used in both directions:

- **Key Vault → cluster** (`ExternalSecret`) — pulls a KV secret into a K8s Secret, e.g. the DuckDNS API token consumed by the cert-manager webhook.
- **Cluster → Key Vault** (`PushSecret`) — pushes a K8s Secret into KV, e.g. a TLS cert issued by cert-manager that AGC will read from KV.

## Authentication flow

```
┌─────────────────────┐                          ┌──────────────────┐
│ external-secrets    │  federated token         │ Azure AD         │
│ controller pod      │ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ▶│                  │
│ (SA: external-      │                          │ trusts the SA    │
│  secrets)           │ ◀─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ │ via federated    │
│                     │  KV access token         │ credential       │
└─────────────────────┘                          └──────────────────┘
                                                          │
                                                          ▼ Secrets Officer
                                                  ┌──────────────────┐
                                                  │  Key Vault       │
                                                  └──────────────────┘
```

The federated credential's subject claim binds it specifically to `system:serviceaccount:external-secrets:external-secrets` — no other workload in the cluster can mint Key Vault tokens with this identity.

## What gets installed

| Resource | Purpose |
|---|---|
| `kubernetes_namespace_v1.external-secrets` | Terraform-owned namespace |
| `azurerm_user_assigned_identity.this` | UAMI for the ESO controller |
| `azurerm_federated_identity_credential.this` | Trusts the AKS OIDC issuer for the ESO ServiceAccount |
| `azurerm_role_assignment.key_vault` | `Key Vault Secrets Officer` on the supplied Key Vault |
| `helm_release.external-secrets` | Controller + cert-controller + webhook + CRDs |

## Why Secrets Officer (not Secrets User)

`Secrets User` (read-only) would suffice for the `ExternalSecret` direction (Key Vault → cluster). But the cert flow in PR 2 uses `PushSecret` (cluster → Key Vault), which requires write. One role for both directions keeps the IAM surface simple.

## Where the ClusterSecretStore lives

The `ClusterSecretStore` that pairs this controller with the regional Key Vault is **not** in this module — it's a YAML manifest at [`k8s/cluster-addons/cert-pipeline/01-cluster-secret-store.yaml`](../../../../k8s/cluster-addons/cert-pipeline/01-cluster-secret-store.yaml), applied by the `infra-uksouth` workflow after Terraform completes.

The reason: the only practical Terraform path for applying CRD-typed manifests is the `alekc/kubectl` provider, which can't defer its configuration when `module.aks.host` is "(known after apply)" on a first-pass deploy. Splitting Helm-installed controllers (Terraform) from CRD-typed resources (YAML applied post-apply) keeps the Terraform graph clean.

## Usage

```hcl
module "external_secrets" {
  source = "../../modules/cluster-addons/external-secrets"

  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  name_prefix         = "uami-ticketing-uksouth"
  oidc_issuer_url     = module.aks.oidc_issuer_url

  key_vault_id = module.keyvault.vault_id

  tags = var.tags
}
```

The `helm`, `kubernetes`, and `kubectl` providers must be configured at the environment level — see `terraform/environments/uksouth-primary/main.tf`.

## Inputs

| Variable | Type | Required | Default | Description |
|---|---|---|---|---|
| `location` | string | Yes | — | Azure region |
| `resource_group_name` | string | Yes | — | Resource group for the UAMI |
| `name_prefix` | string | Yes | — | Prefix for the UAMI name |
| `oidc_issuer_url` | string | Yes | — | AKS cluster OIDC issuer URL |
| `key_vault_id` | string | Yes | — | Resource ID of the Key Vault to bind ESO to (target of the `Secrets Officer` role assignment) |
| `chart_version` | string | No | `0.10.5` | external-secrets Helm chart version |
| `tags` | map(string) | No | `{}` | Tags applied to the UAMI |

## Outputs

| Output | Description |
|---|---|
| `namespace` | The namespace ESO is installed in (`external-secrets`) |
| `uami_client_id` | ESO UAMI client ID |
| `uami_principal_id` | ESO UAMI principal (object) ID — for any additional role assignments outside this module |

## Verification

After apply, the ClusterSecretStore should report Ready:

```bash
kubectl get clustersecretstore keyvault -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
# Expected: True
```

If it reports `False`, the most common causes are:

- The ESO controller pod isn't running yet (`kubectl get pods -n external-secrets`)
- The federated credential's subject claim doesn't match the SA's namespace/name (case-sensitive)
- The UAMI doesn't have `Secrets Officer` on the vault (or the role assignment hasn't propagated — typically resolves within 60s)

## Notes

- **One ClusterSecretStore per Key Vault.** This module creates a single store named `keyvault`. If a second Key Vault is added later, the module would need to accept a list of stores or be instantiated multiple times.
- **Namespace scoping.** ESO also supports namespace-scoped `SecretStore` resources for finer-grained access control. This project uses `ClusterSecretStore` because the cert flow spans multiple namespaces (cert-manager namespace consumes; ticketing namespace will too once HTTPRoutes need cert refs).
- **Helm chart name.** The chart is `external-secrets` (no `-operator` suffix), from the `https://charts.external-secrets.io` repository — not the deprecated Bitnami chart.
