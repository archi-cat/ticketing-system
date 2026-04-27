# 1. Record architecture decisions

Date: 2026-04-27
Status: Accepted

## Context

We need a way to record the architectural decisions made on this project. Without a record, future contributors (and our future selves) lose the context behind why decisions were made, leading to either repeated debate or unintended changes that violate the original constraints.

## Decision

We will use Architectural Decision Records as described by Michael Nygard, in the lightweight [MADR](https://adr.github.io/madr/) format.

## Consequences

### Positive
- Decision rationale is preserved alongside the code
- Future contributors can quickly understand why the system is shaped the way it is
- Decisions can be revisited explicitly via superseding ADRs rather than silent drift

### Negative
- Adds a small overhead when making architectural decisions
- Requires discipline to update the index and write the ADR before implementation