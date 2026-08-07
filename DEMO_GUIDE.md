# Demo Guide — Boundary Agentic AI

This demo independently reproduces the incident-response scenario described in
[Rethinking Infrastructure Access in the Age of Agentic AI](https://www.hashicorp.com/en/blog/rethinking-infrastructure-access-in-the-age-of-agentic-ai) —
built from scratch, since the original implementation isn't public. The goal
is to make the case for the HCP Boundary + Vault combination as the access
model for agentic AI workflows: no standing credentials, every session
ephemeral and brokered, every action audited.

---

## Section 1 — Initial Setup (One-Time)

Do these steps once. After this, skip directly to Section 2 for each demo run.

### 1.1 Install prerequisites

| Tool | Install |
|---|---|
| Docker Desktop | https://www.docker.com/products/docker-desktop |
| Boundary CLI | `brew install hashicorp/tap/boundary` |
| Python 3.11+ | `brew install python` |
| OpenSSH client | Pre-installed on macOS |
| Claude Code CLI | [code.claude.com](https://code.claude.com) — requires a Claude Pro/Max/Team/Enterprise subscription |

Verify:
```bash
docker --version
boundary version
python3 --version
ssh -V
claude --version
```

Log in once with your subscription (not an API key):

```bash
claude /login
```

The agent runs `claude` in headless mode and reuses this login — no `ANTHROPIC_API_KEY` or separate API billing is needed.

### 1.2 Provision (or locate) your HCP Boundary cluster

You need your own HCP Boundary cluster — this demo doesn't ship one. If you don't already have one, create a cluster at [portal.cloud.hashicorp.com](https://portal.cloud.hashicorp.com) (Standard tier if you want session recording for the demo's closing UI walkthrough — see Section 3).

Once it exists, gather these values:

| Setting | Where to find it |
|---|---|
| **Cluster URL** | HCP portal → your cluster → Overview |
| **Cluster ID** | The UUID embedded in the Cluster URL — not shown as a separate field anywhere in the portal |
| **Admin login / password** | Whatever you set when you created the cluster |
| **Tier** | Standard gets you session recording; Essentials works fine without it |

### 1.3 Get your HCP Boundary auth method ID

1. In the HCP Boundary UI, go to **Auth Methods**
2. You'll see a pre-created password auth method — note its ID (starts with `ampw_`)

This is the auth method your admin login (and the demo agent's own account, created in 1.7) authenticates against — HCP-managed clusters only accept `:authenticate` calls against this original pre-provisioned method, not one created afterward.

### 1.4 Clone and configure the project

```bash
cd ~/src
git clone https://github.com/deltwalrus/hcp-boundary-vault-agentic-demo.git
cd hcp-boundary-vault-agentic-demo
cp .env.example .env
```

Open `.env` and fill in the values you gathered in 1.2 and 1.3:

```bash
# Required — from HCP portal → Boundary → your cluster
BOUNDARY_ADDR=https://<cluster-id>.boundary.hashicorp.cloud
HCP_BOUNDARY_CLUSTER_ID=<cluster-id>
BOUNDARY_AUTH_METHOD_ID=ampw_XXXXXXXXXX

# Required — HCP Boundary admin credentials (set when creating cluster)
BOUNDARY_LOGIN_NAME=admin
BOUNDARY_PASSWORD=<your-admin-password>
```

No Anthropic API key is needed — the agent authenticates through your `claude /login` session (see 1.1). Just make sure you've run that once before 1.10.

Leave everything else blank for now — the setup scripts fill it in automatically.

### 1.5 Build Docker images and start services

```bash
docker compose up -d --build
```

This builds the demo-web-app image and starts three containers. Wait ~30 seconds, then verify:

```bash
docker compose ps
```

All three should show `healthy` or `running`:
- `demo-vault` — Vault in dev mode on port 8200
- `demo-postgres` — PostgreSQL on port 5432
- `demo-web-app` — Ubuntu with sshd on port 2222, web app on port 8080

### 1.6 Configure Vault

```bash
bash vault/setup.sh
```

(The script loads `.env` itself — no need to `source` it first.)

This creates:
- SSH Certificate Authority
- SSH signing role for the `ubuntu` user (5-min certificate TTL)
- Database secrets engine connected to PostgreSQL
- Dynamic credentials role for the incidents database
- AppRole for the AI agent with minimal permissions

At the end it prints `VAULT_ROLE_ID` and `VAULT_SECRET_ID` and writes them to `.env` automatically.

Expected output ends with:
```
Vault setup complete. Add these lines to your .env file:
  VAULT_ROLE_ID=...
  VAULT_SECRET_ID=...
  (also written to .env)
```

### 1.7 Configure HCP Boundary resources

```bash
bash boundary/setup.sh
```

(Also loads `.env` itself.)

This creates:
- `incident-response` project scope
- Static host catalog with hosts for demo-web-app (`:2222`) and postgres (`:5432`)
- SSH target and TCP target (filtered to your local worker)
- `demo-agent` password account

At the end it writes target IDs to `.env` automatically.

Expected output ends with:
```
Boundary setup complete. Add these to your .env file:
  BOUNDARY_SSH_TARGET_ID=ttcp_...
  BOUNDARY_DB_TARGET_ID=ttcp_...
  (also written to .env)
```

### 1.8 Register the Boundary worker

Open a **dedicated terminal tab** (leave it open — this runs continuously):

```bash
cd ~/src/hcp-boundary-vault-agentic-demo
bash scripts/start-worker.sh
```

The first time you run this, expect a wall of JSON event-log lines (Boundary's default structured logging — normal, not an error). No manual step is needed: the script detects the worker's registration token itself and registers it automatically via `boundary workers create worker-led`, using the admin credentials already in `.env`. Watch for:

```
✓ Worker registered automatically — no UI step needed
```

followed shortly by `"worker has successfully authenticated"` and `"upstream connection is ready"` in the JSON log stream.

**You only do this once per machine.** The worker stores its state in `boundary/auth/` (gitignored, deliberately *not* under `/tmp` — macOS periodically sweeps files there after a few idle days, which would otherwise silently break this between prepping the demo and actually presenting it) and will reconnect automatically on future runs without needing re-registration. It only needs to repeat if `boundary/auth/` is deleted or you're setting up on a new machine — and if it does, it's still fully automatic, no UI required.

### 1.9 Install Python dependencies

Homebrew's Python refuses system-wide `pip install` (PEP 668) — use a virtual environment:

```bash
cd ~/src/hcp-boundary-vault-agentic-demo/agent
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cd ..
```

`agent/mcp_server.py` (the SSH/DB/approval/health-check tools) needs no separate install or start step — `agent.py` launches it automatically as an MCP server each time it invokes `claude`.

**The venv needs to be active any time you run the agent** — see 1.10 and Section 2.6.

### 1.10 Verify the setup end-to-end

```bash
source agent/.venv/bin/activate
python agent/agent.py
```

`agent.py` shells out to `claude -p` in headless mode using your `claude /login` session — you should see it receive the alert and begin investigating. If you see an auth error here, run `claude /login` again. The first complete run also proves your Boundary worker is routing correctly.

---

## Section 2 — Starting Up for Each Demo Run

Do these steps every time you want to run a practice or live demo.

### 2.1 Start Docker services (if not already running)

```bash
cd ~/src/hcp-boundary-vault-agentic-demo
docker compose up -d
```

If containers are already running this is harmless. Wait a few seconds and verify:

```bash
docker compose ps
```

### 2.2 Re-run Vault + Boundary setup (always — do not skip this)

```bash
bash vault/setup.sh
bash boundary/setup.sh
docker compose restart demo-web-app
```

**Do this every single time, even if you're "pretty sure" nothing changed.** Vault runs in dev mode with no persistent storage — it loses its SSH CA, database role, and AppRole credentials on *any* restart of the Vault container, not just `docker compose down`. `docker compose stop` + `start` wipes it too (confirmed directly — this is not a hypothetical). If you skip this and Vault silently got a fresh CA since the last run, SSH will fail with `Permission denied (publickey)` even though the credential-signing step itself succeeds, because `demo-web-app` will still be trusting the *old* CA until the `docker compose restart` above re-fetches the current one.

All three commands are idempotent and take well under 30 seconds combined — cheaper than debugging why SSH is failing five minutes before you're presenting.

### 2.3 Introduce the fault (reset the broken state)

The demo-web-app starts healthy if you've run it before. Break it:

```bash
docker exec demo-web-app \
  bash -c "sed -i 's/PORT=.*/PORT=not-a-number/' /etc/demo-web-app.env && supervisorctl restart demo-web-app"
```

Verify it's broken (should fail or return connection refused):

```bash
curl -sf http://localhost:8080/health || echo "Service is DOWN — ready for demo"
```

### 2.4 Start the Boundary worker

Open a **dedicated terminal tab** and keep it running in the background:

```bash
cd ~/src/hcp-boundary-vault-agentic-demo
bash scripts/start-worker.sh
```

You should see `✓ Worker already registered — reconnected` (normal case) or, only if `boundary/auth/` was deleted or this is a new machine, `✓ Worker registered automatically — no UI step needed` followed by `"worker has successfully authenticated"` in the log stream. If it hangs or errors, check that Docker is running and step 2.2 actually completed (Vault must be up and configured before the worker starts).

### 2.5 Start the independent verification terminal (do this — it's the point)

Open a **third terminal tab** and keep it visible throughout the demo:

```bash
cd ~/src/hcp-boundary-vault-agentic-demo
bash scripts/verify-live.sh
```

This is the answer to "how do I know this isn't just text on a screen?" It talks directly to the Boundary API and to Postgres itself — it has no code path through `agent.py` or `mcp_server.py` at all, so it cannot be faked by anything the agent's own terminal prints. It refreshes every 2 seconds showing:

- **Live Boundary sessions**, pulled straight from `boundary sessions list` — a real session ID and status will appear the moment the agent opens one, and disappear when it closes.
- **Live dynamic Postgres roles**, queried straight from `pg_roles` — a `v-approle-incident-...` username with a real `rolvaliduntil` timestamp will appear the moment `run_db_query` fires, and the row will be gone once its lease expires.

When nothing is happening, both sections are empty — that emptiness is itself the proof. Point this out explicitly: *"There's a whole terminal here, running independently of my agent, that only shows things while they're actually alive. If I were faking this, this terminal would have no idea."*

### 2.6 Open the HCP Boundary UI

Open your browser to https://portal.cloud.hashicorp.com and navigate to your Boundary cluster. Click **Sessions** in the left nav — have this visible during the demo so you can show sessions appearing in real time. (This is the same data `verify-live.sh` is pulling from the API — showing both the raw API output *and* the polished UI back-to-back is what actually lands with a skeptical audience.)

### 2.7 Switch to your main demo terminal

Separate from the worker and verification terminals:

```bash
cd ~/src/hcp-boundary-vault-agentic-demo
```

### 2.8 Run the agent (when ready to demo)

```bash
source agent/.venv/bin/activate
python agent/agent.py
```

(`agent.py` loads `.env` itself — no separate step needed. The venv, however, must be activated each run.)

---

## Section 3 — Demo Script

**Total runtime: ~5–7 minutes** (varies with how long you pause for discussion)

---

### Opening (30 seconds — say before starting the agent)

> "The challenge with agentic AI in infrastructure is the same challenge we've always had with service accounts and automation — except it's dramatically worse. A compromised AI agent with standing SSH keys and database passwords is a nightmare. HashiCorp Boundary solves this by treating the AI agent exactly like any human operator: it gets no standing access. Every connection requires a session, every credential is ephemeral, and every action is audited."

> "What you're about to see is a P1 incident. The demo-web-app is down. Four enterprise customers are impacted. An AI agent is going to investigate and fix it — but it does so entirely through Boundary."

**Now run `python agent/agent.py`**

---

### Kickoff (10 seconds)

*Terminal prints: "Launching incident-response agent..."*

> "The agent is starting with nothing. No SSH key, no database password, no standing credential of any kind. Everything it's about to touch, it has to ask Boundary and Vault for, one session at a time."

**Note for the presenter:** Boundary and Vault authentication happen automatically, silently, the instant the agent's first tool call fires — there's no separate "authenticated ✓" banner to wait for. The first visible proof is the `cert serial:` line under that first `[SSH →]` call in the next phase. Don't narrate a line that isn't coming; just move straight into pointing at that first security banner when it appears.

---

### Investigation phase (1–2 minutes)

*Agent calls `run_ssh_command` multiple times, checking service status, logs, and the env file.*

> "Every one of these SSH commands is a separate Boundary session. Watch the security line under each call."

**Point to the `cert serial:` line in the output:**

> "That serial number is a unique Vault-signed SSH certificate that was created seconds ago, just for this one command. It expires in five minutes. There is no shared key. There is no password. If this agent were compromised right now, there's nothing to steal — the cert is already almost expired."

*Agent calls `run_db_query`, output shows the dynamic username.*

**Point to the `dynamic user:` line (e.g., `v-approle-incidents-reader-xxxx-1234567890`):**

> "See this username? Vault just created this PostgreSQL role moments ago. That's a real database account — if you connected to Postgres right now, you'd find it. And in fifteen minutes, it will automatically be dropped. There's no shared 'readonly_user' account with a password that everyone knows."

---

### Approval gate (1 minute — most important moment)

*Agent prints the yellow "OPERATOR APPROVAL REQUIRED" panel and asks `Approve remediation? [y/N]`*

**Pause here. Don't type yet.**

> "The agent has finished its investigation. It found the issue: the service config has `PORT=not-a-number`. It checked the database — four customers, two thousand nine hundred fifteen users, four open support tickets. And now it's stopped. It's waiting for me."

> "This isn't a soft guardrail in a prompt. The `request_approval` function is a tool — and the agent cannot call `apply_fix` without getting a `True` back from this tool first. A human must be in the loop before any production change is made."

**Type `y` and press Enter.**

---

### Remediation and verification (30 seconds)

*Agent applies the fix and calls `verify_health`.*

> "Two SSH commands. Fix the config, restart the service. Both through Boundary, both with fresh Vault-signed certificates. And now verify."

*Health check returns `{"status": "healthy"}`.*

> "Service is back up."

---

### Closing — switch to HCP Boundary UI (1–2 minutes)

> "Let's look at what Boundary recorded."

**Click Sessions in HCP Boundary UI:**

> "Every single SSH connection and every database connection the agent made is listed here — session ID, duration, when it started, when it ended. This is the full audit trail. If something had gone wrong — if the agent had tried to do something outside its scope — it would all be here."

> "And critically: all these sessions are now closed. The agent is done. The Vault credentials have expired. The database role has been dropped. The system is back in a least-privilege state. The agent has zero standing access to anything."

---

## Section 4 — How to Surface Each Key Talking Point

### Showing unique SSH certificate serials

- These appear in the terminal output under each `[SSH →]` call
- Look for the line: `cert serial: aa:bb:cc:dd:...`
- Each call has a **different** serial — this proves a new cert was generated
- If the audience is skeptical, point out the timestamp embedded in the serial

### Showing dynamic database usernames

- Look for `dynamic user: v-approle-incidents-reader-xxxx-TIMESTAMP` under each `[DB →]` call
- **Better than checking afterward: point at the `verify-live.sh` terminal (2.5) while it happens.** The same username appears there in real time, independently, with a real `rolvaliduntil` — proof during the moment, not a claim you ask them to trust and check later.
- If you don't have that terminal open for some reason, the after-the-fact check still works:
  ```bash
  docker exec demo-postgres psql -U postgres -d incidents -c "\du" | grep "v-approle"
  ```
  It should return nothing — the lease expired and Vault cleaned it up.

### If the agent guesses a wrong DB column (this is a feature, not a glitch)

- The seeded schema doesn't tell the agent its own column names up front, so on some runs it'll guess (e.g. `customer_name` instead of the real `name`), get a real Postgres error, and query `information_schema` to self-correct
- This renders in dim yellow as `schema probe (agent iterating, not an infra fault): ...` — deliberately styled differently from a red `error:`/`stderr:` line, so it reads as the agent exploring, not something broken
- **This is the moment to make the deeper point:** *"That's a real error from a real database — not something scripted. The agent didn't hallucinate a fake column and confidently report wrong numbers; it saw the actual failure and adjusted. That's only possible because every tool call here returns ground truth, not a guess dressed up as an answer. When you're about to give an AI agent write access to production, that property — it fails loud, not silent — matters as much as the credentials being ephemeral."*
- If asked "wait, is something wrong?" — this is exactly the cue to point at the yellow styling and explain it's the same agent, same investigation, just narrating its own trial-and-error out loud instead of hiding it

### Showing sessions in HCP Boundary UI

- Go to your cluster → **Sessions** → **All sessions**
- Filter by the `incident-response` project
- Each row is one Boundary session — click any one to see: session ID, target, worker, start/end time
- On Standard tier: click **Recordings** to play back exactly what the agent did

### Showing the approval gate live

- When the yellow panel appears, pause and ask: *"What would happen in a traditional setup where an AI agent has standing access?"*
- Answer: *"It would just do it. No gate. No record. No human decision."*
- Then approve it — show that the choice is yours.

### Showing the worker routing in HCP UI

- Go to **Workers** → your worker — you can see it's active and which sessions are routing through it
- Point out: "The Boundary control plane is in HashiCorp's cloud. This worker is running on my laptop. The targets are in Docker. Nothing in the network path is left unmanaged."

### Showing Vault's audit log (optional fourth terminal — "show me how the magic is done")

`vault/setup.sh` now enables Vault's file audit device automatically every run — nothing to configure. If you want a live, presentable feed of Vault's own record of what it did (not narrated, not from `agent.py` — straight from Vault):

```bash
cd ~/src/hcp-boundary-vault-agentic-demo
bash scripts/tail-vault-audit.sh
```

This prints one line per Vault operation, live, as the agent runs — e.g. `update  ssh/sign/ubuntu` the instant a cert is signed, `read  database/creds/incidents-reader` the instant a dynamic DB credential is issued. Sensitive values (keys, passwords) are HMAC-hashed by Vault itself before they ever reach this log — safe to leave on screen. This is the single most concrete answer to "how do I know Vault is actually doing anything" — it's Vault's own receipt, not a claim.

Optional, not part of the standard 3-terminal flow (worker / `verify-live.sh` / agent) — bring it out specifically when someone asks "okay but how does Vault *actually* know to do this."

---

## Section 5 — Shutting Down for Reuse Later

### Stop the agent

`Ctrl+C` in the main demo terminal. State is not saved — that's fine, it's stateless.

### Stop the Boundary worker

`Ctrl+C` in the worker terminal. Worker state is saved in `boundary/auth/` — it will reconnect without re-approval next time (see 1.8).

### Stop Docker services

```bash
cd ~/src/hcp-boundary-vault-agentic-demo
docker compose stop
```

It does not matter whether you use `docker compose stop` or `docker compose down` here — **either way, Vault's dev-mode state (SSH CA, database role) does not survive**, confirmed directly: even a plain `stop`/`start` cycle wipes it, since dev mode never persists to disk in the first place. This used to matter a lot; it doesn't anymore, because Section 2.2 unconditionally rebuilds Vault's config every time you start the demo regardless of which shutdown method you used. PostgreSQL's seed data *does* survive `stop` (it's on disk), so `stop` is still the slightly gentler option, but don't rely on it for Vault.

### Verify everything is stopped

```bash
docker compose ps    # Should show all services as "exited" or "stopped"
```

### Next time you want to run the demo

Go directly to **Section 2** — all of it, including 2.2. Nothing in Section 1 needs repeating unless you delete `agent/.venv/`, rebuild the Docker image, or set up on a new machine.

---

## Quick Reference Card

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
STARTUP — run ALL of this, every time, in order
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
docker compose up -d
bash vault/setup.sh
bash boundary/setup.sh
docker compose restart demo-web-app

docker exec demo-web-app \
  bash -c "sed -i 's/PORT=.*/PORT=not-a-number/' \
  /etc/demo-web-app.env && supervisorctl restart demo-web-app"

[tab 2] bash scripts/start-worker.sh   ← fully automatic, no UI step
[tab 3] bash scripts/verify-live.sh    ← independent proof, keep visible

source agent/.venv/bin/activate && python agent/agent.py

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
SHUTDOWN
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Ctrl+C in agent terminal
Ctrl+C in worker terminal
docker compose stop        ← "stop" or "down", doesn't matter now
```
