# Runbook: Deploy AX to Google Cloud Platform (GCP)

*Note: This revision adds steps to provision a GKE cluster and install Agent Substrate from source prior to deploying AX components.*

---

## What this needs

This deployment **cannot** run purely in-pod or as mock processes. It requires a real **GCP Infrastructure** (GKE, GCS, and GCR/Artifact Registry).

### Why real infrastructure is forced:
- **Agent Substrate integration**: The `ax-controller` integrates with the `Agent Substrate` Control API (running inside the GKE cluster at `api.ate-system.svc.cluster.local:443`) to orchestrate sandboxed execution environments.
- **Node-level / Pod-level reality**: Orchestrating task isolation, projected ServiceAccount tokens, and ClusterTrustBundles (`servicedns-ca`) requires a real Kubernetes control plane and node cluster. If `ClusterTrustBundles` are unsupported on the GKE cluster, the controller must be run with `--substrate-insecure-tls` flag and without `--substrate-ca-file` to bypass CA verification.
- **Image Registry requirement**: `ax-task-runner` must be hosted on a remote container registry (`GCR` or `Artifact Registry`) accessible by the GKE node kubelets. If local Docker/Podman environments are restricted (e.g. nested overlayfs operations are blocked), Google Cloud Build (`gcloud builds submit`) is the official fallback mechanism.

### Feasibility Checklist (Probed on Wednesday, September 23, 2026)

The following checklist represents the results of read-only probes executed under the current identity:

* **Tools:**
  - `go` (v1.27+): ✓ present
  - `kubectl`: ✓ present
  - `gcloud`: ✓ present
  - `ko` (for building container images): ✗ MISSING — Fix: `go install github.com/google/ko@latest`
  - `docker` / `podman` (for building the task-runner image): ✗ MISSING — Fix: `sudo apt-get update && sudo apt-get install -y docker.io` (or `podman`)

* **Permissions & Environments:**
  - GCP Cluster Create & IAM Bindings: ✓ present (Active service account `cnrm-barni-1.svc.id.goog` on project `barni-cnrm-20260529` holds the `roles/owner` role, enabling GKE creation, GCS bucket creation, and SetIamPolicy operations).
  - GCP Registry / Bucket Writer Permissions: ✓ present (Active service account holds write permission to GCR/GCS via `roles/owner` and `roles/artifactregistry.reader`).
  - GKE Cluster Access (`container.clusters.get`): ✓ present once the cluster is provisioned below.
  - Kubernetes cluster-admin RBAC: ✓ present once the cluster is provisioned below.

---

## Preconditions

1. **Set target environment parameters**:
   Export variables to target your GCP project and cluster settings:
   ```bash
   export PROJECT_ID="barni-cnrm-20260529" # (pinned)
   export CLUSTER_NAME="ics-1"           # (pinned)
   export REGION="us-central1"           # (pinned)
   export ZONE="us-central1-a"           # (pinned)
   export BUCKET_NAME="ate-snapshots-${PROJECT_ID}"
   export AX_IMAGE_REPO="gcr.io/${PROJECT_ID}/ate-images"
   export TASK_RUNNER_REPO="${AX_IMAGE_REPO}/ax-task-runner"
   export KO_DOCKER_REPO="${AX_IMAGE_REPO}"
   ```

2. **Enable required Google Cloud APIs** on your project:
   ```bash
   gcloud services enable container.googleapis.com containerregistry.googleapis.com --project="${PROJECT_ID}"
   ```

3. **Authenticate application default credentials**:
   Ensure you are authenticated so that Go/ko commands can perform GCP actions:
   ```bash
   gcloud auth application-default login --project="${PROJECT_ID}"
   ```

4. **Configure Docker authentication** for Google Container Registry:
   ```bash
   gcloud auth configure-docker gcr.io --quiet
   ```

---

## Steps

1. **Clone and configure Agent Substrate**:
   Since AX depends on Agent Substrate, clone it into a temporary location outside the `ax` workspace and configure its environment variables matching your GKE parameters:
   ```bash
   git clone https://github.com/agent-substrate/substrate /tmp/substrate
   cd /tmp/substrate
   
   # Setup dev environment configuration file
   cat <<EOF > .ate-dev-env.sh
   export PROJECT_ID="${PROJECT_ID}"
   export CLUSTER_NAME="${CLUSTER_NAME}"
   export REGION="${REGION}"
   export ZONE="${ZONE}"
   export BUCKET_NAME="${BUCKET_NAME}"
   export KO_DOCKER_REPO="${KO_DOCKER_REPO}"
   EOF
   ```

