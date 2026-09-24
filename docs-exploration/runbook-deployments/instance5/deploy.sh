#!/usr/bin/env bash
# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
cd "${REPO_ROOT}"

# shellcheck source=docs-exploration/runbook-deployments/instance5/params.env
source "${SCRIPT_DIR}/params.env"

# 0. Parameters and derived names (from runbook Step 0)
export NO_DEV_ENV=1 GOCACHE=/tmp/gocache GOTMPDIR=/tmp/gotmp
export PATH="$(go env GOPATH)/bin:${PATH}"
mkdir -p "$GOCACHE" "$GOTMPDIR"

export PROJECT_NUMBER
export CLUSTER_NAME="${RESOURCE_PREFIX}"
export BUCKET_NAME="${RESOURCE_PREFIX}-snap-${PROJECT_NUMBER}"
export KO_DOCKER_REPO="gcr.io/${PROJECT_ID}/${RESOURCE_PREFIX}"
export AX_IMAGE_REPO="gcr.io/${PROJECT_ID}/${RESOURCE_PREFIX}"
export TASK_RUNNER_REPO="gcr.io/${PROJECT_ID}/${RESOURCE_PREFIX}/ax-task-runner"
export KO_DEFAULTPLATFORMS="linux/amd64"
export NETWORK="default"
export SUBNETWORK="default"
export NODE_MACHINE_TYPE="c3-standard-4"
export KUBECTL_CONTEXT="gke_${PROJECT_ID}_${CLUSTER_LOCATION}_${CLUSTER_NAME}"

echo "============================================================"
echo "DEPLOYING AX INSTANCE: ${RESOURCE_PREFIX}"
echo "Project:               ${PROJECT_ID} (${PROJECT_NUMBER})"
echo "Region:                ${GCE_REGION}"
echo "Zone:                  ${CLUSTER_LOCATION}"
echo "Cluster:               ${CLUSTER_NAME}"
echo "Bucket:                gs://${BUCKET_NAME}"
echo "============================================================"

# Install ko if missing
if ! command -v ko &> /dev/null; then
  echo "==> Installing ko..."
  go install github.com/google/ko@latest
fi

# ===========================================================================
# Part I: Provision and Deploy Agent Substrate
# ===========================================================================

# 1. Locate or clone agent-substrate repository
SUBSTRATE_DIR="${REPO_ROOT}/../substrate"
if [ ! -d "${SUBSTRATE_DIR}" ]; then
  SUBSTRATE_DIR="/tmp/substrate"
  if [ ! -d "${SUBSTRATE_DIR}" ]; then
    echo "==> Cloning agent-substrate/substrate..."
    git clone https://github.com/agent-substrate/substrate.git "${SUBSTRATE_DIR}"
  fi
fi

cd "${SUBSTRATE_DIR}"

# 2. APIs, cluster, bucket, IAM
echo "==> Enabling required GCP APIs..."
go run ./tools/setup-gcp enable apis

echo "==> Creating GKE cluster (${CLUSTER_NAME})..."
go run ./tools/setup-gcp create cluster

echo "==> Creating GCS snapshot bucket (gs://${BUCKET_NAME})..."
go run ./tools/setup-gcp create bucket

echo "==> Setting up IAM bindings..."
go run ./tools/setup-gcp create iam

# 3. Workers must not be drained by GKE (prevent autoupgrade conflicts)
echo "==> Disabling auto-upgrade on substrate-node-pool..."
gcloud container node-pools update substrate-node-pool \
  --cluster "${CLUSTER_NAME}" --location "${CLUSTER_LOCATION}" --no-enable-autoupgrade

# 4. Credentials
echo "==> Fetching GKE credentials..."
gcloud container clusters get-credentials "${CLUSTER_NAME}" \
  --location "${CLUSTER_LOCATION}" --project "${PROJECT_ID}"

# 5. Control plane: ko builds and pushes every image, then applies Substrate components
echo "==> Installing Substrate control plane..."
hack/install-ate.sh --deploy-ate-system --rollout-timeout=300s

# ===========================================================================
# Part II: Build and Deploy AX Platform
# ===========================================================================

# 6. Navigate back to the google/ax repository directory
cd "${REPO_ROOT}"

# 7. Build local binaries and install the ax CLI
echo "==> Building AX binaries and installing ax CLI..."
make build
make install

# 8. Build and push the ax-task-runner container image using Google Cloud Build
echo "==> Compiling ax-task-runner and submitting Cloud Build..."
mkdir -p bin/linux_amd64
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o bin/linux_amd64/ax-task-runner ./cmd/ax-task-runner
cp Dockerfile.task-runner Dockerfile
gcloud builds submit --tag "${TASK_RUNNER_REPO}:latest" .
rm -f Dockerfile

# 9. Deploy AX platform components (Redis, ax-controller, ax-server) using ko
echo "==> Deploying AX platform components (Redis, ax-controller, ax-server)..."
make deploy

# 10. Configure the ax-controller with the dynamic snapshot GCS bucket name
echo "==> Configuring ax-controller snapshots bucket..."
kubectl set env deployment/ax-controller -n ax-system AX_SNAPSHOTS_BUCKET="gs://${BUCKET_NAME}/"

# 11. Wait for deployment rollouts to complete
echo "==> Waiting for AX deployments rollout..."
kubectl rollout status deployment/ax-controller -n ax-system --timeout=120s
kubectl rollout status deployment/ax-server -n ax-system --timeout=120s

echo "============================================================"
echo "Deployment of ${RESOURCE_PREFIX} completed successfully."
echo "============================================================"
