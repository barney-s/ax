#!/usr/bin/env bash
# deploy.sh - Deploy AX In-Pod (Local Development & Test)
# This script builds the AX binaries, starts local dependencies, and runs the server.
# Change: Redirected redis-server and ax-server background outputs to log files to prevent hanging shell execution.
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

# 1. Preconditions: Start local Redis instance
echo "=== Step 1: Preconditions - Start Local Redis ==="
if [ "${USE_DOCKER_REDIS}" = "true" ]; then
    echo "Checking for running Docker container: ${REDIS_CONTAINER_NAME}..."
    if docker ps -a --format '{{.Names}}' | grep -Eq "^${REDIS_CONTAINER_NAME}$"; then
        echo "Container ${REDIS_CONTAINER_NAME} already exists. Restarting..."
        docker start "${REDIS_CONTAINER_NAME}"
    else
        echo "Running a new Redis Docker container: ${REDIS_CONTAINER_NAME}..."
        docker run -d --name "${REDIS_CONTAINER_NAME}" -p "${AX_REDIS_ADDR##*:}:6379" redis:7-alpine
    fi
else
    echo "Starting local redis-server process on port ${AX_REDIS_ADDR##*:}..."
    # Check if redis-server is already running on the target port
    if command -v pgrep >/dev/null && pgrep -f "redis-server.*${AX_REDIS_ADDR##*:}" >/dev/null; then
        echo "redis-server is already running."
    else
        redis-server --port "${AX_REDIS_ADDR##*:}" > redis.log 2>&1 &
        # Sleep briefly to allow redis-server to start up
        sleep 2
    fi
fi

# 2. Step 1: Build all local AX binaries
echo "=== Step 2: Build all local AX binaries ==="
make build

# 3. Step 2: Run the full unit and integration test suite
echo "=== Step 3: Run unit and integration tests ==="
make test

# 4. Step 3: Launch the AX API Server locally
echo "=== Step 4: Launch AX API Server locally ==="
./bin/ax-server --addr="${AX_SERVER_ADDR}" --redis-addr="${AX_REDIS_ADDR}" > ax-server.log 2>&1 &

# Sleep briefly to ensure the server starts up and we can verify it
sleep 2

echo "=== Deployment script complete! ==="
echo "To verify connectivity, run:"
echo "  export AX_SERVER=\"${AX_SERVER}\""
echo "  ./bin/ax version"
echo "  ./bin/ax get tasks"
