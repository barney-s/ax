#!/usr/bin/env bash
# deploy.sh - Deploy Agent Substrate and AX to GCP for 'ak-ate-1'
# This script is designed to run deterministically and traceably to the runbook.
# Change: Added /workspaces/.home/go/bin to PATH to ensure ko and other installed Go binaries can be located. Exported CLUSTER_LOCATION and added get-credentials. Added AX_SNAPSHOTS_BUCKET replacement.
set -euo pipefail

# Locate script directory and source params.env
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${SCRIPT_DIR}/params.env" ]; then
    echo "Sourcing parameters from ${SCRIPT_DIR}/params.env..."
    # shellcheck source=params.env
    source "${SCRIPT_DIR}/params.env"
else
    echo "Error: params.env not found in ${SCRIPT_DIR}." >&2
    exit 1
fi

export PATH="/workspaces/.home/go/bin:${PATH}"

WORKSPACE_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

echo "=== Preconditions: GCP Environment Setup ==="

# 1. Enable required Google Cloud APIs on the project
echo "Enabling container.googleapis.com and containerregistry.googleapis.com APIs..."
gcloud services enable container.googleapis.com containerregistry.googleapis.com --project="${PROJECT_ID}"

# 2. Configure Docker authentication
echo "Configuring docker/podman auth for gcr.io..."
gcloud auth configure-docker gcr.io --quiet

# 3. Create custom Cloud Build ignore file
echo "Creating custom-gcloudignore..."
cat <<EOF > "${WORKSPACE_DIR}/custom-gcloudignore"
.git
.github
/tmp
EOF


echo "=== Step 1: Clone and configure Agent Substrate ==="
rm -rf /tmp/substrate
echo "Cloning Agent Substrate into /tmp/substrate..."
git clone https://github.com/agent-substrate/substrate /tmp/substrate
cd /tmp/substrate

echo "Creating .ate-dev-env.sh configuration..."
cat <<EOF > .ate-dev-env.sh
export PROJECT_ID="${PROJECT_ID}"
export CLUSTER_NAME="${CLUSTER_NAME}"
export CLUSTER_LOCATION="${CLUSTER_LOCATION}"
export REGION="${REGION}"
export ZONE="${ZONE}"
export GCE_REGION="${GCE_REGION}"
export BUCKET_NAME="${BUCKET_NAME}"
export KO_DOCKER_REPO="${KO_DOCKER_REPO}"
EOF


echo "=== Step 2: Provision GKE cluster and GCS snapshot bucket ==="
echo "Sourcing .ate-dev-env.sh and running setup-gcp bootstrap..."
source .ate-dev-env.sh
go run ./tools/setup-gcp bootstrap


echo "=== Step 3: Install Agent Substrate components into the cluster ==="
echo "Configuring kubectl credentials for GKE cluster..."
gcloud container clusters get-credentials "${CLUSTER_NAME}" --zone "${CLUSTER_LOCATION}" --project="${PROJECT_ID}"
echo "Installing Agent Substrate control and data plane services..."
./hack/install-ate.sh --deploy-ate-system

echo "Publishing worker images..."
go run ./cmd/ate-setup publish worker-images

echo "Creating default WorkerPool..."
SUBSTRATE_VER=$(kubectl get nodes -o jsonpath='{.items[0].metadata.labels.ate\.dev/substrate-version}')
kubectl apply -f - <<EOF
apiVersion: ate.dev/v1alpha1
kind: WorkerPool
metadata:
  name: default-pool
  namespace: default
spec:
  replicas: 2
  workerImage: "gcr.io/${PROJECT_ID}/ate-images/ateom-gvisor:latest"
  template:
    nodeSelector:
      ate.dev/substrate-version: "${SUBSTRATE_VER}"
    resources:
      limits:
        cpu: "2"
        memory: "2Gi"
      requests:
        cpu: "500m"
        memory: "2Gi"
EOF


echo "=== Step 4: Build and push the AX Task Runner image ==="
cd "${WORKSPACE_DIR}"

CONTAINER_CLI=$(which podman 2>/dev/null || which docker 2>/dev/null || echo "")
if [ -n "${CONTAINER_CLI}" ]; then
    echo "Using local ${CONTAINER_CLI} to build and push task-runner..."
    make push-task-runner
else
    echo "Local docker/podman is unavailable. Executing Google Cloud Build fallback..."
    mkdir -p bin/linux_amd64
    GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o bin/linux_amd64/ax-task-runner ./cmd/ax-task-runner
    mv .dockerignore .dockerignore.bak || true
    cp Dockerfile.task-runner Dockerfile
    gcloud builds submit --tag="${TASK_RUNNER_REPO}:latest" --ignore-file=custom-gcloudignore --project="${PROJECT_ID}" .
    rm Dockerfile
    mv .dockerignore.bak .dockerignore || true
fi


echo "=== Step 5: Deploy Redis to the GKE Cluster ==="
make deploy-redis


echo "=== Step 6: Deploy the AX Controller ==="
sed -i "s|AX_SNAPSHOTS_BUCKET_PLACEHOLDER|gs://${BUCKET_NAME}|g" deploy/ax-controller.yaml
make deploy-controller


echo "=== Step 7: Deploy the AX Server ==="
make deploy-server


echo "=== Verify: Checking Deployed Workloads ==="
echo "Waiting for ax-redis rollout..."
kubectl rollout status deployment/ax-redis -n ax-system

echo "Waiting for ax-controller rollout..."
kubectl rollout status deployment/ax-controller -n ax-system

echo "Waiting for ax-server rollout..."
kubectl rollout status deployment/ax-server -n ax-system

echo "Active Pods in ax-system namespace:"
kubectl get pods -n ax-system

echo "Active Services in ax-system namespace:"
kubectl get svc -n ax-system

echo "=== Deployment scripts prep completed successfully! ==="
echo "To connect to this environment locally, run:"
echo "  make build"
echo "  ./bin/ax ctx"
echo "  ./demo.sh"
