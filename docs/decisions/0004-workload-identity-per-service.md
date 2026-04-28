# 4. One Workload Identity per service (not one per cluster)

Date: 2026-04-27
Status: Accepted

## Context

The application has three Kubernetes services that need to authenticate to Azure resources: API (PostgreSQL, Service Bus, Key Vault), worker (Service Bus, PostgreSQL), and scheduler (PostgreSQL, Redis). We need to decide how to model their Azure identities.

## Decision drivers

- Principle of least privilege — each service should only have access to what it needs
- Blast radius — a compromised service should not grant access to other services' resources
- Auditability — Azure AD logs should clearly attribute actions to the responsible service
- Operational simplicity — adding/removing services should not require restructuring identities

## Considered options

### Option A — One UAMI per service
Three UAMIs, each federated to its own Kubernetes service account. Each gets only the role assignments it needs.

### Option B — One UAMI for the entire application
A single UAMI federated to all three service accounts (or to a single shared service account). Granted the union of all required permissions.

### Option C — Use the AKS cluster's system-assigned identity
Pods authenticate via the cluster identity rather than dedicated UAMIs.

## Decision

Use **Option A — one UAMI per service**.

## Consequences

### Positive
- True least privilege — the worker has no access to Key Vault, the scheduler has no access to Service Bus
- A compromised pod can only access resources its service was granted, not the union
- Azure AD audit logs clearly attribute actions per service
- Adding a new service is a one-line change in the identity module's `service_accounts` input
- Removing a service cleanly removes its UAMI and its role assignments

### Negative
- Slightly more Terraform boilerplate than a shared identity (mitigated by `for_each`)
- Three UAMIs to manage instead of one (negligible — they have no per-resource cost)
- Each new role assignment must be made against the correct UAMI, which requires care