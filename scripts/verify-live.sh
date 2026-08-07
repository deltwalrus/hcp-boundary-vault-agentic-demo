#!/usr/bin/env bash
# scripts/verify-live.sh
#
# Independent, real-time proof that the agent's Boundary sessions and Vault
# dynamic DB credentials are real -- not narrated terminal text. Run this in
# a SEPARATE terminal, visible throughout the demo. It pulls directly from
# the Boundary API and from Postgres itself; it has no dependency on, and
# never talks to, agent.py or mcp_server.py. If the audience doubts what the
# agent's own terminal is showing, this is the terminal that settles it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${REPO_ROOT}/.env"

[ -f "$ENV_FILE" ] && set -a && source "$ENV_FILE" && set +a

: "${BOUNDARY_ADDR:?Set BOUNDARY_ADDR in .env}"
: "${BOUNDARY_AUTH_METHOD_ID:?Set BOUNDARY_AUTH_METHOD_ID in .env}"
export BOUNDARY_ADDR

authenticate() {
    ADMIN_TOKEN_PW="${BOUNDARY_ADMIN_PASSWORD:-${BOUNDARY_PASSWORD:-}}"
    : "${ADMIN_TOKEN_PW:?Set BOUNDARY_ADMIN_PASSWORD (or BOUNDARY_PASSWORD) in .env}"
    export ADMIN_TOKEN_PW
    ADMIN_TOKEN=$(boundary authenticate password \
        -auth-method-id="${BOUNDARY_AUTH_METHOD_ID}" \
        -login-name="${BOUNDARY_ADMIN_LOGIN_NAME:-admin}" \
        -password env://ADMIN_TOKEN_PW \
        -format=json 2>/dev/null | jq -r '.item.attributes.token')
}

authenticate
LAST_AUTH=$SECONDS

# One full clear to start with a clean canvas; every refresh after this
# overwrites in place instead of blanking the screen, which is what actually
# causes the flashing -- a full clear+redraw every 2s reads as a flicker in
# any terminal (Ghostty included), not because anything is wrong.
clear 2>/dev/null || printf '\033[2J\033[H'

while true; do
    # Re-authenticate hourly -- admin tokens are short-lived.
    if (( SECONDS - LAST_AUTH > 3000 )); then
        authenticate
        LAST_AUTH=$SECONDS
    fi

    FRAME=$(
        set +e
        echo "══════════════════════════════════════════════════════════════════"
        echo " INDEPENDENT VERIFICATION — queried directly from Boundary + Postgres"
        echo " (this terminal knows nothing about agent.py; it's asking the source of truth)"
        echo " $(date '+%Y-%m-%d %H:%M:%S')"
        echo "══════════════════════════════════════════════════════════════════"
        echo ""
        echo "── HCP Boundary sessions (live, via API) — age, not Boundary's own 8h cap ──"
        SESSIONS=$(BOUNDARY_TOKEN="$ADMIN_TOKEN" boundary sessions list -token=env://BOUNDARY_TOKEN -format=json -recursive 2>/dev/null \
            | jq -r '.items[]? | "\(.status | ascii_upcase)\t\(.id)\ttarget=\(.target_id)\tage=\((now - (.created_time | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601)) | floor)s"' \
            | column -t -s $'\t')
        if [ -n "$SESSIONS" ]; then echo "$SESSIONS"; else echo "(none right now)"; fi
        echo ""
        echo "── Dynamic Vault-created Postgres roles (live, via psql) — real TTL ───────"
        ROLES=$(docker exec demo-postgres psql -U postgres -d incidents -t -c \
            "SELECT rolname, CASE WHEN rolvaliduntil > NOW() THEN 'expires in ' || to_char(rolvaliduntil - NOW(), 'MI:SS') ELSE 'EXPIRED (cleanup pending)' END AS ttl FROM pg_roles WHERE rolname LIKE 'v-%' ORDER BY rolvaliduntil;" 2>/dev/null \
            | sed '/^\s*$/d')
        if [ -n "$ROLES" ]; then echo "$ROLES"; else echo "(none right now)"; fi
        echo ""
        echo "(session age climbs then the row vanishes when the client disconnects --"
        echo " that churn, not a short TTL, is why Boundary sessions are ephemeral here)"
    )

    # Cursor home, overwrite each line (clearing any leftover tail from a
    # longer previous line), then clear whatever's left below if this frame
    # is shorter than the last one. No blank-screen moment, no flash.
    printf '\033[H'
    while IFS= read -r line; do
        printf '%s\033[K\n' "$line"
    done <<< "$FRAME"
    printf '\033[J'

    sleep 2
done
