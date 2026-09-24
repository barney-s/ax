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
- [x] **Go Compiler**: ✓ Present
- [x] **ko CLI**: ✓ Present (`go install github.com/google/ko@latest`, builds images directly to registry without local Docker daemon)
- [x] **Helm 3**: ✓ Present (Installed via get.helm.sh binary release)
- [x] **Google Cloud Build**: ✓ Present (Used to build and push task-runner image when local Docker daemon is not available)

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
- **Cloud Build Editor (`roles/cloudbuild.builds.editor`)**:
  - Submitting container builds for `ax-task-runner`.
- **Security Admin (`roles/iam.admin`)** or **Project IAM Admin (`roles/resourcemanager.projectIamAdmin`)**:
  - Creating GCP Service Accounts and binding IAM policies for Workload Identity.

---

## Preconditions

1. An active Google Cloud Project ID is exported as `${GCP_PROJECT}`.
2. A unique instance identifier prefix is exported as `${RESOURCE_PREFIX}` (e.g. `ax-instance3`). All created cloud resources will be prefixed with this value.
3. The GCP target region is exported as `${GCP_REGION}` (default: `us-central1`) and zone as `${CLUSTER_LOCATION}` (e.g. `us-central1-a`).
4. `ko` and `helm` are installed and available in `$PATH`.
5. **GKE Standard Volume, RBAC, & Template Constraints**:
   - GKE standard clusters do not support the Kubernetes `ClusterTrustBundle` API. The projected volume `servicedns-ca` in `ax-controller.yaml` must be mounted from a local replicated `ateapi-ca` ConfigMap.
   - Substrate `ate-api-server` and `atelet` worker pods require cluster-scoped list/watch permissions for `storageclasses` and `csidriverconfigs` to synchronize their internal startup reflectors. Because GKE admission webhooks can revert direct edits on the original `ate-api-server-role` ClusterRole, a separate custom ClusterRole and Binding (`ate-api-server-extra-role` and `ate-api-server-extra-binding`) must be created before starting the substrate workloads.
   - Substrate `0.0.12` Helm chart requires `sandboxconfigs.ate.dev` CRD schema to have `required: [sandboxClass]` without requiring `pauseImage`.
   - `ActorTemplate` resources in Substrate require container images to be pinned to explicit digest references (`@sha256:...`).
6. The `gcloud` CLI is logged in and configured to the target project:
   ```bash
   gcloud config set project ${GCP_PROJECT}
   gcloud config set compute/region ${GCP_REGION}
   gcloud config set compute/zone ${CLUSTER_LOCATION}
   ```

---

## Steps

### 1. Provision GKE Cluster and credentials
Create the GKE cluster with gVisor-enabled node pools and retrieve its access context:
```bash
# Provision a standard GKE cluster
gcloud container clusters create "${RESOURCE_PREFIX}-gke" \
  --zone "${CLUSTER_LOCATION}" \
  --num-nodes=3 \
  --machine-type="e2-standard-4" \
  --async \
  --addons=GcePersistentDiskCsiDriver \
  --workload-pool="${GCP_PROJECT}.svc.id.goog" \
  --labels="repo-agent-instance=${RESOURCE_PREFIX}"

# Wait for cluster RUNNING status and fetch kubeconfig credentials
gcloud container clusters get-credentials "${RESOURCE_PREFIX}-gke" --zone "${CLUSTER_LOCATION}"
```

### 2. Create the GCS checkpoint bucket
Create the bucket where AX will store compressed workspace state snapshots during task suspension:
```bash
gcloud storage buckets create "gs://${RESOURCE_PREFIX}-snapshots" \
  --project="${GCP_PROJECT}" \
  --location="${GCP_REGION}"

gcloud storage buckets update "gs://${RESOURCE_PREFIX}-snapshots" \
  --update-labels="repo-agent-instance=${RESOURCE_PREFIX}"
```

### 3. Install Agent Substrate (Control Plane)
Deploy the Agent Substrate platform operator, daemonsets, and its routing service onto the GKE cluster using Helm 3.

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

gcloud projects add-iam-policy-binding "${GCP_PROJECT}" \
  --member="serviceAccount:${RESOURCE_PREFIX}-sa@${GCP_PROJECT}.iam.gserviceaccount.com" \
  --role="roles/storage.objectViewer"

gcloud projects add-iam-policy-binding "${GCP_PROJECT}" \
  --member="serviceAccount:${RESOURCE_PREFIX}-sa@${GCP_PROJECT}.iam.gserviceaccount.com" \
  --role="roles/artifactregistry.reader"
```

#### 3b. Bind Kubernetes Service Accounts (KSA) using Workload Identity
Allow the Kubernetes Service Accounts (KSAs) used by Agent Substrate and AX to impersonate the GSA:
```bash
for sa in "ate-system/substrate-controller" "ate-system/atelet" "ax-system/ax-controller" "ax-system/default" "default/default"; do
  gcloud iam service-accounts add-iam-policy-binding "${RESOURCE_PREFIX}-sa@${GCP_PROJECT}.iam.gserviceaccount.com" \
    --role="roles/iam.workloadIdentityUser" \
    --member="serviceAccount:${GCP_PROJECT}.svc.id.goog[${sa}]" \
    --project="${GCP_PROJECT}"
done
```

#### 3c. Pre-Create Namespaces and Annotate Service Accounts
```bash
kubectl create namespace ate-system || true
kubectl create namespace ax-system || true

