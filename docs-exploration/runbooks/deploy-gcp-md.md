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

### 1. Clone Agent Substrate Repository and Configure Environment
Clone the Agent Substrate source code from its repository and prepare your environment configuration. This repository contains the automated `setup-gcp` tool, deployment helper scripts, and source manifests used to build and install Agent Substrate from source:
```bash
# Clone the repository
git clone https://github.com/agent-substrate/substrate.git
cd substrate

# Create the params.env configuration file to guide the setup tool
cat <<EOF > params.env
export PROJECT_ID="${GCP_PROJECT}"
export GCE_REGION="${GCP_REGION}"
export CLUSTER_LOCATION="${CLUSTER_LOCATION:-us-central1-a}"
export RESOURCE_PREFIX="${RESOURCE_PREFIX}"
EOF

# Load the parameters and export derived environment variables
source params.env
export NO_DEV_ENV=1 GOCACHE=/tmp/gocache GOTMPDIR=/tmp/gotmp
export PATH="$(go env GOPATH)/bin:${PATH}"
mkdir -p "$GOCACHE" "$GOTMPDIR"

# Generate derived names matching Substrate setup patterns
export PROJECT_NUMBER=$(gcloud projects describe "${PROJECT_ID}" --format="value(projectNumber)")
export CLUSTER_NAME="${RESOURCE_PREFIX}"
export BUCKET_NAME="${RESOURCE_PREFIX}-snap-${PROJECT_NUMBER}"
export KO_DOCKER_REPO="gcr.io/${PROJECT_ID}/${RESOURCE_PREFIX}"
export KO_DEFAULTPLATFORMS=linux/amd64
export NETWORK=default SUBNETWORK=default NODE_MACHINE_TYPE=e2-standard-4
export CLUSTER_VERSION=$(gcloud container get-server-config --location "${CLUSTER_LOCATION}" \
 --format=json | jq -r '.validMasterVersions[]' | grep -m1 '^1\.36\.')
export KUBECTL_CONTEXT="gke_${PROJECT_ID}_${CLUSTER_LOCATION}_${CLUSTER_NAME}"
```

### 2. Provision Infrastructure using Setup Tool
Instead of running verbose, error-prone manual GCP CLI commands, execute Substrate's automated Go-based provisioning tool. This enables necessary APIs, creates the GKE cluster (with the standard node pool configurations), provisions the global GCS snapshots bucket, and configures project/instance-level IAM bindings:
```bash
# Enable APIs, create the cluster, bucket, and IAM roles/bindings
go run ./tools/setup-gcp enable apis
go run ./tools/setup-gcp create cluster # about 10 mins
go run ./tools/setup-gcp create bucket
go run ./tools/setup-gcp create iam

# Ensure GKE node-pool workers are never drained or auto-upgraded during runtime
gcloud container node-pools update substrate-node-pool \
 --cluster "${CLUSTER_NAME}" --location "${CLUSTER_LOCATION}" --no-enable-autoupgrade

# Fetch and activate the kubeconfig credentials for your cluster
gcloud container clusters get-credentials "${CLUSTER_NAME}" \
 --location "${CLUSTER_LOCATION}" --project "${PROJECT_ID}"
```

### 3. Deploy Agent Substrate from Source (Control Plane)
Pre-create the required namespaces, configure Workload Identity for AX component access to the snapshot bucket, and compile/deploy the Substrate control plane directly from your source checkout:

#### 3a. Pre-Create Namespaces and Configure AX Workload Identity
Create the logical namespaces and authorize AX's Kubernetes service accounts to impersonate the created GCP Service Account (GSA) so they can read/write checkpoints:
```bash
# Create standard namespaces
kubectl create namespace ate-system || true
kubectl create namespace ax-system || true

# Pre-create and annotate the AX controller service account for GKE Workload Identity
kubectl create serviceaccount ax-controller -n ax-system || true
kubectl annotate serviceaccount ax-controller -n ax-system --overwrite \
  "iam.gke.io/gcp-service-account"="${RESOURCE_PREFIX}-sa@${PROJECT_ID}.iam.gserviceaccount.com"

# Bind AX controller KSA to the Google Service Account via IAM Workload Identity
gcloud iam service-accounts add-iam-policy-binding "${RESOURCE_PREFIX}-sa@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:${PROJECT_ID}.svc.id.goog[ax-system/ax-controller]" \
  --project="${PROJECT_ID}"
```

