#!/usr/bin/env bash
# boundary/setup.sh
# Creates all HCP Boundary resources needed for the agentic AI demo:
#   - Project scope under the existing org scope
#   - Static host catalog with hosts for demo-web-app and postgres
#   - TCP targets for demo-web-app (port 2222) and postgres (port 5432)
#   - demo-agent account + target-access role grant
#
# NOTE: This script does NOT set up a Vault credential store in Boundary because
# the Vault instance runs locally (Docker) and the HCP Boundary controller (cloud)
# cannot reach it. Instead, the AI agent fetches Vault credentials directly and
# passes them through the Boundary session. All sessions are still brokered,
# audited, and controlled by Boundary.
#
# NOTE: demo-web-app's target is TCP type, not SSH type, even though the agent
# uses it for SSH. Boundary's dedicated "ssh" target type requires Boundary to
# broker/inject the credential itself (a Vault SSH credential store reachable
# from the HCP-hosted controller) — the opposite of the local-Vault design
# above. "tcp" targets just proxy bytes and let the SSH client bring its own
# Vault-signed cert, which is what this demo needs.
#
# NOTE: demo-agent is an ACCOUNT under the cluster's original, pre-provisioned
# auth method (the same BOUNDARY_AUTH_METHOD_ID used for admin auth below) —
# NOT a new auth method. On HCP-managed Boundary clusters, only that original
# auth method supports direct password :authenticate calls; any auth method
# created afterward returns 404, regardless of scope.
#
# Prerequisites:
#   - `boundary` CLI installed and BOUNDARY_ADDR set
#   - An HCP Boundary cluster with at least one org scope
#   - BOUNDARY_ADDR, BOUNDARY_AUTH_METHOD_ID, BOUNDARY_LOGIN_NAME, BOUNDARY_PASSWORD in .env
#
# Run: bash boundary/setup.sh   (loads .env itself — no need to `source` first)

set -euo pipefail

ENV_FILE="$(cd "$(dirname "$0")/.." && pwd)/.env"
if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
fi

: "${BOUNDARY_ADDR:?Set BOUNDARY_ADDR in .env}"

divider() { printf '\n%s\n' "─────────────────────────────────────────────"; }

divider
echo "Boundary Setup — HashiCorp Boundary Agentic AI Demo"
echo "Cluster: ${BOUNDARY_ADDR}"
divider

# ── 1. Authenticate ───────────────────────────────────────────────────────────
echo ""
echo "▶ Authenticating to HCP Boundary..."

if [ -z "${BOUNDARY_TOKEN:-}" ]; then
    if [ -z "${BOUNDARY_AUTH_METHOD_ID:-}" ]; then
        echo "ERROR: Set BOUNDARY_AUTH_METHOD_ID (password auth method ID from HCP UI)" >&2
        echo "       Find it under: Boundary cluster → Auth Methods → ampw_XXXXXXXXXX" >&2
        exit 1
    fi
    export BOUNDARY_TOKEN
    # Use admin credentials for initial setup; agent gets its own account below
    export BOUNDARY_PASSWORD="${BOUNDARY_ADMIN_PASSWORD:-${BOUNDARY_PASSWORD}}"
    BOUNDARY_TOKEN=$(boundary authenticate password \
        -auth-method-id="${BOUNDARY_AUTH_METHOD_ID}" \
        -login-name="${BOUNDARY_ADMIN_LOGIN_NAME:-admin}" \
        -password env://BOUNDARY_PASSWORD \
        -format=json | jq -r '.item.attributes.token')
    echo "  ✓ Authenticated"
fi

# ── 2. Find (or create) the org scope ─────────────────────────────────────────
echo ""
echo "▶ Finding organisation scope..."
ORG_SCOPE_ID=$(boundary scopes list -scope-id=global -format=json \
    | jq -r '.items // [] | .[] | select(.type=="org") | .id' | head -1)

if [ -z "$ORG_SCOPE_ID" ]; then
    echo "  No org scope exists yet — creating one..."
    ORG_SCOPE_ID=$(boundary scopes create \
        -scope-id=global \
        -name="incident-response-demo" \
        -description="Agentic AI incident response demo" \
        -format=json | jq -r '.item.id')
    echo "  Created org scope: ${ORG_SCOPE_ID}"
else
    echo "  Org scope: ${ORG_SCOPE_ID}"
fi

# ── 3. Create project scope ───────────────────────────────────────────────────
echo ""
echo "▶ Creating project 'incident-response'..."
PROJECT_ID=$(boundary scopes list -scope-id="${ORG_SCOPE_ID}" -format=json \
    | jq -r '.items[]? | select(.name=="incident-response") | .id' || true)

if [ -z "$PROJECT_ID" ]; then
    PROJECT_ID=$(boundary scopes create \
        -scope-id="${ORG_SCOPE_ID}" \
        -name="incident-response" \
        -description="Agentic AI incident response demo" \
        -format=json | jq -r '.item.id')
    echo "  Created: ${PROJECT_ID}"
