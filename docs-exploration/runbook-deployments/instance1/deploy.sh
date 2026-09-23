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
echo "==> Provisioning GKE Cluster ${GKE_CLUSTER}..."
gcloud container clusters create "${GKE_CLUSTER}" \
  --num-nodes=3 \
  --machine-type="e2-standard-4" \
  --addons=GcePersistentDiskCsiDriver \
  --workload-pool="${GCP_PROJECT}.svc.id.goog" \
  --labels="${LABEL_KEY}=${LABEL_VALUE}"

echo "==> Fetching cluster credentials..."
gcloud container clusters get-credentials "${GKE_CLUSTER}"

# 2. Create the GCS checkpoint bucket
echo "==> Creating GCS snapshot bucket gs://${GCS_BUCKET}..."
gcloud storage buckets create "gs://${GCS_BUCKET}" \
  --project="${GCP_PROJECT}" \
  --location="${GCP_REGION}"

echo "==> Labeling GCS bucket gs://${GCS_BUCKET}..."
gcloud storage buckets update "gs://${GCS_BUCKET}" \
  --update-labels="${LABEL_KEY}=${LABEL_VALUE}"

# 3. Install Agent Substrate (Control Plane)
echo "==> Setting up GSA and IAM configurations..."

# 3a. Provision GCP Service Account & GCS IAM Roles
gcloud iam service-accounts create "${GSA_NAME}" \
  --project="${GCP_PROJECT}" \
  --display-name="AX and Substrate GCS Service Account"

gcloud storage buckets add-iam-policy-binding "gs://${GCS_BUCKET}" \
  --member="serviceAccount:${GSA_EMAIL}" \
  --role="roles/storage.objectAdmin"

# 3b. Bind Kubernetes Service Accounts (KSA) using Workload Identity
gcloud iam service-accounts add-iam-policy-binding "${GSA_EMAIL}" \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:${GCP_PROJECT}.svc.id.goog[ate-system/substrate-controller]" \
  --project="${GCP_PROJECT}"

gcloud iam service-accounts add-iam-policy-binding "${GSA_EMAIL}" \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:${GCP_PROJECT}.svc.id.goog[ate-system/atelet]" \
  --project="${GCP_PROJECT}"

gcloud iam service-accounts add-iam-policy-binding "${GSA_EMAIL}" \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:${GCP_PROJECT}.svc.id.goog[ax-system/ax-controller]" \
  --project="${GCP_PROJECT}"

# 3c. Pre-Create Namespaces and Annotate AX Controller
kubectl create namespace ate-system || true
kubectl create namespace ax-system || true

kubectl create serviceaccount ax-controller -n ax-system || true
kubectl annotate serviceaccount ax-controller -n ax-system --overwrite \
  "iam.gke.io/gcp-service-account"="${GSA_EMAIL}"

# 3d. Install Agent Substrate CRDs
echo "==> Installing Agent Substrate CRDs..."
helm upgrade --install substrate-crds \
  oci://ghcr.io/kagent-dev/substrate/helm/substrate-crds \
  --version 0.0.9 \
  --namespace ate-system --create-namespace --wait

# 3e. Install Agent Substrate Platform
echo "==> Installing Agent Substrate Platform..."
helm upgrade --install substrate \
  oci://ghcr.io/kagent-dev/substrate/helm/substrate \
  --version 0.0.9 \
  --namespace ate-system \
  --set controller.serviceAccount.annotations."iam\.gke\.io/gcp-service-account"="${GSA_EMAIL}" \
  --set atelet.serviceAccount.annotations."iam\.gke\.io/gcp-service-account"="${GSA_EMAIL}" \
  --set snapshotsConfig.location="gs://${GCS_BUCKET}/" \
  --wait

# Navigate to the workspace root for Go, Docker, and Makefile build triggers
cd "${REPO_ROOT}"

# 4. Build and Push the Task-Runner Image
echo "==> Building and pushing ax-task-runner container image..."
export AX_IMAGE_REPO
export TASK_RUNNER_REPO
make push-task-runner

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
