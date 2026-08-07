#!/usr/bin/env python3
"""
demo-web-app — simple HTTP service used as the remediation target.

Reads PORT from /etc/demo-web-app.env at startup. The initial config ships
with PORT=not-a-number so the service crashes immediately, simulating the
production incident the AI agent must investigate and fix.
"""

import json
import logging
import os
import signal
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

ENV_FILE = "/etc/demo-web-app.env"

logging.basicConfig(
    stream=sys.stdout,
    level=logging.INFO,
    format="%(asctime)s [demo-web-app] %(levelname)s %(message)s",
)
log = logging.getLogger(__name__)


def read_env_file(path: str) -> dict:
    config = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    key, _, val = line.partition("=")
                    config[key.strip()] = val.strip()
    except FileNotFoundError:
        log.error("Config file not found: %s", path)
    return config


config = read_env_file(ENV_FILE)
port_str = config.get("PORT", "8080")

log.info("Read config: PORT=%s (from %s)", port_str, ENV_FILE)

try:
    PORT = int(port_str)
except ValueError:
    log.error("Invalid PORT value: '%s' — must be an integer", port_str)
    log.error("Service cannot start. Fix %s and restart.", ENV_FILE)
    sys.exit(1)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            body = json.dumps({"status": "healthy", "service": "demo-web-app", "port": PORT}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, fmt, *args):
        log.debug(fmt, *args)


def main():
    log.info("demo-web-app starting on port %d", PORT)
    server = HTTPServer(("0.0.0.0", PORT), Handler)

    def _shutdown(sig, _):
        log.info("Received signal %d — shutting down", sig)
        server.server_close()
        sys.exit(0)

    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)

    log.info("Listening on 0.0.0.0:%d — /health is ready", PORT)
    server.serve_forever()


if __name__ == "__main__":
    main()
