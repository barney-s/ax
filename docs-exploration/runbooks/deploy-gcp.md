# Runbook: Deploy AX to Google Cloud Platform (GCP)

This runbook guides you through deploying AX components (Redis, ax-controller, and ax-server) to Google Kubernetes Engine (GKE) and Google Container Registry (GCR) or Google Artifact Registry.

---

## What this needs

This deployment **cannot** run purely in-pod or as mock processes. It requires a real **GCP Infrastructure** (GKE and GCR/Artifact Registry). 

### Why real infrastructure is forced:
- **Agent Substrate integration**: The `ax-controller` integrates with the `Agent Substrate` Control API (running inside the GKE cluster at `api.ate-system.svc.cluster.local`) to orchestrate sandboxed execution environments.
- **Node-level / Pod-level reality**: Orchestrating task isolation, projected ServiceAccount tokens, and ClusterTrustBundles (`servicedns-ca`) requires a real Kubernetes control plane and node cluster. If `ClusterTrustBundles` are unsupported on the GKE cluster, the controller must be run with `--substrate-insecure-tls` flag and without `--substrate-ca-file` to bypass CA verification.
- **Image Registry requirement**: `ax-task-runner` must be hosted on a remote container registry (`GCR` or `Artifact Registry`) accessible by the GKE node kubelets. If local Docker/Podman environments are restricted (e.g. nested overlayfs operations are blocked), Google Cloud Build (`gcloud builds submit`) is the official fallback mechanism.

### Feasibility Checklist (Probed on Wednesday, September 23, 2026)

The following checklist represents the results of read-only probes executed under the current identity:

* **Tools:**
  - `go` (v1.27+): ✓ present
  - `kubectl`: ✓ present
  - `gcloud`: ✓ present
  - `ko` (for controller and server container builds): ✗ MISSING — Fix: `go install github.com/google/ko@latest`
  - `docker` / `podman` (for building the task-runner image): ✗ MISSING — Fix: `sudo apt-get update && sudo apt-get install -y docker.io` (or `podman`)

* **Permissions & Environments:**
  - GCP Registry / Bucket Writer Permissions: ✓ present (Active service account `cnrm-barni-1.svc.id.goog` on project `barni-cnrm-20260529` holds the `roles/owner` and `roles/artifactregistry.reader` roles, giving write permission to GCR/GCS).
  - GKE Cluster Access (`container.clusters.get`): ✗ MISSING — Fix: No active cluster or kubeconfig is configured in the environment. Set up a GKE cluster and fetch credentials.
  - Kubernetes cluster-admin RBAC: ✗ MISSING — Fix: Configure access to an active GKE cluster.

---

## Preconditions

1. **Enable required Google Cloud APIs** on your project:
   ```bash
   gcloud services enable container.googleapis.com containerregistry.googleapis.com
   ```
2. **Access GKE cluster** (retrieve and configure kubeconfig credentials):
   ```bash
   gcloud container clusters get-credentials <your-gke-cluster> --region <your-region>
   ```
3. **Configure Docker authentication** for Google Container Registry:
   ```bash
   gcloud auth configure-docker gcr.io
   ```
4. **Choose your registry repositories** and export them as environment variables:
   ```bash
   export PROJECT_ID=$(gcloud config get-value project)
   export AX_IMAGE_REPO="gcr.io/${PROJECT_ID}/ate-images"
   export TASK_RUNNER_REPO="${AX_IMAGE_REPO}/ax-task-runner"
   ```

---

## Steps

1. **Build and push the Task Runner container image**:
   The AX controller deploys sandboxes using the task runner image. Compile the task-runner binary and build/push its container:
   ```bash
   make push-task-runner
   ```
   *Fallback (Google Cloud Build):* If local `docker`/`podman` is unavailable or restricted, cross-compile the binary locally and build/push via Google Cloud Build:
   ```bash
   mkdir -p bin/linux_amd64
   GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o bin/linux_amd64/ax-task-runner ./cmd/ax-task-runner
   mv .dockerignore .dockerignore.bak || true
   cp Dockerfile.task-runner Dockerfile
   gcloud builds submit --tag="${TASK_RUNNER_REPO}:latest" --ignore-file=custom-gcloudignore --project="${PROJECT_ID}" .
   rm Dockerfile
   mv .dockerignore.bak .dockerignore || true
   ```

2. **Deploy Redis to the GKE Cluster**:
   Redis acts as the events queue and resource state store for AX. Deploy it to the `ax-system` namespace:
   ```bash
   make deploy-redis
   ```

3. **Deploy the AX Controller**:
   The controller reconciles tasks from Redis Streams and provisions sandboxes through Agent Substrate. Deploy it using `ko`:
   ```bash
   make deploy-controller
   ```

4. **Deploy the AX Server**:
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

To clean up all deployed AX components, namespaces, and services from your cluster:

1. **Delete AX components**:
   ```bash
   kubectl delete -f deploy/ax-server.yaml --ignore-not-found
   kubectl delete -f deploy/ax-controller.yaml --ignore-not-found
   kubectl delete -f deploy/redis.yaml --ignore-not-found
   ```

2. **Delete the namespace**:
   ```bash
   kubectl delete namespace ax-system --ignore-not-found
   ```

3. **(Optional) Remove local CLI binary build artifacts**:
   ```bash
   make clean
   ```
