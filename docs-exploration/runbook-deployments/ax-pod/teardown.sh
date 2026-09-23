#!/usr/bin/env bash
# teardown.sh - Stop and clean up local AX In-Pod deployment
set -euo pipefail

# Locate script directory and source params.env
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${SCRIPT_DIR}/params.env" ]; then
    echo "Sourcing parameters from ${SCRIPT_DIR}/params.env..."
    # shellcheck source=params.env
    source "${SCRIPT_DIR}/params.env"
else
    echo "Warning: params.env not found in ${SCRIPT_DIR}. Using existing environment."
fi

# 1. Stop local AX Server
echo "=== Stopping local AX Server ==="
pkill ax-server || true

# 2. Stop local Redis instance
echo "=== Stopping local Redis ==="
if [ "${USE_DOCKER_REDIS}" = "true" ]; then
    echo "Stopping and removing Redis Docker container: ${REDIS_CONTAINER_NAME}..."
    docker stop "${REDIS_CONTAINER_NAME}" || true
    docker rm "${REDIS_CONTAINER_NAME}" || true
else
    echo "Stopping local redis-server process..."
    pkill redis-server || true
fi

# 3. Clean up compiled binaries and build artifacts
echo "=== Cleaning up build artifacts and logs ==="
make clean
rm -f redis.log ax-server.log

echo "=== Teardown complete! ==="
