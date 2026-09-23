TORN-DOWN

## Overview

The deployment instance "ax-gcp1" has been successfully and completely torn down. All active workloads, services, and the namespace have been removed from the GKE cluster `ics-1`.

---

## Verifying Evidence

### 1. Deleted Namespace and Kubernetes Resources
Running `teardown.sh` completed successfully and deleted:
- Deployment `ax-server` and Service `ax-server`
- Deployment `ax-controller` and its associated RBAC ClusterRole/ClusterRoleBindings and ServiceAccount
- Deployment `ax-redis`
- Namespace `ax-system` (which cascade-deleted all other namespace-scoped resources such as pods, secrets, services, and configmaps).

### 2. Validation Queries
We verified the removal of the resources by querying the Kubernetes cluster:

- **Namespace Verification:**
  ```bash
  $ kubectl get namespaces
  NAME                                STATUS   AGE
  default                             Active   23h
  gke-managed-cim                     Active   23h
  gke-managed-networking-dra-driver   Active   23h
  gke-managed-system                  Active   23h
  gke-managed-volumepopulator         Active   23h
  gmp-public                          Active   23h
  gmp-system                          Active   23h
  kube-agentfs-system                 Active   23h
  kube-node-lease                     Active   23h
  kube-objectfs-system                Active   23h
  kube-public                         Active   23h
  kube-system                         Active   23h
  ```
  *(The `ax-system` namespace is no longer present, confirming all workload pods and local services are destroyed.)*

- **Cluster-Wide RBAC Verification:**
  ```bash
  $ kubectl get clusterrole,clusterrolebinding | grep ax
  (Exit code 1 - No matches found)
  ```
  *(Confirms all AX controller cluster roles and bindings are deleted.)*

- **Active Resources Hunt:**
  ```bash
  $ kubectl get all -A | grep -i ax
  (No AX deployment, pod, service, or other workload resources found.)
  ```

---

## Remaining Assets (Cost-Relevant Resources)

The following container images remain in the Google Container Registry repository `gcr.io/barni-cnrm-20260529/ate-images` as build artifacts (deletion of GCR repositories is not managed by the `teardown.sh` or standard runbook workflow):
- `gcr.io/barni-cnrm-20260529/ate-images/ax-task-runner:latest`
- `gcr.io/barni-cnrm-20260529/ate-images/ax-controller-7ebf6094b73be08cb227c879d4802a93`
- `gcr.io/barni-cnrm-20260529/ate-images/ax-server-340c3583cc4a989b584acf55b1619e8e`
