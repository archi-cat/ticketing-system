# ADR-0015: Co-locate AKS node resource group with regional RG

Status: Accepted
Date: 2026-05-19

## Context

AKS by default creates a separate node resource group (`mc_*` or similar)
holding VMSS, kubelet identity, add-on identities (including the ALB
Controller UAMI), auto-created NSGs and disks. This separation is the
industry default — it cleanly separates application-owned resources
from platform-managed ones.

For this project, the separation creates friction:

- The AGC add-on creates its UAMI in the node RG and grants permissions
  scoped to that RG. Our Terraform-created AGC lives in the regional RG.
  Without alignment, the auto-granted permissions don't cover our AGC.
- Our destroy/redeploy cycles span the node RG (managed by AKS) and the
  regional RG (managed by Terraform). Cleanup timing is non-deterministic.

## Decision

Set `node_resource_group` on the AKS cluster to the regional RG name.
All AKS-managed resources are co-located with the rest of the regional
deployment.

## Consequence

The AGC add-on's auto-granted role assignments cover our Terraform-created
AGC because they share the same RG scope. This eliminates the need for
the AGC module to create its own role assignments — the add-on handles
identity authorization end-to-end.

The agc module's responsibility narrows to just provisioning the AGC
resource, frontend, and subnet association. See ADR-0014 (revised) for
the AGC module's updated scope.

The identity module no longer needs an `alb` entry — the AGC add-on's
UAMI is fully outside Terraform's view, which is appropriate because
it's lifecycle-coupled to the add-on, not to our workloads.

## Trade-offs accepted

- **Mingled ownership.** The main RG contains both Terraform-owned and
  AKS-owned resources. AKS may create/modify resources outside Terraform's
  view. We don't run wildcard queries on the RG so drift doesn't surface.
- **Less defence-in-depth.** A misconfigured RG destroy takes down both
  application and platform resources. For production, separation would
  be preferred.
- **Cluster recreation required to reverse.** `node_resource_group` is
  immutable post-creation. If we ever want the default separation,
  we'd need a fresh AKS deployment.
