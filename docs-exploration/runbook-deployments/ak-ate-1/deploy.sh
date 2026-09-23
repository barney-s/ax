#!/usr/bin/env bash
# deploy.sh - Deploy AX and Agent Substrate to GCP (GKE & GCR)
# This script provisions the GKE cluster 'ak-ate-1', installs Agent Substrate, and deploys AX components.
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

echo "=== Preconditions: GCP Environment Setup ==="

# 1. Enable required Google Cloud APIs
echo "1. Enabling container.googleapis.com and containerregistry.googleapis.com APIs..."
gcloud services enable container.googleapis.com containerregistry.googleapis.com --project="${PROJECT_ID}"

# 2. Configure Docker authentication
echo "2. Configuring docker/podman auth for gcr.io..."
gcloud auth configure-docker gcr.io --quiet


echo "=== Step 1: Clone and Configure Agent Substrate ==="
echo "Cloning Agent Substrate from source into /tmp/substrate..."
rm -rf /tmp/substrate
git clone https://github.com/agent-substrate/substrate /tmp/substrate

echo "Generating Substrate configuration file (.ate-dev-env.sh)..."
cat <<EOF > /tmp/substrate/.ate-dev-env.sh
export PROJECT_ID="${PROJECT_ID}"
export CLUSTER_NAME="${CLUSTER_NAME}"
export REGION="${REGION}"
export ZONE="${ZONE}"
export BUCKET_NAME="${BUCKET_NAME}"
export KO_DOCKER_REPO="${KO_DOCKER_REPO}"
EOF


echo "=== Step 2: Provision GKE Cluster and GCS Snapshot Bucket ==="
echo "Bootstrapping GKE cluster '${CLUSTER_NAME}' and bucket '${BUCKET_NAME}'..."
(
    cd /tmp/substrate
    # shellcheck source=/dev/null
    source .ate-dev-env.sh
    go run ./tools/setup-gcp bootstrap
)


echo "=== Step 3: Install Agent Substrate into Cluster ==="
echo "Retrieving cluster credentials to ensure kubectl target is configured..."
gcloud container clusters get-credentials "${CLUSTER_NAME}" --region "${REGION}" --project="${PROJECT_ID}"

echo "Installing Agent Substrate control and data plane services in the ate-system namespace..."
(
    cd /tmp/substrate
    ./hack/install-ate.sh --deploy-ate-system
)


echo "=== Step 4: Build and Push AX Task Runner Image ==="
echo "Cross-compiling ax-task-runner for linux/amd64..."
mkdir -p bin/linux_amd64
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o bin/linux_amd64/ax-task-runner ./cmd/ax-task-runner

echo "Building and pushing task-runner image '${TASK_RUNNER_REPO}:latest' via Google Cloud Build..."
# Backup existing .dockerignore to avoid interferring with standard rules
mv .dockerignore .dockerignore.bak || true
cp Dockerfile.task-runner Dockerfile
gcloud builds submit --tag="${TASK_RUNNER_REPO}:latest" --ignore-file=custom-gcloudignore --project="${PROJECT_ID}" .
rm Dockerfile
mv .dockerignore.bak .dockerignore || true


echo "=== Step 5: Deploy Redis to GKE Cluster ==="
echo "Deploying Redis to the ax-system namespace..."
make deploy-redis


echo "=== Step 6: Deploy AX Controller ==="
echo "Building and deploying ax-controller using ko..."
make deploy-controller


echo "=== Step 7: Deploy AX Server ==="
echo "Building and deploying ax-server using ko..."
make deploy-server


echo "=== Verification: Checking Workload Health ==="
echo "Waiting for deployments to roll out successfully..."
kubectl rollout status deployment/ax-redis -n ax-system
kubectl rollout status deployment/ax-controller -n ax-system
kubectl rollout status deployment/ax-server -n ax-system

echo "Active Pods in ax-system namespace:"
kubectl get pods -n ax-system

echo "Active Services in ax-system namespace:"
kubectl get svc -n ax-system

echo "=== Deployment successful! ==="
echo "To connect via ax CLI client locally, run:"
echo "  make build"
echo "  ./bin/ax ctx"
echo "  ./demo.sh"
