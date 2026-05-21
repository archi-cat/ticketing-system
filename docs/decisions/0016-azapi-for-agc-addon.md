# ADR-0016: Enable the AGC add-on via the azapi provider

Status: Accepted
Date: 2026-05-20

## Context

The AGC (Application Gateway for Containers) add-on and the managed
Gateway API installation are configured via the cluster's ingressProfile
property. The azurerm provider does not surface this property (it's in
the 2025-09-02-preview API version).

Previously this was a manual step: after terraform apply, an operator ran
an 'az rest PUT' to enable the add-on. This made the deployment a
two-phase process — apply, manual step, apply again — because the AGC
module needs to reference the add-on's auto-created UAMI, which doesn't
exist until the add-on is enabled.

## Decision

Use the azapi provider's azapi_update_resource to enable the ingressProfile
add-on as part of terraform apply. The AGC module's data lookup for the
add-on UAMI depends on this resource, so Terraform defers the lookup to
apply time — enabling a single-apply deployment.

A time_sleep resource inside the AKS module provides a propagation delay
(~3 min) so the add-on UAMI has materialised before downstream role
assignments reference it.

## Rationale

- **Single-apply deployment.** No manual az rest step, no two-phase dance.
- **Destroy/redeploy is clean.** terraform destroy then terraform apply
  fully rebuilds without operator intervention.
- **The add-on config is now in code.** Visible in plan, version
  controlled, reviewable.

## Trade-offs accepted

- **A second Azure provider.** azapi is now a dependency. It's a
  first-class HashiCorp-partnered provider, low risk.
- **time_sleep is a heuristic.** The 180s wait is conservative but not
  guaranteed. If Azure is slow, the data lookup could still race. The
  duration can be tuned; a failed apply is re-runnable.
- **Two providers touch the cluster.** azurerm manages the cluster;
  azapi patches one property. Because azurerm doesn't model ingressProfile,
  there's no plan-time tug-of-war — but it's a pattern to be aware of.

## Operational note — AKSOperationPreempted

AKS permits only one mutating operation on a cluster at a time. The
cluster can report provisioningState=Succeeded while post-provisioning
operations are still settling. The ingress_profile PATCH can land in
that window and be rejected with AKSOperationPreempted.

Mitigation: the azapi_update_resource has a retry block matching that
error, plus a brief time_sleep before the PATCH. The retry is what
guarantees eventual success; the sleep reduces how often the retry
path is exercised.

## Preview feature note

The preview features ApplicationLoadBalancerPreview and
ManagedGatewayAPIPreview must still be registered once per subscription
(Phase 0.1 of the runbook). The azapi resource enables the add-on on the
cluster but does not register subscription-level preview features.