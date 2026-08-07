#!/usr/bin/env python3
"""
MCP server exposing Boundary/Vault-backed incident-response tools.

Launched by the `claude` CLI (via --mcp-config) as a stdio subprocess. stdin/stdout
are reserved for the MCP JSON-RPC transport — every human-facing prompt (the
operator approval panel, the y/N confirmation) is written to /dev/tty instead,
never to stdout, or it would corrupt the protocol stream.
"""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import httpx
import psycopg2
from dotenv import load_dotenv
from mcp.server.fastmcp import FastMCP
from rich.console import Console
from rich.panel import Panel
from rich.rule import Rule

# ── Configuration ─────────────────────────────────────────────────────────────

load_dotenv(Path(__file__).parent.parent / ".env", override=True)

VAULT_ADDR              = os.environ.get("VAULT_ADDR",          "http://localhost:8200")
VAULT_DEV_TOKEN         = os.environ.get("VAULT_DEV_TOKEN",     "root")
VAULT_ROLE_ID           = os.environ.get("VAULT_ROLE_ID",       "")
VAULT_SECRET_ID         = os.environ.get("VAULT_SECRET_ID",     "")
BOUNDARY_ADDR           = os.environ.get("BOUNDARY_ADDR",       "")
BOUNDARY_AUTH_METHOD_ID = os.environ.get("BOUNDARY_AUTH_METHOD_ID", "")
BOUNDARY_LOGIN_NAME     = os.environ.get("BOUNDARY_LOGIN_NAME",     "demo-agent")
BOUNDARY_PASSWORD       = os.environ.get("BOUNDARY_PASSWORD",       "")
BOUNDARY_SSH_TARGET_ID  = os.environ.get("BOUNDARY_SSH_TARGET_ID",  "")
BOUNDARY_DB_TARGET_ID   = os.environ.get("BOUNDARY_DB_TARGET_ID",   "")

DB_PROXY_PORT = 16432   # local port for the Boundary TCP proxy to postgres

mcp = FastMCP("ops")

# ── Vault helpers ─────────────────────────────────────────────────────────────

_vault_token: str | None = None


def vault_token() -> str:
    global _vault_token
    if _vault_token:
        return _vault_token

    # Prefer AppRole (restricted policy); fall back to dev root token
    if VAULT_ROLE_ID and VAULT_SECRET_ID:
        resp = httpx.post(
            f"{VAULT_ADDR}/v1/auth/approle/login",
            json={"role_id": VAULT_ROLE_ID, "secret_id": VAULT_SECRET_ID},
            timeout=10,
        )
        resp.raise_for_status()
        _vault_token = resp.json()["auth"]["client_token"]
    else:
        _vault_token = VAULT_DEV_TOKEN

    return _vault_token


def vault_get(path: str) -> dict:
    resp = httpx.get(
        f"{VAULT_ADDR}/v1/{path}",
        headers={"X-Vault-Token": vault_token()},
        timeout=10,
    )
    resp.raise_for_status()
    return resp.json()


def vault_post(path: str, payload: dict) -> dict:
    resp = httpx.post(
        f"{VAULT_ADDR}/v1/{path}",
        headers={"X-Vault-Token": vault_token()},
        json=payload,
        timeout=10,
    )
    resp.raise_for_status()
    return resp.json()


# ── Boundary helpers ──────────────────────────────────────────────────────────

_boundary_token: str | None = None


def boundary_token() -> str:
    global _boundary_token
    if _boundary_token:
        return _boundary_token

    env = {**os.environ, "BOUNDARY_PASSWORD": BOUNDARY_PASSWORD}
    result = subprocess.run(
        [
            "boundary", "authenticate", "password",
            f"-auth-method-id={BOUNDARY_AUTH_METHOD_ID}",
            f"-login-name={BOUNDARY_LOGIN_NAME}",
            "-password", "env://BOUNDARY_PASSWORD",
            "-format=json",
        ],
        capture_output=True, text=True, env=env, timeout=30,
    )
    if result.returncode != 0:
        raise RuntimeError(f"Boundary auth failed:\n{result.stderr}")

    _boundary_token = json.loads(result.stdout)["item"]["attributes"]["token"]
    return _boundary_token


def _boundary_env() -> dict:
    return {
        **os.environ,
        "BOUNDARY_ADDR":  BOUNDARY_ADDR,
        "BOUNDARY_TOKEN": boundary_token(),
    }


# ── Operator-facing I/O (always via /dev/tty, never stdout/stdin) ─────────────

