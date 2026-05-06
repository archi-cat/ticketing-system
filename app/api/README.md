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

## Local development workflow

### 1. Start dependencies

```bash
docker compose -f ../../docker-compose.dev.yml up -d
```

### 2. Apply migrations

```bash
export POSTGRES_HOST=localhost
export POSTGRES_PORT=5432
export POSTGRES_DATABASE=ticketing
export POSTGRES_USER=postgres
export POSTGRES_PASSWORD=postgres
export POSTGRES_USE_WORKLOAD_IDENTITY=false

uv run alembic upgrade head
```

Or via the .env file:

```bash
cp .env.example .env  # uses local docker-compose values
uv run alembic upgrade head
```

### 3. Run the API

```bash
uv run python -m ticketing_api
```

### 4. Hit the API

```bash
# List events (empty unless you seed locally)
curl http://localhost:8000/events

# Manually insert a test event
docker exec -it $(docker ps --filter "name=postgres" -q) \
    psql -U postgres -d ticketing -c \
    "INSERT INTO events (id, name, venue, starts_at, total_seats, available_seats, price_pence)
     VALUES (gen_random_uuid(), 'Test Show', 'Test Venue', NOW() + INTERVAL '7 days', 100, 100, 1000);"

# Reserve seats for the event (use the ID from the listing above)
EVENT_ID=$(curl -s http://localhost:8000/events | jq -r '.items[0].id')
curl -X POST http://localhost:8000/events/$EVENT_ID/reservations \
    -H "Content-Type: application/json" \
    -d '{"customer_email":"alice@example.com","seat_count":2}'
```

## Migrations

Alembic is configured to use the same Settings as the API. To create a new migration:

```bash
uv run alembic revision -m "add my new column" --autogenerate
```

To roll back:

```bash
uv run alembic downgrade -1
```