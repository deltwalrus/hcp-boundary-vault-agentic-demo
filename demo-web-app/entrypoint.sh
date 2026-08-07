#!/bin/bash
set -euo pipefail

echo "[entrypoint] Starting demo-web-app container..."

# Generate SSH host keys
ssh-keygen -A -q

# Fetch the Vault SSH CA public key so this host trusts certs signed by Vault.
# The agent's SSH key will be signed by Vault; no static credentials needed.
echo "[entrypoint] Fetching Vault SSH CA public key from ${VAULT_ADDR}..."
MAX_TRIES=30
for i in $(seq 1 "$MAX_TRIES"); do
    if curl -sf \
        -H "X-Vault-Token: ${VAULT_TOKEN}" \
        "${VAULT_ADDR}/v1/ssh/public_key" \
        -o /etc/ssh/trusted-user-ca-keys.pem 2>/dev/null \
        && [ -s /etc/ssh/trusted-user-ca-keys.pem ]; then
        echo "[entrypoint] Vault CA key loaded — SSH cert auth is ready"
        break
    fi
    echo "[entrypoint] Waiting for Vault SSH CA... (${i}/${MAX_TRIES})"
    sleep 2
    if [ "$i" -eq "$MAX_TRIES" ]; then
        echo "[entrypoint] WARNING: Could not fetch Vault CA key. SSH cert auth will fail."
        touch /etc/ssh/trusted-user-ca-keys.pem
    fi
done

echo "[entrypoint] Handing off to supervisord..."
exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
