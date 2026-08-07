#!/usr/bin/env bash
# scripts/tail-vault-audit.sh
#
# Optional fourth terminal: a clean, live view of Vault's own audit log --
# every SSH cert signed, every dynamic DB credential issued, straight from
# Vault itself. Sensitive values are HMAC-hashed by Vault's audit device
# (never plaintext), so this is safe to leave on screen during a demo.
#
# Requires vault/setup.sh to have enabled the file audit device (it does
# this automatically now). Run this any time after that.

set -euo pipefail

echo "Tailing Vault's audit log (Ctrl+C to stop)..."
echo "path = what Vault operation happened; type = request (asked) or response (answered)"
echo ""

docker exec demo-vault tail -F /vault/logs/audit.log 2>/dev/null | jq -r --unbuffered '
    "\(.time // "?" | .[11:19])  \(.type)\t\(.request.operation // "-")\t\(.request.path // "-")"
'
