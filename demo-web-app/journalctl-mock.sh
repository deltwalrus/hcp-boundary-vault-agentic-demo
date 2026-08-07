#!/bin/bash
# Minimal journalctl shim — tails the supervisor-managed application log.
LINES=50
LOG_FILE="/var/log/demo-web-app.log"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--lines) LINES="$2"; shift ;;
        -u|--unit)  shift ;;  # ignore unit arg, we only have one log
        -f|--follow) exec tail -f "$LOG_FILE" ;;
        *) ;;
    esac
    shift
done

tail -n "$LINES" "$LOG_FILE" 2>/dev/null || echo "(log not yet available)"
