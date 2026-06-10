# Network policies — landing-zone security baseline

Namespace-scoped default-deny plus per-component allow rules for the `ticketing` namespace ([Phase 3 Tier 1 #2](../../../phase_3_plan.md)). Applied by `infra-uksouth.yml` as part of the regional platform bootstrap — by the time app pods deploy, the cluster's security baseline is already in place.

Other namespaces (`cert-manager`, `external-secrets`, `kube-system`, `cert-manager-webhook-duckdns`) are unaffected. They keep their default-allow behaviour. The threat model this guards against is "compromised app pod laterals into the data layer or platform services."

## What's here

Files are numbered to make the apply order explicit (also the alphabetical order `kubectl apply -f .` follows):

| File | Kind | What it does |
| --- | --- | --- |
| `00-default-deny.yaml` | `NetworkPolicy` (upstream) | Denies all ingress + egress for every pod in `ticketing`. Allow rules below layer on top. |
| `01-dns-egress.yaml` | `CiliumNetworkPolicy` | All pods → `kube-dns` (53/UDP+TCP). L4-only baseline; the L7 DNS hints live in 02/03. |
| `02-azure-ad-egress.yaml` | `CiliumNetworkPolicy` | All pods → AAD + az-CLI endpoints on 443, FQDN-scoped (`*.microsoftonline.com`, `*.windows.net`, `*.microsoft.com`, `*.msauth.net`, `*.msftauth.net`, `management.azure.com`). DNS hint + `toFQDNs` in the same policy — see pattern provenance in the file. |
| `03-app-insights-egress.yaml` | `CiliumNetworkPolicy` | api/worker/scheduler → `*.in.applicationinsights.azure.com:443`, FQDN-scoped with same-policy DNS hint. OpenTelemetry trace ingestion. |
| `10-api-ingress.yaml` | `CiliumNetworkPolicy` | AGC frontend → api:8000, kubelet probes → api:8000. |
| `11-api-egress.yaml` | `CiliumNetworkPolicy` | api → postgres (10.10.5.0/24:5432), redis+sb (10.10.4.0/24:10000+443). |
| `12-worker-egress.yaml` | `CiliumNetworkPolicy` | Same shape as api egress — postgres + redis + service bus. |
| `13-scheduler-egress.yaml` | `CiliumNetworkPolicy` | postgres + redis only. Scheduler doesn't touch Service Bus. |
| `20-bootstrap-postgres-egress.yaml` | `CiliumNetworkPolicy` | All db-bootstrap pods → postgres:5432. |
| `21-db-load-events-storage-egress.yaml` | `CiliumNetworkPolicy` | db-load-events → storage (10.10.4.0/24:443). |

(A `24-bootstrap-aad-egress-workaround.yaml` with `world:443` for bootstrap pods existed while ACNS FQDN tracking was broken — retired once `security.advancedNetworkPolicies = "FQDN"` made the `toFQDNs` rules in `02` actually work.)

## Why both upstream NetworkPolicy and CiliumNetworkPolicy

The default-deny uses upstream `networking.k8s.io/v1` `NetworkPolicy` because that's the universal, well-understood expression of "deny everything for these pods." The allow rules use `CiliumNetworkPolicy` because they need features upstream doesn't have:

- **`toFQDNs`** — the AAD and App Insights egresses point at FQDNs with rotating IPs. CIDR-based egress would either need to track Microsoft's published IP ranges (brittle, breaks on rotations) or allow egress to the whole internet on port 443 (which gives up most of the value).
- **DNS interception for `toFQDNs`** — the ACNS DNS proxy only inspects (and caches IPs from) lookups that match an explicit `rules.dns.matchPattern` hint, and that hint must live in the *same policy* as the `toFQDNs` rule it feeds (see `02` / `03`). The universal wildcard `matchPattern: "*"` is rejected by ACNS's `advanced-networking-validating-policy` — explicit patterns only. Lookups matching no pattern pass through `01-dns-egress.yaml`'s L4 allow uninspected and keep resolving normally. (An earlier theory that "ACNS transparently handles all DNS interception, so L4-only is enough" was wrong — without the explicit hints the FQDN cache stays empty and `toFQDNs` silently matches nothing.)
- **`fromEntities: [host]`** — clean expression of "allow kubelet probes from the local node."

Cilium enforces both policy types, so they coexist.

## CIDR-level vs FQDN-level for in-VNet egress

The Postgres / Redis / Service Bus / Storage rules use the **subnet CIDR**, not the individual private endpoint FQDN. Two practical consequences:

1. **Over-permissive within the subnet.** The api's `10.10.4.0/24:443` allow also reaches Key Vault and Storage (both private endpoints on port 443 in that subnet) even though the api doesn't use them. Accepted because AAD-required auth is what actually gates access — network reach alone doesn't grant it.
2. **Region-coupled YAML.** `10.10.4.0/24` and `10.10.5.0/24` are uksouth-specific. Phase 4 multi-region will refactor to either parameterise via envsubst, or use FQDN policies for in-VNet endpoints too.

The other option — `toFQDNs: ["psql-ticketing-uksouth-xxx.postgres.database.azure.com"]` — would be more precise but requires substituting Terraform outputs into the YAML, like the cert-pipeline already does. The CIDR approach was the preference for simplicity at this stage.

## Required cluster feature: ACNS

Cilium's FQDN egress filtering (`toFQDNs`) on AKS-managed Cilium requires **Advanced Container Networking Services (ACNS)** with **`security.advancedNetworkPolicies = "FQDN"`** (az CLI: `--acns-advanced-networkpolicies FQDN`). This deploys the DNS proxy that inspects DNS responses and populates the IPs behind `toFQDNs` matches.

`security.enabled = true` alone is NOT sufficient — it only turns on eBPF L3/L4 policy enforcement. Hard-won lesson: with only `security.enabled`, `toFQDNs` rules silently match nothing (the FQDN cache stays empty), and policies carrying an explicit `rules.dns` block are rejected by the Cilium agent with `L7 policy is not supported since L7 proxy is not enabled`. The `"L7"` value would additionally enable Envoy-based HTTP/gRPC/Kafka rules — not needed here.

ACNS observability (`observability.enabled = true`) enables Hubble flow metrics — invaluable for debugging policy drops.

All of this is enabled by the AKS Terraform module via `azapi_update_resource.acns` (same pattern as the AGC ingress profile, since the azurerm provider doesn't expose these properties yet).

## Verification

```bash
# All policies installed in the ticketing namespace
kubectl get networkpolicy,ciliumnetworkpolicy -n ticketing

# Policies show as Enforcing (Cilium-side)
kubectl get cep -n ticketing -o wide  # CiliumEndpoint, shows policy status per pod

# Smoke tests after apps deploy:
# - API reachable through the Gateway
curl -i https://<duckdns-fqdn>/health

# - api → postgres works (any DB-backed endpoint exercises this)
# - worker consumes from service bus (check worker logs for "received message")
# - scheduler leases the lock (check scheduler logs for "acquired lease")

# Watch for drops — cilium monitor works per-node without Hubble relay.
# NB: `exec ds/cilium` picks ONE agent pod; the FQDN cache and monitor
# output are per-node, so target the cilium pod on the node actually
# running the workload you're debugging:
kubectl get pod -n ticketing <pod> -o wide                  # find the node
kubectl get pods -n kube-system -l k8s-app=cilium -o wide   # agent on that node
kubectl -n kube-system exec <cilium-pod> -c cilium-agent -- cilium monitor --type drop
kubectl -n kube-system exec <cilium-pod> -c cilium-agent -- cilium fqdn cache list
```

If something is unexpectedly denied, Hubble will show the source pod, the destination IP/FQDN, the verdict (`DROPPED`), and the reason. Then it's either:

- An allow rule is missing → add to the appropriate `1X-` or `2X-` file
- A platform egress (DNS / AAD / App Insights) is incomplete → fix in `01–03`
- An FQDN policy not enforcing → check ACNS has `security.advancedNetworkPolicies = "FQDN"` (`az aks show --query "networkProfile.advancedNetworking"`) — `security.enabled` alone is not sufficient. Config lives in `azapi_update_resource.acns` in the AKS Terraform module

## Adding a NetworkPolicy for a new component

1. Pick a number prefix in the right range:
   - `0X-` for platform-wide (selects all pods or a broad class)
   - `1X-` for app services
   - `2X-` for bootstrap jobs / one-off operators
2. Use the `app.kubernetes.io/name` (apps) or `app.kubernetes.io/component` (bootstrap) label selector.
3. Include the policy filename and intent in the table above.
4. If the component talks to a new external FQDN, that's a `CiliumNetworkPolicy` with `toFQDNs`. If a new in-VNet subnet, `toCIDR`. Match the existing patterns.
5. Verify on the next deploy with Hubble — confirm there are no `DROPPED` verdicts for the new component's traffic, and that traffic to denied destinations is in fact dropped.
