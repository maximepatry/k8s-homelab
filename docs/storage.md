# Storage — Longhorn

Longhorn provides distributed block storage across all three nodes (host1 is untainted/schedulable too,
not etcd-only — see `docs/ansible.md`). It is the default `StorageClass`.

## How it Works

None of the three hosts have a second physical disk — each is single-disk, so Longhorn does **not** manage
a raw block device directly here (unlike the original VM-template design, which assumed a dedicated
`/dev/sdb`). Instead, the Ansible `storage` role (`ansible/roles/storage/`) carves a dedicated LV out of
each host's otherwise-unallocated LVM free space, formats it XFS, and mounts it at `/var/lib/longhorn`
*before* Kubernetes/Longhorn ever gets involved — Longhorn just sees a normal, already-mounted filesystem
path on each node. Per-host LV sizes (`ansible/host_vars/{host1,host2,host3}.yml`) come from real
`lsblk`/`vgs` polling, not an assumption:

| Host | LV size | Notes |
|------|---------|-------|
| host1 | 800 GB | 1TB NVMe, ~846GB was free in the VG |
| host2 | 380 GB | 512GB SATA SSD, ~397GB was free in the VG |
| host3 | 380 GB | 512GB NVMe, ~390GB was free in the VG — **NIC currently links at only 100 Mb/s**, fix the cable/switch port before relying on this node for replica placement, replication over 100 Mb will bottleneck |

With `defaultReplicaCount: 2` (`clusters/homelab/infrastructure/longhorn.yml`) across three nodes, every
volume is replicated onto two of the three — one node going down does not cause data loss.

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

Longhorn only supports `ReadWriteOnce`. For `ReadWriteMany`, you need NFS on top — see the Longhorn docs
for the NFS provisioner.

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

## Growing a Node's Longhorn LV

Each host's VG still has headroom left after the initial LV size (see table above). To grow it:

```bash
ssh -i ~/.ssh/id_ed25519_homelab foo@<host-ip>
sudo lvextend -L +100G /dev/rl_<hostname>/lv_longhorn
sudo xfs_growfs /var/lib/longhorn
```

Longhorn picks up the extra space automatically — no node re-annotation needed, unlike adding a whole new
disk (see the Longhorn docs' **Node → Edit Disks** UI for that case, not applicable here since there's no
second disk to add).

## What to Watch

- Longhorn volumes become `Degraded` if a replica is unavailable (node down, disk full). They recover
  automatically when the replica comes back.
- Disk pressure: Longhorn reserves `storageMinimalAvailablePercentage: 10` — it will stop scheduling new
  replicas when less than 10% disk is free.
- host3's degraded NIC link (100 Mb/s instead of 1 Gb/s) will slow replica rebuilds/writes to that node
  specifically — worth fixing before leaning on this cluster for anything storage-heavy.
