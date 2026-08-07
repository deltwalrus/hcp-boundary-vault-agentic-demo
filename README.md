# Boundary Agentic AI Demo

Independently reproduces the incident-response use case from
[Rethinking Infrastructure Access in the Age of Agentic AI](https://www.hashicorp.com/en/blog/rethinking-infrastructure-access-in-the-age-of-agentic-ai) —
built from scratch, since the original implementation isn't public.

An AI agent (Claude, driven via the `claude` CLI in headless mode — subscription
auth, no API key) investigates a production health-check failure, assesses
customer impact, and — with explicit operator approval — remediates the root
cause. Every action is brokered through **HCP Boundary** with ephemeral
credentials from **Vault**.

---

## What the demo shows

| Security property | How it's implemented |
|---|---|
| **No standing privileges** | Agent holds no SSH keys or DB passwords at rest |
| **Just-in-time SSH access** | Each SSH call generates a fresh Vault-signed certificate (5-min TTL, unique serial) |
| **Dynamic database credentials** | Vault creates a unique PostgreSQL role per session (5-min TTL, auto-revoked) |
| **Session brokering & audit** | Every connection is a Boundary session — recorded, attributable, terminatable |
| **Human-in-the-loop** | Agent cannot modify the system without explicit operator approval |

---

## Architecture

```
Operator's laptop
│
├── agent.py ──▶ `claude -p` (headless, subscription auth via `claude /login`)
│                     │
│                     └── mcp_server.py (MCP tool server, launched via --mcp-config)
│                           │
│                           ├── Vault API ──▶ local Vault (Docker :8200)
│                           │                  ├── SSH CA: signs ephemeral key per session
│                           │                  └── DB engine: creates unique Postgres role per session
│                           │
│                           └── boundary CLI ──▶ HCP Boundary (cloud control plane)
│                                                     └── Local Boundary Worker
│                                                             ├── demo-web-app (:2222 SSH)
│                                                             └── postgres      (:5432 TCP)
│
└── Docker Compose
      ├── vault      — dev mode, :8200
      ├── postgres   — incidents DB, :5432
      └── demo-web-app — Ubuntu + sshd + supervisor, :2222 / :8080
```

> **Why local Vault?** HCP Boundary's control plane (cloud) cannot reach services
> on your laptop. The Vault database secrets engine must connect to Postgres
> directly. Running Vault in Docker alongside the targets solves this cleanly.
> The API and configuration patterns are identical to HCP Vault Dedicated —
> point `VAULT_ADDR` at your HCP cluster to use it in a real environment where
> targets are cloud-hosted.

---

## Prerequisites

| Tool | Version | Install |
|---|---|---|
| Docker + Compose | ≥ 24 | docker.com |
| Boundary CLI | ≥ 0.15 | `brew install hashicorp/tap/boundary` |
| Python | ≥ 3.11 | python.org |
| OpenSSH | any | pre-installed on macOS/Linux |
| Claude Code CLI | — | code.claude.com — log in with `claude /login` (Pro/Max/Team/Enterprise subscription; no API key or separate billing) |
| HCP Boundary cluster | — | portal.cloud.hashicorp.com |

---

## Setup (one-time)

### 1. Clone and configure

```bash
git clone https://github.com/deltwalrus/hcp-boundary-vault-agentic-demo.git
cd hcp-boundary-vault-agentic-demo
cp .env.example .env
```

Edit `.env` and fill in:

- `BOUNDARY_ADDR` — your HCP cluster URL (e.g. `https://cluster.boundary.hashicorp.cloud`)
- `HCP_BOUNDARY_CLUSTER_ID` — the UUID from the HCP portal
- `BOUNDARY_AUTH_METHOD_ID` — find it in HCP Boundary → Auth Methods

No Anthropic API key needed — run `claude /login` once instead (subscription auth).

### 2. Start Docker services

```bash
docker compose up -d
```

This starts Vault (dev mode), PostgreSQL (pre-seeded), and demo-web-app.
The demo-web-app intentionally has `PORT=not-a-number` in its config — it will
fail to start until the agent fixes it.

### 3. Configure Vault

```bash
bash vault/setup.sh
```

This sets up:
- SSH secrets engine with a CA and `ubuntu` signing role
- Database secrets engine connected to Postgres
- AppRole for the agent with a minimal policy
- Outputs `VAULT_ROLE_ID` and `VAULT_SECRET_ID` → automatically written to `.env`

### 4. Configure HCP Boundary

```bash
bash boundary/setup.sh
```

This creates (idempotent):
- A `incident-response` project scope
- Static host catalog with hosts for demo-web-app (`:2222`) and postgres (`:5432`)
- SSH target and TCP target, both filtered to your local worker
- A `demo-agent` password account
- Outputs target IDs → automatically written to `.env`

### 5. Start the Boundary worker

In a separate terminal:

```bash
bash scripts/start-worker.sh
```

**First run only:** expect a wall of JSON event-log lines (Boundary's default
structured logging — normal, not an error). No manual UI step is needed — the
script detects the worker's registration token itself and registers it
automatically via `boundary workers create worker-led`, using the admin
credentials already in `.env`. See `DEMO_GUIDE.md` section 1.8 for the full walkthrough.

### 6. Install agent dependencies

Homebrew's Python refuses system-wide `pip install` (PEP 668) — use a virtual environment:

```bash
cd agent
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cd ..
```

---

## Running the demo

```bash
source agent/.venv/bin/activate
python agent/agent.py
```

### What you'll see

```
╭─────────────────────────────╮
│  P1 INCIDENT DETECTED       │
│  all access via HCP Boundary│
╰─────────────────────────────╯

╭─ Incoming Alert ────────────────────────────────────────────────╮
│  🚨 ALERT: Automated health check failure detected               │
│  Service: demo-web-app   Duration: ~18 minutes   Severity: P1   │
╰─────────────────────────────────────────────────────────────────╯

Launching agent via `claude` CLI (subscription auth, no API key)...

── Boundary sessions ──────────────────────────────────────────────
  [SSH →]  systemctl status demo-web-app
           cert serial: aa:bb:cc:...  │  broker: HCP Boundary (session recorded)

  [SSH →]  journalctl -n 20 -u demo-web-app
  [SSH →]  cat /etc/demo-web-app.env

  [DB  →]  SELECT c.name, c.user_count FROM customers c ...
           dynamic user: v-approle-incidents-reader-xxxx-1234567890

⚠  OPERATOR APPROVAL REQUIRED
╭─ Incident Summary ────────────────────────────────────────────────╮
│  Issue: /etc/demo-web-app.env contains PORT=not-a-number          │
│  Impact: 4 customers, 2915 users, 4 open tickets                  │
│  Fix:  sed -i 's/PORT=.*/PORT=8080/' /etc/demo-web-app.env        │
│         systemctl restart demo-web-app                            │
╰───────────────────────────────────────────────────────────────────╯
Approve remediation? [y/N]:
```

After you approve:

```
  [SSH →]  sed -i 's/PORT=.*/PORT=8080/' /etc/demo-web-app.env
  [SSH →]  systemctl restart demo-web-app
  [VERIFY] health endpoint → {"status":"healthy","port":8080}

── Incident response complete ─────────────────────────────────────
╭─ Security posture restored ──────────────────────────────────────╮
│  All sessions closed and logged in HCP Boundary.                 │
│  Vault credentials have expired. No standing access remains.     │
╰──────────────────────────────────────────────────────────────────╯
```

---

## Resetting for a repeat demo

Re-introduce the fault so you can demo again:

```bash
docker exec demo-web-app \
  bash -c "sed -i 's/PORT=.*/PORT=not-a-number/' /etc/demo-web-app.env && supervisorctl restart demo-web-app"
```

---

## Key talking points

### "The agent has no standing access"
When the Python process starts, it holds no SSH keys and no database passwords.
Every credential is fetched on-demand from Vault at the moment it's needed.

### "Each SSH connection is a unique identity"
The Vault SSH certificate shown in the output has a unique serial number. It expires
in 5 minutes. The private key is generated fresh, used once, and discarded.

### "The database user in the output was just created"
The `v-approle-incidents-reader-xxxx-timestamp` username in the results is a real
PostgreSQL role that Vault created seconds before the query ran. It will be
automatically dropped when the 5-minute lease expires.

### "Boundary is the only path to the target"
The SSH port (2222) and Postgres port (5432) are only reachable through the
Boundary worker. Every connection appears in HCP Boundary's session audit log
with session ID, duration, and operator identity.

### "No approval = no change"
The `request_approval` tool pauses the agent and waits for a human `[y/N]`.
If you decline, the agent stops and performs no remediation.

---

## File layout

```
hcp-boundary-vault-agentic-demo/
├── docker-compose.yml          — Vault, Postgres, demo-web-app
├── demo-web-app/
│   ├── Dockerfile              — Ubuntu 22.04, sshd, supervisor
│   ├── app.py                  — Python HTTP server (reads PORT from env file)
│   ├── entrypoint.sh           — fetches Vault CA key, starts supervisord
│   ├── supervisord.conf        — manages sshd + app
│   ├── sshd_config             — cert-based auth only
│   ├── systemctl-mock.sh       — wraps supervisorctl for familiar UX
│   └── journalctl-mock.sh      — tails the app log
├── postgres/
│   └── init.sql                — schema + seed (4 customers, 2915 users, 4 tickets)
├── vault/
│   └── setup.sh                — SSH CA + DB engine + AppRole
├── boundary/
│   ├── setup.sh                — project, hosts, targets, auth method
│   └── worker.hcl              — local PKI worker config
├── scripts/
│   ├── setup-all.sh            — one-shot full setup
│   ├── start-worker.sh         — start the local Boundary worker
│   ├── verify-live.sh          — independent proof terminal (Boundary sessions + live DB roles)
│   └── tail-vault-audit.sh     — tails Vault's own audit log, filtered to one line per operation
└── agent/
    ├── agent.py                — launches `claude -p` headlessly, renders the stream-json output
    ├── mcp_server.py            — MCP tool server: SSH/DB/approval/health-check tools
    └── requirements.txt
```
