#!/usr/bin/env bash

# MODIFIED: Installed Substrate via Helm chart v0.0.12 to align with GKE standard capabilities, added RBAC for storageclasses, Cloud Build for task-runner, and CA replication.

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

# shellcheck source=docs-exploration/runbook-deployments/instance4/params.env
source "${SCRIPT_DIR}/params.env"

# Ensure user go bin is in PATH for ko, helm, and other tools
export PATH="/workspaces/.home/go/bin:${PATH}"

echo "============================================================"
echo "DEPLOYING AX INSTANCE: ${RESOURCE_PREFIX}"
echo "Project:               ${GCP_PROJECT}"
echo "Region:                ${GCP_REGION}"
echo "Zone:                  ${CLUSTER_LOCATION}"
echo "Cluster:               ${CLUSTER_NAME}"
echo "Bucket:                gs://${BUCKET_NAME}"
echo "============================================================"

# Preconditions / gcloud configuration
echo "==> Configuring gcloud tool defaults..."
gcloud config set project "${GCP_PROJECT}"
gcloud config set compute/region "${GCP_REGION}"
gcloud config set compute/zone "${CLUSTER_LOCATION}"

# 1. Provision GKE Cluster and credentials
if gcloud container clusters describe "${CLUSTER_NAME}" --zone "${CLUSTER_LOCATION}" >/dev/null 2>&1; then
  echo "==> GKE Cluster ${CLUSTER_NAME} already exists or is provisioning. Skipping creation."
else
  echo "==> 1. Provisioning GKE Cluster (${CLUSTER_NAME})..."
  gcloud container clusters create "${CLUSTER_NAME}" \
    --zone "${CLUSTER_LOCATION}" \
    --num-nodes=3 \
    --machine-type="${NODE_MACHINE_TYPE}" \
    --async \
    --addons=GcePersistentDiskCsiDriver \
    --workload-pool="${GCP_PROJECT}.svc.id.goog" \
    --labels="repo-agent-instance=${RESOURCE_PREFIX}"
fi

echo "==> Checking and waiting for GKE cluster ${CLUSTER_NAME} to be RUNNING..."
while true; do
  STATUS=$(gcloud container clusters describe "${CLUSTER_NAME}" --zone "${CLUSTER_LOCATION}" --format="get(status)" 2>/dev/null || echo "PENDING")
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

echo "==> Fetching kubeconfig credentials..."
gcloud container clusters get-credentials "${CLUSTER_NAME}" --zone "${CLUSTER_LOCATION}"

# 2. Create the GCS checkpoint bucket
if gcloud storage buckets describe "gs://${BUCKET_NAME}" >/dev/null 2>&1; then
  echo "==> GCS bucket gs://${BUCKET_NAME} already exists. Skipping creation."
else
  echo "==> 2. Creating GCS Checkpoint Bucket (gs://${BUCKET_NAME})..."
  gcloud storage buckets create "gs://${BUCKET_NAME}" \
    --project="${GCP_PROJECT}" \
    --location="${GCP_REGION}"
  gcloud storage buckets update "gs://${BUCKET_NAME}" \
    --update-labels="repo-agent-instance=${RESOURCE_PREFIX}"
fi

# 3. Install Agent Substrate (Control Plane)
echo "==> 3. Setting up GSA and IAM configurations..."

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
if gcloud iam service-accounts describe "${GSA_EMAIL}" --project="${GCP_PROJECT}" >/dev/null 2>&1; then
  echo "==> Service account ${GSA_EMAIL} already exists. Skipping creation."
else
  echo "==> 3a. Provisioning GCP Service Account (${GSA_NAME})..."
  gcloud iam service-accounts create "${GSA_NAME}" \
    --project="${GCP_PROJECT}" \
    --display-name="AX and Substrate GCS Service Account"
  echo "==> Sleeping 15 seconds to allow GCP Service Account replication..."
  sleep 15
fi

echo "==> Granting storage.objectAdmin role on GCS bucket..."
retry_cmd gcloud storage buckets add-iam-policy-binding "gs://${BUCKET_NAME}" \
  --member="serviceAccount:${GSA_EMAIL}" \
  --role="roles/storage.objectAdmin"

