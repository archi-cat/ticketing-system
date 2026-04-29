# 9. Service Bus — Premium with Private Endpoint, SAS auth disabled

Date: 2026-04-27
Status: Accepted

## Context

The application uses event-driven async processing — the API publishes events when reservations and bookings are created; workers consume them. The messaging system needs to be private, support Entra ID authentication, and support cross-region active-passive replication in Phase 4.

## Decision drivers

- Messaging must be private — no public namespace endpoint
- Authentication must avoid storing connection strings in app config
- Tier must support Private Endpoints and geo-DR pairing
- Topology (topics, subscriptions) must be data-driven, not hardcoded

## Considered options

### Tier — Standard vs Premium
Standard supports topics but not Private Endpoints or geo-DR. Premium supports both. Phase 4 requires geo-DR.

### Authentication — SAS keys vs Entra ID
SAS keys are stored in connection strings, which are credentials. Entra ID is consistent with the rest of the project's authentication story.

### Topology — hardcoded resources vs data-driven
Hardcoded resources are simpler for one environment but require duplication across environments. Data-driven topology lets the same module serve multiple environments with different topic configurations.

## Decision

- **Premium tier**, single messaging unit
- **SAS authentication disabled at the namespace level** (`local_auth_enabled = false`)
- **Private Endpoint** + namespace-level `public_network_access_enabled = false`
- **Topics and subscriptions data-driven** via the `topics` variable

## Consequences

### Positive
- No connection strings exist anywhere — apps authenticate via Workload Identity
- Service Bus cannot be accessed from outside the VNet
- Tier supports geo-DR pairing for Phase 4
- Topology is declarative and varies between environments without code changes

### Negative
- Premium is significantly more expensive than Standard (mitigated by tear-down-when-idle pattern)
- Disabling SAS auth means any code expecting connection strings fails immediately — this is intentional but worth flagging in onboarding
- The `subscriptions_flattened` flattening pattern in `locals` is non-obvious for Terraform newcomers — module README documents it