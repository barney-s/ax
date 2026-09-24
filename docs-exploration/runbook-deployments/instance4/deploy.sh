#!/usr/bin/env bash
# Deploy script for instance4
# Derived strictly from docs-exploration/runbooks/deploy-gcp-md.md

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AX_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

# Source instance parameters
source "${SCRIPT_DIR}/params.env"

echo "==> Configuring gcloud project and region..."
gcloud config set project "${PROJECT_ID}"
gcloud config set compute/region "${GCE_REGION}"

# ---------------------------------------------------------------------------
# Step 1: Clone Agent Substrate Repository and Configure Environment
# ---------------------------------------------------------------------------
echo "==> Step 1: Setting up Agent Substrate repository..."
cd "${AX_ROOT}"
if [ ! -d "substrate" ]; then
  git clone https://github.com/agent-substrate/substrate.git
fi
cd substrate

cat <<EOF > params.env
export PROJECT_ID="${PROJECT_ID}"
export GCE_REGION="${GCE_REGION}"
export CLUSTER_LOCATION="${CLUSTER_LOCATION}"
export RESOURCE_PREFIX="${RESOURCE_PREFIX}"
EOF

source params.env
export NO_DEV_ENV=1 GOCACHE=/tmp/gocache GOTMPDIR=/tmp/gotmp
export PATH="$(go env GOPATH)/bin:${PATH}"
mkdir -p "$GOCACHE" "$GOTMPDIR"

export PROJECT_NUMBER="${PROJECT_NUMBER}"
export CLUSTER_NAME="${CLUSTER_NAME}"
export BUCKET_NAME="${BUCKET_NAME}"
export KO_DOCKER_REPO="${KO_DOCKER_REPO}"
export KO_DEFAULTPLATFORMS="${KO_DEFAULTPLATFORMS}"
export NETWORK="${NETWORK}"
export SUBNETWORK="${SUBNETWORK}"
export NODE_MACHINE_TYPE="${NODE_MACHINE_TYPE}"
export KUBECTL_CONTEXT="${KUBECTL_CONTEXT}"

# ---------------------------------------------------------------------------
# Step 2: Provision Infrastructure using Setup Tool
# ---------------------------------------------------------------------------
echo "==> Step 2: Provisioning GCP Infrastructure via Substrate setup-gcp tool..."
go run ./tools/setup-gcp enable apis
go run ./tools/setup-gcp create cluster
go run ./tools/setup-gcp create bucket
go run ./tools/setup-gcp create iam

gcloud container node-pools update substrate-node-pool \
  --cluster "${CLUSTER_NAME}" --location "${CLUSTER_LOCATION}" --no-enable-autoupgrade

gcloud container clusters get-credentials "${CLUSTER_NAME}" \
  --location "${CLUSTER_LOCATION}" --project "${PROJECT_ID}"

# ---------------------------------------------------------------------------
# Step 3: Deploy Agent Substrate from Source (Control Plane)
# ---------------------------------------------------------------------------
echo "==> Step 3: Deploying Agent Substrate control plane..."

# 3a. Pre-Create Namespaces and Configure AX Workload Identity
kubectl create namespace ate-system || true
kubectl create namespace ax-system || true

kubectl create serviceaccount ax-controller -n ax-system || true
kubectl annotate serviceaccount ax-controller -n ax-system --overwrite \
  "iam.gke.io/gcp-service-account"="${GSA_EMAIL}"

gcloud iam service-accounts add-iam-policy-binding "${GSA_EMAIL}" \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:${PROJECT_ID}.svc.id.goog[ax-system/ax-controller]" \
  --project="${PROJECT_ID}"

# 3b. Compile and Roll Out Substrate Control Plane
hack/install-ate.sh --deploy-ate-system --rollout-timeout=300s

kubectl annotate serviceaccount substrate-controller -n ate-system --overwrite \
  "iam.gke.io/gcp-service-account"="${GSA_EMAIL}"

kubectl annotate serviceaccount atelet -n ate-system --overwrite \
  "iam.gke.io/gcp-service-account"="${GSA_EMAIL}"

cd "${AX_ROOT}"

# ---------------------------------------------------------------------------
# Step 4: Build and Push the Task-Runner Image
# ---------------------------------------------------------------------------
echo "==> Step 4: Building and pushing ax-task-runner image..."
export AX_IMAGE_REPO="${AX_IMAGE_REPO}"
export TASK_RUNNER_REPO="${TASK_RUNNER_REPO}"

make push-task-runner

# ---------------------------------------------------------------------------
# Step 5: Deploy AX Components (Redis, Server, Controller)
# ---------------------------------------------------------------------------
echo "==> Step 5: Deploying AX components (Redis, Controller, Server)..."
export KO_DOCKER_REPO="${AX_IMAGE_REPO}"

make deploy-redis
make deploy-controller
make deploy-server

# ---------------------------------------------------------------------------
# Step 6: Configure Controller Snapshots Bucket
# ---------------------------------------------------------------------------
echo "==> Step 6: Configuring Controller Snapshots Bucket..."
kubectl set env deployment/ax-controller -n ax-system \
  AX_SNAPSHOTS_BUCKET="gs://${BUCKET_NAME}/"

echo "==> Deployment of instance4 complete."
