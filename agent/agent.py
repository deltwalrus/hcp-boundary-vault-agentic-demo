#!/usr/bin/env python3
"""
HashiCorp Boundary Agentic AI Demo
────────────────────────────────────────────────────────────────────────────────
Demonstrates just-in-time infrastructure access for an AI incident-response agent.

Security properties shown:
  • All access is session-based — the agent holds no standing privileges
  • SSH credentials are ephemeral Vault-signed certificates (unique serial per session)
  • Database credentials are dynamic Vault leases (unique username per session)
  • Every session is brokered, recorded, and auditable through HCP Boundary
  • Remediation requires explicit operator approval before any change is made

Model access:
  This script drives the `claude` CLI in headless mode (`claude -p`) rather than
  calling the Anthropic API directly. When you're logged in via `claude /login`
  (Claude Pro/Max/Team/Enterprise), headless invocations draw on that same
  subscription — no separate ANTHROPIC_API_KEY or metered API billing required.
  Custom tools (SSH, DB, approval gate, health check) are exposed to the CLI as
  an MCP server (mcp_server.py), launched automatically via --mcp-config.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

from dotenv import load_dotenv
from rich.console import Console
from rich.markdown import Markdown
from rich.markup import escape as rich_escape
from rich.panel import Panel
from rich.rule import Rule

# ── Configuration ─────────────────────────────────────────────────────────────

ROOT_DIR = Path(__file__).parent.parent
load_dotenv(ROOT_DIR / ".env", override=True)

BOUNDARY_ADDR          = os.environ.get("BOUNDARY_ADDR",         "")
BOUNDARY_SSH_TARGET_ID = os.environ.get("BOUNDARY_SSH_TARGET_ID", "")
BOUNDARY_DB_TARGET_ID  = os.environ.get("BOUNDARY_DB_TARGET_ID",  "")
AGENT_MODEL            = os.environ.get("AGENT_MODEL",            "sonnet")

MCP_SERVER_PATH = Path(__file__).parent / "mcp_server.py"
MCP_TOOL_PREFIX = "mcp__ops__"
MCP_TOOLS       = ["run_ssh_command", "run_db_query", "request_approval", "verify_health"]

console = Console()

# ── System prompt & alert ──────────────────────────────────────────────────────

SYSTEM_PROMPT = """\
You are an autonomous incident-response agent for the HashiCorp demo environment.
Your job: investigate production incidents, assess customer impact, and — with
explicit operator approval — remediate the root cause.

Security constraints you MUST follow:
1. Never store or log credentials. All credentials are fetched per-session from Vault.
2. Before any write/change to the production system, call request_approval first.
   If the operator declines, stop immediately.
3. Only use read operations during investigation. No changes until approved.
4. Use run_db_query only for SELECT statements.

