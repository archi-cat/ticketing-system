# ADR-0025: Use SQLAlchemy 2.0 async with Alembic

Status: Accepted
Date: 2026-06-11

> Retrospective record — this decision was made at project inception (Phase 1) but never written down. Documented now so the decision log is complete.

## Context

With PostgreSQL (ADR-0002) and FastAPI (ADR-0024) decided, the API needs a data-access layer and a migration story. The reservation flow has real transactional requirements (seat holds must be atomic) so raw-SQL-with-no-structure wasn't an option.

## Decision drivers

- Async support that actually works with asyncpg, not a sync ORM behind a thread pool
- Typed query API — the project is strict-mypy throughout
- Schema migrations as code, runnable in CI/CD (the db-migrate Job, later ADR-0018)
- Transferable skills — the data layer pattern should be the one used in real production Python

## Considered options

### Raw asyncpg

- Fastest, no abstraction tax
- Every query is a hand-written string; no model layer, no migration tooling
- Transaction and relationship handling becomes bespoke code to maintain

### Tortoise ORM / SQLModel

- Async-native (Tortoise) or Pydantic-integrated (SQLModel)
- Both significantly smaller ecosystems; SQLModel tracks SQLAlchemy anyway but lags it
- Migration tooling (Aerich) less mature than Alembic

### SQLAlchemy 2.0 async + Alembic

- The 2.0 API is typed, explicit (`select()` style), and async-first via `AsyncSession`/asyncpg
- Alembic is the de-facto migration standard, autogenerates diffs from model metadata
- Largest ecosystem and the most transferable skill of the options

## Decision

**SQLAlchemy 2.0 async** (asyncpg driver) with **Alembic** migrations, owned by the api service (`app/api/alembic/`) and applied by the in-cluster db-migrate Job (ADR-0018).

## Consequences

### Positive

- One pattern covers models, transactions, and seat-hold atomicity, fully typed
- Alembic migrations run identically locally and in the bootstrap Job; schema history is in git
- The 2.0 explicit style avoids the classic lazy-loading-in-async footguns (no implicit I/O)

### Negative

- SQLAlchemy's flexibility comes with a steep API surface; the 2.0 + async + typing combination has sparse examples for edge cases
- asyncpg's prepared-statement behaviour interacts with PgBouncer-style pooling — constrains future pooler choices
- Alembic autogenerate is a starting point, not a truth source; migrations still need human review