#### 3b. Compile and Roll Out Substrate Control Plane
Use `ko` and the repository's installer script to compile the Substrate binaries, build container images, publish them to your Artifact Registry/GCR, and deploy the entire control plane onto the GKE cluster:
```bash
# Install and roll out the core control plane workloads (CRDs, APIs, atelet, and routing gateways)
hack/install-ate.sh --deploy-ate-system --rollout-timeout=300s

# Manually annotate the newly created Substrate KSAs to complete the Workload Identity loop
kubectl annotate serviceaccount substrate-controller -n ate-system --overwrite \
  "iam.gke.io/gcp-service-account"="${RESOURCE_PREFIX}-sa@${PROJECT_ID}.iam.gserviceaccount.com"

kubectl annotate serviceaccount atelet -n ate-system --overwrite \
  "iam.gke.io/gcp-service-account"="${RESOURCE_PREFIX}-sa@${PROJECT_ID}.iam.gserviceaccount.com"

# Return to the AX repository root
cd ..
```

### 4. Build and Push the Task-Runner Image
The `ax-task-runner` serves as the guest supervisor inside tasks. Package and push it to Google Container Registry (GCR) or Artifact Registry (GAR):
```bash
# Define your image repository path and parameters
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
# Configure the controller with the exact GCS bucket name generated by the setup tool
export PROJECT_NUMBER=$(gcloud projects describe "${GCP_PROJECT}" --format="value(projectNumber)")
export BUCKET_NAME="${RESOURCE_PREFIX}-snap-${PROJECT_NUMBER}"

kubectl set env deployment/ax-controller -n ax-system \
  AX_SNAPSHOTS_BUCKET="gs://${BUCKET_NAME}/"
```

---

## Verify

Verify that the GKE deployment has succeeded and the control plane is healthy:

1. **Verify Pod Status:** All AX and Substrate system pods must be in the `Running` state:
   ```bash
   kubectl get pods -n ax-system
   kubectl get pods -n ate-system
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

1. **Delete AX Components and Substrate Control Plane:**
   ```bash
   # Return to the substrate directory
   cd substrate

   # Ensure the parameters and environment are loaded
   source params.env
   export PROJECT_NUMBER=$(gcloud projects describe "${PROJECT_ID}" --format="value(projectNumber)")
   export CLUSTER_NAME="${RESOURCE_PREFIX}"
   export BUCKET_NAME="${RESOURCE_PREFIX}-snap-${PROJECT_NUMBER}"
   export KO_DOCKER_REPO="gcr.io/${PROJECT_ID}/${RESOURCE_PREFIX}"

   # Delete all Substrate control plane workloads and CRDs from the cluster
   hack/install-ate.sh --delete-all
   ```
2. **Delete GCP Infrastructure and IAM Bindings:**
   Use Substrate's automated teardown utility to destroy the cluster, snapshot bucket, and IAM/Workload Identity bindings:
   ```bash
   # Tear down the GCP cluster, bucket, and bindings
   hack/teardown.sh --delete-iam-policy-bindings --delete-snapshot-bucket --delete-cluster
   ```
3. **Delete Published Images:** Remove the published images from GCR/Artifact Registry to clean up the workspace:
   ```bash
   # Delete Substrate images
   for img in $(gcloud artifacts docker images list "${KO_DOCKER_REPO}" --format='value(package)' | sort -u); do
     gcloud artifacts docker images delete "${img}" --delete-tags --quiet
   done

   # Return to AX root and delete AX images
   cd ..
   export AX_IMAGE_REPO="gcr.io/${GCP_PROJECT}/${RESOURCE_PREFIX}-images"
   gcloud container images delete "${AX_IMAGE_REPO}/ax-task-runner:latest" --force-delete-tags --quiet
   ```
