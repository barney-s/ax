# Open Questions & System Ambiguities

These notes identify open questions, architectural limits, and details not fully resolved by the source code as of September 2026.

---

## 1. Event Redelivery and Queue Reliability
- **Observation:** `internal/controller/worker.go` consumes events from Redis Streams via `XREADGROUP` and processes them. Every event is acknowledged via `Ack` even if `Reconcile` fails (to prevent a bad task from wedging the queue).
- **Ambiguity:** If an `ax-controller` worker crashes *during* the execution of `processEvent` (before `Ack` is called), the event remains in the Redis Stream pending list. Does AX have a garbage collection or retry mechanism (e.g., via `XPENDING` / `XCLAIM`) to reclaim and reassign stalled tasks to other alive controller workers?

## 2. Egress Gateway Composite Security Policies
- **Observation:** `TaskSpec` supports exactly one `GatewayRef` (`gateway`).
- **Ambiguity:** Are there use cases where a task must compose multiple gateway definitions (e.g., separating global platform egress rules from user-configured egress policies)? Is the platform restricted strictly to single-gateway references, or will future iterations support list-based gateway refs?

## 3. Dynamic Secret Rotation & Alternative Key KMS
- **Observation:** `reconciler.go` resolves the `GEMINI_API_KEY` from a specific Kubernetes secret (`gemini-api-secret`) in the task's atespace or falls back to the controller's own environment.
- **Ambiguity:** Since the resolved key is injected directly into the `ActorTemplate`'s static environment map, it gets persisted inside Substrate's database. Does Substrate support dynamic secret injection/rotation, or does a rotating key require re-creating the entire `ActorTemplate`?

## 4. Multi-Tenant Network Isolation on Agent Substrate
- **Observation:** Tasks run in sandboxed Actors inside logical namespaces called Atespaces.
- **Ambiguity:** How are Atespaces separated at the network overlay layer in Agent Substrate? Do Atespaces map directly to Kubernetes Namespaces with NetworkPolicies, or is there an overlay networking framework (e.g., Cilium or Istio) enforcing tenants' isolation?

## 5. Graceful Termination & Container Life-Cycle
- **Observation:** `runner/runner.go` defines `stopGracePeriod` of `10 * time.Second` before killing a process group with `SIGKILL`.
- **Ambiguity:** How does this relate to the standard Kubernetes Pod `terminationGracePeriodSeconds` (defaulting to 30s) under which the `ax-task-runner` pod runs? Is there a risk that the pod is terminated by Kubernetes before the `ax-task-runner` finishes its internal `SIGKILL` graceful shutdown sequence?