def _prompt_operator_approval(issue_summary: str, customer_impact: str, proposed_fix: str) -> bool:
    """
    Pause and ask the human operator to approve remediation.

    Reads/writes /dev/tty directly rather than stdin/stdout — those file
    descriptors carry the MCP JSON-RPC stream between this process and the
    `claude` CLI that spawned it, and touching them here would corrupt it.

    Opened as two separate handles, not a single "r+" handle: Python wraps
    "r+" mode in an io.BufferedRandom, whose init seeks to determine the
    current position, which raises "File or stream is not seekable" on a
    tty. Separate read-only and write-only handles avoid that entirely.
    """
    with open("/dev/tty", "w") as tty_out, open("/dev/tty", "r") as tty_in:
        console = Console(file=tty_out, force_terminal=True)
        console.print()
        console.print(Rule("[bold yellow]⚠  OPERATOR APPROVAL REQUIRED", style="yellow"))
        console.print()
        console.print(Panel(
            f"[bold]Issue[/bold]\n{issue_summary}\n\n"
            f"[bold]Customer Impact[/bold]\n{customer_impact}\n\n"
            f"[bold]Proposed Remediation[/bold]\n[cyan]{proposed_fix}[/cyan]",
            title="[yellow]Incident Summary",
            border_style="yellow",
            padding=(1, 2),
        ))
        console.print()
        tty_out.write("Approve remediation? [y/N]: ")
        tty_out.flush()
        answer = tty_in.readline().strip().lower()
        approved = answer in ("y", "yes")

        console.print()
        if approved:
            console.print("[green]✓ Remediation approved by operator[/green]")
        else:
            console.print("[red]✗ Remediation rejected by operator[/red]")
        console.print()

        return approved


# ── Tool implementations ───────────────────────────────────────────────────────

def _run_ssh_command(command: str) -> dict[str, Any]:
    """
    Execute a command on demo-web-app via a Boundary-managed SSH session.

    Credential flow:
      1. Generate an ephemeral ECDSA key pair (in memory / temp dir)
      2. Ask Vault to sign the public key -> unique signed certificate (5-min TTL)
      3. Open a Boundary session to the SSH target (session is recorded + audited)
      4. SSH through the Boundary proxy using the signed cert -- no password ever sent
      5. Temp dir and key material are deleted after the call
    """
    with tempfile.TemporaryDirectory() as tmpdir:
        key_path  = f"{tmpdir}/id_ecdsa"
        cert_path = f"{tmpdir}/id_ecdsa-cert.pub"

        subprocess.run(
            ["ssh-keygen", "-t", "ecdsa", "-b", "256", "-N", "", "-f", key_path],
            capture_output=True, check=True,
        )
        pub_key = Path(f"{key_path}.pub").read_text().strip()

        # NOTE: omit valid_principals here. Explicitly requesting it produces a
        # signed cert with an empty Principals field (a Vault quirk on this
        # role) which sshd then rejects outright. The role's default_user
        # ("ubuntu", set in vault/setup.sh) supplies it correctly instead.
        sign_resp = vault_post(
            "ssh/sign/ubuntu",
            {"public_key": pub_key},
        )
        cert_data = sign_resp["data"]["signed_key"]
        Path(cert_path).write_text(cert_data)

        serial = sign_resp["data"].get("serial_number", "unknown")

        # NOTE: the remote command MUST be passed via -remote-command, not as
        # a trailing positional after "--". That section is ssh-client-option
        # passthrough only; a trailing positional there is parsed by ssh as
        # the destination hostname, not a remote command.
        result = subprocess.run(
            [
                "boundary", "connect", "ssh",
                "-token=env://BOUNDARY_TOKEN",
                f"-target-id={BOUNDARY_SSH_TARGET_ID}",
                "-username=ubuntu",
                f"-remote-command={command}",
                "--",
                "-o", f"CertificateFile={cert_path}",
                "-i",  key_path,
                "-o", "StrictHostKeyChecking=no",
                "-o", "UserKnownHostsFile=/dev/null",
                "-o", "LogLevel=ERROR",
            ],
            capture_output=True, text=True,
            env=_boundary_env(),
            timeout=60,
        )

    return {
        "stdout":      result.stdout,
        "stderr":      result.stderr,
        "exit_code":   result.returncode,
        "cert_serial": serial,
        "_security": {
            "method":      "Vault SSH signed certificate",
            "cert_ttl":    "5 minutes",
            "unique_cert": True,
            "broker":      "HCP Boundary (session recorded)",
        },
    }


