#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
cd "${REPO_ROOT}"

# shellcheck source=docs-exploration/runbook-deployments/instance3/params.env
source "${SCRIPT_DIR}/params.env"

echo "==> Configuring gcloud defaults..."
gcloud config set project "${GCP_PROJECT}"
gcloud config set compute/region "${GCP_REGION}"

echo "==> 1. Provisioning GKE Cluster (${CLUSTER_NAME})..."
gcloud container clusters create "${CLUSTER_NAME}" \
  --num-nodes=3 \
  --machine-type="e2-standard-4" \
  --addons=GcePersistentDiskCsiDriver \
  --workload-pool="${GCP_PROJECT}.svc.id.goog" \
  --labels="repo-agent-instance=${RESOURCE_PREFIX}"

echo "==> Fetching kubeconfig credentials..."
gcloud container clusters get-credentials "${CLUSTER_NAME}"

echo "==> 2. Creating GCS Checkpoint Bucket (gs://${BUCKET_NAME})..."
gcloud storage buckets create "gs://${BUCKET_NAME}" \
  --project="${GCP_PROJECT}" \
  --location="${GCP_REGION}" \
  --labels="repo-agent-instance=${RESOURCE_PREFIX}"

echo "==> 3. Installing Agent Substrate (Control Plane)..."

echo "==> 3a. Provisioning GCP Service Account (${GSA_NAME})..."
gcloud iam service-accounts create "${GSA_NAME}" \
  --project="${GCP_PROJECT}" \
  --display-name="AX and Substrate GCS Service Account"

echo "==> Granting storage.objectAdmin role on GCS bucket..."
gcloud storage buckets add-iam-policy-binding "gs://${BUCKET_NAME}" \
  --member="serviceAccount:${GSA_EMAIL}" \
  --role="roles/storage.objectAdmin"

echo "==> 3b. Binding Kubernetes Service Accounts with Workload Identity..."
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

echo "==> 3c. Pre-creating namespaces and annotating AX controller service account..."
kubectl create namespace ate-system || true
kubectl create namespace ax-system || true

kubectl create serviceaccount ax-controller -n ax-system || true
kubectl annotate serviceaccount ax-controller -n ax-system --overwrite \
  "iam.gke.io/gcp-service-account"="${GSA_EMAIL}"

echo "==> 3d. Cloning Agent Substrate repository..."
if [ ! -d "substrate" ]; then
  git clone https://github.com/agent-substrate/substrate.git
fi
cd substrate

echo "==> 3e. Building and deploying Agent Substrate from source..."
export PROJECT_ID="${GCP_PROJECT}"
export BUCKET_NAME="${BUCKET_NAME}"
export CLUSTER_NAME="${CLUSTER_NAME}"
export CLUSTER_LOCATION="${CLUSTER_LOCATION}"
export KO_DOCKER_REPO="${SUBSTRATE_KO_DOCKER_REPO}"
export KO_DEFAULTPLATFORMS="${KO_DEFAULTPLATFORMS}"

./hack/install-ate.sh --deploy-ate-system

echo "==> 3f. Annotating Substrate Service Accounts for Workload Identity..."
kubectl annotate serviceaccount substrate-controller -n ate-system --overwrite \
  "iam.gke.io/gcp-service-account"="${GSA_EMAIL}"

kubectl annotate serviceaccount atelet -n ate-system --overwrite \
  "iam.gke.io/gcp-service-account"="${GSA_EMAIL}"

cd "${REPO_ROOT}"

echo "==> 4. Building and Pushing Task Runner Image (${TASK_RUNNER_REPO})..."
export AX_IMAGE_REPO="${AX_IMAGE_REPO}"
export TASK_RUNNER_REPO="${TASK_RUNNER_REPO}"
make push-task-runner

echo "==> 5. Deploying AX Components (Redis, Server, Controller)..."
export KO_DOCKER_REPO="${AX_IMAGE_REPO}"
make deploy-redis
make deploy-controller
make deploy-server

echo "==> 6. Configuring Controller Snapshots Bucket..."
kubectl set env deployment/ax-controller -n ax-system \
  AX_SNAPSHOTS_BUCKET="gs://${BUCKET_NAME}/"

echo "==> Deployment of instance3 completed successfully."
