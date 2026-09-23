#!/usr/bin/env bash
# teardown.sh - Stop and clean up all AX and Agent Substrate GCP resources
# This script deletes all AX resources, tears down Agent Substrate, and deletes the GKE cluster 'ak-ate-1'.
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

echo "=== Authentication: GCP Environment Setup ==="
echo "Configuring kubectl credentials for GKE cluster '${CLUSTER_NAME}' in region '${REGION}'..."
gcloud container clusters get-credentials "${CLUSTER_NAME}" --region "${REGION}" --project="${PROJECT_ID}" || {
    echo "Warning: Failed to retrieve cluster credentials. The cluster might have already been deleted or not yet created."
}


echo "=== Step 1: Delete AX Components and Namespace ==="
echo "Deleting AX server, controller, and redis resources..."
kubectl delete -f deploy/ax-server.yaml --ignore-not-found || true
kubectl delete -f deploy/ax-controller.yaml --ignore-not-found || true
kubectl delete -f deploy/redis.yaml --ignore-not-found || true

echo "Deleting ax-system namespace..."
kubectl delete namespace ax-system --ignore-not-found || true


echo "=== Step 2: Delete Agent Substrate Components ==="
# Ensure Agent Substrate repo is cloned so we can use its cleanup scripts
if [ ! -d "/tmp/substrate" ]; then
    echo "Agent Substrate not found at /tmp/substrate. Cloning repository to run teardown script..."
    git clone https://github.com/agent-substrate/substrate /tmp/substrate || true
fi

if [ -d "/tmp/substrate" ]; then
    echo "Tearing down Agent Substrate components from cluster..."
    (
        cd /tmp/substrate
        ./hack/install-ate.sh --delete-all || true
    )
else
    echo "Warning: Could not access /tmp/substrate. Skipping substrate components teardown."
fi


echo "=== Step 3: Delete GKE Cluster and GCS Snapshots Bucket ==="
echo "Deleting GKE cluster '${CLUSTER_NAME}' in region '${REGION}' (this may take several minutes)..."
gcloud container clusters delete "${CLUSTER_NAME}" --region "${REGION}" --project="${PROJECT_ID}" --quiet || {
    echo "Warning: Failed to delete GKE cluster '${CLUSTER_NAME}' (it may already be deleted)."
}

echo "Deleting GCS bucket 'gs://${BUCKET_NAME}'..."
gcloud storage buckets delete "gs://${BUCKET_NAME}" --recursive --project="${PROJECT_ID}" --quiet || {
    echo "Warning: Failed to delete GCS bucket '${BUCKET_NAME}' (it may already be deleted)."
}


echo "=== Step 4: Local Cleanup ==="
echo "Cleaning up local build artifacts..."
make clean

echo "=== Teardown complete! ==="