else
    echo "  Already exists: ${PROJECT_ID}"
fi

# ── 4. Static host catalog ────────────────────────────────────────────────────
echo ""
echo "▶ Creating static host catalog 'local-docker'..."
CATALOG_ID=$(boundary host-catalogs list -scope-id="${PROJECT_ID}" -format=json \
    | jq -r '.items[]? | select(.name=="local-docker") | .id' || true)

if [ -z "$CATALOG_ID" ]; then
    CATALOG_ID=$(boundary host-catalogs create static \
        -scope-id="${PROJECT_ID}" \
        -name="local-docker" \
        -description="Docker Compose targets (accessible via local Boundary worker)" \
        -format=json | jq -r '.item.id')
    echo "  Created: ${CATALOG_ID}"
else
    echo "  Already exists: ${CATALOG_ID}"
fi

# Hosts (127.0.0.1 — reachable from the worker running on the demo host)
echo ""
echo "▶ Creating hosts..."
create_host() {
    local NAME=$1 ADDR=$2
    local EXISTING
    EXISTING=$(boundary hosts list -host-catalog-id="${CATALOG_ID}" -format=json \
        | jq -r ".items[]? | select(.name==\"${NAME}\") | .id" || true)
    if [ -z "$EXISTING" ]; then
        boundary hosts create static \
            -host-catalog-id="${CATALOG_ID}" \
            -name="${NAME}" \
            -address="${ADDR}" \
            -format=json | jq -r '.item.id'
    else
        echo "$EXISTING"
    fi
}

WEB_HOST_ID=$(create_host "demo-web-app" "127.0.0.1")
DB_HOST_ID=$(create_host "postgres"      "127.0.0.1")
echo "  demo-web-app host: ${WEB_HOST_ID}"
echo "  postgres host:     ${DB_HOST_ID}"

# Host sets — one per target
echo ""
echo "▶ Creating host sets..."
create_host_set() {
    local NAME=$1
    local EXISTING
    EXISTING=$(boundary host-sets list -host-catalog-id="${CATALOG_ID}" -format=json \
        | jq -r ".items[]? | select(.name==\"${NAME}\") | .id" || true)
    if [ -z "$EXISTING" ]; then
        boundary host-sets create static \
            -host-catalog-id="${CATALOG_ID}" \
            -name="${NAME}" \
            -format=json | jq -r '.item.id'
    else
        echo "$EXISTING"
    fi
}

WEB_SET_ID=$(create_host_set "web-app-hosts")
DB_SET_ID=$(create_host_set  "db-hosts")

boundary host-sets add-hosts -id="${WEB_SET_ID}" -host="${WEB_HOST_ID}" 2>/dev/null || true
boundary host-sets add-hosts -id="${DB_SET_ID}"  -host="${DB_HOST_ID}"  2>/dev/null || true
echo "  web-app host set: ${WEB_SET_ID}"
echo "  db host set:      ${DB_SET_ID}"

# ── 5. Targets ────────────────────────────────────────────────────────────────
echo ""
echo "▶ Creating targets..."
create_target() {
    local TYPE=$1 NAME=$2 PORT=$3
    local EXISTING
    EXISTING=$(boundary targets list -scope-id="${PROJECT_ID}" -format=json \
        | jq -r ".items[]? | select(.name==\"${NAME}\") | .id" || true)
    if [ -z "$EXISTING" ]; then
        boundary targets create "${TYPE}" \
            -scope-id="${PROJECT_ID}" \
            -name="${NAME}" \
            -default-port="${PORT}" \
            -description="Managed by Boundary — agent access requires an active session" \
            -egress-worker-filter='"local" in "/tags/type"' \
            -format=json | jq -r '.item.id'
    else
        echo "$EXISTING"
    fi
}

SSH_TARGET_ID=$(create_target tcp demo-web-app 2222)
DB_TARGET_ID=$(create_target  tcp postgres     5432)

boundary targets add-host-sources -id="${SSH_TARGET_ID}" -host-source="${WEB_SET_ID}" 2>/dev/null || true
boundary targets add-host-sources -id="${DB_TARGET_ID}"  -host-source="${DB_SET_ID}"  2>/dev/null || true

echo "  SSH target (demo-web-app): ${SSH_TARGET_ID}"
echo "  DB  target (postgres):     ${DB_TARGET_ID}"

# ── 6. Agent account (under the existing, working auth method) ───────────────
AUTH_ID="${BOUNDARY_AUTH_METHOD_ID}"

