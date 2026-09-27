TORN-DOWN

## Teardown Information
- **Instance**: instance5
- **Runbook**: `docs-exploration/runbooks/deploy-gcp.md`
- **Resource Prefix**: `ax-instance5`
- **GCP Project**: `barni-cnrm-20260529` (Project Number: `77658989016`)
- **GCP Region / Zone**: `us-central1` / `us-central1-a`

## Removed Resources & Verification Evidence

### 1. Kubernetes Workloads & Namespaces
- **Resources**: `ax-system` namespace (including `ax-controller`, `ax-server`, `ax-redis` StatefulSet, and Redis PVC) and `ate-system` Substrate control plane components (`ate-api-server`, `ate-controller`, `atelet`, `atenet`, `sandbox-workerpool`).
- **Evidence**:
  ```
  ==> 1. Deleting ax-system namespace and resources...
  namespace "ax-system" deleted
  ==> 2. Removing Substrate control plane...
  [step]: delete_all
  [step]: delete_ate_system
  ```

### 2. GKE Cluster & Compute Node Pools
- **Resource**: `ax-instance5` GKE zonal cluster with 2 x `c3-standard-4` nodes (`substrate-node-pool`).
- **Evidence**:
  ```
  $ gcloud container clusters list --project=barni-cnrm-20260529
  Listed 0 items.
  ```

### 3. Google Cloud Storage (GCS) Snapshot Bucket
- **Resource**: `gs://ax-instance5-snap-77658989016` (including all saved task snapshots and durable directory archives).
- **Evidence**:
  ```
  $ gcloud storage ls --project=barni-cnrm-20260529 | grep ax-instance5
  # (empty - bucket deleted)
  ```

### 4. Container Images (GCR / Artifact Registry)
- **Resources**: All image packages and sha256 digests published under `gcr.io/barni-cnrm-20260529/ax-instance5/*` (`ateapi`, `atecontroller`, `atelet`, `atenet`, `ateom-gvisor`, `ax-controller-*`, `ax-server-*`, `ax-task-runner`, `podcertcontroller`, `sandbox`).
- **Evidence**:
  ```
  $ gcloud container images list-tags gcr.io/barni-cnrm-20260529/ax-instance5/ateapi
  Listed 0 items.
  $ gcloud artifacts docker images list us-docker.pkg.dev/barni-cnrm-20260529/gcr.io --filter="package:ax-instance5"
  Listed 0 items.
  ```

### 5. IAM Policy Bindings & Workload Identity
- **Resources**: Project-level IAM bindings for `atelet` (`roles/storage.objectAdmin`, `roles/artifactregistry.reader`) and bucket-level IAM policies for `atelet` and `ate-api-server`.
- **Evidence**:
  ```
  $ gcloud projects get-iam-policy barni-cnrm-20260529
  # Verified: No bindings remain for atelet or ax-instance5 principals.
  ```

### 6. Cloud Monitoring Dashboards
- **Resources**: Substrate monitoring dashboards (`Substrate Snapshot Size & QPS`, `Substrate Routing & E2E Latency`, `Substrate gRPC Server`).
- **Evidence**:
  ```
  $ gcloud monitoring dashboards list --project=barni-cnrm-20260529
  Listed 0 items.
  ```

## Remaining Resources
None. All infrastructure, compute nodes, storage buckets, container digests, and IAM bindings created for `instance5` have been completely removed.

## Procedure Amended

1. **`docs-exploration/agent-runs/instance5/teardown.sh`**:
   - *Reason*: `hack/teardown.sh` failed because environment variables (`PROJECT_ID`, `PROJECT_NUMBER`, `RESOURCE_PREFIX`, `CLUSTER_LOCATION`, etc.) were not exported to child subshells. Additionally, `ko` generated multi-digest and SBOM tagged images that prevented simple tag deletion from removing image repositories.
   - *Fix*: Added explicit `export` for all required configuration variables, updated Substrate teardown invocation to `hack/teardown.sh --all` to ensure IAM bindings and dashboards are purged, and implemented full sha256 digest enumeration via `jq` during container image cleanup.

2. **`docs-exploration/runbooks/deploy-gcp.md`**:
   - *Reason*: Align the canonical runbook Teardown section with the deterministic, robust script steps so future teardowns cleanly clean up IAM bindings and image digests.
   - *Fix*: Reconciled the Teardown section to use `hack/teardown.sh --all` and the JSON `jq` image digest deletion loop.
