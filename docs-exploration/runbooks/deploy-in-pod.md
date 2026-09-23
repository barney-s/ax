# Runbook: Deploy AX In-Pod (Local Development & Test)

*Note: This revision is updated to accurately reflect local Redis availability and verify connectivity on port 8080. Some dependencies are missing in the local environment and must be installed prior to running.*

---

## What this needs

This deployment **can run completely in-pod**. It does not require real GCP infrastructure, cloud registries, or an active GKE cluster.

### Why in-pod is possible:
- **Mock integrations**: The full AX control plane, reconciler, and state transitions are validated using the built-in mock Agent Substrate server and in-memory store implementations included in the test suite.
- **Standalone Mode**: Both the `ax-server` and `ax-controller` binaries are designed to run as standalone Go processes connected to a standard Redis instance on `localhost:6379`.
- **Auto-fallback CLI**: The `ax` CLI automatically falls back to `http://localhost:8080` if no active Kubernetes cluster context is configured.

### Feasibility Checklist (Probed on Wednesday, September 23, 2026)

The following checklist represents the results of read-only probes executed under the current identity:

* **Tools:**
  - `go` (v1.27+): ✓ present
  - `make`: ✓ present
  - `redis-server` (or local Redis container): ✗ MISSING — Fix: `sudo apt-get update && sudo apt-get install -y redis-server`

* **Permissions & Environments:**
  - Local Sandbox write/execute permissions: ✓ present (You have write access to `/workspaces/ax` to build binaries and compile code).

---

## Preconditions

1. **Start a local Redis instance** on port `6379`:
   - If `redis-server` is installed locally, run it in the background redirecting logs to avoid hanging the terminal session:
     ```bash
     redis-server --port 6379 > redis.log 2>&1 &
     ```
   - If using `docker` or `podman` in your sandbox:
     ```bash
     docker run -d --name ax-redis -p 6379:6379 redis:7-alpine
     ```

---

## Steps

1. **Build all local AX binaries**:
   Compile the `ax` CLI, `ax-controller`, and `ax-server` binaries into the `bin/` directory:
   ```bash
   make build
   ```

2. **Run the full unit and integration test suite**:
   Validate all components (including the reconciler, the mock Substrate gRPC server, memory store, and model client) in-process:
   ```bash
   make test
   ```

3. **Launch the AX API Server locally**:
   Start `ax-server` pointing to your local Redis instance. It will listen on port `8080`, redirecting outputs to avoid hanging:
   ```bash
   ./bin/ax-server --addr=:8080 --redis-addr=localhost:6379 > ax-server.log 2>&1 &
   ```

---

## Verify

1. **Verify server connection using the `ax` CLI**:
   Explicitly configure the CLI to use your local server and verify connectivity:
   ```bash
   export AX_SERVER="http://localhost:8080"
   ./bin/ax version
   ```
   *Expected Output:*
   ```
   ax version v1alpha1 (standalone redis engine)
   ```

2. **Interrogate the local database**:
   Run commands to verify that the CLI successfully communicates with the API server:
   ```bash
   ./bin/ax get tasks
   ```
   *Expected Output:*
   ```
   No tasks found.
   ```

---

## Teardown

1. **Stop the local AX Server**:
   ```bash
   pkill ax-server
   ```

2. **Stop the local Redis instance**:
   - If running via `redis-server` process:
     ```bash
     pkill redis-server
     ```
   - If running via Docker:
     ```bash
     docker stop ax-redis && docker rm ax-redis
     ```

3. **Clean up compiled binaries and build artifacts**:
   ```bash
   make clean
   ```
