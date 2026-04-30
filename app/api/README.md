# Ticketing API

FastAPI service handling synchronous customer requests for the ticketing system.
Reservations, bookings, event listings, and health endpoints.

## Quick start

```bash
uv sync
uv run python -m ticketing_api
```

API at <http://localhost:8000>, docs at <http://localhost:8000/docs>.

## Project layout

```
src/ticketing_api/
├── main.py             # FastAPI app factory
├── settings.py         # Pydantic Settings
├── observability.py    # logging + tracing
├── domain/             # domain models (Pydantic)
├── routes/             # FastAPI routers
├── services/           # business logic
├── repositories/       # data access (SQLAlchemy)
└── infrastructure/     # external clients (db, redis, sb, kv)
tests/
├── unit/               # unit tests with mocks
└── integration/        # integration tests against docker-compose
```
## Configuration

Settings load from environment variables. See `src/ticketing_api/settings.py`
for the full list.

For local development create a `.env` file (not committed):

```env
ENVIRONMENT=local
LOG_LEVEL=DEBUG
LOG_FORMAT=console

POSTGRES_HOST=localhost
POSTGRES_PORT=5432
POSTGRES_DATABASE=ticketing
POSTGRES_USER=postgres
POSTGRES_PASSWORD=postgres

REDIS_HOST=localhost
REDIS_PORT=6379
REDIS_USE_TLS=false
```

In Azure, settings are injected via Kubernetes ConfigMaps and the
Workload-Identity-aware code path activates (`POSTGRES_USE_WORKLOAD_IDENTITY=true`).

## Development tasks

```bash
# Format
uv run ruff format .

# Lint
uv run ruff check .

# Type-check
uv run mypy src

# Test (unit only)
uv run pytest tests/unit

# Test (everything — requires docker-compose stack up)
uv run pytest
```

## Authentication model

In production, the API authenticates to:

- **PostgreSQL** — directly via Workload Identity. The pod's UAMI is mapped to a
  database role; SQLAlchemy obtains an Entra ID token at connection time.
- **Service Bus** — directly via Workload Identity. The Service Bus SDK
  presents the UAMI's token; no connection strings.
- **Key Vault** — directly via Workload Identity. Used to fetch the Redis
  primary key at startup.
- **Redis** — indirectly. The primary key is fetched from Key Vault using
  Workload Identity, then used as the AUTH credential. See ADR-0008.

Locally, all four use connection strings/passwords from environment variables.