# Runbook: Upgrade AX in Google Cloud Platform (GCP)

This runbook guides you through performing an in-place upgrade of the AX control plane components (ax-controller, ax-server) and the guest sandbox component (ax-task-runner) inside an existing Google Kubernetes Engine (GKE) cluster.

---

## What this needs

This upgrade **cannot** run purely in-pod. It requires an existing **GCP Infrastructure** deployment (GKE and GCR/Artifact Registry) where AX is already installed and running.

### Why real infrastructure is forced:
- **Zero-downtime rolling upgrades**: Verifying that Kubernetes gracefully terminates old controller and server pods while spinning up new ones requires GKE.
- **Durable sandbox resumption**: Upgrading the `ax-task-runner` image template is validated by suspending an existing active task and resuming it under the newly pushed task-runner image on the real Agent Substrate cluster.

### Feasibility Checklist (Probed on Wednesday, September 23, 2026)

The following checklist represents the results of read-only probes executed under the current identity:

* **Tools:**
  - `go` (v1.27+): ✓ present
  - `kubectl`: ✓ present
  - `gcloud`: ✓ present
  - `ko` (for building container upgrades): ✗ MISSING — Fix: `go install github.com/google/ko@latest`
  - `docker` / `podman` (for building the updated task-runner image): ✗ MISSING — Fix: `sudo apt-get update && sudo apt-get install -y docker.io` (or `podman`)

* **Permissions & Environments:**
  - GCP Registry / Bucket Writer Permissions: ✓ present (Active service account `cnrm-barni-1.svc.id.goog` on project `barni-cnrm-20260529` holds the `roles/owner` and `roles/artifactregistry.reader` roles, giving write permission to GCR/GCS).
  - Existing GKE Cluster: ✗ MISSING — Fix: Configure access to an active GKE cluster.
  - Kubernetes cluster-admin RBAC: ✗ MISSING — Fix: Configure access to an active GKE cluster.

---

## Preconditions

1. **Access the GKE cluster** with credentials configured:
   ```bash
   gcloud container clusters get-credentials <your-gke-cluster> --region <your-region>
   ```
2. **Retrieve existing registry repository configuration**:
   ```bash
   export PROJECT_ID=$(gcloud config get-value project)
   export AX_IMAGE_REPO="gcr.io/${PROJECT_ID}/ate-images"
   export TASK_RUNNER_REPO="${AX_IMAGE_REPO}/ax-task-runner"
   ```
3. **Verify current AX installation**:
   Ensure AX is already running healthy in the `ax-system` namespace before starting the upgrade:
   ```bash
   kubectl get deployments -n ax-system
   ```

---

## Steps

1. **Rebuild and push the upgraded Task Runner**:
   If the sandbox environment or runner daemon logic has changed, compile the updated task-runner and push the new container image tag:
   ```bash
   make push-task-runner
   ```
   *Note: Substrate templates pointing to `:latest` will pull the new image when new tasks are started, or when existing suspended tasks are resumed.*

2. **Roll out AX Controller Upgrade**:
   Compile and deploy the updated controller via `ko`. `ko` automatically generates a new container image tag, pushes it to your GCP repository, and performs a rolling update of the `ax-controller` deployment:
   ```bash
   KO_DOCKER_REPO=${AX_IMAGE_REPO} ko apply -f deploy/ax-controller.yaml
   ```

3. **Roll out AX Server Upgrade**:
   Compile and deploy the updated server via `ko`. This applies the latest spec and initiates a rolling update for the `ax-server` deployment:
   ```bash
   KO_DOCKER_REPO=${AX_IMAGE_REPO} ko apply -f deploy/ax-server.yaml
   ```

---

## Verify

1. **Verify rollout completion**:
   Monitor the status of the rolling updates to ensure all pods are replaced cleanly without error:
   ```bash
   kubectl rollout status deployment/ax-controller -n ax-system
   kubectl rollout status deployment/ax-server -n ax-system
   ```

2. **Verify persistence and resumption with upgraded runner**:
   Verify that a task suspended before the upgrade can be resumed cleanly under the new template:
   - Apply a task: `./bin/ax apply -f examples/task.yaml`
   - Wait for it to become Ready: `./bin/ax watch task/task-example`
   - Suspend the task: `./bin/ax suspend task/task-example`
   - Resume the task: `./bin/ax resume task/task-example`
   - Check that state was preserved in `/workspace` and the task returns to `Running` and `Ready` state.

---

## Teardown

If you need to roll back the upgrade or completely remove AX:

1. **Rollback Deployment to previous revision**:
   If the upgraded version fails verification, roll back the deployment to the previous stable state:
   ```bash
   kubectl rollout undo deployment/ax-controller -n ax-system
   kubectl rollout undo deployment/ax-server -n ax-system
   ```

2. **Full Teardown**:
   To delete all AX components and namespace:
   ```bash
   kubectl delete namespace ax-system --ignore-not-found
   ```
