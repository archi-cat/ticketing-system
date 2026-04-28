# 5. AKS cluster design — separate node pools, Cilium, Azure CNI Overlay

Date: 2026-04-27
Status: Accepted

## Context

The application requires a Kubernetes cluster to host the API, worker, and scheduler services. Several cluster-level design decisions need to be made up front because they are difficult or impossible to change after creation.

## Decision drivers

- Cluster-critical pods must not be impacted by application pod resource pressure
- The cluster must support Workload Identity (the project's chosen auth strategy)
- Pod address space must not be tied to VNet subnet sizing
- NetworkPolicy must be enforceable for future security hardening
- The cluster must fit within default pay-as-you-go subscription quotas

## Considered options

### Node pool topology
- **Single combined pool** — simpler, but application workloads can starve system pods
- **Separate system + user pools** — isolation at the cost of one extra pool

### CNI plugin
- **Kubenet** — deprecated, no NetworkPolicy support
- **Azure CNI** — pod IPs from VNet (subnet exhaustion risk at scale)
- **Azure CNI Overlay** — pod IPs from overlay, node IPs from VNet, no exhaustion

### NetworkPolicy engine
- **None** — NetworkPolicy resources silently ignored
- **Calico (Microsoft-managed)** — supported but in maintenance mode
- **Cilium** — Microsoft's recommended default, eBPF-based, actively developed

## Decision

- **Two node pools** — `system` (tainted with `CriticalAddonsOnly`) and `user` (untainted)
- **Azure CNI Overlay** — node IPs from VNet, pod IPs from `10.244.0.0/16`
- **Cilium** as both network plugin dataplane and NetworkPolicy engine
- **`Standard_B2s`** VM size — fits default 10 vCPU per region quota with 2+2 node layout

## Consequences

### Positive
- Application failures cannot impact CoreDNS, kube-proxy, or the Workload Identity webhook
- Pod overlay address space avoids the most common AKS scaling pitfall
- NetworkPolicy is genuinely enforceable from Phase 2 onwards
- Future migration to managed pods (Karpenter, etc.) is straightforward
- Stays within default subscription quotas — no Microsoft support tickets needed

### Negative
- Two node pools cost slightly more than one combined pool (4 vCPUs minimum vs 3)
- Cilium is newer than Calico — fewer community resources for niche debugging
- Overlay CNI has slightly higher latency than direct VNet IPs (negligible at this scale)