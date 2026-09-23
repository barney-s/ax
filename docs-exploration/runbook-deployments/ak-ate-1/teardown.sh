#!/usr/bin/env bash
# teardown.sh - Stop and clean up GCP AX and Agent Substrate deployment for 'ak-ate-1'
set -euo pipefail

# Locate script directory and source params.env
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${SCRIPT_DIR}/params.env" ]; then
    echo "Sourcing parameters from ${SCRIPT_DIR}/params.env..."
    # shellcheck source=params.env
    source "${SCRIPT_DIR}/params.env"
else
    echo "Error: params.env not found in ${SCRIPT_DIR}." >&2
    exit 1
fi

WORKSPACE_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

echo "=== Teardown: Deleting AX Components ==="

# 1. Delete AX components
echo "1. Deleting AX deployments and services..."
kubectl delete -f "${WORKSPACE_DIR}/deploy/ax-server.yaml" --ignore-not-found
kubectl delete -f "${WORKSPACE_DIR}/deploy/ax-controller.yaml" --ignore-not-found
kubectl delete -f "${WORKSPACE_DIR}/deploy/redis.yaml" --ignore-not-found

# 2. Delete the namespace
echo "2. Deleting namespace 'ax-system'..."
kubectl delete namespace ax-system --ignore-not-found


echo "=== Teardown: Deleting Agent Substrate Components ==="

# 3. Delete Agent Substrate components
if [ -d "/tmp/substrate" ]; then
    echo "3. Deleting Agent Substrate components..."
    cd /tmp/substrate
    ./hack/install-ate.sh --delete-all
else
    echo "3. Agent Substrate directory /tmp/substrate does not exist. Skipping Substrate component deletion."
fi


echo "=== Teardown: Deleting GKE Cluster and GCS Storage Bucket ==="

# 4. Delete the GKE cluster and GCS bucket to avoid continuing charges
echo "4. Deleting GKE cluster '${CLUSTER_NAME}' in region '${REGION}'..."
gcloud container clusters delete "${CLUSTER_NAME}" --region "${REGION}" --quiet || true

echo "Deleting GCS bucket 'gs://${BUCKET_NAME}'..."
gcloud storage buckets delete "gs://${BUCKET_NAME}" --recursive --quiet || true


echo "=== Teardown: Cleaning Up Local Build Artifacts ==="

# 5. Clean up compiled binaries and build artifacts
echo "5. Cleaning up local build artifacts..."
cd "${WORKSPACE_DIR}"
make clean

echo "=== Teardown complete! ==="
