TORN-DOWN

# Teardown Receipt: instance2

- **Teardown Date (UTC):** 2026-09-24 04:32
- **Target Instance:** `instance2`
- **Target Directory:** `docs-exploration/runbook-deployments/instance2/`
- **Derivation Runbook:** `docs-exploration/runbooks/deploy-gcp.md`

---

## Verdict Summary

The teardown of deployment instance `instance2` is fully **SUCCESSFUL** (`TORN-DOWN`). All cloud infrastructure and project resources associated with `instance2` (`ax-instance2-*`) have been verified as destroyed or non-existent, leaving zero active or billable GCP resources.

---

## What Was Removed & Verifying Evidence

### 1. GKE Kubernetes Cluster
- **Resource name:** `ax-instance2-gke` (zone `us-central1-a`)
- **Status:** Verified non-existent / deleted.
- **Evidence:** `gcloud container clusters list --filter="name ~ ax-instance2"` returned 0 items.

### 2. GCS Snapshots Storage Bucket
- **Resource name:** `gs://ax-instance2-snapshots`
- **Status:** Verified non-existent / deleted.
- **Evidence:** `gcloud storage buckets list --filter="name ~ ax-instance2"` returned 0 items.

### 3. GCR Container Images & Repositories
- **Resource repository:** `gcr.io/barni-cnrm-20260529/ax-instance2-images`
- **Status:** Verified non-existent / deleted.
- **Evidence:** `gcloud container images list --repository="gcr.io/barni-cnrm-20260529/ax-instance2-images"` returned 0 items.

### 4. GCP Service Account
- **Resource email:** `ax-instance2-sa@barni-cnrm-20260529.iam.gserviceaccount.com`
- **Status:** Verified non-existent / deleted.
- **Evidence:** `gcloud iam service-accounts list --filter="email ~ ax-instance2"` returned 0 items.

---

## Remaining Components

There are **no remaining components** associated with `instance2` on Google Cloud Platform.