def _run_db_query(query: str) -> dict[str, Any]:
    """
    Execute a SQL query on the incidents database via a Boundary-managed TCP session.

    Credential flow:
      1. Request dynamic credentials from Vault database secrets engine
         -> Vault creates a unique PostgreSQL role (e.g. v-approle-incidents-reader-xxxx)
      2. Open a Boundary TCP session to the postgres target (proxied through worker)
      3. Connect psycopg2 to the local Boundary proxy with the dynamic credentials
      4. Vault lease expires in 15 minutes; the DB role is auto-revoked
    """
    creds_resp = vault_get("database/creds/incidents-reader")
    db_username = creds_resp["data"]["username"]
    db_password = creds_resp["data"]["password"]
    lease_id    = creds_resp.get("lease_id", "")
    lease_ttl   = creds_resp.get("lease_duration", 900)

    proxy_proc = subprocess.Popen(
        [
            "boundary", "connect",
            "-token=env://BOUNDARY_TOKEN",
            f"-target-id={BOUNDARY_DB_TARGET_ID}",
            f"-listen-port={DB_PROXY_PORT}",
            "-listen-addr=127.0.0.1",
        ],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        env=_boundary_env(),
    )

    rows = []
    columns = []
    error = None

    try:
        time.sleep(1.5)

        conn = psycopg2.connect(
            host="127.0.0.1",
            port=DB_PROXY_PORT,
            database="incidents",
            user=db_username,
            password=db_password,
            connect_timeout=10,
        )
        try:
            cur = conn.cursor()
            cur.execute(query)
            columns = [d[0] for d in (cur.description or [])]
            rows    = [list(r) for r in cur.fetchall()]
            cur.close()
        finally:
            conn.close()
    except Exception as exc:
        error = str(exc)
    finally:
        proxy_proc.terminate()
        try:
            proxy_proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proxy_proc.kill()

    return {
        "columns":     columns,
        "rows":        rows,
        "row_count":   len(rows),
        "error":       error,
        "_security": {
            "db_username":  db_username,
            "lease_id":     lease_id,
            "lease_ttl_s":  lease_ttl,
            "unique_user":  True,
            "broker":       "HCP Boundary (session recorded)",
            "note":         "This DB role is auto-revoked when the lease expires",
        },
    }


def _verify_health() -> dict[str, Any]:
    """Check service status and health endpoint after remediation."""
    status_result = _run_ssh_command("systemctl status demo-web-app")
    health_result = _run_ssh_command("curl -sf http://localhost:8080/health || echo 'HEALTH_CHECK_FAILED'")
    return {
        "service_status": status_result["stdout"],
        "health_endpoint": health_result["stdout"].strip(),
        "healthy": "HEALTH_CHECK_FAILED" not in health_result["stdout"],
    }


# ── MCP tool registration ──────────────────────────────────────────────────────

@mcp.tool()
def run_ssh_command(command: str) -> dict[str, Any]:
    """Execute a shell command on the demo-web-app production server via a
    Boundary-managed SSH session. Each call generates a fresh, unique
    Vault-signed SSH certificate (5-min TTL) -- the agent never handles a
    password or a long-lived key. The session is brokered and recorded by
    HCP Boundary."""
    return _run_ssh_command(command)


@mcp.tool()
def run_db_query(query: str) -> dict[str, Any]:
    """Execute a read-only SQL query on the incidents PostgreSQL database via
    a Boundary-managed TCP session. Vault generates a unique, short-lived
    database role for each call (15-min TTL). Only SELECT statements are
    allowed by the Vault role."""
    return _run_db_query(query)


@mcp.tool()
def request_approval(issue_summary: str, customer_impact: str, proposed_fix: str) -> dict[str, Any]:
    """Request explicit operator approval before making any change to the
    production system. REQUIRED before calling run_ssh_command for any
    write/mutating operation. Explain the issue, impact, and exact proposed
    change. Pauses and waits for a live human y/N response."""
    approved = _prompt_operator_approval(issue_summary, customer_impact, proposed_fix)
    if approved:
        return {"approved": True, "timestamp": datetime.now(timezone.utc).isoformat()}
    return {"approved": False, "reason": "operator declined"}


@mcp.tool()
def verify_health() -> dict[str, Any]:
    """Verify the demo-web-app is healthy after remediation: checks
    systemctl status and the /health HTTP endpoint."""
    return _verify_health()


if __name__ == "__main__":
    mcp.run()
