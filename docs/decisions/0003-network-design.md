# 3. Regional VNet design

Date: 2026-04-27
Status: Accepted

## Context

Each region needs a VNet hosting AKS, an AGC ingress controller, PostgreSQL with VNet injection, and Private Endpoints for several PaaS services. The subnet layout, address spacing across regions, and DNS zone placement all need explicit decisions.

## Decision drivers

- Future cross-region VNet peering must be possible without renumbering
- Subnet delegations are required for AGC and PostgreSQL Flexible Server
- Private DNS resolution for PaaS services must work cluster-wide
- The same Terraform module must work for both regions

## Considered options

### One subnet for everything
Simpler, but breaks because AGC and PostgreSQL each require their own delegated subnets.

### Subnet per service / role
More structure, supports delegations, allows per-subnet NSGs.

### Hub-and-spoke with centralised DNS
The "right" enterprise pattern, but significant overkill for this project's scale.

## Decision

Use a **subnet-per-role** layout in each region with five subnets: `aks-system`, `aks-user`, `agc` (delegated), `private-endpoints`, and `postgres` (delegated). Use non-overlapping address spaces between regions:

- uksouth: `10.10.0.0/16`
- westeurope: `10.20.0.0/16`

Place Private DNS zones inside the regional resource group rather than a centralised hub. This is simpler at this scale; if a hub is added later, DNS zones can be migrated.

## Consequences

### Positive
- Future VNet peering across regions is trivial (no overlapping ranges)
- Each service gets its own NSG attachment point
- Subnet delegations satisfy AGC and PostgreSQL requirements
- The module is fully reusable across regions

### Negative
- Five subnets is more setup than strictly needed for Phase 1
- Private DNS zones in each region means future centralisation requires migration
- VMs in the VNet cannot auto-register in the `privatelink` DNS zones (intentional, but worth noting)