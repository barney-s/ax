TORN-DOWN

## Resources Removed

1. **AX Components (ax-system Namespace)**:
   - Deleted Deployments: `ax-server`, `ax-controller`, `ax-redis`.
   - Deleted Services: `ax-server`, `ax-redis`.
   - Deleted RBAC: ClusterRole, ClusterRoleBinding, ServiceAccount.
   - Deleted Namespace: `ax-system`.
   - *Verifying Evidence:* Verified namespace and deployments were successfully destroyed before cluster deletion, and fully confirmed by the deletion of the hosting GKE clusters.

2. **Primary GKE Cluster (`ics-1`)**:
   - Location: Zone `us-central1-a` (2 nodes, machine type `c3-standard-4`).
   - *Verifying Evidence:* `gcloud container clusters list --zone=us-central1-a` returned empty, and describe API calls confirm it is no longer found.

3. **Straggler GKE Cluster (`ak-ate-1`)**:
   - Location: Zone `us-west1-c` (2 nodes, machine type `c3-standard-4`). This GKE cluster was left running from a previous mismatched deployment attempt.
   - *Verifying Evidence:* `gcloud container clusters list --zone=us-west1-c` returned empty, confirming deletion completed successfully.

4. **GCS Storage Bucket (`ate-snapshots-barni-cnrm-20260529-us-central1`)**:
   - Location: Region `us-central1`.
   - *Verifying Evidence:* `gcloud storage buckets list` confirms the bucket has been deleted recursively.

5. **Straggler GCS Storage Bucket (`ate-snapshots-barni-cnrm-20260529`)**:
   - Location: Region `US-WEST1`. This empty bucket was left from a previous mismatched deployment attempt.
   - *Verifying Evidence:* `gcloud storage buckets list` confirms the bucket has been deleted recursively.

6. **Orphaned GCE Persistent Disks**:
   - `pvc-0da78f43-62f8-4c21-a55c-ece6f7b677fc` (500GB, `us-west1-c` - `data-postgres-0` for `ak-ate-1` GKE cluster)
   - `pvc-29378ab3-d976-4a0f-8b87-290e4d864dec` (500GB, `us-central1-a` - `data-postgres-0` for `ics-1` GKE cluster)
   - `pvc-aaa1f99c-1cc8-4cac-af7b-dd176d902364` (10GB, `us-central1-a` - `data-agentfs-controller-0` for `ics-1` GKE cluster)
   - *Verifying Evidence:* `gcloud compute disks list` shows only non-related kops disks remain.

7. **Local Build Artifacts**:
   - Executed `make clean` to remove compiled local CLI binaries and temporary directories.

## Remaining Resources

No resources belonging to or provisioned by the `ak-ate-1` deployment instance remain active. The only active resources in the project are dedicated to an independent, pre-existing `kops` cluster (`ics3-k8s-local`), including its VMs, GCS state bucket, networking configurations, and associated PVC disks.
