# Upgrade GCP GKE Runbook

This runbook guides you through performing safe, rolling upgrades of the AX platform control plane (the stateless API server and worker controller) and running task sandboxes inside GCP GKE environments without losing persistent agent workspace states.

---

## What this needs

This scenario **needs real cloud infrastructure and real nodes**. It operates on an active GCP/GKE environment with deployed AX services. It performs in-place upgrades of GKE deployments, updates Docker registries, and triggers Actor state checkpointing/restorations on Agent Substrate.

### Components forcing real infrastructure:
- **Kubernetes Deployments**: Requires active GKE clusters to perform rolling image updates (`ko apply` rollout transitions).
- **Agent Substrate & GCS Snapshots**: Required to execute task suspensions, snapshotting active workspaces to GCS, and resuming them inside containers upgraded to the latest `ax-task-runner` image.

### Cost of Teardown
- **$0.00** additional cost beyond the already running GKE and GCS resources. Tearing down the underlying GKE cluster and GCS bucket completely (as detailed in the `deploy-gcp.md` teardown steps) will fully stop all continuous billing.

### Feasibility Checklist
- [x] **gcloud CLI**: Present (`gcloud version` shows active installation, active project: `barni-cnrm-20260529`)
- [x] **kubectl CLI**: Present (Connected to the active cluster)
- [x] **Go 1.27+ Compiler**: Present (`go version` shows `go1.27.1`)
- [ ] **ko CLI**: MISSING (Must be installed on the operator's machine via `go install github.com/google/ko@latest`)
- [ ] **Docker / Podman Daemon**: MISSING (Must be active to recompile and push the upgraded `ax-task-runner` image)
- [x] **Active GCP Project**: Present (Configured to `barni-cnrm-20260529`)

---

## Preconditions

1. A healthy AX deployment is already running on a GKE cluster (e.g., provisioned via `deploy-gcp.md`).
2. The environment variables `${GCP_PROJECT}`, `${RESOURCE_PREFIX}`, and `${GCP_REGION}` are exported.
3. Target task names and their atespaces are identified (e.g. `demo-task` in atespace `default`).

---

## Steps

### 1. Upgrade the Control Plane (ax-server and ax-controller)
Build and deploy the updated control plane services using Go `ko` compilation. Kubernetes will perform a zero-downtime rolling update of the active pods:
```bash
export AX_IMAGE_REPO="gcr.io/${GCP_PROJECT}/${RESOURCE_PREFIX}-images"
export KO_DOCKER_REPO="${AX_IMAGE_REPO}"

# Redeploy updated control plane binaries to GKE
make deploy-controller
make deploy-server
```

### 2. Build and Push the Upgraded Task-Runner Image
When there is a change to the runtime supervisor (`runner/` package or `cmd/ax-task-runner`), compile, build and push the new guest image to GCR/GAR:
```bash
export TASK_RUNNER_REPO="${AX_IMAGE_REPO}/ax-task-runner"

# Compile and build latest runner image tag
make push-task-runner
```

### 3. Upgrade Running Task Workloads without Data Loss
To transition a running task to the new runner version without losing the progress inside its workspace:

#### A. Suspend the running task to snapshot its workspace
Run the `suspend` command to tell the controller to freeze the sandbox and upload a compressed snapshot of `/workspace` to the GCS snapshots bucket:
```bash
./bin/ax suspend task "${TASK_NAME}" -a "${ATESPACE}"
```
Wait until the task phase transitions to `Suspended`. You can monitor this progress:
```bash
./bin/ax watch task "${TASK_NAME}" -a "${ATESPACE}"
```

#### B. Update the Task's container image specification
Apply the updated Task manifest pointing to the new runner image (or omit `spec.image` if you want it to automatically fall back to the newly updated default ActorTemplate image on the controller):
```bash
# Apply updated task manifest
./bin/ax apply -f updated-task.yaml -a "${ATESPACE}"
```

#### C. Resume the task to boot the upgraded sandbox
Resume the suspended task. The controller will instruct Substrate to build/load a fresh sandbox container using the upgraded ActorTemplate, mount the durable persistent volume, and populate its state from the GCS snapshot:
```bash
./bin/ax resume task "${TASK_NAME}" -a "${ATESPACE}"
```
The task-runner will boot (now running the upgraded version), verify that the workspace is already initialized (skipping maiden setup/repo clones), and immediately resume the supervised command.

---

## Verify

Verify that both the control plane and active workloads have successfully upgraded:

1. **Verify Deployments Rollout:** Ensure Kubernetes completed the deployment rollout of the control plane services:
   ```bash
   kubectl rollout status deployment/ax-server -n ax-system
   ```
2. **Verify Upgraded Workload Phase:** Verify that the resumed task has returned to `Running` with `Ready=True`:
   ```bash
   ./bin/ax describe task "${TASK_NAME}" -a "${ATESPACE}"
   ```
3. **Verify Sandbox Runtime State:** Run a remote command inside the running task over `ax ssh` to print the task configuration from the metadata server, proving the upgraded runner is serving metadata correctly:
   ```bash
   ./bin/ax ssh "${TASK_NAME}" -a "${ATESPACE}" -- curl -s "\$AX_METADATA_URL/metadata/v1alpha1/ax/task"
   ```

---

## Teardown

No infrastructure is destroyed during an upgrade runbook. All upgraded deployments and tasks continue executing on the GKE cluster.

To fully tear down and stop incurring GKE/GCS charges, follow the detailed teardown steps in the `deploy-gcp.md` runbook.
