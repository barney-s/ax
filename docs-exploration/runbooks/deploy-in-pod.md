# Deploy In-Pod Runbook

This runbook guides you through compiling, running, and verifying the AX platform locally inside a single-machine development environment or sandbox (in-pod). It uses Go binaries, in-memory/localhost services, and Go unit/integration tests to prove the entire platform's functionality.

---

## What this needs

This scenario **can run in the pod** or on any local developer workstation. It does not require real cloud infrastructure, physical Kubernetes nodes, node-level privileged features (like CSI drivers, host sockets, or DaemonSets), or cloud credentials.

### Cost of Teardown
- **$0.00**. All resources are ephemeral local processes and files.

### Feasibility Checklist
- [x] **Go 1.27+ Compiler**: Present (`go version` shows `go1.27.1`)
- [x] **gcloud CLI**: Present (Not strictly required for local, but available)
- [x] **kubectl CLI**: Present (Not strictly required for local, but available)
- [ ] **Docker / Podman**: MISSING (Required if running the standalone Redis container or building the task-runner image, but skipped here as we run local Go tests and binaries directly)
- [ ] **Redis Server Binary**: MISSING (Can be installed locally via `sudo apt-get install -y redis-server` or run via Docker; integration tests run their own in-memory/mock storage validation)

---

## Preconditions

1. Go 1.27+ is installed and accessible in the system path.
2. The current directory is `/workspaces/ax`.

---

## Steps

### 1. Clean previous build artifacts
Remove any old binaries or residues before building:
```bash
make clean
```

### 2. Build the local Go binaries
Compile the `ax` developer CLI, `ax-server`, and `ax-controller` binaries:
```bash
make build
```
This produces three executable binaries in the `./bin/` directory:
- `bin/ax`: The CLI tool used to manage AX resources.
- `bin/ax-server`: The multiplexed gRPC/HTTP API ingestion server.
- `bin/ax-controller`: The core worker reconciler.

### 3. Run the integrated test suite
Execute the complete set of unit and integration tests. This verified the persistence store (Redis/Memory), API server gRPC endpoints, Workspace planners (model client and LLM simulation), metadata server endpoints, Guest process execution deamons, and the complete `ax-controller` reconciliation loop using an in-process mock Agent Substrate server:
```bash
make test
```

### 4. (Optional) Run the local API Server and Client CLI
If you have a local Redis server running on `localhost:6379`, you can start the stateless API server locally:
```bash
./bin/ax-server --addr=:8080 --redis-addr=localhost:6379
```
Then, verify that the local CLI can communicate with it to query and list tasks (which will fall back to `http://localhost:8080` in the absence of a Kubernetes cluster context):
```bash
AX_SERVER=http://localhost:8080 ./bin/ax get tasks
```

---

## Verify

You know the in-pod deployment is successful when:
1. **Tests pass:** The entire Go test suite reports a clean `PASS` without errors:
   ```bash
   go test -v ./...
   ```
2. **Binaries respond:** Executing help or version commands on the CLI and Server binaries completes successfully:
   ```bash
   ./bin/ax version
   ./bin/ax --help
   ./bin/ax-server --help
   ```

---

## Teardown

To tear down the local in-pod resources and clean up compiled artifacts, run:
```bash
make clean
```
Additionally, kill any background `ax-server` or `redis-server` processes if they were started manually:
```bash
pkill ax-server || true
pkill redis-server || true
```
