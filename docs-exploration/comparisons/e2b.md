# Comparison: Agent Substrate vs. E2B (Firecracker MicroVMs)

**Date:** September 21, 2026  
**Topic:** Comparing AX's execution substrate (Agent Substrate) with the leading AI agent sandboxing alternative (E2B).

---

## 1. Architectural Philosophy

Both **Agent Substrate** (used by AX) and **E2B** are designed to execute untrusted AI agent code securely and with high density. However, they approach sandbox isolation from different virtualization layers:

- **Agent Substrate:** Leverages **gVisor** (via the `SANDBOX_CLASS_GVISOR` runtime class) to provide container-level sandboxing. It intercept system calls inside the container and executes them in a user-space kernel written in Go, eliminating direct access to the host kernel.
- **E2B:** Leverages **Firecracker MicroVMs** (running via KVM) to spin up lightweight virtual machines with their own guest Linux kernels, offering hard hardware-virtualized boundaries.

---

## 2. Comparison Matrix

| Feature | Agent Substrate (gVisor) | E2B (Firecracker) |
|---|---|---|
| **Isolation Layer** | User-space Linux Kernel (Go-based) | Hardware Virtualization (KVM Hypervisor) |
| **Infrastructure Host** | Standard Kubernetes Clusters (GKE, EKS) | Bare-metal hosts or VMs with Nested Virtualization |
| **Startup Overhead** | Minimal (Standard container spawn speed) | Ultra-low (optimized Firecracker boot in ~100ms) |
| **Resource Density** | Exceptionally high (shared memory/CPU efficiency) | High, but bounded by guest kernel memory overhead |
| **State Persistence** | `/workspace` snapshots written to cloud storage (e.g. GCS) | VM state checkpointing (RAM/VCPU serialization) |
| **Egress Filtering** | Dynamic `EgressPolicies` (Wildcard hostnames/CIDRs) | In-VM firewall rules or host-level network namespaces |
| **Guest Communication** | gRPC multiplexed with HTTP via `h2c` on Port 80 | `vsock` (Virtual Sockets) or VM network forwarding |

---

## 3. Deep-Dive Trade-offs

### A. Infrastructure Portability & Kubernetes Native
- **Agent Substrate:** Because gVisor runs as a container runtime plugin (such as `runsc`), AX can be deployed on standard managed Kubernetes clouds (like GKE or EKS) without nested virtualization. It integrates directly with Kubernetes scheduling, pod lifecycles, and standard deployment manifests.
- **E2B:** Firecracker requires direct access to `/dev/kvm`. Running Firecracker inside standard cloud environments requires bare-metal instances or virtual machines with nested virtualization enabled, which increases infrastructure complexity and cost.

### B. State snapshotting & Checkpoint/Restore
- **Agent Substrate:** Relies on volume-level persistence (`/workspace` snapshotting). While individual container checkpoints are possible, AX mainly ensures that the agent's work directory survives across suspension (`SuspendActor`) and resumption (`ResumeActor`) via dynamic mounting of durable volumes backed by GCS/S3.
- **E2B:** Uses Firecracker's microVM snapshot/restore capability. This serializes the entire RAM and CPU state, allowing a running VM process to resume execution instantly from a previously frozen state, although managing memory snapshots at scale requires substantial disk storage.

### C. Network Isolation & Router Overhead
- **Agent Substrate (atenet-router):** Ingress traffic routes through a single cluster Service (`atenet-router`), which inspects the `ate-target-actor` header to find the active container. Egress is regulated per-actor via `EgressPolicies` configured directly on the local container network namespace.
- **E2B:** Network isolation is achieved via microVM tap devices connected to host bridges. This requires external orchestration to handle dynamic port allocation or ingress routing across multiple bare-metal hosts.

---

## 4. Summary Recommendation

- **Choose Agent Substrate (AX) when:** You are building enterprise-grade agent orchestration on standard cloud Kubernetes clusters, require deep multi-tenant egress rules (e.g., locking agents to specific LLM endpoints), and prioritize memory density and standard container tooling.
- **Choose E2B when:** Your agents require custom kernel modules, full hardware-virtualized sandbox isolation, or sub-second VM instantiation directly from memory-warm snapshots.
