# ADR-0014: AGC deployment pattern — BYO over Managed

Status: Accepted
Date: 2026-05-17

## Context

Azure Application Gateway for Containers (AGC) can be provisioned two ways:

**Managed mode**: The ALB Controller in-cluster watches for
`ApplicationLoadBalancer` Kubernetes resources and creates/destroys AGC
instances on demand. Cluster authority over the cloud resource.

**BYO mode**: The AGC instance is provisioned explicitly in Terraform.
The cluster's Gateway resource has annotations pointing at the AGC
resource ID. Terraform owns the lifecycle.

Both modes are first-class supported by Microsoft. The choice affects
lifecycle ownership, audit story, disaster recovery, and how AGC fits
with the rest of the infrastructure as code.

## Update — 2026-05-19

The original decision (BYO with Terraform-managed role assignments) was
correct in spirit but interacted poorly with the AKS managed AGC add-on.
The add-on auto-provisions the ALB Controller's UAMI and grants it role
assignments on the AKS node resource group — not on our Terraform-created
AGC resource.

The resolution (see ADR-0015) is to co-locate the node RG with the
regional RG. With co-location:

- The add-on grants permissions on the regional RG (where it expects AGC
  to be in managed mode)
- Our Terraform-created AGC lives in the regional RG
- The add-on's permissions cover our AGC automatically

Consequence: The AGC module no longer creates role assignments. Its
responsibility is purely "provision AGC resources" — the identity layer
is owned entirely by the AKS add-on.

The identity module's `alb` entry was removed; the AGC add-on's UAMI is
fully outside Terraform.

## Decision

We use **BYO mode**. The AGC resource is provisioned by the `agc`
Terraform module and managed alongside the rest of the regional
infrastructure.

## Rationale

The ticketing-system architecture has Terraform owning every cloud
resource — PostgreSQL, Redis, Service Bus, Key Vault, AKS itself. AGC
fits the pattern naturally as just another cloud resource. Managed mode
would create an asymmetry where one specific cloud resource has its
lifecycle controlled by the cluster.

The specific advantages of BYO that matter for this project:

- **Drift detection via terraform plan**. Any out-of-band change to AGC
  shows up at the next plan.
- **AGC survives cluster destruction**. If we tear down AKS (for upgrade,
  for cost reasons, in incident response), the AGC and its public IP
  remain. External integrations and DNS pointers don't churn.
- **Multi-region consistency**. The same module is called from each
  regional composition with different parameters. No per-region
  divergence in deployment style.
- **Unified audit trail**. Every infrastructure change is a git commit
  to Terraform code.

## Trade-offs accepted

- More Terraform code (~80 lines in the new agc module vs ~20 lines
  for an `ApplicationLoadBalancer` K8s manifest).
- The Gateway resource carries region-specific annotations
  (`alb.networking.azure.io/alb-id`, `alb.networking.azure.io/alb-frontend`)
  in each overlay, rather than being identical across regions.

## Implementation

- New module: `terraform/modules/agc/`
- New network resource: `azurerm_subnet.agc` in the network module with
  the `Microsoft.ServiceNetworking/trafficControllers` delegation
- Regional composition wires AGC subnet and AKS OIDC issuer URL into
  the agc module
- Per-region Kustomize overlays inject the AGC ID and frontend ID as
  Gateway annotations
- Deploy workflow reads AGC outputs from the regional state and
  substitutes them into the rendered manifests