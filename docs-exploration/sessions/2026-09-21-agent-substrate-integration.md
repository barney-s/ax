# Session: Agent Substrate Integration Deep-Dive

**Date:** September 21, 2026  
**Topic:** How does AX use the Agent Substrate project?

---

## 1. Executive Summary

AX is designed as a high-throughput, declarative orchestrator for autonomous agents. To run billions of agent workloads securely and efficiently, AX does not manage low-level container sandboxing directly. Instead, it offloads sandboxing, tenant isolation, and container-level process/filesystem manipulation to **Agent Substrate** and its guest environment utility **`ate-env`**.

AX integrates with Agent Substrate via two distinct layers:
1. **The Control Plane Layer (`github.com/agent-substrate/substrate`):** Used by `ax-controller` to orchestrate multi-tenant logical namespaces (**Atespaces**), reusable blueprint configurations (**ActorTemplates**), sandboxed runtimes (**Actors**), and dynamic egress filters (**EgressPolicies**).
2. **The Guest Environment Layer (`github.com/agent-substrate/env`):** Embedded inside the AX task execution container (`ax-task-runner`), enabling secure, gRPC-driven command supervision, process execution, and remote shell tunneling (`ax ssh`).

---

## 2. Structural Architecture and Data Flows

The diagram below illustrates how AX components integrate with Agent Substrate APIs to provision, run, and interact with agent sandboxes:

```
                  [Developer CLI (ax)]
                           │
                Port-forwarding / Tunnel
                           │
                           ▼
          [Substrate atenet-router Service]  ◄── (Routes traffic via 'ate-target-actor' header)
                           │
                           ▼
                 [ax-controller worker]
                           │
                   Control API (gRPC)
                           │
                           ▼
                [Agent Substrate Control]
                           │
       Provisions & Schedules (gVisor Runtime)
                           │
                           ▼
           [Actor Sandbox Container (Atespace)]
             └─► [ax-task-runner (PID 1)]
                   ├─► HTTP Metadata Endpoints (/readyz, /metadata)
                   ├─► Guest gRPC Server (multiplexed on Port 80 via h2c)
                   │     └─► Process Management (Start, Stream, Kill)
                   └─► Supervised Task Command (Child Process Group)
```

---

## 3. Subsystem Integration: Control Plane (`github.com/agent-substrate/substrate`)

The core control plane driver is `internal/controller/reconciler.go`, which uses the `internal/substrate` package's wrapper client (`Client`) to drive Agent Substrate's gRPC APIs.

### A. Namespace Isolation via Atespaces
Each AX task is placed within a logical namespace called an **Atespace** (determined by `task.Metadata.Atespace`, defaulting to `default`).
- **Integration:** The reconciler calls `EnsureAtespace` on the Substrate client during reconciliation.
- **Substrate Call:** `CreateAtespace` (via `ateapipb.ControlClient`). It is designed to be idempotent; if the atespace already exists (`codes.AlreadyExists`), the error is safely ignored.

### B. Sandbox Blueprints via ActorTemplates
Every Actor in Agent Substrate must be spawned from an **ActorTemplate**. An ActorTemplate defines the container image, entrypoint, environment, volumes, liveness/readiness probes, and sandboxing characteristics.
- **Dynamic Templates:** If a Task spec requests custom environment variables or a specific container image, the reconciler generates a unique ActorTemplate name based on a SHA-256 digest of the image and environment map (`taskTemplateName`). It then provisions this template on Substrate.
- **Durability & Snapshotting:** ActorTemplates built via `BuildActorTemplate` specify robust checkpointing and snapshot configurations:
  - **Volume Mounts:** Mounts a durable `/workspace` directory inside the sandbox.
  - **Snapshots Bucket:** Sourced via `AX_SNAPSHOTS_BUCKET` or a default GCP bucket.
  - **Checkpoint Triggers:** Configures state snapshotting on pause and commit events:
    - `OnPause`: `SNAPSHOT_CONTENT_SCOPE_DATA`
    - `OnCommit`: `SNAPSHOT_CONTENT_SCOPE_DATA`
  - **Restoration Behavior:** On resume, the Actor is populated from the "golden" snapshot state (`ResumeSource_RESUME_SOURCE_GOLDEN`).
  - **Sandbox Class:** Forces the use of `gVisor` (`SANDBOX_CLASS_GVISOR`, `gvisor-default`) for strict kernel-level sandboxing, protecting the host system from untrusted agent code.

### C. Lifecycle Management (Actors)
A running task instance maps directly to an **Actor** in Substrate, which shares the task's name.
- **Creation:** Reconciler ensures the Actor exists on Substrate via `CreateActor`. If the actor was previously in a crashed state (`ACTOR_STATE_CRASHED`), the client automatically deletes it and waits to recreate a fresh instance.
- **Suspension (Checkpointing):** When `task.Spec.Suspend` is true, the reconciler calls `SuspendActor`, freezing the Actor container and saving the `/workspace` volume snapshot to GCS.
- **Resumption:** When restoring a task, the reconciler calls `ResumeActor`. Substrate schedules the Actor onto a physical worker pod, loads its `/workspace` snapshot from GCS, starts the container, and returns the worker pod's IP.

