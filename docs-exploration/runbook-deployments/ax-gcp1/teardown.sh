#!/usr/bin/env bash
# teardown.sh - Stop and clean up GCP AX deployment
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

# Retrieve GKE cluster credentials to ensure we target the correct cluster
echo "Configuring kubectl credentials for GKE cluster '${CLUSTER}' in region '${REGION}'..."
gcloud container clusters get-credentials "${CLUSTER}" --region "${REGION}" --project="${PROJECT}"


echo "=== Teardown: Deleting AX Components ==="

# 1. Delete AX components
echo "1. Deleting AX deployments and services..."
kubectl delete -f deploy/ax-server.yaml --ignore-not-found
kubectl delete -f deploy/ax-controller.yaml --ignore-not-found
kubectl delete -f deploy/redis.yaml --ignore-not-found

# 2. Delete the namespace
echo "2. Deleting namespace 'ax-system'..."
kubectl delete namespace ax-system --ignore-not-found

# 3. Clean up compiled binaries and build artifacts
echo "3. Cleaning up local build artifacts..."
make clean

echo "=== Teardown complete! ==="