echo "==> Granting GCR and Artifact Registry read access to GSA at project level..."
retry_cmd gcloud projects add-iam-policy-binding "${GCP_PROJECT}" \
  --member="serviceAccount:${GSA_EMAIL}" \
  --role="roles/storage.objectViewer"

retry_cmd gcloud projects add-iam-policy-binding "${GCP_PROJECT}" \
  --member="serviceAccount:${GSA_EMAIL}" \
  --role="roles/artifactregistry.reader"

# 3b. Bind Kubernetes Service Accounts with Workload Identity
echo "==> 3b. Binding Kubernetes Service Accounts with Workload Identity..."
retry_cmd gcloud iam service-accounts add-iam-policy-binding "${GSA_EMAIL}" \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:${GCP_PROJECT}.svc.id.goog[ate-system/substrate-controller]" \
  --project="${GCP_PROJECT}"

retry_cmd gcloud iam service-accounts add-iam-policy-binding "${GSA_EMAIL}" \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:${GCP_PROJECT}.svc.id.goog[ate-system/atelet]" \
  --project="${GCP_PROJECT}"

retry_cmd gcloud iam service-accounts add-iam-policy-binding "${GSA_EMAIL}" \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:${GCP_PROJECT}.svc.id.goog[ax-system/ax-controller]" \
  --project="${GCP_PROJECT}"

retry_cmd gcloud iam service-accounts add-iam-policy-binding "${GSA_EMAIL}" \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:${GCP_PROJECT}.svc.id.goog[ax-system/default]" \
  --project="${GCP_PROJECT}"

retry_cmd gcloud iam service-accounts add-iam-policy-binding "${GSA_EMAIL}" \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:${GCP_PROJECT}.svc.id.goog[default/default]" \
  --project="${GCP_PROJECT}"

# 3c. Pre-creating namespaces and annotating AX controller service account
echo "==> 3c. Pre-creating namespaces and annotating AX controller service account..."
kubectl create namespace ate-system || true
kubectl create namespace ax-system || true

kubectl create serviceaccount ax-controller -n ax-system || true
kubectl annotate serviceaccount ax-controller -n ax-system --overwrite \
  "iam.gke.io/gcp-service-account"="${GSA_EMAIL}"

kubectl create serviceaccount default -n ax-system || true
kubectl annotate serviceaccount default -n ax-system --overwrite \
  "iam.gke.io/gcp-service-account"="${GSA_EMAIL}"

kubectl annotate serviceaccount default -n default --overwrite \
  "iam.gke.io/gcp-service-account"="${GSA_EMAIL}" || true

# 3d. Install Agent Substrate CRDs via Helm
echo "==> 3d. Installing Agent Substrate CRDs via Helm..."
helm upgrade --install substrate-crds \
  oci://ghcr.io/kagent-dev/substrate/helm/substrate-crds \
  --version 0.0.12 \
  --namespace ate-system --create-namespace --wait

echo "==> Patching sandboxconfigs.ate.dev CRD schema for Helm 0.0.12 compatibility..."
kubectl get crd sandboxconfigs.ate.dev -o json | jq '.spec.versions[0].schema.openAPIV3Schema.properties.spec.required = ["sandboxClass"]' | kubectl apply -f -

echo "==> Applying RBAC extra permissions for storageclasses..."
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

# 3e. Install Agent Substrate Platform via Helm
echo "==> 3e. Installing Agent Substrate Platform via Helm..."
helm upgrade --install substrate \
  oci://ghcr.io/kagent-dev/substrate/helm/substrate \
  --version 0.0.12 \
  --namespace ate-system \
  --set controller.serviceAccount.annotations."iam\.gke\.io/gcp-service-account"="${GSA_EMAIL}" \
  --set atelet.serviceAccount.annotations."iam\.gke\.io/gcp-service-account"="${GSA_EMAIL}" \
  --set snapshotsConfig.location="gs://${BUCKET_NAME}/" \
  --set auth.jwt.issuer="https://container.googleapis.com/v1/projects/${GCP_PROJECT}/locations/${CLUSTER_LOCATION}/clusters/${CLUSTER_NAME}" \
  --wait

