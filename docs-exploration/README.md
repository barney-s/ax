# AX Onboarding & Exploration Notes

Welcome! This directory contains documentation designed to help new and returning contributors get up to speed with AX quickly and accurately.

These documents are kept up-to-date and reflect the actual system architecture as of September 2026.

## Index (Freshest First)

- [runbook-deployments/instance1/receipt-20260923-2149.md](runbook-deployments/instance1/receipt-20260923-2149.md) *(Sept 23, 2026)* — Execution receipt for the `instance1` deployment instance on GCP GKE, validating full GCP provisioning, Substrate installation with GKE JWT mode, and standalone, privileged, SPIFFE-certified worker pools.
- [runbook-deployments/ak-ate-1/receipt-20260923-0836.md](runbook-deployments/ak-ate-1/receipt-20260923-0836.md) *(Sept 23, 2026)* — Execution receipt for the `ak-ate-1` deployment instance on GCP GKE, verifying full GCP GKE provisioning, Substrate installation, and correcting the AX Controller snapshots bucket config to achieve a successful task suspension and checkpointing flow.
- [runbook-deployments/ak-ate-1/receipt-20260923-0755.md](runbook-deployments/ak-ate-1/receipt-20260923-0755.md) *(Sept 23, 2026)* — Execution receipt for the `ak-ate-1` deployment instance on GCP GKE, validating GKE provisioning, Substrate installation, WorkerPools, and full AX end-to-end task suspend/resume lifecycle.
- [runbooks/upgrade-gcp.md](runbooks/upgrade-gcp.md) *(Sept 23, 2026)* — Upgraded & verified: Guides you through performing in-place rolling upgrades of the controller, server, and task-runner templates in GCP/GKE environments.
- [runbooks/deploy-gcp.md](runbooks/deploy-gcp.md) *(Sept 23, 2026)* — Upgraded & verified: Comprehensive guide to provisioning a GKE cluster, installing Agent Substrate using Helm, and deploying AX components on GCP GKE/GCS infrastructure.
- [runbooks/deploy-in-pod.md](runbooks/deploy-in-pod.md) *(Sept 23, 2026)* — Upgraded & verified: Executable guide for deploying AX locally inside a sandbox/pod for local testing, standalone mode, and in-process development.
- [comparisons/e2b.md](comparisons/e2b.md) *(Sept 21, 2026)* — Deep-dive comparison of Agent Substrate's container-level gVisor sandboxing vs. E2B's Firecracker-based MicroVM approach.
- [sessions/2026-09-21-agent-substrate-integration.md](sessions/2026-09-21-agent-substrate-integration.md) *(Sept 21, 2026)* — In-depth architectural session detailing AX's integration with Agent Substrate (Control Plane) and `ate-env` (Guest Environment).
- [activity/2026-09-21.md](activity/2026-09-21.md) *(Sept 21, 2026)* — Comprehensive summary of recent 2-week activity, v0.3.0 architectural restructuring, major merges, codebase churn, and open maintainer asks.
- [questions.md](questions.md) *(Sept 22, 2026)* — Open questions, key structural limits, and architectural ambiguities discovered during codebase analysis, including object validation.
- [code-map.md](code-map.md) *(Sept 22, 2026)* — Directory-by-directory mapping, executable entry points, and Top 18 critical files (with Substrate and model integration details).
- [overview.md](overview.md) *(Sept 22, 2026)* — What AX does, the problems it solves, target audience, and core value propositions.
- [architecture.md](architecture.md) *(Sept 22, 2026)* — Structural diagrams, core component multiplexing details, and task reconciliation sequence diagrams.