AGENT_PASSWORD="${BOUNDARY_AGENT_PASSWORD:-$(openssl rand -base64 16)}"
export AGENT_PASSWORD
echo ""
echo "▶ Creating managed account 'demo-agent'..."
ACCT_ID=$(boundary accounts list -auth-method-id="${AUTH_ID}" -format=json \
    | jq -r '.items[]? | select(.attributes.login_name=="demo-agent") | .id' || true)

if [ -z "$ACCT_ID" ]; then
    ACCT_ID=$(boundary accounts create password \
        -auth-method-id="${AUTH_ID}" \
        -login-name="demo-agent" \
        -password env://AGENT_PASSWORD \
        -format=json | jq -r '.item.id')
    echo "  Created account: ${ACCT_ID}"
else
    boundary accounts set-password -id="${ACCT_ID}" -password env://AGENT_PASSWORD -format=json > /dev/null
    echo "  Already exists: ${ACCT_ID} (password reset)"
fi

# A "user" resource isn't created/linked to the account until its first
# successful login — authenticate once now so we can look it up below.
echo "▶ Linking demo-agent's user (first login)..."
DEMO_AGENT_TOKEN=$(boundary authenticate password \
    -auth-method-id="${AUTH_ID}" \
    -login-name="demo-agent" \
    -password env://AGENT_PASSWORD \
    -format=json | jq -r '.item.attributes.token')
export DEMO_AGENT_TOKEN

# `users list` doesn't populate account_ids on each item (only `users read`
# does) — loop and read each candidate to find the one linked to ACCT_ID.
AGENT_USER_ID=""
for CANDIDATE_UID in $(boundary users list -scope-id=global -token=env://BOUNDARY_TOKEN -format=json | jq -r '.items[]?.id'); do
    MATCH=$(boundary users read -id="${CANDIDATE_UID}" -token=env://BOUNDARY_TOKEN -format=json \
        | jq -r --arg acct "$ACCT_ID" 'select(.item.account_ids != null and (.item.account_ids | index($acct))) | .item.id')
    if [ -n "$MATCH" ]; then
        AGENT_USER_ID="$MATCH"
        break
    fi
done
echo "  User: ${AGENT_USER_ID}"

# ── 7. Grant demo-agent access to the project's targets ──────────────────────
# Boundary's default "Default Grants" role only gives authenticated users
# `type=target;actions=list` — not enough to actually open a session.
echo ""
echo "▶ Granting demo-agent target access..."
ROLE_ID=$(boundary roles list -scope-id="${PROJECT_ID}" -format=json \
    | jq -r '.items[]? | select(.name=="demo-agent-access") | .id' || true)

if [ -z "$ROLE_ID" ]; then
    ROLE_ID=$(boundary roles create \
        -scope-id="${PROJECT_ID}" \
        -name="demo-agent-access" \
        -description="Grants demo-agent authorize-session on incident-response targets" \
        -format=json | jq -r '.item.id')
    boundary roles add-grants -id="${ROLE_ID}" -grant="ids=*;type=target;actions=authorize-session" -format=json > /dev/null
    echo "  Created role: ${ROLE_ID}"
else
    echo "  Already exists: ${ROLE_ID}"
fi

boundary roles add-principals -id="${ROLE_ID}" -principal="${AGENT_USER_ID}" 2>/dev/null || true
echo "  Principal attached: ${AGENT_USER_ID}"

# ── 7. Write outputs ──────────────────────────────────────────────────────────
divider
echo ""
echo "Boundary setup complete. Add these to your .env file:"
echo ""
echo "  BOUNDARY_AUTH_METHOD_ID=${AUTH_ID}"
echo "  BOUNDARY_LOGIN_NAME=demo-agent"
echo "  BOUNDARY_PASSWORD=${AGENT_PASSWORD}"
echo "  BOUNDARY_SSH_TARGET_ID=${SSH_TARGET_ID}"
echo "  BOUNDARY_DB_TARGET_ID=${DB_TARGET_ID}"
echo ""

if [ -f "$ENV_FILE" ]; then
    for VAR in \
        "BOUNDARY_AUTH_METHOD_ID=${AUTH_ID}" \
        "BOUNDARY_LOGIN_NAME=demo-agent" \
        "BOUNDARY_PASSWORD=${AGENT_PASSWORD}" \
        "BOUNDARY_SSH_TARGET_ID=${SSH_TARGET_ID}" \
        "BOUNDARY_DB_TARGET_ID=${DB_TARGET_ID}"; do
        KEY="${VAR%%=*}"
        if grep -q "^${KEY}=" "$ENV_FILE"; then
            sed -i.bak "s|^${KEY}=.*|${VAR}|" "$ENV_FILE" && rm -f "${ENV_FILE}.bak"
        else
            echo "${VAR}" >> "$ENV_FILE"
        fi
    done
    echo "  (also written to .env)"
fi

echo ""
echo "Next: start the Boundary worker and run the demo agent."
echo "  bash scripts/start-worker.sh"
echo "  python agent/agent.py"
echo ""