Investigation workflow:
1. Check service status (systemctl status demo-web-app)
2. Review recent logs (journalctl -n 30 -u demo-web-app)
3. Inspect the environment config (cat /etc/demo-web-app.env)
4. Test the health endpoint (curl -sf http://localhost:8080/health)
5. Query the incidents database to assess customer impact
6. Summarise findings and call request_approval with clear impact + proposed fix
7. If approved: apply the minimal fix, then verify_health

Be concise, factual, and precise. Every SSH command and DB query opens a new
Boundary session with a fresh Vault credential — this is visible in the results.
Only use the run_ssh_command, run_db_query, request_approval, and verify_health
tools — do not use any other tools.
"""

INITIAL_MESSAGE = """\
🚨 ALERT: Automated health check failure detected

Service:   demo-web-app
Check:     HTTP /health endpoint — connection refused
Duration:  ~18 minutes
Severity:  P1 — multiple enterprise customers affected

Monitoring indicates the service is not accepting connections on any replica.
Please investigate, assess impact, and remediate if appropriate.
"""


# ── MCP config ──────────────────────────────────────────────────────────────────

def write_mcp_config() -> Path:
    config = {
        "mcpServers": {
            "ops": {
                "command": sys.executable,
                "args": [str(MCP_SERVER_PATH)],
            }
        }
    }
    fd, path = tempfile.mkstemp(prefix="boundary-demo-mcp-", suffix=".json")
    with os.fdopen(fd, "w") as f:
        json.dump(config, f)
    return Path(path)


# ── UI helpers ─────────────────────────────────────────────────────────────────

def print_tool_call(name: str, inputs: dict) -> None:
    short_name = name.removeprefix(MCP_TOOL_PREFIX)
    label = {
        "run_ssh_command":  "SSH →",
        "run_db_query":     "DB  →",
        "request_approval": "APPROVAL",
        "verify_health":    "VERIFY",
    }.get(short_name, short_name)

    detail = inputs.get("command") or inputs.get("query") or ""
    if detail:
        detail = f"[dim]{detail[:80]}{'…' if len(detail) > 80 else ''}[/dim]"

    console.print(f"  [bold cyan][{label}][/bold cyan] {detail}")


def print_security_banner(result: dict) -> None:
    sec = result.get("_security")
    if not sec:
        return
    parts = []
    if sec.get("db_username"):
        parts.append(f"[dim]dynamic user:[/] [green]{sec['db_username']}[/green]")
    if result.get("cert_serial"):
        parts.append(f"[dim]cert serial:[/] [green]{result['cert_serial']}[/green]")
    if sec.get("broker"):
        parts.append(f"[dim]broker:[/] {sec['broker']}")
    if parts:
        console.print("  " + "  │  ".join(parts))


def print_tool_failure(is_error: bool, result: dict | None, raw_text: str) -> None:
    """Surface real tool failures. Without this, a failing SSH/DB/health call
    is silently swallowed and the model has to guess at a root cause instead
    of seeing the actual error."""
    if is_error:
        console.print(f"  [bold red]tool error:[/] {rich_escape(raw_text.strip()[:500])}")
        return
    if result is None:
        return
    stderr = result.get("stderr")
    error = result.get("error")
    exit_code = result.get("exit_code")
    # run_db_query's shape is the only tool result carrying "columns"/"row_count".
    # A SQL error there means the agent guessed a wrong table/column name while
    # exploring the schema -- its own trial-and-error, not an infra fault -- so
    # it's styled distinctly from a real failure (SSH/health/session errors).
    is_db_query = "columns" in result and "row_count" in result
    if error:
        if is_db_query:
            console.print(f"  [dim yellow]schema probe (agent iterating, not an infra fault):[/] {rich_escape(str(error)[:500])}")
        else:
            console.print(f"  [red]error:[/] {rich_escape(str(error)[:500])}")
    if stderr and stderr.strip():
        console.print(f"  [red]stderr:[/] {rich_escape(stderr.strip()[:500])}")
    if exit_code not in (None, 0):
        console.print(f"  [yellow]exit code:[/] {exit_code}")


def _extract_tool_result_dict(content: Any) -> dict | None:
    """Best-effort extraction of the structured dict a tool call returned.

    `content` may be a plain JSON string (what FastMCP tools actually send),
    or a list of content blocks (text / structuredContent) per the MCP spec.
    """
    if isinstance(content, str):
        try:
            parsed = json.loads(content)
        except (json.JSONDecodeError, TypeError):
            return None
        return parsed if isinstance(parsed, dict) else None

    if not isinstance(content, list):
        return None

    for block in content:
        if not isinstance(block, dict):
            continue
        structured = block.get("structuredContent") or block.get("structured_content")
        if isinstance(structured, dict):
            return structured
        text = block.get("text")
        if isinstance(text, str):
            try:
                parsed = json.loads(text)
            except (json.JSONDecodeError, TypeError):
                continue
            if isinstance(parsed, dict):
                return parsed
    return None


# ── Stream-JSON event handling ──────────────────────────────────────────────────

def handle_event(event: dict) -> str | None:
    """Process one stream-json event. Returns the final result text, if any."""
    etype = event.get("type")

    if etype == "assistant":
        for block in event.get("message", {}).get("content", []):
            if block.get("type") == "text" and block.get("text", "").strip():
                console.print(Markdown(block["text"]))
            elif block.get("type") == "tool_use":
                console.print()
                console.print(Rule("[dim]Boundary sessions", style="dim"))
                print_tool_call(block.get("name", ""), block.get("input", {}))

    elif etype == "user":
        for block in event.get("message", {}).get("content", []):
            if block.get("type") == "tool_result":
                content = block.get("content", [])
                is_error = bool(block.get("is_error"))
                result_dict = _extract_tool_result_dict(content)
                if result_dict:
                    print_security_banner(result_dict)
                if isinstance(content, str):
                    raw_text = content
                elif isinstance(content, list):
                    raw_text = "\n".join(
                        b.get("text", "") for b in content
                        if isinstance(b, dict) and b.get("type") == "text"
                    )
                else:
                    raw_text = str(content)
                print_tool_failure(is_error, result_dict, raw_text)

    elif etype == "result":
        return event.get("result", "")

    return None


# ── Main agent run ────────────────────────────────────────────────────────────

def run_agent() -> None:
    console.print()
    console.print(Panel.fit(
        "[bold red]P1 INCIDENT DETECTED[/bold red]\n"
        "[dim]Agentic AI response initiated — all access via HCP Boundary[/dim]",
        border_style="red",
        padding=(0, 2),
    ))
    console.print()

    # ── Pre-flight checks ─────────────────────────────────────────────────────
    missing = []
    if not BOUNDARY_SSH_TARGET_ID: missing.append("BOUNDARY_SSH_TARGET_ID")
    if not BOUNDARY_DB_TARGET_ID:  missing.append("BOUNDARY_DB_TARGET_ID")
    if not BOUNDARY_ADDR:         missing.append("BOUNDARY_ADDR")
    if missing:
        console.print(f"[red]Missing .env variables: {', '.join(missing)}[/red]")
        console.print("Copy .env.example to .env and fill in all values.")
        sys.exit(1)

    if shutil.which("claude") is None:
        console.print("[red]The `claude` CLI is not on PATH.[/red]")
        console.print("Install Claude Code and run `claude /login` before running this demo.")
        sys.exit(1)

    # ── Alert ────────────────────────────────────────────────────────────────
    console.print(Panel(
        INITIAL_MESSAGE.strip(),
        title="[red]Incoming Alert",
        border_style="red",
        padding=(1, 2),
    ))
    console.print()

    # ── Launch claude in headless mode with our MCP tool server ──────────────
    mcp_config_path = write_mcp_config()
    allowed_tools = ",".join(f"{MCP_TOOL_PREFIX}{name}" for name in MCP_TOOLS)

    cmd = [
        "claude", "-p", INITIAL_MESSAGE,
        "--mcp-config", str(mcp_config_path),
        "--model", AGENT_MODEL,
        "--append-system-prompt", SYSTEM_PROMPT,
        "--allowedTools", allowed_tools,
        "--output-format", "stream-json",
        "--verbose",
    ]

    console.print("[dim]Launching incident-response agent...[/dim]")
    console.print()

    final_result = ""
    try:
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        assert proc.stdout is not None
        for line in proc.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            result = handle_event(event)
            if result is not None:
                final_result = result

        proc.wait()
        if proc.returncode != 0:
            stderr = proc.stderr.read() if proc.stderr else ""
            console.print(f"[red]claude exited with status {proc.returncode}[/red]")
            if stderr.strip():
                console.print(f"[red]{stderr.strip()}[/red]")
    finally:
        mcp_config_path.unlink(missing_ok=True)

    # ── Closing banner ────────────────────────────────────────────────────────
    console.print()
    console.print(Rule("[green]Incident response complete", style="green"))
    console.print()
    if final_result:
        console.print(Markdown(final_result))
        console.print()
    console.print(Panel(
        "[green]All sessions have been closed and logged in HCP Boundary.\n"
        "Vault credentials have expired or will expire shortly.\n"
        "No standing access remains.[/green]",
        title="Security posture restored",
        border_style="green",
        padding=(0, 2),
    ))
    console.print()


if __name__ == "__main__":
    run_agent()
