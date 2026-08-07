#!/usr/bin/env bash
# vault/setup.sh
# Configures local Vault (Docker dev mode) for the Boundary agentic AI demo.
#
# Run after `docker compose up -d` and before boundary/setup.sh.
# Idempotent — safe to re-run. Loads .env itself — no need to `source` first.

set -euo pipefail

ENV_FILE="$(cd "$(dirname "$0")/.." && pwd)/.env"
if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
fi

VAULT_ADDR="${VAULT_ADDR:-http://localhost:8200}"
VAULT_TOKEN="${VAULT_TOKEN:-root}"
export VAULT_ADDR VAULT_TOKEN

# Postgres connection details — Vault connects using the Docker hostname
POSTGRES_HOST="${POSTGRES_HOST:-postgres}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
POSTGRES_DB="${POSTGRES_DB:-incidents}"
VAULT_PG_PASSWORD="${VAULT_PG_PASSWORD:-vaultpassword}"

# Agent AppRole defaults
ROLE_NAME="demo-agent"

divider() { printf '\n%s\n' "─────────────────────────────────────────────"; }

divider
echo "Vault Setup — HashiCorp Boundary Agentic AI Demo"
echo "Vault: ${VAULT_ADDR}"
divider

# ── 0. Clean up orphaned dynamic roles from a prior Vault instance ───────────
# Vault dev mode has no persistent storage: every restart forgets every lease
# it ever issued, so any Postgres role it created before that restart never
# gets auto-revoked -- it just sits there with a lapsed rolvaliduntil forever.
# Harmless functionally, but exactly the kind of "wait, why hasn't this been
# cleaned up?" clutter a skeptical demo audience would notice in \du.
echo ""
echo "▶ Cleaning up any expired dynamic Postgres roles from a prior Vault instance..."
docker exec demo-postgres psql -U postgres -d "${POSTGRES_DB}" -t -c "
DO \$\$
DECLARE r RECORD;
BEGIN
  FOR r IN SELECT rolname FROM pg_roles WHERE rolname LIKE 'v-%' AND rolvaliduntil < NOW() LOOP
    EXECUTE format('DROP ROLE IF EXISTS %I', r.rolname);
  END LOOP;
END \$\$;
" >/dev/null 2>&1 && echo "  ✓ Cleaned up" || echo "  (skipped -- demo-postgres not up yet, that's fine)"

# ── 0b. Audit logging (for live demo visibility into what Vault actually did) ─
echo ""
echo "▶ Enabling file audit device..."
vault audit enable file file_path=/vault/logs/audit.log 2>/dev/null && echo "  Enabled" \
    || echo "  already enabled"

# ── 1. SSH Signed Certificates ───────────────────────────────────────────────
echo ""
echo "▶ Enabling SSH secrets engine..."
vault secrets enable -path=ssh ssh 2>/dev/null && echo "  Enabled ssh/" \
    || echo "  ssh/ already enabled"

echo "▶ Generating SSH Certificate Authority..."
vault write -f ssh/config/ca generate_signing_key=true 2>/dev/null \
    && echo "  CA key pair created" \
    || echo "  CA already exists"

echo "▶ Creating SSH role 'ubuntu' (signed certificates, 5-min TTL)..."
vault write ssh/roles/ubuntu \
    key_type=ca \
    allowed_users="ubuntu" \
    default_user="ubuntu" \
    ttl="5m" \
    max_ttl="10m" \
    allow_user_certificates=true \
    valid_principals="ubuntu" \
    extensions='{"permit-pty":"","permit-port-forwarding":""}'

echo "  ✓ SSH engine configured"

# ── 2. Database Dynamic Credentials ─────────────────────────────────────────
echo ""
echo "▶ Enabling database secrets engine..."
vault secrets enable -path=database database 2>/dev/null && echo "  Enabled database/" \
    || echo "  database/ already enabled"

echo "▶ Connecting Vault to PostgreSQL (retrying until ready)..."
CONNECTED=false
for i in $(seq 1 30); do
    if vault write database/config/postgres \
        plugin_name=postgresql-database-plugin \
        allowed_roles="incidents-reader" \
        connection_url="postgresql://{{username}}:{{password}}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}?sslmode=disable" \
        username="vault" \
        password="${VAULT_PG_PASSWORD}" \
        >/dev/null 2>&1; then
        CONNECTED=true
        break
    fi
    echo "  Retrying PostgreSQL connection... (${i}/30)"
    sleep 3
done

if ! $CONNECTED; then
    echo "ERROR: Could not connect Vault to PostgreSQL. Is 'docker compose up -d' complete?" >&2
    exit 1
fi

echo "▶ Creating database role 'incidents-reader' (dynamic users, 5-min TTL)..."
vault write database/roles/incidents-reader \
    db_name=postgres \
    creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}' IN ROLE incidents_reader;" \
    revocation_statements="DROP ROLE IF EXISTS \"{{name}}\";" \
    default_ttl="5m" \
    max_ttl="10m"

echo "  ✓ Database engine configured"

# ── 3. AppRole Auth for the AI Agent ────────────────────────────────────────
echo ""
echo "▶ Enabling AppRole auth..."
vault auth enable approle 2>/dev/null && echo "  Enabled approle/" \
    || echo "  approle/ already enabled"

echo "▶ Writing agent policy..."
vault policy write demo-agent - <<'POLICY'
# Allow the agent to sign SSH public keys
path "ssh/sign/ubuntu" {
  capabilities = ["create", "update"]
}
# Allow the agent to fetch the CA public key
path "ssh/config/ca" {
  capabilities = ["read"]
}
# Allow the agent to generate dynamic database credentials
path "database/creds/incidents-reader" {
  capabilities = ["read"]
}
# Allow Vault token self-renewal
path "auth/token/renew-self" {
  capabilities = ["update"]
}
POLICY

echo "▶ Creating AppRole '${ROLE_NAME}'..."
vault write auth/approle/role/"${ROLE_NAME}" \
    token_policies="demo-agent" \
    token_ttl="1h" \
    token_max_ttl="4h" \
    secret_id_ttl="24h" \
    bind_secret_id=true

ROLE_ID=$(vault read -field=role_id auth/approle/role/"${ROLE_NAME}"/role-id)
SECRET_ID=$(vault write -f -field=secret_id auth/approle/role/"${ROLE_NAME}"/secret-id)

echo "  ✓ AppRole configured"

# ── 4. Output ────────────────────────────────────────────────────────────────
divider
echo ""
echo "Vault setup complete. Add these lines to your .env file:"
echo ""
echo "  VAULT_ROLE_ID=${ROLE_ID}"
echo "  VAULT_SECRET_ID=${SECRET_ID}"
echo ""

# Convenience: append to .env if it exists
ENV_FILE="$(dirname "$0")/../.env"
if [ -f "$ENV_FILE" ]; then
    # Update or append each variable
    for VAR in "VAULT_ROLE_ID=${ROLE_ID}" "VAULT_SECRET_ID=${SECRET_ID}"; do
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
