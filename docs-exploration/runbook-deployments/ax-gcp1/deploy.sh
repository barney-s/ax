#!/usr/bin/env bash
# deploy.sh - Deploy AX to GCP (GKE & GCR)
# Changed: Built task-runner using Google Cloud Build instead of local Container CLI due to nested namespace limits.
# This script deploys AX components (Redis, ax-controller, and ax-server) to the GKE cluster.
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
gcloud services enable container.googleapis.com containerregistry.googleapis.com --project="${PROJECT}"

# 2. Retrieve GKE cluster credentials
echo "2. Configuring kubectl credentials for GKE cluster '${CLUSTER}' in region '${REGION}'..."
gcloud container clusters get-credentials "${CLUSTER}" --region "${REGION}" --project="${PROJECT}"

# 3. Configure Docker authentication
echo "3. Configuring docker/podman auth for gcr.io..."
gcloud auth configure-docker gcr.io --quiet


echo "=== Deployment: Building and Applying AX Components ==="

# Step 1: Build and push the Task Runner container image
echo "Step 1: Building and pushing the Task Runner container image..."
echo "Cross-compiling ax-task-runner for linux/amd64..."
mkdir -p bin/linux_amd64
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o bin/linux_amd64/ax-task-runner ./cmd/ax-task-runner

echo "Building and pushing container image ${TASK_RUNNER_REPO}:latest via Google Cloud Build..."
mv .dockerignore .dockerignore.bak || true
cp Dockerfile.task-runner Dockerfile
gcloud builds submit --tag="${TASK_RUNNER_REPO}:latest" --ignore-file=custom-gcloudignore --project="${PROJECT}" .
rm Dockerfile
mv .dockerignore.bak .dockerignore || true

# Step 2: Deploy Redis to the GKE Cluster
echo "Step 2: Deploying Redis to the GKE Cluster (ax-system namespace)..."
make deploy-redis

# Step 3: Deploy the AX Controller using ko
echo "Step 3: Deploying the AX Controller using ko..."
make deploy-controller

# Step 4: Deploy the AX Server using ko
echo "Step 4: Deploying the AX Server using ko..."
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
