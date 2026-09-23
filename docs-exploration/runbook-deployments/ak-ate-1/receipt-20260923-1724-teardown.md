TORN-DOWN

## Resources Removed

1. **GKE Cluster (`ics-1`)**:
   - Location: Zone `us-central1-a` (2 nodes, machine type `c3-standard-4`).
   - *Verifying Evidence:* `gcloud container clusters list` returns empty. Running `gcloud container clusters describe ics-1 --zone us-central1-a` confirms the cluster is non-existent.

2. **GCS Storage Bucket (`ate-snapshots-barni-cnrm-20260529-us-central1`)**:
   - Location: Region `us-central1`.
   - *Verifying Evidence:* `gcloud storage buckets list` confirms only the independent kops state bucket exists. Running `gcloud storage buckets describe gs://ate-snapshots-barni-cnrm-20260529-us-central1` confirms the bucket has been deleted.

3. **AX Components (ax-system Namespace)**:
   - Deleted Deployments: `ax-server`, `ax-controller`, `ax-redis`.
   - Deleted Services: `ax-server`, `ax-redis`.
   - Deleted RBAC: ClusterRole, ClusterRoleBinding, ServiceAccount.
   - Deleted Namespace: `ax-system`.
   - *Verifying Evidence:* Since the hosting GKE cluster `ics-1` is deleted, all in-cluster components are completely destroyed.

4. **Orphaned GCE Persistent Disks**:
   - Checked for any orphaned or lingering disks associated with `ak-ate-1`.
   - *Verifying Evidence:* `gcloud compute disks list` shows only persistent disks associated with the pre-existing kops cluster (labeled for `ics3-k8s-local`), and no `ak-ate-1` disks remain.

5. **Local Build Artifacts**:
   - Verified that running `teardown.sh` cleanly executed `make clean` to remove compiled local CLI binaries and temporary directories.

## Remaining Resources

No resources belonging to or provisioned by the `ak-ate-1` deployment instance remain active. The only active resources in the project are dedicated to the independent, pre-existing `kops` cluster (`ics3-k8s-local`), including its virtual machines (e.g., `control-plane-us-central1-a-d2dw` and node instances), its GCS state bucket (`gs://barni-cnrm-20260529-ics3-kops-state/`), and its associated PVC disks (e.g., `pvc-6604b280-f0ba-479f-8faf-415ab2b15e53`).
