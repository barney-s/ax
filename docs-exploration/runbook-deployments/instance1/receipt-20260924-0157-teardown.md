TORN-DOWN

# Teardown Receipt: instance1

- **Teardown Date (UTC):** 2026-09-24 01:57
- **Target Instance:** `instance1`
- **Target Directory:** `docs-exploration/runbook-deployments/instance1/`
- **Derivation Runbook:** `docs-exploration/runbooks/deploy-gcp.md`

---

## Verdict Summary

The teardown of deployment instance `instance1` is fully **SUCCESSFUL** (`TORN-DOWN`). All cloud infrastructure resources have been completely destroyed, and there are no remaining billable components, active VM instances, block storage volumes, container image digests, or service accounts on Google Cloud Platform.

---

## What Was Removed & Verifying Evidence

### 1. GKE Kubernetes Cluster
- **Resource name:** `ax-instance1-gke` (zone `us-central1-a`)
- **Status:** Deleted (which terminated the 3x `e2-standard-4` VM instances, NodePools, underlying Compute Engine resources, Firewalls, Service Directory resources, and all Kubernetes-internal components like ClusterRoles, ClusterRoleBindings, namespaces, pods, and PVCs/PVs).
- **Evidence:** `gcloud container clusters list --filter="name:ax-instance1"` successfully returned:
  ```
  Listed 0 items.
  ```

### 2. GCS Snapshots Storage Bucket
- **Resource name:** `gs://ax-instance1-snapshots`
- **Status:** Deleted recursively (including all task Actor volume snapshot folders/files).
- **Evidence:** `gcloud storage buckets list --filter="name:ax-instance1"` successfully returned:
  ```
  Listed 0 items.
  ```

### 3. GCR Container Images & Repositories
- **Resource repository:** `gcr.io/barni-cnrm-20260529/ax-instance1-images`
- **Status:** Fully purged of all active container image digests and tags (across sub-repositories `ateom-gvisor`, `ateom-gvisor-*`, `ateom-microvm`, `ateom-microvm-*`, `ax-controller-*`, `ax-server-*`, and `ax-task-runner`).
- **Evidence:** Running `gcloud container images list-tags` on these repositories successfully returned:
  ```
  Listed 0 items.
  ```

### 4. GCP Service Account
- **Resource email:** `ax-instance1-sa@barni-cnrm-20260529.iam.gserviceaccount.com`
- **Status:** Deleted.
- **Evidence:** `gcloud iam service-accounts list --filter="email:ax-instance1-sa"` successfully returned:
  ```
  Listed 0 items.
  ```

---

## Remaining Components

There are **no remaining components** associated with this deployment instance on Google Cloud Platform. The environment is completely clean.
