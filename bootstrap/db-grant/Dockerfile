# syntax=docker/dockerfile:1.7
#
# Image for the db-grant Job: PostgreSQL client + Azure CLI + the grant
# scripts. Small, single-purpose. Not an application image.

FROM debian:bookworm-slim

# Pull in security updates over the base image (Trivy will flag stale
# OS packages otherwise — same pattern as the service Dockerfiles).
RUN apt-get update && \
    apt-get upgrade -y --no-install-recommends && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        postgresql-client \
    && rm -rf /var/lib/apt/lists/*

# ── Azure CLI ─────────────────────────────────────────────────────────────────
# Installed from Microsoft's apt repository.
# Note: the Azure CLI is heavy (~hundreds of MB with its Python runtime).
# It is used here only for the workload-identity token exchange in
# entrypoint.sh. A lighter approach (raw OAuth call against the token
# endpoint) would shrink the image considerably — deferred as a future
# optimisation; for a rarely-run Job, image size is not a concern and the
# CLI is the most readable, obviously-correct way to do the exchange.
RUN curl -sLS https://packages.microsoft.com/keys/microsoft.asc \
        | gpg --dearmor -o /usr/share/keyrings/microsoft.gpg && \
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft.gpg] \
https://packages.microsoft.com/repos/azure-cli/ bookworm main" \
        > /etc/apt/sources.list.d/azure-cli.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends azure-cli && \
    /opt/az/bin/python3 -m pip install --upgrade "urllib3>=2.7.0,<3" && \
    rm -rf /var/lib/apt/lists/*

# ── Scripts ───────────────────────────────────────────────────────────────────
WORKDIR /opt/db-grant
COPY entrypoint.sh grant.sh ./
RUN chmod +x entrypoint.sh grant.sh

# ── Non-root user ─────────────────────────────────────────────────────────────
# Nothing here needs root at runtime. Create an unprivileged user, matching
# the security posture of the application images.
RUN groupadd --system --gid 1000 dbgrant && \
    useradd  --system --uid 1000 --gid dbgrant --create-home --shell /bin/false dbgrant
USER 1000

ENTRYPOINT ["/opt/db-grant/entrypoint.sh"]
