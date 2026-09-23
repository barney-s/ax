# Deploy GCP GKE Runbook

This runbook guides you through provisioning a real Google Kubernetes Engine (GKE) cluster, setting up Google Cloud Storage (GCS) for task checkpoint snapshots, compiling and publishing the `ax-task-runner` container image, and deploying the AX platform components (Redis, ax-server, and ax-controller) on GCP infrastructure.

---

## What this needs

This scenario **needs real cloud infrastructure and real nodes**. It cannot run solely within a local developer sandbox or pod because it requires physical cloud resources, persistent block storage, network overlay configurations, and gVisor isolation capabilities provided by Agent Substrate.

### Components forcing real infrastructure:
- **Agent Substrate & `ate-env` Runtimes**: Requires real GKE nodes configured with kernel headers to support gVisor sandboxes (`SANDBOX_CLASS_GVISOR`), physical persistent disk volume claims for Actor `/workspace` persistence, and external/internal ingress routing controllers.
- **GCS Bucket**: Required to store snapshot checkpoints of task Actor volumes (`/workspace`) on task suspension and restoration.

### Cost of Teardown
- Approximately **$0.01 - $0.05 per hour** of cluster runtime (primarily standard GKE VM instance usage, e.g. `e2-standard-4`). Tearing down all resources immediately after validation keeps costs minimal.

### Feasibility Checklist
- [x] **gcloud CLI**: Present (`gcloud version` shows active installation, active project: `barni-cnrm-20260529`)
- [x] **kubectl CLI**: Present (Installed and ready)
- [x] **Go 1.27+ Compiler**: Present (`go version` shows `go1.27.1`)
- [ ] **ko CLI**: MISSING (Must be installed on the operator's machine via `go install github.com/google/ko@latest`)
- [ ] **Docker / Podman Daemon**: MISSING (Must be installed and active to build the linux/amd64 task-runner container image)
- [ ] **Agent Substrate Control Plane**: MISSING (Assumes Substrate control services are pre-installed or will be installed in the `ate-system` namespace on the GKE cluster)

### IAM Permissions Required
The executing identity (`cnrm-barni-1.svc.id.goog`) requires the following IAM roles or permissions on the target GCP project:
- **Kubernetes Engine Admin (`roles/container.admin`)**:
  - `container.clusters.create`
  - `container.clusters.get`
  - `container.clusters.update`
- **Storage Admin (`roles/storage.admin`)**:
  - `storage.buckets.create`
  - `storage.buckets.get`
  - `storage.objects.create`
  - `storage.objects.delete`
- **Artifact Registry Admin (`roles/artifactregistry.admin`)** or **Storage Admin**:
  - Writing and pushing Docker images to GCR/GAR.

---

## Preconditions

1. An active Google Cloud Project ID is exported as `${GCP_PROJECT}`.
2. A unique instance identifier prefix is exported as `${RESOURCE_PREFIX}` (e.g. `ax-prod-1`). All created cloud resources will be prefixed with this value.
3. The GCP target region is exported as `${GCP_REGION}` (default: `us-central1`).
4. Docker/Podman is running locally, and `ko` is installed.
5. The `gcloud` CLI is logged in and configured to the target project:
   ```bash
   gcloud config set project ${GCP_PROJECT}
   gcloud config set compute/region ${GCP_REGION}
   ```

---

## Steps

### 1. Provision GKE Cluster and credentials
Create the GKE cluster with gVisor-enabled node pools and retrieve its access context:
```bash
# Provision a standard GKE cluster
gcloud container clusters create "${RESOURCE_PREFIX}-gke" \
  --num-nodes=3 \
  --machine-type="e2-standard-4" \
  --addons=GcePersistentDiskCsiDriver \
  --workload-pool="${GCP_PROJECT}.svc.id.goog"

# Fetch kubeconfig credentials
gcloud container clusters get-credentials "${RESOURCE_PREFIX}-gke"
```

### 2. Create the GCS checkpoint bucket
Create the bucket where AX will store compressed workspace state snapshots during task suspension:
```bash
gcloud storage buckets create "gs://${RESOURCE_PREFIX}-snapshots" \
  --project="${GCP_PROJECT}" \
  --location="${GCP_REGION}"
```

### 3. Install Agent Substrate (Control Plane)
Deploy the Agent Substrate platform operator and its routing service onto the GKE cluster. Follow the standard installation guidelines of the Agent Substrate project to ensure `api.ate-system.svc.cluster.local` is fully operational in the `ate-system` namespace.

### 4. Build and Push the Task-Runner Image
The `ax-task-runner` serves as the guest supervisor inside tasks. Package and push it to Google Container Registry (GCR) or Artifact Registry (GAR):
```bash
# Define your image repository path
export AX_IMAGE_REPO="gcr.io/${GCP_PROJECT}/${RESOURCE_PREFIX}-images"
export TASK_RUNNER_REPO="${AX_IMAGE_REPO}/ax-task-runner"

# Cross-compile for Linux and build/push using Makefile tooling
make push-task-runner
```

### 5. Deploy AX Components (Redis, Server, Controller)
Deploy the AX state store (Redis), the API server, and the horizontal controller workers using Go `ko` compilation:
```bash
# Export the ko target repository
export KO_DOCKER_REPO="${AX_IMAGE_REPO}"

# Deploy the standard Redis state store
make deploy-redis

# Build and apply controller and server manifests using ko
make deploy-controller
make deploy-server
```

### 6. Configure Controller Snapshots Bucket
Update the newly deployed `ax-controller` to use your custom GCS bucket for volume checkpoints:
```bash
kubectl set env deployment/ax-controller -n ax-system \
  AX_SNAPSHOTS_BUCKET="gs://${RESOURCE_PREFIX}-snapshots/"
```

---

## Verify

Verify that the GKE deployment has succeeded and the control plane is healthy:

1. **Verify Pod Status:** All AX system pods must be in the `Running` state:
   ```bash
   kubectl get pods -n ax-system
   ```
2. **Verify API Server Connectivity:** Port-forward the AX API server and query tasks via the CLI:
   ```bash
   # In a background shell or process
   kubectl port-forward svc/ax-server -n ax-system 8080:8080 &
   PORT_FORWARD_PID=$!
   sleep 2

   # Query the cluster using local CLI compiled from source
   ./bin/ax get tasks
   ```
3. **Verify Demo Lifecycle Flow:** Run the standard demo script to test Task submission, Atespace generation, sandbox boot, `ax ssh` connectivity, task suspension (checkpoint upload to GCS), and task deletion:
   ```bash
   AX_BIN=./bin/ax ./demo.sh
   ```
4. **Cleanup Port Forward:** Close the active port-forward tunnel:
   ```bash
   kill $PORT_FORWARD_PID
   ```

---

## Teardown

To avoid incurring continuous cloud costs, tear down the GCP resources once verification is complete:

1. **Delete the GKE Cluster:**
   ```bash
   gcloud container clusters delete "${RESOURCE_PREFIX}-gke" --quiet
   ```
2. **Delete the GCS Snapshots Bucket:**
   ```bash
   gcloud storage buckets delete "gs://${RESOURCE_PREFIX}-snapshots" --recursive --quiet
   ```
3. **Delete Published Images:** Remove the Artifact Registry / GCR images deployed for this instance:
   ```bash
   gcloud container images delete "${TASK_RUNNER_REPO}:latest" --force-delete-tags --quiet
   ```