kubectl create serviceaccount ax-controller -n ax-system || true
kubectl annotate serviceaccount ax-controller -n ax-system --overwrite \
  "iam.gke.io/gcp-service-account"="${RESOURCE_PREFIX}-sa@${GCP_PROJECT}.iam.gserviceaccount.com"

kubectl create serviceaccount default -n ax-system || true
kubectl annotate serviceaccount default -n ax-system --overwrite \
  "iam.gke.io/gcp-service-account"="${RESOURCE_PREFIX}-sa@${GCP_PROJECT}.iam.gserviceaccount.com"

kubectl annotate serviceaccount default -n default --overwrite \
  "iam.gke.io/gcp-service-account"="${RESOURCE_PREFIX}-sa@${GCP_PROJECT}.iam.gserviceaccount.com" || true
```

#### 3d. Install Agent Substrate via Helm
```bash
# Install CRDs
helm upgrade --install substrate-crds \
  oci://ghcr.io/kagent-dev/substrate/helm/substrate-crds \
  --version 0.0.12 \
  --namespace ate-system --create-namespace --wait

# Patch CRD schema for pauseImage compatibility
kubectl get crd sandboxconfigs.ate.dev -o json | jq '.spec.versions[0].schema.openAPIV3Schema.properties.spec.required = ["sandboxClass"]' | kubectl apply -f -

# Apply custom RBAC for storageclasses reflector
kubectl apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ate-api-server-extra-role
rules:
  - apiGroups: ["storage.k8s.io"]
    resources: ["storageclasses", "csidrivers"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["ate.dev"]
    resources: ["csidriverconfigs", "sandboxconfigs", "actortemplates", "workerpools"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ate-api-server-extra-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: ate-api-server-extra-role
subjects:
  - kind: ServiceAccount
    name: ate-api-server
    namespace: ate-system
  - kind: ServiceAccount
    name: atelet
    namespace: ate-system
  - kind: ServiceAccount
    name: substrate-controller
    namespace: ate-system
EOF

# Install platform
helm upgrade --install substrate \
  oci://ghcr.io/kagent-dev/substrate/helm/substrate \
  --version 0.0.12 \
  --namespace ate-system \
  --set controller.serviceAccount.annotations."iam\.gke\.io/gcp-service-account"="${RESOURCE_PREFIX}-sa@${GCP_PROJECT}.iam.gserviceaccount.com" \
  --set atelet.serviceAccount.annotations."iam\.gke\.io/gcp-service-account"="${RESOURCE_PREFIX}-sa@${GCP_PROJECT}.iam.gserviceaccount.com" \
  --set snapshotsConfig.location="gs://${RESOURCE_PREFIX}-snapshots/" \
  --set auth.jwt.issuer="https://container.googleapis.com/v1/projects/${GCP_PROJECT}/locations/${CLUSTER_LOCATION}/clusters/${RESOURCE_PREFIX}-gke" \
  --wait

# Replicate CA configmap to ax-system
kubectl get configmap ateapi-ca -n ate-system -o json | jq 'del(.metadata.namespace, .metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.ownerReferences)' | kubectl apply -n ax-system -f -
```

### 4. Build and Push the Task-Runner Image
Cross-compile the binary and submit to Cloud Build:
```bash
export AX_IMAGE_REPO="gcr.io/${GCP_PROJECT}/${RESOURCE_PREFIX}-images"
export TASK_RUNNER_REPO="${AX_IMAGE_REPO}/ax-task-runner"

mkdir -p bin/linux_amd64
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o bin/linux_amd64/ax-task-runner ./cmd/ax-task-runner

cp Dockerfile.task-runner Dockerfile
printf ".git\n.github\n" > .gcloudignore
gcloud builds submit --tag "${TASK_RUNNER_REPO}:latest" .
rm -f Dockerfile .gcloudignore
```

### 5. Deploy AX Components (Redis, Server, Controller)
Deploy the AX state store (Redis), the API server, and the horizontal controller workers using Go `ko` compilation:
```bash
export KO_DOCKER_REPO="${AX_IMAGE_REPO}"

make deploy-redis
make deploy-controller
make deploy-server
```

### 6. Configure Controller Snapshots Bucket
```bash
kubectl set env deployment/ax-controller -n ax-system \
  AX_SNAPSHOTS_BUCKET="gs://${RESOURCE_PREFIX}-snapshots/"
```

---

## Verify

1. **Verify Pod Status:** All AX system pods must be in the `Running` state:
   ```bash
   kubectl get pods -n ax-system
   kubectl get pods -n ate-system
   ```
2. **Verify API Server Connectivity:** Port-forward the AX API server and query tasks via the CLI:
   ```bash
   kubectl port-forward svc/ax-server -n ax-system 8080:8080 &
   PORT_FORWARD_PID=$!
   sleep 2

   ./bin/ax get tasks
   kill $PORT_FORWARD_PID
   ```

---

## Teardown

1. **Delete the GKE Cluster:**
   ```bash
   gcloud container clusters delete "${RESOURCE_PREFIX}-gke" --zone="${CLUSTER_LOCATION}" --quiet
   ```
2. **Delete the GCS Snapshots Bucket:**
   ```bash
   gcloud storage buckets delete "gs://${RESOURCE_PREFIX}-snapshots" --recursive --quiet
   ```
3. **Delete Published Images:**
   ```bash
   gcloud container images delete "${TASK_RUNNER_REPO}:latest" --force-delete-tags --quiet
   ```
4. **Delete GCP Service Account:**
   ```bash
   gcloud iam service-accounts delete "${RESOURCE_PREFIX}-sa@${GCP_PROJECT}.iam.gserviceaccount.com" --quiet
   ```
