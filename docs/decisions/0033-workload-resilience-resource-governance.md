# ADR-0033: Workload resilience and resource governance

Status: Accepted
Date: 2026-06-16

## Context

Phase 3 Tier 2 #10, #11, #12 — taken together because they're one cohesive concern (how the `ticketing` namespace behaves under disruption and load) and three small manifest changes. Before this work:

- **No PodDisruptionBudgets.** An AKS node auto-upgrade or node patch drains nodes; with nothing guarding the workloads, a drain could evict *all* replicas of a service at once and take it fully down.
- **No resource governance.** A single misconfigured pod could request a node's worth of CPU/memory; nothing bounds the namespace.
- **No autoscaling.** The api ran at a fixed 2 replicas and couldn't absorb load.

## Decision

### PodDisruptionBudgets (#10)

One PDB per service, guarding **voluntary** disruptions (node drains, evictions) — distinct from rollouts, which the Deployments already handle with `maxUnavailable: 0` / `maxSurge: 1`.

- **api**, **worker** → `minAvailable: 1`. With 2+ replicas a drain evicts one at a time and the other keeps serving.
- **scheduler** → `maxUnavailable: 1` (not `minAvailable`). It runs 2 replicas with leader election, so brief unavailability is fine, and `maxUnavailable` avoids deadlocking a drain if it's ever scaled to one replica (where `minAvailable: 1` would block all eviction).

### LimitRange + ResourceQuota (#11)

A namespace `LimitRange` and `ResourceQuota`, applied via `base/shared/` (so every service deploy re-applies them, idempotently).

The two are a **pair, and the order of reasoning matters**: once a `ResourceQuota` constrains `requests.*`/`limits.*`, Kubernetes requires *every* pod in the namespace to declare those values or admission rejects it. The bootstrap Jobs (db-grant/migrate/load-events/event-upload) don't set resources — so the `LimitRange` `default`/`defaultRequest` is what keeps them admittable. The app Deployments set their own resources and are unaffected; the `LimitRange` `max`/`min` just bound them.

The `ResourceQuota` is a **guardrail against a runaway pod, not tight bin-packing** (actual placement is bounded by node capacity). It's sized to fit steady state + the api HPA at max + a bootstrap Job: `requests.cpu: 2`, `requests.memory: 4Gi`, `limits.cpu: 6`, `limits.memory: 8Gi`, `pods: 20`.

### HPA on the api (#12)

An `autoscaling/v2` HPA: **min 2 / max 5, CPU target 70%**, CPU-only. `replicas` is **removed** from the api Deployment so the HPA owns the count — otherwise every `kubectl apply` resets it and fights the autoscaler.

- **scheduler** is explicitly **not** autoscaled — leader election means only one replica works regardless of count.
- **worker** stays at a fixed 2 replicas. CPU-based HPA is the wrong signal for a queue consumer (it's I/O-bound waiting on Service Bus, not CPU-bound); the right tool is **KEDA** scaling on queue depth, which is a larger addition deferred to its own item.

## Rationale

- **PDBs are the direct fix** for "node patching can take the service down," and the api/worker-vs-scheduler split reflects their availability models (continuous serving vs leader-elected).
- **The quota pair encodes a real Kubernetes gotcha:** a ResourceQuota without a LimitRange breaks any pod that omits resources — here, the bootstrap Jobs. Shipping them together is deliberate.
- **HPA is CPU-only on purpose.** A stateless API's memory is flat; a memory target tends to flap. CPU utilisation against the declared request is the honest signal.
- **Worker = fixed, not CPU-HPA.** Autoscaling a queue consumer on CPU would scale on the wrong dimension; better no autoscaling than misleading autoscaling. KEDA is the correct future tool.

## Trade-offs accepted

- **The ResourceQuota is generous, not tight.** On a small Burstable cluster the node is the real binding constraint; the quota mainly catches a grossly misconfigured pod. Tunable as the load profile firms up.
- **`minAvailable: 1` allows only one voluntary disruption at a time.** A multi-node drain serializes — slower, but that's the point.
- **Removing `replicas` from the api Deployment** means the very first apply (before the HPA exists) briefly defaults to 1 replica until the HPA sets min 2. Negligible on a fresh deploy.
- **HPA can't see memory pressure or queue depth.** Accepted; the api is CPU-bound and the worker's real signal (queue depth) is KEDA's job.
- **The worker isn't autoscaled at all** this iteration. Fine at current load; revisit with KEDA if it ever backs up.

## Operator path — rollout and node-drain expectations

- **Rolling deploy:** unchanged — `maxUnavailable: 0` / `maxSurge: 1` adds a pod before removing one, so a deploy never dips below current capacity. The HPA and the Deployment don't conflict (HPA scales; the rollout replaces).
- **Node drain / AKS auto-upgrade:** the PDBs serialise evictions — api/worker keep ≥1 pod up, the scheduler loses at most 1 (the standby takes leadership). A drain that would violate a PDB blocks until a replacement pod is Ready elsewhere.
- **Under load:** the api scales 2→5 on 70% CPU; it scales back down after the default 5-minute stabilisation window.
- **Admission:** any pod (including future Jobs) that omits resources gets the LimitRange defaults; one that exceeds the per-container `max` or would breach the namespace quota is rejected at admission with a clear message.

## Future work

- **KEDA for the worker** — scale on Service Bus queue depth (the queue-consumer-correct autoscaler).
- **Custom/memory metrics for the api HPA** if CPU proves an insufficient signal under real traffic.
- **Tighten the ResourceQuota** to reflect measured usage + node capacity once the cluster runs continuously.
- **Chaos validation (Tier 4 #17):** pod-kill and node-drain drills confirm the PDBs hold as described here.

## References

- `k8s/base/api/{pdb,hpa}.yaml`, `k8s/base/worker/pdb.yaml`, `k8s/base/scheduler/pdb.yaml`
- `k8s/base/shared/{limitrange,resourcequota}.yaml`
- `k8s/base/api/deployment.yaml` — `replicas` removed (HPA-owned)
- ADR-0011 — Kustomize base + overlay structure these slot into
- ADR-0028 — Redis distributed locking / leader election (the scheduler model the PDB reflects)
