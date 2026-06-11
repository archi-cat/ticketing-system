# ADR-0021: Default-deny network policies with FQDN-scoped egress

Status: Accepted
Date: 2026-06-11

## Context

Phase 3 Tier 1 #2: before the platform hardens anything else, the `ticketing` namespace needed a network security baseline. The threat model is "compromised app pod laterals into the data layer or platform services" — without policies, any pod in the namespace can reach Postgres, Redis, Service Bus, Key Vault, Storage, and the public internet.

The goals:

1. Default-deny every pod in `ticketing` for both ingress and egress
2. Layer narrow, per-component allow rules on top
3. Scope external egress (Azure AD, Application Insights) by FQDN, not by IP — Microsoft rotates IPs behind those hostnames
4. Keep other namespaces (`cert-manager`, `external-secrets`, `kube-system`) untouched

This turned into the longest-running debugging effort of Phase 3. The policies themselves were written in a day; making FQDN egress actually work on AKS took three weeks of iteration across two full teardown/redeploy cycles, because the critical cluster prerequisite is poorly documented and fails silently without it.

## Decision

Namespace-scoped default-deny using an upstream `NetworkPolicy`, plus per-component `CiliumNetworkPolicy` allow rules, living in `k8s/cluster-addons/network-policies/` and applied by `infra-uksouth.yml` during platform bootstrap — before any app pods deploy.

### Upstream NetworkPolicy for the deny, CiliumNetworkPolicy for the allows

The default-deny is `networking.k8s.io/v1` — the universal, portable, audit-tool-recognised expression of "deny everything." The allow rules are `CiliumNetworkPolicy` because they need features upstream doesn't have: `toFQDNs`, DNS `rules.dns` hints, `fromEntities: [host]` for kubelet probes.

Cilium compiles both CRD types into one policy engine and takes the union, so they coexist cleanly. A "never mix the two API groups" rule circulates in some community content, claiming an upstream deny breaks Cilium L7 allows via proxy-redirect conflicts — we evaluated it and found the described mechanism doesn't match Cilium's verdict model, and our E2E tests confirmed the mixed setup works. A switch to a CNP-based deny (`enableDefaultDeny`) remains cheap if evidence ever appears.

### FQDN-scoped egress requires ACNS `advancedNetworkPolicies = "FQDN"` — `security.enabled` is NOT enough

The single most expensive lesson of this work. AKS's Advanced Container Networking Services has two separate gates:

- `security.enabled = true` — turns on eBPF L3/L4 policy *enforcement*. CIDR and entity rules work.
- `security.advancedNetworkPolicies = "FQDN"` (az CLI `--acns-advanced-networkpolicies FQDN`) — deploys the **DNS proxy** that inspects lookups and populates the FQDN cache that `toFQDNs` rules match against.

With only the first, `toFQDNs` rules validate, apply, and silently match **nothing** — the FQDN cache stays empty and all matching traffic is dropped by the default-deny. There is no error anywhere unless the policy also carries an explicit `rules.dns` block, in which case the agent reports `L7 policy is not supported since L7 proxy is not enabled` — the breadcrumb that finally cracked the case.

