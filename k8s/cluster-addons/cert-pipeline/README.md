# Cert pipeline manifests

CRD-typed Kubernetes resources for the Gateway TLS cert flow ([Phase 3 Tier 1 #1](../../../phase_3_plan.md)). Applied by the `infra-uksouth` workflow after Terraform completes — `envsubst` substitutes the three placeholders below, then `kubectl apply -f` brings them up.

These live in YAML (rather than as Terraform `kubectl_manifest` resources) because the `alekc/kubectl` Terraform provider can't gracefully handle the case where `module.aks.host` is "(known after apply)" on a first-pass deploy. Splitting Helm-installed controllers (Terraform) from CRD-typed resources (YAML) sidesteps the issue and matches how the rest of this repo's Kubernetes config is structured.

## What's here

Files are numbered to make the apply order explicit (it's also the alphabetical order `kubectl apply -f .` follows):

| File | Resource | What it does |
|---|---|---|
| `00-webhook-secret-rbac.yaml` | `Role` + `RoleBinding/duckdns-webhook-token-reader` | Grants the DuckDNS webhook's ServiceAccount permission to read the synced `duckdns-api-token` Secret. The chart only auto-creates RBAC for its inline-token path |
| `01-cluster-secret-store.yaml` | `ClusterSecretStore/keyvault` | Cluster-wide handle for ESO to read/write the regional Key Vault via Workload Identity |
| `02-external-secret-duckdns-token.yaml` | `ExternalSecret/duckdns-api-token` | Syncs the DuckDNS API token from KV into the cert-manager namespace |
| `03-cluster-issuer-letsencrypt-staging.yaml` | `ClusterIssuer/letsencrypt-staging` | Let's Encrypt staging issuer using DNS-01 via the DuckDNS webhook |
| `04-cluster-issuer-letsencrypt-production.yaml` | `ClusterIssuer/letsencrypt-production` | Same, against the production ACME endpoint |
| `05-certificate-ticketing-tls.yaml` | `Certificate/ticketing-tls` | The actual TLS cert. Points at the staging issuer for now — PR 3 switches it to production |
| `06-push-secret-ticketing-tls.yaml` | `PushSecret/ticketing-tls-push` | Mirrors the issued cert into KV — archive / Phase 4 Front Door consumption (AGC reads the K8s Secret directly, not from KV) |
| `07-reference-grant-gateway-tls.yaml` | `ReferenceGrant/gateway-to-cert-manager-tls` | Authorises the Gateway in the `ticketing` namespace to reference the `ticketing-tls` Secret here in `cert-manager`. Gateway API requires explicit cross-namespace consent for certificateRefs |

## Placeholders

`envsubst` replaces these at apply time:

| Variable | Source | Example |
|---|---|---|
| `${KEYVAULT_URI}` | `terraform output -raw keyvault_uri` | `https://kv-ticketing-uks-xxx.vault.azure.net/` |
| `${ACME_EMAIL}` | `secrets.ACME_EMAIL` (repo secret) | `ops@example.com` |
| `${DUCKDNS_FQDN}` | `secrets.DUCKDNS_FQDN` (repo secret) | `ticketing-floryda.duckdns.org` |

## Apply order matters in spirit but not strictly

`kubectl apply -f <dir>` doesn't enforce ordering between manifests. The numbering reflects logical dependency:

- `01` (ClusterSecretStore) must Ready before `02` and `06` can sync. ESO's reconcile loop handles this — both ExternalSecret and PushSecret stay Pending until the store is Ready, then succeed on the next reconcile.
- `03`/`04` (ClusterIssuers) register ACME accounts and must Ready before `05` (Certificate) can request issuance. cert-manager's reconcile loop handles this — Certificate stays Pending until the issuer is Ready.

Net effect: a single `kubectl apply -f <dir>` followed by a couple of reconcile cycles brings the whole pipeline up. No targeted ordering needed.

## Verification

After apply, watch the chain converge:

```bash
kubectl get clustersecretstore keyvault
kubectl get externalsecret -n cert-manager duckdns-api-token
kubectl get clusterissuer
kubectl get certificate -n cert-manager ticketing-tls
kubectl get pushsecret -n cert-manager ticketing-tls-push
```

All should report `READY=True` (or `SecretSynced=True` / `Synced=True`) once the pipeline has run to completion. Typical end-to-end time on a fresh cluster: 5–10 min, dominated by the ACME challenge round-trips.
