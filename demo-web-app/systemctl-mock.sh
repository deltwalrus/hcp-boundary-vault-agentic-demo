#!/bin/bash
# Thin wrapper so the AI agent can use familiar systemctl commands.
# Delegates to supervisorctl under the hood.

CMD="${1:-}"
SVC="${2:-demo-web-app}"

# Normalise service name (strip .service suffix)
PROC="${SVC%.service}"

# supervisorctl talks to a root-owned socket -- sudo here so callers can use
# plain systemctl-style commands without needing to know that.
case "$CMD" in
    status)
        sudo supervisorctl status "$PROC" 2>/dev/null
        STATUS=$(sudo supervisorctl status "$PROC" 2>/dev/null | awk '{print $2}')
        [[ "$STATUS" == "RUNNING" ]] && exit 0 || exit 3
        ;;
    start)   sudo supervisorctl start   "$PROC" ;;
    stop)    sudo supervisorctl stop    "$PROC" ;;
    restart) sudo supervisorctl restart "$PROC" ;;
    reload)  sudo supervisorctl restart "$PROC" ;;
    is-active)
        STATUS=$(sudo supervisorctl status "$PROC" 2>/dev/null | awk '{print $2}')
        if [[ "$STATUS" == "RUNNING" ]]; then echo "active"; exit 0
        else echo "inactive"; exit 3; fi
        ;;
    *)
        echo "Usage: systemctl {start|stop|restart|reload|status|is-active} [service]" >&2
        exit 1
        ;;
esac
