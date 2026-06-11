# Storage — Longhorn

Longhorn provides distributed block storage across the two worker nodes. It is the default `StorageClass`.

## How it Works

Longhorn manages `/dev/sdb` on each worker directly. The disk is **raw and unformatted** — do not partition or mount it. Longhorn discovers it automatically.

With two workers and `defaultReplicaCount: 2`, every volume is replicated across both workers. This means:
- One worker going down does **not** cause data loss
- You lose ~50% of raw capacity to replication (400 GB raw × 2 workers / 2 replicas = ~400 GB usable)

## Using Longhorn (PVCs)

Any `PersistentVolumeClaim` without an explicit `storageClassName` uses Longhorn by default:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-data
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
```

Longhorn only supports `ReadWriteOnce`. For `ReadWriteMany`, you need NFS on top — see the Longhorn docs for the NFS provisioner.

## Longhorn UI

```bash
kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80
# Open http://localhost:8080
```

The UI shows volume health, disk usage, replica placement, and snapshot/backup status.

## Useful Commands

```bash
# Node and disk status
kubectl -n longhorn-system get nodes.longhorn.io -o wide

# Volume list
kubectl -n longhorn-system get volumes.longhorn.io

# Replica placement
kubectl -n longhorn-system get replicas.longhorn.io

# See which PVC maps to which Longhorn volume
kubectl get pv -o custom-columns='PV:.metadata.name,PVC:.spec.claimRef.name,VOLUME:.spec.csi.volumeHandle'
```

## Backups

Longhorn supports snapshots (local, instant) and backups (to S3-compatible storage or NFS).

**Snapshots** (point-in-time, stored on the same disk — not a backup):
```bash
# Via UI or:
kubectl apply -f - <<EOF
apiVersion: longhorn.io/v1beta2
kind: Snapshot
metadata:
  name: my-snapshot
  namespace: longhorn-system
spec:
  volume: <longhorn-volume-name>
EOF
```

**Backups to S3** — configure a backup target in the Longhorn UI or via settings:
```bash
kubectl -n longhorn-system edit settings.longhorn.io backup-target
# Set to: s3://bucket@region/path
# Also set backup-target-credential-secret
```

## Expanding a Volume

Longhorn supports online volume expansion for `ReadWriteOnce` volumes:

```bash
kubectl patch pvc my-data -p '{"spec":{"resources":{"requests":{"storage":"20Gi"}}}}'
```

The filesystem is resized automatically after the volume expands.

## Adding a Disk

If you add more storage to a worker VM, you can add it to Longhorn via the UI under **Node → Edit Disks**, or by annotating the node:

```bash
kubectl -n longhorn-system edit nodes.longhorn.io ser5-worker-1
```

## What to Watch

- Longhorn volumes become `Degraded` if a replica is unavailable (worker down, disk full). They recover automatically when the replica comes back.
- Disk pressure: Longhorn reserves `storageMinimalAvailablePercentage: 10` — it will stop scheduling new replicas when less than 10% disk is free.
- `/dev/sdb` must be visible to the VM. If a worker VM loses its second virtual disk (Proxmox config issue), Longhorn will mark that node's disk as unavailable.
