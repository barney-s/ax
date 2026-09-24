#!/usr/bin/env bash
# Teardown script for instance4
# Derived strictly from docs-exploration/runbooks/deploy-gcp-md.md

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AX_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

# Source instance parameters
source "${SCRIPT_DIR}/params.env"

echo "==> Step 1: Deleting AX components and Substrate control plane..."
cd "${AX_ROOT}"
if [ -d "substrate" ]; then
  cd substrate
  if [ -f "params.env" ]; then
    source params.env
  fi
  export PROJECT_NUMBER="${PROJECT_NUMBER}"
  export CLUSTER_NAME="${CLUSTER_NAME}"
  export BUCKET_NAME="${BUCKET_NAME}"
  export KO_DOCKER_REPO="${KO_DOCKER_REPO}"

  if [ -f "hack/install-ate.sh" ]; then
    hack/install-ate.sh --delete-all || true
  fi

  echo "==> Step 2: Tearing down GCP infrastructure (cluster, bucket, IAM)..."
  if [ -f "hack/teardown.sh" ]; then
    hack/teardown.sh --delete-iam-policy-bindings --delete-snapshot-bucket --delete-cluster || true
  fi

  echo "==> Step 3: Deleting published Substrate container images..."
  for img in $(gcloud artifacts docker images list "${KO_DOCKER_REPO}" --format='value(package)' 2>/dev/null | sort -u); do
    gcloud artifacts docker images delete "${img}" --delete-tags --quiet || true
  done
fi

echo "==> Step 4: Deleting published AX container images..."
cd "${AX_ROOT}"
export AX_IMAGE_REPO="${AX_IMAGE_REPO}"
gcloud container images delete "${AX_IMAGE_REPO}/ax-task-runner:latest" --force-delete-tags --quiet || true

echo "==> Teardown of instance4 complete."
