# AX Code Map

This document maps the repository's directory layout, identifies main executable entry points, and highlights the critical files that are most important to understand.

---

## Directory Structure Overview

- `cmd/`: Command-line executable entry points.
- `pkg/apis/v1alpha1/`: Schemas, Protobuf specifications, and validation logic.
- `runner/`: Sandbox runtime supervisor that runs inside container workloads.
- `internal/`: Private internal libraries:
  - `controller/`: Consumes events, manages reconcilers, and talks to Agent Substrate.
  - `server/`: Houses the gRPC API endpoints for AX resources.
  - `store/`: Data persistence definitions and Redis/Memory backends.
  - `substrate/`: Client wrapper for communication with the Agent Substrate Control API.
  - `workspace/`: Planners and setup executors for workspace environments.
  - `model/`: Integrations with external model APIs (Gemini).
  - `metadata/`: Inside-actor cloud metadata server.
  - `guest/`: Powers the in-actor execution and filesystem guest daemon.
  - `tunnel/`: Automatically establishes Kubernetes port-forwards to the API server.

---

## Critical Executable Entry Points

- `cmd/ax/main.go`: The `ax` developer CLI. Handles manifest submissions and commands.
- `cmd/ax-server/main.go`: API server executing gRPC/HTTP endpoints, writing to Redis.
- `cmd/ax-controller/main.go`: Horizontal scaling reconciling worker daemon.
- `cmd/ax-task-runner/main.go`: Container entrypoint binary wrapping the `runner` package.
- `cmd/ax-task-runner/antigravity_bootstrap.py`: Python script invoked inside the sandbox container to run the `google-antigravity` agent for workspace setup goals.

---

## Top 17 Files That Matter Most

### Schemas & APIs
1. `pkg/apis/v1alpha1/ax.proto`: Protobuf schema defining `Task`, `Workspace`, `Gateway`, `Model`, and control service RPCs. **CRITICAL: Modifying this requires rebuilding generated code (`ax.pb.go`, `ax_grpc.pb.go`).**
2. `pkg/apis/v1alpha1/types.go`: Implements custom YAML encoders/decoders for protobuf types, mapping schema definitions to standard YAML structures. Includes legacy normalization rules.

### Command Line & Networking
3. `cmd/ax/main.go`: Handles CLI input, connects to `ax-server` via local or automated Kubernetes port-forward tunnels.
4. `internal/tunnel/tunnel.go`: Automates `kubectl port-forward` under the hood to ensure a seamless developer experience without manually configuring proxy setups.

### API Server & Persistence
5. `internal/store/store.go`: Defs for `Store`, `EventQueue`, and `Subscription` interfaces. Keeps storage backends separate from API/worker logic.
6. `internal/store/redis/store.go`: Redis implementation mapping AX resources to Redis hashes, tracking sorted set indexes, and running the Stream work queue.
7. `internal/server/server.go`: Realizes the `ax.v1alpha1.AX` service, implementing API endpoints and saving entries into the `Store`.

### Worker & Reconciler
8. `internal/controller/worker.go`: Evaluates Redis Streams, manages worker consumer loops, processes reconcile/delete events, and writes status back to Redis.
9. `internal/controller/reconciler.go`: **CRITICAL: The core state driver.** Coordinates with Agent Substrate to create atespaces, actors, custom templates, network rules, and handles actor suspend/resume logic.
10. `internal/substrate/client.go`: High-performance gRPC wrapper client managing connections to the Agent Substrate Control API.

### Inside the Sandbox (Workloads)
11. `runner/runner.go`: **CAUTION: Core container runtime supervisor.** Performs maiden workspace setup, starts metadata servers, launches client tasks, and manages SIGTERM/graceful termination of child processes.
12. `internal/workspace/setup.go`: Prepares the workspace filesystem (clones repos, handles skills, boots antigravity helper scripts).
13. `cmd/ax-task-runner/antigravity_bootstrap.py`: Connects to Gemini via the `google-antigravity` Python SDK to autonomously fulfill setup goals specified in workspace references.
14. `internal/workspace/planner.go`: Interacts with LLM models to synthesize execution/bootstrap setup instructions.
15. `internal/metadata/server.go`: Implements the container metadata HTTP endpoints (`/metadata/...`) and handles `/readyz` workspace setup status reports.
16. `internal/guest/client.go`: Handles the in-sandbox guest daemon interface, allowing secure gRPC filesystem access and shell execution that powers `ax ssh`.

### Build & Tooling
17. `Dockerfile.task-runner`: Specifies the sandbox container environment (Python 3.12, git, curl, `google-antigravity` library, and the `ax-task-runner` binary).

---

## Modifying Cautions ⚠️

- **`pkg/apis/v1alpha1/ax.proto`:** Changing field IDs or types can break compatibility between running `ax-server`, `ax-controller` and older compiled `ax` CLI binaries. Avoid removing fields; prefer using `reserved` numbers.
- **`runner/runner.go`:** Any modification to process execution, signals, or process groups can result in orphaned zombie processes inside sandboxes or blocked gracefully-shut-down containers. Keep edits here clean and verified under multiple signal contexts.
- **`internal/controller/reconciler.go`:** Governs external Substrate resources. Bad logic can lead to orphaned atespaces or actors, leaking infrastructure resources.