2. **Provision GKE cluster and GCS snapshot bucket**:
   Inside the `/tmp/substrate` directory, execute the Substrate setup-gcp tool to provision the GKE cluster, storage buckets, and IAM bindings:
   ```bash
   source .ate-dev-env.sh
   go run ./tools/setup-gcp bootstrap
   ```

3. **Install Agent Substrate components into the cluster**:
   Still inside the `/tmp/substrate` directory, install Agent Substrate control and data plane services under the `ate-system` namespace:
   ```bash
   ./hack/install-ate.sh --deploy-ate-system
   ```

4. **Build and push the AX Task Runner image**:
   Return to your `ax` repository directory, compile the task-runner, and push its container image to GCR:
   ```bash
   cd - # Return to the ax directory
   make push-task-runner
   ```
   *Fallback (Google Cloud Build):* If local `docker`/`podman` is unavailable, cross-compile the binary locally and push via Google Cloud Build:
   ```bash
   mkdir -p bin/linux_amd64
   GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o bin/linux_amd64/ax-task-runner ./cmd/ax-task-runner
   mv .dockerignore .dockerignore.bak || true
   cp Dockerfile.task-runner Dockerfile
   gcloud builds submit --tag="${TASK_RUNNER_REPO}:latest" --ignore-file=custom-gcloudignore --project="${PROJECT_ID}" .
   rm Dockerfile
   mv .dockerignore.bak .dockerignore || true
   ```

5. **Deploy Redis to the GKE Cluster**:
   Redis acts as the events queue and resource state store for AX. Deploy it to the `ax-system` namespace:
   ```bash
   make deploy-redis
   ```

6. **Deploy the AX Controller**:
   The controller reconciles tasks from Redis Streams and provisions sandboxes through Agent Substrate. Deploy it using `ko`:
   ```bash
   make deploy-controller
   ```

7. **Deploy the AX Server**:
   The API server serves the gRPC and HTTP endpoints used by the `ax` CLI. Deploy it using `ko`:
   ```bash
   make deploy-server
   ```

---

## Verify

1. **Verify all workloads are running in the `ax-system` namespace**:
   Ensure all deployments successfully roll out and transition to the running state:
   ```bash
   kubectl rollout status deployment/ax-redis -n ax-system
   kubectl rollout status deployment/ax-controller -n ax-system
   kubectl rollout status deployment/ax-server -n ax-system
   ```

2. **Verify active deployment status with Kubernetes**:
   ```bash
   kubectl get pods -n ax-system
   kubectl get svc -n ax-system
   ```

3. **Verify ax CLI client connection**:
   Compile the local CLI and check the server status. The CLI will automatically detect the Kubernetes context and open a background port-forward tunnel to `ax-server`:
   ```bash
   make build
   ./bin/ax ctx
   ```

4. **Run the End-to-End Demo**:
   Execute the AX demo lifecycle to verify container provisioning, SSH connectivity, workspace cloning, and task suspension:
   ```bash
   ./demo.sh
   ```

---

## Teardown

To clean up all deployed AX components, namespaces, and provisioned GCP hardware resources:

1. **Delete AX components**:
   ```bash
   kubectl delete -f deploy/ax-server.yaml --ignore-not-found
   kubectl delete -f deploy/ax-controller.yaml --ignore-not-found
   kubectl delete -f deploy/redis.yaml --ignore-not-found
   kubectl delete namespace ax-system --ignore-not-found
   ```

2. **Delete Agent Substrate components**:
   ```bash
   cd /tmp/substrate
   ./hack/install-ate.sh --delete-all
   ```

3. **Delete the GKE cluster and GCS bucket**:
   Tear down the provisioned GCP infrastructure to avoid continuing charges:
   ```bash
   gcloud container clusters delete "${CLUSTER_NAME}" --region "${REGION}" --quiet
   gcloud storage buckets delete "gs://${BUCKET_NAME}" --recursive --quiet
   ```

4. **(Optional) Remove local CLI binary build artifacts**:
   ```bash
   cd - # Return to the ax directory
   make clean
   ```
