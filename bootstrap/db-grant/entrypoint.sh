#!/usr/bin/env bash
#
# Container entrypoint for the db-grant Job.
#
# Responsibilities, in order:
#   1. Acquire a PostgreSQL Entra access token using the pod's workload
#      identity (the db-grant UAMI, federated to this Job's service account).
#   2. Export it as PGPASSWORD.
#   3. Hand off to grant.sh, which does the SQL orchestration.
#
# Keeping token acquisition here (not in grant.sh) means grant.sh stays a
# pure SQL-orchestration script with no Azure dependency.

set -euo pipefail

echo "==> Acquiring PostgreSQL Entra access token via workload identity"

# `az login` with the federated token: the AKS workload identity webhook
# injects AZURE_CLIENT_ID, AZURE_TENANT_ID, and AZURE_FEDERATED_TOKEN_FILE
# into the pod. The CLI exchanges the federated token for an Entra token.
az login --service-principal \
  --username "$AZURE_CLIENT_ID" \
  --tenant "$AZURE_TENANT_ID" \
  --federated-token "$(cat "$AZURE_FEDERATED_TOKEN_FILE")" \
  --output none

# Mint an access token scoped to Azure Database for PostgreSQL.
PGPASSWORD="$(az account get-access-token \
  --resource-type oss-rdbms \
  --query accessToken \
  --output tsv)"
export PGPASSWORD

if [[ -z "${PGPASSWORD:-}" ]]; then
  echo "ERROR: failed to acquire a PostgreSQL access token." >&2
  exit 1
fi

echo "==> Token acquired. Handing off to grant.sh"
exec /opt/db-grant/grant.sh
