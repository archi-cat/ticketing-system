# syntax=docker/dockerfile:1.7
# ─── Stage 1: build dependencies ──────────────────────────────────────────────
# Use the bookworm-slim variant — small, stable, security updates available.
# Multi-stage means the final image doesn't contain uv or build artefacts.
FROM python:3.14-slim-bookworm AS builder

# Copy uv binary from its official image (multi-arch, pre-built)
COPY --from=ghcr.io/astral-sh/uv:0.5.13 /uv /uvx /bin/

# Cache the venv outside the source tree so a code-only change doesn't
# invalidate the dependency install layer
ENV UV_PROJECT_ENVIRONMENT=/opt/venv \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_PREFERENCE=only-system \
    UV_PYTHON_DOWNLOADS=never

WORKDIR /app

# ── Dependencies layer (cached when pyproject.toml + uv.lock don't change) ────
# We mount uv's cache so re-builds reuse downloaded wheels
COPY pyproject.toml uv.lock ./

RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-install-project --no-dev

# ── Application layer (re-runs when source changes) ───────────────────────────
COPY src ./src

RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-dev

# ── Migration files ───────────────────────────────────────────────────────────
# alembic.ini and the alembic/ directory (env.py + versions/) so the API
# image can run `alembic upgrade head` as the db-migrate bootstrap Job.
# Placed after uv sync — they are not needed for the dependency install,
# and putting them last keeps a migration-file change from invalidating
# the expensive sync layer.
COPY alembic.ini ./alembic.ini
COPY alembic ./alembic

# ─── Stage 2: runtime ─────────────────────────────────────────────────────────
FROM python:3.14-slim-bookworm AS runtime

# Pull in any security updates released since the base image was built.
# Base images age — Debian publishes patches continuously; this step ensures
# we pick them up at our build time. Use --no-install-recommends to avoid
# pulling in extras we don't need.
RUN apt-get update && \
    apt-get upgrade -y --no-install-recommends && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Create a non-root user for the application. Distroless would be even safer,
# but slim is more debuggable and still has good security posture.
RUN groupadd --system --gid 1000 app \
 && useradd  --system --uid 1000 --gid app --create-home --shell /bin/false app

# Copy the venv from the builder stage
COPY --from=builder --chown=app:app /opt/venv /opt/venv

# Copy the source — needed because the venv references the package by path
COPY --from=builder --chown=app:app /app /app

ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONPATH=/app/src

WORKDIR /app
USER 1000

# HTTP port the API listens on. Matches Settings.http_port default.
EXPOSE 8000

# Liveness probe target — Kubernetes hits this directly
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/health/live', timeout=2)" \
        || exit 1

# Run via uvicorn directly (the __main__.py module also works, but using
# uvicorn directly gives us cleaner control over worker count, log level,
# and process behaviour in production).
CMD ["uvicorn", "ticketing_api.main:app", \
     "--host", "0.0.0.0", \
     "--port", "8000", \
     "--no-access-log"]
