TORN-DOWN

# Deployment Instance Teardown Receipt

- **Teardown Date (UTC):** 2026-09-24 07:46
- **Target Instance:** `instance4`
- **Target Directory:** `docs-exploration/runbook-deployments/instance4/`
- **Derivation Runbook:** `docs-exploration/runbooks/deploy-gcp-md.md`

---

## Verdict Summary

The teardown of deployment instance `instance4` (`ax-instance4`) has been completed with verdict **TORN-DOWN**. All GCP and Kubernetes resources provisioned under prefix `ax-instance4` have been completely removed and verified. Nothing remains running for this instance.

---

## Verified Removed Checklist & Evidence

### 1. GKE Cluster
- **Resource:** GKE Cluster `ax-instance4` in zone `us-central1-a`
- **Verification Command:** `gcloud container clusters list --project="barni-cnrm-20260529"`
- **Result:** No cluster named `ax-instance4` exists in the project. (Only unrelated instances `substrat-instance1` exist).

### 2. GCS Storage Bucket
- **Resource:** `gs://ax-instance4-snap-77658989016`
- **Verification Command:** `gcloud storage buckets list --project="barni-cnrm-20260529"`
- **Result:** Bucket `gs://ax-instance4-snap-77658989016` does not exist.

### 3. Container Images & Artifacts
- **Resource:** Container images under `gcr.io/barni-cnrm-20260529/ax-instance4-images` (`ax-task-runner`, `ax-controller`, `ax-server`)
- **Verification Command:** `gcloud artifacts docker images list us-docker.pkg.dev/barni-cnrm-20260529/gcr.io/ax-instance4-images --include-tags`
- **Result:** Returned 0 items; no image tags or digests remain.

### 4. GCP IAM Service Account & Role Bindings
- **Resource:** Service Account `ax-instance4-sa@barni-cnrm-20260529.iam.gserviceaccount.com`
- **Verification Command:** `gcloud iam service-accounts list --project="barni-cnrm-20260529"` and `gcloud projects get-iam-policy barni-cnrm-20260529`
- **Result:** Service account is absent and no project IAM policy bindings remain for `ax-instance4-sa`.

---

## Remaining Resources

**None.** Zero resources named or labeled for instance `ax-instance4` remain active in GCP project `barni-cnrm-20260529`.
