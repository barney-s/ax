#!/usr/bin/env bash

# MODIFIED: Transitioned Substrate Helm chart and CRDs to version 0.0.12 to align with compiled client proto API contracts and resolve template compatibility issues.
# MODIFIED: Configured explicit zone us-central1-a for GKE and transitioned task-runner compilation to Google Cloud Build to bypass local Docker/Podman daemon requirements.

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

# Determine script directory and repository root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/params.env"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

echo "============================================================"
echo "DEPLOYING AX INSTANCE: ${RESOURCE_PREFIX}"
echo "Project:               ${GCP_PROJECT}"
echo "Region:                ${GCP_REGION}"
echo "Cluster:               ${GKE_CLUSTER}"
echo "Bucket:                ${GCS_BUCKET}"
echo "============================================================"

# Preconditions / gcloud configuration
echo "==> Configuring gcloud tool..."
gcloud config set project "${GCP_PROJECT}"
gcloud config set compute/region "${GCP_REGION}"

# 1. Provision GKE Cluster and credentials
if gcloud container clusters describe "${GKE_CLUSTER}" --zone "${GCP_REGION}-a" >/dev/null 2>&1; then
  echo "==> GKE Cluster ${GKE_CLUSTER} already exists or is provisioning. Skipping creation."
else
  echo "==> Provisioning GKE Cluster ${GKE_CLUSTER}..."
  gcloud container clusters create "${GKE_CLUSTER}" \
    --zone "${GCP_REGION}-a" \
    --num-nodes=3 \
    --machine-type="e2-standard-4" \
    --addons=GcePersistentDiskCsiDriver \
    --workload-pool="${GCP_PROJECT}.svc.id.goog" \
    --labels="${LABEL_KEY}=${LABEL_VALUE}"
fi

echo "==> Fetching cluster credentials..."
echo "==> Checking and waiting for GKE cluster ${GKE_CLUSTER} to be RUNNING..."
while true; do
  STATUS=$(gcloud container clusters describe "${GKE_CLUSTER}" --zone "${GCP_REGION}-a" --format="get(status)" 2>/dev/null || echo "PENDING")
  echo "Current GKE cluster status: ${STATUS} at $(date)"
  if [ "${STATUS}" = "RUNNING" ]; then
    break
  fi
  if [ "${STATUS}" = "DEGRADED" ] || [ "${STATUS}" = "STOPPING" ]; then
    echo "Cluster status is unexpected: ${STATUS}"
    exit 1
  fi
  sleep 15
done
gcloud container clusters get-credentials "${GKE_CLUSTER}" --zone "${GCP_REGION}-a"

# 2. Create the GCS checkpoint bucket
if gcloud storage buckets describe "gs://${GCS_BUCKET}" >/dev/null 2>&1; then
  echo "==> GCS bucket gs://${GCS_BUCKET} already exists. Skipping creation."
else
  echo "==> Creating GCS snapshot bucket gs://${GCS_BUCKET}..."
  gcloud storage buckets create "gs://${GCS_BUCKET}" \
    --project="${GCP_PROJECT}" \
    --location="${GCP_REGION}"

  echo "==> Labeling GCS bucket gs://${GCS_BUCKET}..."
  gcloud storage buckets update "gs://${GCS_BUCKET}" \
    --update-labels="${LABEL_KEY}=${LABEL_VALUE}"
fi

# 3. Install Agent Substrate (Control Plane)
echo "==> Setting up GSA and IAM configurations..."

# Define a robust retry helper for IAM replication delays
retry_cmd() {
  local max_attempts=10
  local delay=5
  local attempt=1
  until "$@"; do
    if (( attempt >= max_attempts )); then
      echo "Command '$*' failed after $max_attempts attempts."
      return 1
    fi
    echo "Command failed. Retrying in $delay seconds (attempt $attempt/$max_attempts)..."
    sleep $delay
    (( attempt++ ))
  done
}

# 3a. Provision GCP Service Account & GCS IAM Roles
if gcloud iam service-accounts describe "${GSA_EMAIL}" >/dev/null 2>&1; then
  echo "==> Service account ${GSA_EMAIL} already exists. Skipping creation."
else
  echo "==> Creating GCP Service Account ${GSA_NAME}..."
  gcloud iam service-accounts create "${GSA_NAME}" \
    --project="${GCP_PROJECT}" \
    --display-name="AX and Substrate GCS Service Account"
  echo "==> Sleeping 15 seconds to allow GCP Service Account replication..."
  sleep 15
fi

echo "==> Binding storage objectAdmin role to GSA on snapshots bucket..."
retry_cmd gcloud storage buckets add-iam-policy-binding "gs://${GCS_BUCKET}" \
  --member="serviceAccount:${GSA_EMAIL}" \
  --role="roles/storage.objectAdmin"

echo "==> Granting GCR and Artifact Registry read access to GSA at project level..."
retry_cmd gcloud projects add-iam-policy-binding "${GCP_PROJECT}" \
  --member="serviceAccount:${GSA_EMAIL}" \
  --role="roles/storage.objectViewer"

retry_cmd gcloud projects add-iam-policy-binding "${GCP_PROJECT}" \
  --member="serviceAccount:${GSA_EMAIL}" \
  --role="roles/artifactregistry.reader"

