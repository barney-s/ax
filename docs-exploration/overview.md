# AX: AI Agent Task Execution Platform

## What It Is & Why It Exists

Storing and managing millions of short-lived agent tasks using standard orchestrators (like Kubernetes CRDs and etcd) introduces severe bottleneck challenges. High write rates, large volumes of ephemeral states, and etcd's storage limits (typically single-digit gigabytes) quickly lead to control plane degradation.

**AX** solves this problem by keeping its state in a fast, lightweight, and scalable Redis-backed store and utilizing Redis Streams as a decoupled work queue. It allows developers to define, run, and scale millions of short-lived AI agent tasks securely, safely, and asynchronously.

AX provides high-throughput, low-latency agent execution environments by offloading execution to sandboxed environments called **Actors** inside logical namespaces called **Atespaces** on **Agent Substrate**.

---

## Target Audience & Use Cases

- **AI Agent Platform Engineers:** Developers building and scaling execution systems for AI agents, who require high-density, secure, multi-tenant sandboxing with strict network and environment control.
- **AI Agent Developers:** Users who need to launch long-running or batch tasks (e.g. repo exploration, code generation, tool/environment configuration) and securely interact with sandboxes (e.g., via interactive CLI tunneling, metadata serving, or SSH debugging).

---

## Core Value Propositions

### 1. High-Density & Horizontally Scalable Orchestration
By utilizing **Redis Streams** as the queue and a lightweight **ax-controller** worker group instead of heavy Kubernetes operators and etcd storage, AX scales horizontally by simply adding more controller worker replicas. Millions of tasks can transition through their lifecycles without degrading the core infrastructure.

### 2. Sandbox Security (Agent Substrate)
Every task runs inside its own sandboxed **Actor** on **Agent Substrate**. Tasks can declare custom gateway network configurations with strict egress policy allowlists (e.g., allowing access only to specific LLM endpoints like `*.googleapis.com`), preventing prompt-injection attacks from triggering malicious data egress or unauthorized network requests.

### 3. Native Model Context Protocol (MCP) & Agent Tools Support
Workspaces in AX define git repositories, Model Context Protocol (MCP) servers, and skill registries. Workspaces can automatically bootstrap their environment, retrieve credentials, install toolchains, and expose relevant MCP services and skills directly to the agent.

### 4. Interactive Sandbox Debugging & SSH
Tasks opting in via `spec.debug` run in-container guest services (gRPC process execution and file access), allowing developers to tunnel directly into a running sandbox container over cleartext HTTP/2 via `ax ssh` and inspect active workspaces, log outputs, or agent behaviors.
