#!/usr/bin/env bash
# scripts/setup-all.sh
# One-shot setup: brings up Docker Compose then runs Vault and Boundary setup scripts.
# Safe to re-run (all steps are idempotent).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${REPO_ROOT}/.env"

cd "$REPO_ROOT"

# Load .env
if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: .env not found. Copy .env.example to .env and fill in your credentials." >&2
    exit 1
fi
set -a && source "$ENV_FILE" && set +a

echo "════════════════════════════════════════════════"
echo "  Boundary Agentic AI Demo — Full Setup"
echo "════════════════════════════════════════════════"
echo ""

# 1. Start Docker Compose
echo "▶ Starting Docker Compose services..."
docker compose up -d --build
echo ""

# 2. Wait for all services to be healthy
echo "▶ Waiting for services to be healthy..."
for SVC in demo-vault demo-postgres demo-web-app; do
    printf "  Waiting for %s..." "$SVC"
    for _ in $(seq 1 60); do
        STATUS=$(docker inspect --format='{{.State.Health.Status}}' "$SVC" 2>/dev/null || echo "starting")
        if [ "$STATUS" = "healthy" ] || [ "$STATUS" = "" ]; then
            echo " ready"
            break
        fi
        printf "."
        sleep 2
    done
done
echo ""

# 3. Configure Vault
echo "▶ Running Vault setup..."
bash "${REPO_ROOT}/vault/setup.sh"

# 4. Configure Boundary
echo ""
echo "▶ Running Boundary setup..."
bash "${REPO_ROOT}/boundary/setup.sh"

echo ""
echo "════════════════════════════════════════════════"
echo "  Setup complete!"
echo ""
echo "  Next steps:"
echo "  1. Start the Boundary worker (registers itself automatically, no UI step):"
echo "     bash scripts/start-worker.sh"
echo ""
echo "  2. Run the AI agent demo:"
echo "     cd agent && pip install -r requirements.txt"
echo "     python agent.py"
echo "════════════════════════════════════════════════"
