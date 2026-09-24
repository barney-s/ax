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

# Determine script directory and source params
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/params.env"

echo "============================================================"
echo "TEARING DOWN AX INSTANCE: ${RESOURCE_PREFIX}"
echo "Project:                 ${GCP_PROJECT}"
echo "Region:                  ${GCP_REGION}"
echo "Cluster:                 ${GKE_CLUSTER}"
echo "Bucket:                  ${GCS_BUCKET}"
echo "============================================================"

# Preconditions / gcloud configuration
echo "==> Configuring gcloud tool..."
gcloud config set project "${GCP_PROJECT}"
gcloud config set compute/region "${GCP_REGION}"

# 1. Delete the GKE Cluster
echo "==> Deleting GKE Cluster ${GKE_CLUSTER}..."
gcloud container clusters delete "${GKE_CLUSTER}" --zone "${GCP_REGION}-a" --quiet || echo "GKE Cluster ${GKE_CLUSTER} deletion failed or already deleted."

# 2. Delete the GCS Snapshots Bucket
echo "==> Deleting GCS snapshots bucket gs://${GCS_BUCKET}..."
gcloud storage rm --recursive "gs://${GCS_BUCKET}" || echo "GCS Bucket gs://${GCS_BUCKET} deletion failed or already deleted."

# 3. Delete Published Images
echo "==> Deleting all published container images from ${AX_IMAGE_REPO}..."
if gcloud container images list --repository="${AX_IMAGE_REPO}" >/dev/null 2>&1; then
  for repo in $(gcloud container images list --repository="${AX_IMAGE_REPO}" --format="value(name)"); do
    echo "Deleting image repository: ${repo}"
    gcloud container images delete "${repo}" --force-delete-tags --quiet || echo "Failed to delete repository ${repo} or already deleted."
  done
else
  echo "No images found or repository ${AX_IMAGE_REPO} does not exist."
fi

# 4. Delete GCP Service Account
echo "==> Deleting GCP Service Account ${GSA_EMAIL}..."
gcloud iam service-accounts delete "${GSA_EMAIL}" --quiet || echo "Service account ${GSA_EMAIL} deletion failed or already deleted."

echo "============================================================"
echo "TEARDOWN COMPLETED"
echo "============================================================"
