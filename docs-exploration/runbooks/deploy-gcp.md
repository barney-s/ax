# Deploy — GCP (GKE cluster, Agent Substrate, and AX platform)

*Drafted 2026-09-24. The steps come from Substrate's `tools/setup-gcp`, `hack/install-ate.sh`, and `hack/teardown.sh` combined with AX's `Makefile`, `deploy/` manifests, and `demo.sh` CLI verification lifecycle.*

## What this needs

**This cannot run in the pod. It needs real infrastructure:** a GKE Standard cluster (specifically one zonal cluster with one node pool of two `c3-standard-4` nodes, provisioned via Substrate's `setup-gcp create cluster`), and a Google Cloud Storage (GCS) bucket for state snapshots.

Real nodes and infrastructure are required due to:
1. **Agent Substrate Worker Sandboxing:** Substrate relies on `atelet`, which is a privileged-path DaemonSet. It hostPath-mounts `/var/lib/kubelet/plugins`, `/var/lib/kubelet/device-plugins`, host `/dev`, and `/var/lib/ateom-gvisor`, which it shares with the `ateom` worker pods running gVisor's `runsc` engine.
2. **Kubernetes API Requirements:** Substrate requires Kubernetes ≥ 1.36 because it utilizes the beta `PodCertificateRequest` and `ClusterTrustBundle` APIs, which are only enabled at cluster creation on GKE.
3. **Google Cloud Storage (GCS) for Snapshots:** State suspension/checkpointing and resume flows in AX rely on Substrate saving `/workspace` volume snapshots directly to a project-unique GCS bucket.

**Cost while up:** Two `c3-standard-4` VMs and their boot disks, the GKE management fee (unless covered by GKE's free tier), one small PD for Redis inside the `ax-system` namespace, a GCS bucket for snapshots, and images stored under `gcr.io/${PROJECT_ID}/${RESOURCE_PREFIX}`.

**Teardown** takes about 10 minutes, mostly cluster deletion. It deletes the GCS bucket along with all snapshots, and removes all container images under the repository namespace.

**Parameters** come from `params.env` (resolved at plan time, never hardcoded here): `PROJECT_ID`, `GCE_REGION`, `CLUSTER_LOCATION` (a zone inside `GCE_REGION`), and `RESOURCE_PREFIX`. Every resource created is named from `RESOURCE_PREFIX`.

### Feasibility Checklist

- **Permissions:** Each step assumes specific GCP IAM permissions:
  - **GKE Cluster Provisioning:** `container.clusters.create`, `container.clusters.get`, `container.clusters.update`, `container.nodePools.create` (granted via Kubernetes Engine Admin role).
  - **Snapshot GCS Bucket Management:** `storage.buckets.create`, `storage.buckets.get`, `storage.buckets.setIamPolicy` (granted via Storage Admin role).
  - **Project IAM Bindings:** `iam.serviceAccounts.create`, `iam.serviceAccounts.actAs`, `resourcemanager.projects.setIamPolicy` (granted via Project IAM Admin or Project Owner).
- **Tools:**
  - `gcloud` CLI: ✓ (version 585.0.0, present and authenticated)
  - `kubectl` CLI: ✓ (version 1.35.8, present)
  - `jq`: ✓ (present)
  - `go`: ✓ (version 1.27.1, present)
  - `ko`: ✗ MISSING — install using `go install github.com/google/ko@latest`
  - `docker`/`podman` daemon: ✗ MISSING (not required; the task-runner container image is compiled locally with Go and built via Google Cloud Build, and `ko` is completely daemonless)

---

## Preconditions

- The repository checkouts for **BOTH** `agent-substrate/substrate` and `google/ax` are cloned on your local workstation.
- A `params.env` file has been prepared at the root of the checkouts or sourced.
- `CLUSTER_LOCATION` is a zone in `GCE_REGION` that offers `c3-standard-4` machines.

---

## Steps

```bash
# 0. Parameters and derived names.
source params.env # PROJECT_ID GCE_REGION CLUSTER_LOCATION RESOURCE_PREFIX
export NO_DEV_ENV=1 GOCACHE=/tmp/gocache GOTMPDIR=/tmp/gotmp
export PATH="$(go env GOPATH)/bin:${PATH}"
mkdir -p "$GOCACHE" "$GOTMPDIR"

export PROJECT_NUMBER=$(gcloud projects describe "${PROJECT_ID}" --format="value(projectNumber)")
export CLUSTER_NAME="${RESOURCE_PREFIX}"
export BUCKET_NAME="${RESOURCE_PREFIX}-snap-${PROJECT_NUMBER}" # bucket names are global
export KO_DOCKER_REPO="gcr.io/${PROJECT_ID}/${RESOURCE_PREFIX}"
export AX_IMAGE_REPO="gcr.io/${PROJECT_ID}/${RESOURCE_PREFIX}"
export KO_DEFAULTPLATFORMS=linux/amd64
export NETWORK=default SUBNETWORK=default NODE_MACHINE_TYPE=c3-standard-4
export KUBECTL_CONTEXT="gke_${PROJECT_ID}_${CLUSTER_LOCATION}_${CLUSTER_NAME}"

# Install ko if missing
if ! command -v ko &> /dev/null; then
  echo "==> Installing ko..."
  go install github.com/google/ko@latest
fi

# ===========================================================================
# Part I: Provision and Deploy Agent Substrate
# ===========================================================================

# 1. Navigate to the agent-substrate/substrate checkout directory
cd /path/to/substrate # <--- REPLACE with your local substrate directory

# 2. APIs, cluster, bucket, IAM.
go run ./tools/setup-gcp enable apis
go run ./tools/setup-gcp create cluster # about 10 min; 2 nodes in substrate-node-pool
go run ./tools/setup-gcp create bucket
go run ./tools/setup-gcp create iam

# 3. Workers must not be drained by GKE (prevent autoupgrade conflicts).
gcloud container node-pools update substrate-node-pool \
 --cluster "${CLUSTER_NAME}" --location "${CLUSTER_LOCATION}" --no-enable-autoupgrade

# 4. Credentials.
gcloud container clusters get-credentials "${CLUSTER_NAME}" \
 --location "${CLUSTER_LOCATION}" --project "${PROJECT_ID}"

# 5. Control plane: ko builds and pushes every image, then applies Substrate components.
hack/install-ate.sh --deploy-ate-system --rollout-timeout=300s

# ===========================================================================
# Part II: Build and Deploy AX Platform
# ===========================================================================

# 6. Navigate back to the google/ax repository directory
cd /path/to/ax # <--- REPLACE with your local ax directory

# 7. Build local binaries and install the ax CLI
make build
make install # Installs CLI to $(go env GOPATH)/bin

# 8. Build and push the ax-task-runner container image using Google Cloud Build
# Because local docker/podman daemons are not required, we compile the Go runner binary locally for linux_amd64,
# and submit the remote Docker build to Google Cloud Build using the Task-Runner Dockerfile.
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o bin/linux_amd64/ax-task-runner ./cmd/ax-task-runner
cp Dockerfile.task-runner Dockerfile
gcloud builds submit --tag "gcr.io/${PROJECT_ID}/${RESOURCE_PREFIX}/ax-task-runner:latest" .
rm Dockerfile

# 9. Deploy AX platform components (Redis, ax-controller, ax-server) using ko
# ko compiles and deploys ax-controller and ax-server daemonlessly directly to GKE.
make deploy

# 10. Configure the ax-controller with the dynamic snapshot GCS bucket name
kubectl set env deployment/ax-controller -n ax-system AX_SNAPSHOTS_BUCKET="gs://${BUCKET_NAME}/"

# 11. Wait for deployment rollouts to complete
kubectl rollout status deployment/ax-controller -n ax-system --timeout=120s
kubectl rollout status deployment/ax-server -n ax-system --timeout=120s
```

---

## Verify

AX CLI has auto-tunneling capability built-in; as long as the current `kubectl` context is set to your active cluster, `ax` commands will automatically connect to `ax-server` via port-forwarding without requiring manual background tunnels.

```bash
# 1. Verify all Pods are running and healthy across both namespaces
kubectl get pods -n ate-system  # Substrate control plane
kubectl get pods -n ax-system   # AX platform (Redis, ax-controller, ax-server)

# 2. Check that the ax CLI can fetch current task status
ax get tasks -a default

# 3. Create a verification manifest pointing to your custom pushed task-runner image
cat <<EOF > test-task.yaml
apiVersion: ax.io/v1alpha1
kind: Workspace
metadata:
  name: gcp-test-workspace
  atespace: default
spec:
  git:
    - name: ax
      repo: "https://github.com/google/ax.git"
      branch: "main"
      depth: 1
---
apiVersion: ax.io/v1alpha1
kind: Task
metadata:
  name: gcp-test-task
  atespace: default
spec:
  debug: true # Required to expose guest ssh daemon
  image: "gcr.io/${PROJECT_ID}/${RESOURCE_PREFIX}/ax-task-runner:latest"
  workspaces:
    - name: gcp-test-workspace
      path: "/workspace"
  env:
    - name: TEST_ENV
      value: "gcp-verified"
EOF

# 4. Apply the verification manifest
ax apply -f test-task.yaml

# 5. Monitor task progression until Phase=Running and Ready=True (takes ~1-2 mins to clone workspace)
ax get tasks -a default
ax describe task gcp-test-task -a default

# 6. SSH into the sandboxed task container to verify the workspace git clone and environment variables
ax ssh gcp-test-task -a default -- sh -c 'ls -la /workspace'
ax ssh gcp-test-task -a default -- sh -c 'ls -la /workspace/ax/docs'
ax ssh gcp-test-task -a default -- sh -c 'echo "TEST_ENV=\$TEST_ENV"'

# 7. Suspend the task to verify checkpointing (Workspace gets archived and sandbox is torn down)
ax suspend task gcp-test-task -a default

# Watch task state transition to Phase=Suspended
ax describe task gcp-test-task -a default

# Verify that the checkpoint archive (.tar.gz snapshot) successfully landed in GCS
gcloud storage ls "gs://${BUCKET_NAME}/" | head

# 8. Resume the task to verify state restoration from GCS
ax resume task gcp-test-task -a default

# Watch task transition back to Phase=Running and Ready=True
# 9. SSH back into the sandbox to confirm files survived checkpointing/restoration
ax ssh gcp-test-task -a default -- sh -c 'ls -la /workspace/ax/docs'

# 10. Clean up verification resources
ax delete task gcp-test-task -a default
ax delete workspace gcp-test-workspace -a default
```

Success is verified when:
- The task is successfully suspended and creates a `.tar.gz` checkpoint archive inside the GCS bucket.
- The task is resumed, and files under `/workspace/ax` survive the lifecycle transition completely.

---

## Teardown

```bash
source params.env; export NO_DEV_ENV=1 # then re-run the Step 0 exports
export PROJECT_NUMBER=$(gcloud projects describe "${PROJECT_ID}" --format="value(projectNumber)")
export CLUSTER_NAME="${RESOURCE_PREFIX}"
export BUCKET_NAME="${RESOURCE_PREFIX}-snap-${PROJECT_NUMBER}"
export KO_DOCKER_REPO="gcr.io/${PROJECT_ID}/${RESOURCE_PREFIX}"

# 1. Clean up AX platform namespace first (deletes Redis PVC and its GCE PD)
kubectl delete namespace ax-system --wait=true

# 2. Navigate to your agent-substrate/substrate checkout directory to remove Substrate control plane
cd /path/to/substrate # <--- REPLACE with your local substrate directory
hack/install-ate.sh --delete-all

# 3. Revoke IAM policy bindings, delete GCS bucket (including all snapshots), and GKE cluster
hack/teardown.sh --delete-iam-policy-bindings --delete-snapshot-bucket --delete-cluster

# 4. Delete compiled task-runner and platform container images from GCR
for img in $(gcloud artifacts docker images list "${KO_DOCKER_REPO}" --format='value(package)' 2>/dev/null || gcloud container images list --repository="${KO_DOCKER_REPO}" --format='value(name)' 2>/dev/null); do
  gcloud artifacts docker images delete "${img}" --delete-tags --quiet 2>/dev/null || gcloud container images delete "${img}" --force-delete-tags --quiet 2>/dev/null
done

echo "Teardown complete. All GCP resources have been cleaned up."
```
