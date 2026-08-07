#!/usr/bin/env bash
# scripts/start-worker.sh
# Starts the local Boundary worker that bridges HCP Boundary to the Docker targets.
#
# On first run the worker generates a registration token; this script detects
# that automatically and registers it via `boundary workers create worker-led`
# using the admin credentials already in .env -- no manual UI step needed.
# Subsequent runs reuse the stored state in boundary/auth/ (gitignored) --
# deliberately not /tmp, which macOS periodically sweeps after a few idle days.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
WORKER_HCL="${REPO_ROOT}/boundary/worker.hcl"
ENV_FILE="${REPO_ROOT}/.env"
WORKER_AUTH_STORAGE_PATH="${REPO_ROOT}/boundary/auth"

# Load .env if present
[ -f "$ENV_FILE" ] && set -a && source "$ENV_FILE" && set +a

TMP_HCL="$(mktemp -t worker-hcl)"
WORKER_LOG="$(mktemp -t worker-log)"
WORKER_PID=""
TAIL_PID=""

cleanup() {
    [ -n "$TAIL_PID" ] && kill "$TAIL_PID" 2>/dev/null || true
    [ -n "$WORKER_PID" ] && kill "$WORKER_PID" 2>/dev/null || true
    rm -f "$TMP_HCL" "$WORKER_LOG"
}
trap cleanup EXIT INT TERM

sed \
    -e "s|HCP_BOUNDARY_CLUSTER_ID|${HCP_BOUNDARY_CLUSTER_ID:-HCP_BOUNDARY_CLUSTER_ID}|" \
    -e "s|WORKER_AUTH_STORAGE_PATH|${WORKER_AUTH_STORAGE_PATH}|" \
    "$WORKER_HCL" > "$TMP_HCL"
WORKER_HCL="$TMP_HCL"

mkdir -p "$WORKER_AUTH_STORAGE_PATH"

echo "Starting Boundary worker..."
echo "  Config: ${WORKER_HCL}"
echo ""

boundary server -config="$WORKER_HCL" > "$WORKER_LOG" 2>&1 &
WORKER_PID=$!

echo "Waiting for worker to come up (pid ${WORKER_PID})..."
TOKEN=""
REGISTERED=false
for _ in $(seq 1 30); do
    if ! kill -0 "$WORKER_PID" 2>/dev/null; then
        echo "ERROR: worker process exited early. Log:" >&2
        cat "$WORKER_LOG" >&2
        exit 1
    fi
    if grep -q "worker has successfully authenticated" "$WORKER_LOG" 2>/dev/null; then
        REGISTERED=true
        break
    fi
    if [ -z "$TOKEN" ] && grep -q "Worker Auth Registration Request:" "$WORKER_LOG" 2>/dev/null; then
        TOKEN=$(grep "Worker Auth Registration Request:" "$WORKER_LOG" | tail -1 | awk '{print $NF}')
    fi
    sleep 1
done

if [ "$REGISTERED" = true ]; then
    echo "  ✓ Worker already registered — reconnected"
elif [ -n "$TOKEN" ]; then
    echo "  New worker — registering automatically via boundary CLI..."
    : "${BOUNDARY_ADDR:?Set BOUNDARY_ADDR in .env}"
    : "${BOUNDARY_AUTH_METHOD_ID:?Set BOUNDARY_AUTH_METHOD_ID in .env}"
    ADMIN_TOKEN_PW="${BOUNDARY_ADMIN_PASSWORD:-${BOUNDARY_PASSWORD:-}}"
    : "${ADMIN_TOKEN_PW:?Set BOUNDARY_ADMIN_PASSWORD (or BOUNDARY_PASSWORD) in .env}"
    export BOUNDARY_ADDR ADMIN_TOKEN_PW

    ADMIN_TOKEN=$(boundary authenticate password \
        -auth-method-id="${BOUNDARY_AUTH_METHOD_ID}" \
        -login-name="${BOUNDARY_ADMIN_LOGIN_NAME:-admin}" \
        -password env://ADMIN_TOKEN_PW \
        -format=json | jq -r '.item.attributes.token')

    WORKER_NAME="demo-worker-$(hostname -s 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' || echo local)"
    BOUNDARY_TOKEN="$ADMIN_TOKEN" boundary workers create worker-led \
        -worker-generated-auth-token="$TOKEN" \
        -name="$WORKER_NAME" \
        -format=json > /dev/null

    echo "  ✓ Worker registered automatically — no UI step needed"

    # Give the worker a moment to complete the handshake it can now finish.
    for _ in $(seq 1 15); do
        grep -q "worker has successfully authenticated" "$WORKER_LOG" 2>/dev/null && break
        sleep 1
    done
else
    echo "  WARNING: worker did not report a registration token or a successful" >&2
    echo "  auth within 30s. It may still be starting -- check the tailed log below." >&2
fi

echo ""
echo "Worker running. Tailing logs (Ctrl+C to stop)..."
echo ""
tail -f "$WORKER_LOG" &
TAIL_PID=$!
wait "$WORKER_PID"