### D. Network Egress Control (EgressPolicies)
To prevent prompt-injection attacks from leaking sensitive keys or executing unauthorized data egress, AX configures strict egress routing using Substrate's dynamic firewalls.
- **Gateway Mapping:** AX maps the hosts listed in a bound `Gateway` configuration into Substrate `EgressRule` specs.
- **Rules Configuration:**
  - Hosts matching CIDR patterns (e.g., `10.0.0.0/8`) map to `ateapipb.CIDRRule`.
  - Static or wildcard hostnames (e.g., `*.googleapis.com`) map to `ateapipb.HostnameRule`.
  - Wildcard rules (`*` or `0.0.0.0/0`) map to `ateapipb.EgressRule{All: &emptypb.Empty{}}`.
- **Substrate Call:** `CreateActorEgressPolicy` / `UpdateActorEgressPolicy` on Substrate. This binds the dynamic egress filtering directly to the Actor's network namespace at runtime.

---

## 4. Subsystem Integration: Guest Environment (`github.com/agent-substrate/env`)

While the control plane schedules and isolates the container sandbox, interacting inside the running sandbox relies on the `agent-substrate/env` project.

### A. The In-Container Guest Daemon (`ax-task-runner`)
The AX task runner acts as PID 1 inside the actor sandbox. It is responsible for orchestrating workspace setup (git cloning, MCP, bootstrap goals) and executing the agent's main process.
- **Guest API Server:** The runner initializes a server (`internal/metadata/server.go`) that serves both HTTP endpoints and a gRPC guest daemon.
- **Service Registration:** If `task.Spec.Debug` is set to `true`, the runner imports `github.com/agent-substrate/env/guest` and spawns the `guest.NewServer(guestCfg)`.
- **gRPC Services Exposed:**
  - `ateenvv1alpha.ProcessServiceClient`: Manages processes (starting, inspecting, streaming stdout/stderr, killing).
  - `ateenvv1alpha.FileSystemServiceClient`: Handles streaming files inside the workspace.
- **Multiplexing via `h2c`:** Both the HTTP metadata REST APIs (serving Task specs/status on `/metadata/...`) and the gRPC guest services are served over a single port (port 80) multiplexed using unencrypted HTTP/2 (`h2c`).

### B. Remote Tunneling (`ax ssh`)
Developers can open an interactive shell or execute commands directly inside a running task's sandbox. This is powered by AX's guest client (`internal/guest/client.go`) interacting with the guest daemon:
1. **Connectivity Check:**
   - If the task's `workerIP` is directly routable from the user's workspace, AX connects directly.
   - Otherwise, it initiates a Kubernetes port-forwarding tunnel to the Substrate `atenet-router` Service in the `ate-system` namespace on port 80.
2. **gRPC Dialing & Routing:**
   - AX dials the router, injecting the custom metadata header `ate-target-actor` (`<atespace>/<task-name>`) onto the connection.
   - `atenet-router` reads this header, locates the physical worker where the sandbox is running, automatically resumes the sandbox if it is suspended, and forwards the gRPC connection directly to the container.
3. **Execution Stream:**
   - Once connected, the client makes a gRPC streaming call: `StartProcess` followed by `StreamProcessOutput` (via `ateenvv1alpha.ProcessServiceClient`).
   - Standard output and error bytes are piped in real time to the developer's console, and process exit codes are correctly returned upon termination.

---

## 5. Summary of Main Integration Interfaces

| AX Subsystem | Agent Substrate Component | API/Protocol | Primary Use Case |
|---|---|---|---|
| `ax-controller` | `ateapipb.ControlClient` | gRPC (Control API) | Creating Atespaces, spawning/deleting Actors, updating dynamic `EgressPolicy` configurations. |
| `ax-controller` | `ResumeActor` / `SuspendActor` | gRPC (Control API) | Transitioning tasks between `Running` and `Suspended` states, snapshotting the durable `/workspace` state. |
| `ax-task-runner` | `github.com/agent-substrate/env/guest` | Go Library Integration | Embedding the guest daemon gRPC services directly into the PID 1 container entrypoint. |
| `ax` CLI (`ssh`) | `atenet-router` Service | TCP Port-Forward + HTTP/2 | Tunneling connections to a running sandbox across Kubernetes boundaries. |
| `ax` CLI (`ssh`) | `ProcessServiceClient` | gRPC (`ate-env` Spec) | Streaming process creation and terminal standard streams for interactive sandboxed shell access. |
