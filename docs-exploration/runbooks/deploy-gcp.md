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
- [x] **gcloud CLI**: ✓ Present (`gcloud version` shows active installation, active project: `barni-cnrm-20260529`)
- [x] **kubectl CLI**: ✓ Present (Installed and ready)
- [x] **Go 1.27+ Compiler**: ✓ Present (`go version` shows `go1.27.1`)
- [ ] **ko CLI**: ✗ MISSING (Install on the operator's machine via `go install github.com/google/ko@latest`. Crucial for compiling and deploying Agent Substrate and AX from source)
- [ ] **Docker / Podman Daemon**: ✗ MISSING (Install Docker and start the daemon to build the linux/amd64 container images)
- [ ] **Agent Substrate Source Code**: ✗ MISSING (Clone `https://github.com/agent-substrate/substrate` to build and deploy from source)

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
- **Security Admin (`roles/iam.admin`)** or **Project IAM Admin (`roles/resourcemanager.projectIamAdmin`)**:
  - Creating GCP Service Accounts and binding IAM policies for Workload Identity.

---

## Preconditions

1. An active Google Cloud Project ID is exported as `${GCP_PROJECT}`.
2. A unique instance identifier prefix is exported as `${RESOURCE_PREFIX}` (e.g. `ax-prod-1`). All created cloud resources will be prefixed with this value.
3. The GCP target region is exported as `${GCP_REGION}` (default: `us-central1`).
4. Docker/Podman is running locally, and `ko` is installed.
5. **GKE Standard Volume, RBAC, & Template Constraints**:
   - GKE standard clusters do not support the Kubernetes `ClusterTrustBundle` API. The projected volume `servicedns-ca` in `ax-controller.yaml` must be mounted from a local replicated `ateapi-ca` ConfigMap.
   - Substrate `ate-api-server` and `atelet` worker pods require cluster-scoped list/watch permissions for `storageclasses` (and `csidriverconfigs`) to synchronize their internal startup reflectors. Because GKE admission webhooks can revert direct edits on the original `ate-api-server-role` ClusterRole, a separate custom ClusterRole and Binding (e.g., `ate-api-server-extra-role` and `ate-api-server-extra-binding`) must be created to grant these.
   - Substrate `0.0.12` uses Valkey/Redis but requires an empty `ate-api-authentication` ConfigMap to exist in the `ate-system` namespace to satisfy its volume mount.
   - Active worker nodes must have corresponding `WorkerPool` custom resources (e.g. `default-workerpool`) declared in the cluster namespaces for workers to successfully register as active/available.
   - In GKE standard virtualization environments, executing sandboxed actors will fail at the container socket initialization stage due to host mounting restrictions, meaning end-to-end task boots are DEPLOYED-UNVERIFIED.
6. The `gcloud` CLI is logged in and configured to the target project:
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
Deploy the Agent Substrate platform operator, daemonsets, and its routing service onto the GKE cluster. We configure GKE Workload Identity to authorize Agent Substrate and AX to read and write to the GCS snapshots bucket, and then compile and deploy Substrate from source.

#### 3a. Provision GCP Service Account & GCS IAM Roles
Create a dedicated Google Cloud Service Account (GSA) and grant it administrative access to the GCS snapshots bucket:
```bash
# Create the Google Service Account
gcloud iam service-accounts create "${RESOURCE_PREFIX}-sa" \
  --project="${GCP_PROJECT}" \
  --display-name="AX and Substrate GCS Service Account"

# Grant the storage.objectAdmin role on the GCS snapshots bucket to the GSA
gcloud storage buckets add-iam-policy-binding "gs://${RESOURCE_PREFIX}-snapshots" \
  --member="serviceAccount:${RESOURCE_PREFIX}-sa@${GCP_PROJECT}.iam.gserviceaccount.com" \
  --role="roles/storage.objectAdmin"
```

#### 3b. Bind Kubernetes Service Accounts (KSA) using Workload Identity
Allow the Kubernetes Service Accounts (KSAs) used by Agent Substrate and AX to impersonate the GSA:
```bash
# Bind Substrate's controller KSA (in ate-system namespace)
gcloud iam service-accounts add-iam-policy-binding "${RESOURCE_PREFIX}-sa@${GCP_PROJECT}.iam.gserviceaccount.com" \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:${GCP_PROJECT}.svc.id.goog[ate-system/substrate-controller]" \
  --project="${GCP_PROJECT}"

# Bind Substrate's atelet daemon KSA (in ate-system namespace)
gcloud iam service-accounts add-iam-policy-binding "${RESOURCE_PREFIX}-sa@${GCP_PROJECT}.iam.gserviceaccount.com" \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:${GCP_PROJECT}.svc.id.goog[ate-system/atelet]" \
  --project="${GCP_PROJECT}"

# Bind AX's controller KSA (in ax-system namespace)
gcloud iam service-accounts add-iam-policy-binding "${RESOURCE_PREFIX}-sa@${GCP_PROJECT}.iam.gserviceaccount.com" \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:${GCP_PROJECT}.svc.id.goog[ax-system/ax-controller]" \
  --project="${GCP_PROJECT}"
```

#### 3c. Pre-Create Namespaces and Annotate AX Controller
Create the required namespaces and pre-annotate the AX controller service account so that it automatically inherits the GSA's permissions when deployed:
```bash
# Create namespaces
kubectl create namespace ate-system || true
kubectl create namespace ax-system || true

# Pre-create and annotate the AX controller service account
kubectl create serviceaccount ax-controller -n ax-system || true
kubectl annotate serviceaccount ax-controller -n ax-system --overwrite \
  "iam.gke.io/gcp-service-account"="${RESOURCE_PREFIX}-sa@${GCP_PROJECT}.iam.gserviceaccount.com"
```

#### 3d. Clone Agent Substrate Repository
Clone the Agent Substrate source code from its repository. This repository contains the installer scripts, manifests, and build logic to compile Agent Substrate from source:
```bash
# Clone the repository
git clone https://github.com/agent-substrate/substrate.git
cd substrate
```

#### 3e. Build and Deploy Agent Substrate from Source
Configure the deployment environment variables, targeting your active GKE cluster, GCP project, and snapshots bucket, then run the installer script. This will use Go compilation and `ko` to build OCI images from source, publish them to your container registry, and deploy the CRDs and components onto the cluster:
```bash
# Export standard environment variables for building and installing from source
export PROJECT_ID="${GCP_PROJECT}"
export BUCKET_NAME="${RESOURCE_PREFIX}-snapshots"
export CLUSTER_NAME="${RESOURCE_PREFIX}-gke"
export CLUSTER_LOCATION="${GCP_REGION}-a"
export KO_DOCKER_REPO="gcr.io/${GCP_PROJECT}/${RESOURCE_PREFIX}-images/substrate"
export KO_DEFAULTPLATFORMS="linux/amd64"

# Run the installation script to compile and deploy the core system (CRDs, APIs, atelet, gateway)
./hack/install-ate.sh --deploy-ate-system
```

#### 3f. Annotate Service Accounts for Workload Identity
Since the deployment from source creates the Kubernetes Service Accounts (KSAs) in the `ate-system` namespace, manually apply the GKE Workload Identity annotations to authorize them to access the GCS snapshots bucket via your Google Service Account (GSA):
```bash
# Annotate the Substrate controller service account
kubectl annotate serviceaccount substrate-controller -n ate-system --overwrite \
  "iam.gke.io/gcp-service-account"="${RESOURCE_PREFIX}-sa@${GCP_PROJECT}.iam.gserviceaccount.com"

# Annotate the atelet daemon service account
kubectl annotate serviceaccount atelet -n ate-system --overwrite \
  "iam.gke.io/gcp-service-account"="${RESOURCE_PREFIX}-sa@${GCP_PROJECT}.iam.gserviceaccount.com"

# Return to the AX repository root
cd ..
```

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
4. **Delete GCP Service Account:**
   ```bash
   gcloud iam service-accounts delete "${RESOURCE_PREFIX}-sa@${GCP_PROJECT}.iam.gserviceaccount.com" --quiet
   ```
