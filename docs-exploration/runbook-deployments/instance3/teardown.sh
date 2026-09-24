#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
cd "${REPO_ROOT}"

# shellcheck source=docs-exploration/runbook-deployments/instance3/params.env
source "${SCRIPT_DIR}/params.env"

echo "==> Teardown: 1. Deleting GKE Cluster (${CLUSTER_NAME})..."
gcloud container clusters delete "${CLUSTER_NAME}" --zone="${CLUSTER_LOCATION}" --quiet || true

echo "==> Teardown: 2. Deleting GCS Snapshots Bucket (gs://${BUCKET_NAME})..."
gcloud storage buckets delete "gs://${BUCKET_NAME}" --recursive --quiet || true

echo "==> Teardown: 3. Deleting Published Container Images (${TASK_RUNNER_REPO})..."
gcloud container images delete "${TASK_RUNNER_REPO}:latest" --force-delete-tags --quiet || true

echo "==> Teardown: 4. Deleting GCP Service Account (${GSA_EMAIL})..."
gcloud iam service-accounts delete "${GSA_EMAIL}" --project="${GCP_PROJECT}" --quiet || true

echo "==> Teardown of instance3 completed."
