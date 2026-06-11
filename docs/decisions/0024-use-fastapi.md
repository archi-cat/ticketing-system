# ADR-0024: Use FastAPI for the HTTP API

Status: Accepted
Date: 2026-06-11

> Retrospective record — this decision was made at project inception (Phase 1) but never written down. Documented now so the decision log is complete.

## Context

The API service needs a Python HTTP framework for the customer-facing REST endpoints (browse events, reserve seats, confirm bookings). The data layer was already decided as PostgreSQL with an async driver (ADR-0002), so the framework had to be async-native end to end.

## Decision drivers

- Async-first request handling — the API is I/O-bound (Postgres, Redis, Service Bus) and a sync framework would waste the small node pool
- Request/response validation without hand-rolled checks
- OpenAPI schema generation for free (documentation + client generation)
- First-class type annotations — the project uses strict typing throughout
- OpenTelemetry instrumentation availability for the App Insights pipeline

## Considered options

### Flask

- Mature, minimal, huge ecosystem
- Sync-first; async support is bolted on and the extension ecosystem largely assumes WSGI
- No built-in validation or OpenAPI — needs Marshmallow/APIFlask layered on

### Django + DRF

- Batteries included, admin UI, ORM
- The ORM and ecosystem assume sync; async support is still partial in practice
- Far more framework than three small services need; the ORM would conflict with the SQLAlchemy decision

### FastAPI

- Async-native on ASGI (uvicorn)
- Pydantic request/response models give validation + serialisation + OpenAPI in one declaration
- Dependency-injection system fits the per-request session/client lifecycle cleanly
- `opentelemetry-instrumentation-fastapi` exists and is maintained

## Decision

**FastAPI** on uvicorn, with Pydantic models for all request/response shapes.

## Consequences

### Positive

- One declaration per endpoint covers routing, validation, serialisation, and documentation
- Async end to end: FastAPI → SQLAlchemy 2.0 async → asyncpg, no sync/async bridging
- Auto-generated OpenAPI has been the de-facto API reference throughout development

### Negative

- Smaller core team than Flask/Django; release cadence occasionally breaks pinned ecosystems (mitigated by lockfiles + Dependabot, ADR-0023)
- Pydantic v2 model semantics are their own learning curve
- ASGI deployment knowledge (uvicorn workers, lifespan events) required from day one
