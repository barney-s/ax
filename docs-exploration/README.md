# AX Onboarding & Exploration Notes

Welcome! This directory contains documentation designed to help new and returning contributors get up to speed with AX quickly and accurately.

These documents are kept up-to-date and reflect the actual system architecture as of September 2026.

## Index (Freshest First)

- [runbooks/upgrade-gcp.md](runbooks/upgrade-gcp.md) *(Sept 23, 2026)* — Guides you through performing in-place rolling upgrades of the controller, server, and task-runner templates in GCP/GKE environments.
- [runbooks/deploy-gcp.md](runbooks/deploy-gcp.md) *(Sept 23, 2026)* — Comprehensive guide to compiling, packaging, and deploying AX components on real GCP GKE/GCR infrastructure.
- [runbooks/deploy-in-pod.md](runbooks/deploy-in-pod.md) *(Sept 23, 2026)* — Executable guide for deploying AX locally inside a sandbox/pod for local testing, standalone mode, and in-process development.
- [comparisons/e2b.md](comparisons/e2b.md) *(Sept 21, 2026)* — Deep-dive comparison of Agent Substrate's container-level gVisor sandboxing vs. E2B's Firecracker-based MicroVM approach.
- [sessions/2026-09-21-agent-substrate-integration.md](sessions/2026-09-21-agent-substrate-integration.md) *(Sept 21, 2026)* — In-depth architectural session detailing AX's integration with Agent Substrate (Control Plane) and `ate-env` (Guest Environment).
- [activity/2026-09-21.md](activity/2026-09-21.md) *(Sept 21, 2026)* — Comprehensive summary of recent 2-week activity, v0.3.0 architectural restructuring, major merges, codebase churn, and open maintainer asks.
- [questions.md](questions.md) *(Sept 22, 2026)* — Open questions, key structural limits, and architectural ambiguities discovered during codebase analysis, including object validation.
- [code-map.md](code-map.md) *(Sept 22, 2026)* — Directory-by-directory mapping, executable entry points, and Top 18 critical files (with Substrate and model integration details).
- [overview.md](overview.md) *(Sept 22, 2026)* — What AX does, the problems it solves, target audience, and core value propositions.
- [architecture.md](architecture.md) *(Sept 22, 2026)* — Structural diagrams, core component multiplexing details, and task reconciliation sequence diagrams.