The setting is applied via `azapi_update_resource.acns` in the AKS module (the azurerm provider doesn't expose it). `"FQDN"` rather than `"L7"`: L7 additionally deploys Envoy for HTTP/gRPC/Kafka rules, which nothing here needs.

### The DNS-hint pattern: `rules.dns` + `toFQDNs` in the same policy

The ACNS DNS proxy only inspects lookups matching an explicit `rules.dns.matchPattern` hint, and the hint must live in the **same policy** as the `toFQDNs` rule it feeds:

```yaml
egress:
  # 1. DNS to kube-dns with the L7 pattern hint -> proxy caches resolved IPs
  - toEndpoints:
      - matchLabels:
          io.kubernetes.pod.namespace: kube-system
          k8s-app: kube-dns
    toPorts:
      - ports: [{port: "53", protocol: ANY}]
        rules:
          dns:
            - matchPattern: "*.microsoftonline.com"
  # 2. HTTPS to the IPs cached above
  - toFQDNs:
      - matchPattern: "*.microsoftonline.com"
    toPorts:
      - ports: [{port: "443", protocol: TCP}]
```

Two constraints discovered empirically:

1. The universal wildcard `matchPattern: "*"` is rejected by ACNS's `advanced-networking-validating-policy` admission policy — explicit patterns only.
2. Lookups matching no pattern pass through the L4-only baseline DNS allow (`01-dns-egress.yaml`) uninspected and keep resolving normally — the hints are an inspection allowlist, not a DNS firewall.

### CIDR-level egress for in-VNet destinations

Postgres / Redis / Service Bus / Storage rules use the private-endpoints subnet CIDR (`10.10.4.0/24`, `10.10.5.0/24`) rather than per-endpoint FQDNs. Over-permissive within the subnet (the api's 443 allow also reaches Key Vault's PE), accepted because Entra ID auth is what actually gates access. The region-coupled CIDRs are a known Phase 4 refactor item.

### The AAD pattern list is az-CLI-driven, not just token-endpoint-driven

`02-azure-ad-egress.yaml` allows six FQDN patterns. Two of them were found only by watching `cilium monitor --type drop` on the node running the db-grant bootstrap Job:

- `management.azure.com` (was the mysterious dropped IP `4.150.240.10`) — `az login` touches ARM even when the workload only needs a Postgres token
- `azcliprod.blob.core.windows.net` (was `57.150.61.65`, covered by `*.windows.net`) — the az CLI's startup version check

Neither IP appears in the `AzureActiveDirectory` service tag, which is why the earlier CIDR-fallback approach (pinning the service tag's published ranges) could never work. The pattern provenance is documented in the policy file itself.

## Rationale

- **Default-deny is the baseline that makes every other Phase 3 control meaningful.** Workload Identity limits what a stolen token can do; network policy limits where a compromised pod can even connect.
- **FQDN scoping is the only honest way to allow Microsoft endpoints.** The alternatives both failed empirically: service-tag CIDR pinning missed real traffic (see above), and `world:443` gives up most of the value.
- **Applying policies during platform bootstrap, before app pods,** means a pod is never scheduled into a permissive-then-tightened window.
- **Policy files are numbered** (`00-` deny, `0X-` platform, `1X-` apps, `2X-` bootstrap jobs) so `kubectl apply -f .` order is explicit and the README table maps one-to-one to files.

## Trade-offs accepted

- **Subnet-CIDR over-permission within the PE subnet.** Accepted; auth gates access. Revisit if a non-Entra service ever lands in that subnet.
- **`*.windows.net` and `*.microsoft.com` are broad patterns.** They cover vastly more than the az CLI's needs. Accepted because the FQDN proxy only allowlists what pods actually resolve, the alternative is enumerating unstable Microsoft hostnames, and bootstrap Jobs are short-lived. Tightening to exact hostnames is possible once the az CLI's behaviour is observed over more releases.
- **Region-coupled YAML.** `10.10.x.0/24` is uksouth-specific. Phase 4 multi-region will parameterise (envsubst, mirroring the cert-pipeline) or move in-VNet rules to FQDN.
- **The FQDN cache and `cilium monitor` are per-node.** Debugging requires targeting the Cilium agent on the node actually running the workload — `kubectl exec ds/cilium` picks an arbitrary pod and cost us a half-day of false "it's broken again." Documented in the README's verification section.
- **A three-week `world:443` workaround era happened** (bootstrap pods, then briefly App Insights egress) while the root cause was unknown. The workaround files are deleted; this ADR and the README record why they existed.

## Operator path

- **Fresh deploy:** nothing manual — `infra-uksouth.yml` applies the policies after Terraform; ACNS settings ride the azapi resource in the AKS module.
- **Something can't connect:** find the node running the pod → exec the Cilium agent on that node → `cilium monitor --type drop` for the destination, `cilium fqdn cache list` for what was resolved. Add the missing pattern to the relevant policy (both the `rules.dns` hint AND the `toFQDNs` list).
- **New component:** follow the README's "Adding a NetworkPolicy for a new component" checklist. A new pod is fully isolated until its allow policy exists — "new pod hangs mysteriously" debugging starts with "did we write its egress policy."

## Future work

- Tighten `*.windows.net` / `*.microsoft.com` to exact hostnames once az CLI behaviour is stable across versions.
- Phase 4: parameterise region-coupled CIDRs; evaluate Hubble relay/UI enablement for flow debugging (the `cilium monitor` per-node workflow is functional but clunky).
- Consider `ingressDeny`/`egressDeny` CNP rules if an explicit-deny-overrides-allow need ever appears (upstream NetworkPolicy cannot express it).

## References

- `k8s/cluster-addons/network-policies/` — policies + README with verification commands
- `terraform/modules/aks/main.tf` — `azapi_update_resource.acns` with the FQDN gate
- [Set up FQDN filtering for Container Network Security](https://learn.microsoft.com/en-us/azure/aks/how-to-apply-fqdn-filtering-policies)
- [Set up L7 policies with ACNS](https://learn.microsoft.com/en-us/azure/aks/how-to-apply-l7-policies) — documents `--acns-advanced-networkpolicies`
- ADR-0005 (AKS cluster design — Cilium dataplane), ADR-0018 (database bootstrap Jobs — the db-grant Job whose az CLI drove the pattern discovery)