# 3b. Bind Kubernetes Service Accounts (KSA) using Workload Identity
echo "==> Binding Workload Identity for substrate-controller..."
retry_cmd gcloud iam service-accounts add-iam-policy-binding "${GSA_EMAIL}" \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:${GCP_PROJECT}.svc.id.goog[ate-system/substrate-controller]" \
  --project="${GCP_PROJECT}"

echo "==> Binding Workload Identity for atelet..."
retry_cmd gcloud iam service-accounts add-iam-policy-binding "${GSA_EMAIL}" \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:${GCP_PROJECT}.svc.id.goog[ate-system/atelet]" \
  --project="${GCP_PROJECT}"

echo "==> Binding Workload Identity for ax-controller..."
retry_cmd gcloud iam service-accounts add-iam-policy-binding "${GSA_EMAIL}" \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:${GCP_PROJECT}.svc.id.goog[ax-system/ax-controller]" \
  --project="${GCP_PROJECT}"

echo "==> Binding Workload Identity for ax-system default..."
retry_cmd gcloud iam service-accounts add-iam-policy-binding "${GSA_EMAIL}" \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:${GCP_PROJECT}.svc.id.goog[ax-system/default]" \
  --project="${GCP_PROJECT}"

echo "==> Binding Workload Identity for default/default..."
retry_cmd gcloud iam service-accounts add-iam-policy-binding "${GSA_EMAIL}" \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:${GCP_PROJECT}.svc.id.goog[default/default]" \
  --project="${GCP_PROJECT}"

# 3c. Pre-Create Namespaces and Annotate AX Controller
kubectl create namespace ate-system || true
kubectl create namespace ax-system || true

kubectl create serviceaccount ax-controller -n ax-system || true
kubectl annotate serviceaccount ax-controller -n ax-system --overwrite \
  "iam.gke.io/gcp-service-account"="${GSA_EMAIL}"

kubectl annotate serviceaccount default -n ax-system --overwrite \
  "iam.gke.io/gcp-service-account"="${GSA_EMAIL}"

kubectl annotate serviceaccount default -n default --overwrite \
  "iam.gke.io/gcp-service-account"="${GSA_EMAIL}"

# 3d. Install Agent Substrate CRDs
echo "==> Installing Agent Substrate CRDs..."
helm upgrade --install substrate-crds \
  oci://ghcr.io/kagent-dev/substrate/helm/substrate-crds \
  --version 0.0.12 \
  --namespace ate-system --create-namespace --wait

# 3e. Install Agent Substrate Platform
echo "==> Installing Agent Substrate Platform..."
helm upgrade --install substrate \
  oci://ghcr.io/kagent-dev/substrate/helm/substrate \
  --version 0.0.12 \
  --namespace ate-system \
  --set controller.serviceAccount.annotations."iam\.gke\.io/gcp-service-account"="${GSA_EMAIL}" \
  --set atelet.serviceAccount.annotations."iam\.gke\.io/gcp-service-account"="${GSA_EMAIL}" \
  --set snapshotsConfig.location="gs://${GCS_BUCKET}/" \
  --set auth.jwt.issuer="https://container.googleapis.com/v1/projects/${GCP_PROJECT}/locations/${GCP_REGION}-a/clusters/${GKE_CLUSTER}" \
  --wait

echo "==> Replicating ateapi-ca ConfigMap to ax-system namespace..."
kubectl get configmap ateapi-ca -n ate-system -o json | jq 'del(.metadata.namespace, .metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.ownerReferences)' | kubectl apply -n ax-system -f -

# Navigate to the workspace root for Go, Docker, and Makefile build triggers
cd "${REPO_ROOT}"

# 4. Build and Push the Task-Runner Image
echo "==> Building and pushing ax-task-runner container image..."
export AX_IMAGE_REPO
export TASK_RUNNER_REPO

echo "==> Cross-compiling ax-task-runner for linux/amd64..."
mkdir -p bin/linux_amd64
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o bin/linux_amd64/ax-task-runner ./cmd/ax-task-runner

echo "==> Submitting Google Cloud Build for ax-task-runner using temporary Dockerfile and .gcloudignore..."
cp Dockerfile.task-runner Dockerfile
printf ".git\n.github\n" > .gcloudignore
if [ -f .dockerignore ]; then
  mv .dockerignore .dockerignore.bak
fi
# Ensure we clean up even if build fails
trap 'rm -f Dockerfile .gcloudignore; if [ -f .dockerignore.bak ]; then mv .dockerignore.bak .dockerignore; fi' EXIT
gcloud builds submit --tag "${TASK_RUNNER_REPO}:latest" .
rm -f Dockerfile .gcloudignore
if [ -f .dockerignore.bak ]; then
  mv .dockerignore.bak .dockerignore
fi
# Reset trap
trap - EXIT

# 5. Deploy AX Components (Redis, Server, Controller)
echo "==> Deploying AX Components..."
export KO_DOCKER_REPO
make deploy-redis
make deploy-controller
make deploy-server

# 6. Configure Controller Snapshots Bucket
echo "==> Configuring ax-controller snaps bucket env..."
kubectl set env deployment/ax-controller -n ax-system \
  AX_SNAPSHOTS_BUCKET="gs://${GCS_BUCKET}/"

echo "============================================================"
echo "DEPLOY COMPLETED SUCCESSFULLY"
echo "============================================================"
