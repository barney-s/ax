#!/usr/bin/env bash
# teardown.sh - Stop and clean up GCP AX and Agent Substrate deployment for 'ak-ate-1'
# Change: Updated cluster deletion to use zone instead of region.
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

echo "=== Teardown: Deleting AX and Agent Substrate Components ==="

# Check if the GKE cluster exists
if gcloud container clusters describe "${CLUSTER_NAME}" --zone "${CLUSTER_LOCATION}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    echo "GKE cluster '${CLUSTER_NAME}' exists. Configuring credentials..."
    gcloud container clusters get-credentials "${CLUSTER_NAME}" --zone "${CLUSTER_LOCATION}" --project="${PROJECT_ID}"

    # 1. Delete AX components
    echo "1. Deleting AX deployments and services..."
    kubectl delete -f "${WORKSPACE_DIR}/deploy/ax-server.yaml" --ignore-not-found || true
    kubectl delete -f "${WORKSPACE_DIR}/deploy/ax-controller.yaml" --ignore-not-found || true
    kubectl delete -f "${WORKSPACE_DIR}/deploy/redis.yaml" --ignore-not-found || true

    # 2. Delete the namespace
    echo "2. Deleting namespace 'ax-system'..."
    kubectl delete namespace ax-system --ignore-not-found || true

    # 3. Delete Agent Substrate components
    if [ -d "/tmp/substrate" ]; then
        echo "3. Deleting Agent Substrate components..."
        cd /tmp/substrate
        ./hack/install-ate.sh --delete-all || true
    else
        echo "3. Agent Substrate directory /tmp/substrate does not exist. Skipping Substrate component deletion."
    fi
else
    echo "GKE cluster '${CLUSTER_NAME}' does not exist. Skipping in-cluster component deletion."
fi


echo "=== Teardown: Deleting GKE Cluster and GCS Storage Bucket ==="

# 4. Delete the GKE cluster and GCS bucket to avoid continuing charges
echo "4. Deleting GKE cluster '${CLUSTER_NAME}' in zone '${CLUSTER_LOCATION}'..."
if gcloud container clusters describe "${CLUSTER_NAME}" --zone "${CLUSTER_LOCATION}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    gcloud container clusters delete "${CLUSTER_NAME}" --zone "${CLUSTER_LOCATION}" --quiet || true
else
    echo "GKE cluster '${CLUSTER_NAME}' is already gone."
fi

echo "Deleting GCS bucket 'gs://${BUCKET_NAME}'..."
if gcloud storage buckets describe "gs://${BUCKET_NAME}" >/dev/null 2>&1; then
    gcloud storage rm --recursive "gs://${BUCKET_NAME}" --quiet || true
else
    echo "GCS bucket 'gs://${BUCKET_NAME}' is already gone."
fi


echo "=== Teardown: Cleaning Up Local Build Artifacts ==="

# 5. Clean up compiled binaries and build artifacts
echo "5. Cleaning up local build artifacts..."
cd "${WORKSPACE_DIR}"
make clean

echo "=== Teardown complete! ==="
