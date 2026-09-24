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

export NO_DEV_ENV=1
export PROJECT_NUMBER
export CLUSTER_NAME="${RESOURCE_PREFIX}"
export BUCKET_NAME="${RESOURCE_PREFIX}-snap-${PROJECT_NUMBER}"
export KO_DOCKER_REPO="gcr.io/${PROJECT_ID}/${RESOURCE_PREFIX}"

echo "============================================================"
echo "TEARING DOWN AX INSTANCE: ${RESOURCE_PREFIX}"
echo "Project:                  ${PROJECT_ID}"
echo "Cluster:                  ${CLUSTER_NAME}"
echo "Bucket:                   gs://${BUCKET_NAME}"
echo "============================================================"

# 1. Clean up AX platform namespace first (deletes Redis PVC and its GCE PD)
echo "==> 1. Deleting ax-system namespace and resources..."
kubectl delete namespace ax-system --wait=true --ignore-not-found=true || true

# 2. Locate substrate directory
SUBSTRATE_DIR="${REPO_ROOT}/../substrate"
if [ ! -d "${SUBSTRATE_DIR}" ]; then
  SUBSTRATE_DIR="/tmp/substrate"
fi

if [ -d "${SUBSTRATE_DIR}" ]; then
  cd "${SUBSTRATE_DIR}"
  echo "==> 2. Removing Substrate control plane..."
  hack/install-ate.sh --delete-all || true

  echo "==> 3. Revoking IAM policy bindings, deleting GCS bucket, and deleting GKE cluster..."
  hack/teardown.sh --delete-iam-policy-bindings --delete-snapshot-bucket --delete-cluster || true
else
  echo "==> Substrate directory not found. Cleaning up GCP resources directly via gcloud..."
  gcloud container clusters delete "${CLUSTER_NAME}" --zone="${CLUSTER_LOCATION}" --project="${PROJECT_ID}" --quiet || true
  gcloud storage rm --recursive "gs://${BUCKET_NAME}" --quiet || true
  gcloud iam service-accounts delete "${GSA_EMAIL}" --project="${PROJECT_ID}" --quiet || true
fi

# 4. Delete compiled task-runner and platform container images from GCR
echo "==> 4. Deleting published container images..."
for img in $(gcloud artifacts docker images list "${KO_DOCKER_REPO}" --format='value(package)' 2>/dev/null || gcloud container images list --repository="${KO_DOCKER_REPO}" --format='value(name)' 2>/dev/null); do
  gcloud artifacts docker images delete "${img}" --delete-tags --quiet 2>/dev/null || gcloud container images delete "${img}" --force-delete-tags --quiet 2>/dev/null || true
done

echo "Teardown complete. All GCP resources for ${RESOURCE_PREFIX} have been cleaned up."