echo "==> Replicating ateapi-ca ConfigMap to ax-system namespace..."
if kubectl get configmap ateapi-ca -n ate-system >/dev/null 2>&1; then
  kubectl get configmap ateapi-ca -n ate-system -o json | jq 'del(.metadata.namespace, .metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.ownerReferences)' | kubectl apply -n ax-system -f -
fi

cd "${REPO_ROOT}"

# 4. Building and Pushing Task Runner Image
echo "==> 4. Building and Pushing Task Runner Image (${TASK_RUNNER_REPO})..."
export AX_IMAGE_REPO="${AX_IMAGE_REPO}"
export TASK_RUNNER_REPO="${TASK_RUNNER_REPO}"

echo "==> Cross-compiling ax-task-runner for linux/amd64..."
mkdir -p bin/linux_amd64
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o bin/linux_amd64/ax-task-runner ./cmd/ax-task-runner

echo "==> Submitting Google Cloud Build for ax-task-runner using temporary Dockerfile and .gcloudignore..."
cp Dockerfile.task-runner Dockerfile
printf ".git\n.github\n" > .gcloudignore
if [ -f .dockerignore ]; then
  mv .dockerignore .dockerignore.bak
fi
trap 'rm -f Dockerfile .gcloudignore; if [ -f .dockerignore.bak ]; then mv .dockerignore.bak .dockerignore; fi' EXIT
gcloud builds submit --tag "${TASK_RUNNER_REPO}:latest" .
rm -f Dockerfile .gcloudignore
if [ -f .dockerignore.bak ]; then
  mv .dockerignore.bak .dockerignore
fi
trap - EXIT

echo "==> Fetching pinned task-runner image digest..."
TASK_RUNNER_DIGEST=$(gcloud container images list-tags "${TASK_RUNNER_REPO}" --format="get(digest)" --limit=1)
PINNED_TASK_RUNNER_IMAGE="${TASK_RUNNER_REPO}@${TASK_RUNNER_DIGEST}"

echo "==> Creating default ActorTemplates in ax-system and default namespaces..."
kubectl apply -f - <<EOF
apiVersion: ate.dev/v1alpha1
kind: ActorTemplate
metadata:
  name: default-template
  namespace: ax-system
spec:
  sandboxClass: gvisor
  snapshotsConfig:
    location: "gs://${BUCKET_NAME}/"
  containers:
    - name: guest
      image: "${PINNED_TASK_RUNNER_IMAGE}"
      command: ["/usr/local/bin/ax-task-runner"]
      volumeMounts:
        - name: workspace
          mountPath: /workspace
  volumes:
    - name: workspace
      durableDir: {}
---
apiVersion: ate.dev/v1alpha1
kind: ActorTemplate
metadata:
  name: default-template
  namespace: default
spec:
  sandboxClass: gvisor
  snapshotsConfig:
    location: "gs://${BUCKET_NAME}/"
  containers:
    - name: guest
      image: "${PINNED_TASK_RUNNER_IMAGE}"
      command: ["/usr/local/bin/ax-task-runner"]
      volumeMounts:
        - name: workspace
          mountPath: /workspace
  volumes:
    - name: workspace
      durableDir: {}
EOF

# 5. Deploying AX Components (Redis, Server, Controller)
echo "==> 5. Deploying AX Components (Redis, Server, Controller)..."
export KO_DOCKER_REPO="${AX_IMAGE_REPO}"
make deploy-redis
make deploy-controller
make deploy-server

# 6. Configuring Controller Snapshots Bucket
echo "==> 6. Configuring Controller Snapshots Bucket..."
kubectl set env deployment/ax-controller -n ax-system \
  AX_SNAPSHOTS_BUCKET="gs://${BUCKET_NAME}/"

# 7. Waiting for AX deployments rollout
echo "==> 7. Waiting for AX deployments rollout..."
kubectl rollout status deployment/ax-redis -n ax-system --timeout=180s
kubectl rollout status deployment/ax-controller -n ax-system --timeout=180s
kubectl rollout status deployment/ax-server -n ax-system --timeout=180s

echo "============================================================"
echo "Deployment of instance4 completed successfully."
echo "============================================================"
