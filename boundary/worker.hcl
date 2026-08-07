# boundary/worker.hcl
# Local Boundary worker — runs on the demo machine alongside Docker Compose.
# The worker bridges HCP Boundary's cloud control plane to the local Docker
# containers (demo-web-app on port 2222, postgres on port 5432).
#
# Replace HCP_BOUNDARY_CLUSTER_ID with the value from your HCP portal or .env.

disable_mlock = true

# Top-level, NOT nested inside worker{} — that's the documented location for
# HCP-managed clusters and is required for the worker to discover its upstream
# (the worker otherwise connects to {cluster_id}.proxy.boundary.hashicorp.cloud:9202,
# a separate hostname from the cluster's public API address).
hcp_boundary_cluster_id = "HCP_BOUNDARY_CLUSTER_ID"

listener "tcp" {
  address = "0.0.0.0:9202"
  purpose = "proxy"
}

worker {
  # advertise localhost — targets are reachable on the loopback via Docker port mappings
  public_addr = "127.0.0.1"

  # Worker-led PKI registration: the worker generates its own key pair and
  # registers with HCP Boundary. `scripts/start-worker.sh` handles registration
  # automatically (via `boundary workers create worker-led`) using the admin
  # credentials in .env — no manual approval step needed.
  #
  # Deliberately NOT under /tmp: macOS periodically sweeps files in /tmp that
  # haven't been touched in ~3 days (see /etc/defaults/periodic.conf), which
  # would silently invalidate this worker's registration after any multi-day
  # gap (e.g. between prepping this demo and actually presenting it) and
  # force re-approving it in the HCP UI right when there's no time for that.
  auth_storage_path = "WORKER_AUTH_STORAGE_PATH"

  tags {
    type    = ["local"]
    purpose = ["docker-demo"]
  }
}
