---
tags: [homelab, kubernetes, storage, longhorn, nfs]
updated: 2026-03-21
---

# Storage

Longhorn distributed storage and NFS integration.

## Longhorn

| Setting | Value |
|---------|-------|
| Version | 1.10.1 |
| Namespace | longhorn-system |
| Data path | /var/lib/longhorn |
| Default replicas | 2 |
| StorageClass | longhorn (default) |

### Capacity

| Node | NVMe | OS/etcd | Available for Longhorn |
|------|------|---------|------------------------|
| Each | 512GB | ~100GB | ~400GB |
| Total (3 nodes) | 1.5TB | ~300GB | ~1.2TB raw |
| With 2x replication | — | — | ~600GB usable |

### Settings

| Setting | Value | Reason |
|---------|-------|--------|
| defaultReplicaCount | 2 | Balance HA and space |
| defaultDataPath | /var/lib/longhorn | Use NVMe |
| storageMinimalAvailablePercentage | 10 | Keep 10% for OS |
| dataLocality | best-effort | Schedule near data |
| nodeDownPodDeletionPolicy | delete-both-statefulset-and-deployment-pod | Auto-delete pods when node goes down (not drain) |
| orphanResourceAutoDeletion | `replica-data;instance` | Auto-cleanup orphaned replicas and instances |

### Access UI

```bash
kubectl-homelab -n longhorn-system port-forward svc/longhorn-frontend 8080:80
# Open http://localhost:8080
```

Or via: https://longhorn.k8s.rommelporras.com

## NFS (Dell 3090)

| Setting | Value |
|---------|-------|
| Server | 10.10.30.4 (omv.home.rommelporras.com) |
| System | OpenMediaVault 7.6.0-1 |
| NFS Version | NFSv4.1 |
| Pseudo-root | `/export` (fsid=0) |
| Hardware | Single drive — avoid heavy write I/O for config/DBs |

### NFS Export & Directory Convention

All K8s NFS storage uses a **single export** (`/export/Kubernetes`) with **one subdirectory per service group**. No new OMV shares needed for new services — just `mkdir` a new subdirectory.

**Isolation:** Each K8s PV mounts a specific subdirectory (e.g., `/Kubernetes/Media`). Pods cannot traverse above their mount point to see sibling directories. K8s PV/PVC binding, namespace isolation, and NetworkPolicy enforce access boundaries.

```
/export/Kubernetes/                   (OMV NFS export, NFSv4 path: /Kubernetes)
├── Immich/                           (photos/videos — PV: immich-nfs)
├── Media/                            (ARR stack — PV: arr-data-nfs, Phase 4.25)
│   ├── torrents/{movies,tv,music}/   (qBittorrent downloads)
│   └── media/{movies,tv,music}/      (Sonarr/Radarr hardlinked library)
├── Backups/                          (service database backups & snapshots)
│   ├── atuin/                        (Atuin PostgreSQL pg_dump, weekly CronJob)
│   ├── vault/                        (Vault Raft snapshots, daily CronJob)
│   ├── pki/                          (PKI certificate backups)
│   ├── longhorn/                     (Longhorn volume backups - backup target)
│   ├── etcd/                         (etcd snapshot backups)
│   ├── adguard/                      (AdGuard Home SQLite backups)
│   ├── uptime-kuma/                  (Uptime Kuma SQLite backups)
│   ├── grafana/                      (Grafana SQLite backups)
│   ├── karakeep/                     (Karakeep SQLite backups)
│   ├── myspeed/                      (MySpeed SQLite backups)
│   ├── arr/                          (ARR config SQLite backups)
│   ├── invoicetron/                  (Invoicetron PostgreSQL backups)
│   └── ghost-mysql/                  (Ghost MySQL backups)
├── Documents/                        (future — Nextcloud or Paperless-ngx)
└── (future services)/
```

| Subdirectory | NFSv4 Mount Path | K8s PV | Namespace | Status |
|-------------|-----------------|--------|-----------|--------|
| `Immich/` | `/Kubernetes/Immich` | `immich-nfs` | `immich` | Deployed |
| `Media/` | `/Kubernetes/Media` | `arr-data-nfs` | `arr-stack` | Deployed |
| `Backups/atuin/` | `/Kubernetes/Backups/atuin` | inline NFS volume | `atuin` | Deployed (v0.28.1) |
| `Backups/vault/` | `/Kubernetes/Backups/vault` | `vault-snapshots-nfs` | `vault` | Deployed (v0.29.0) |
| `Backups/pki/` | `/Kubernetes/Backups/pki` | inline NFS volume | `kube-system` | Phase 5.4 |
| `Backups/longhorn/` | `/Kubernetes/Backups/longhorn` | Longhorn backup target | `longhorn-system` | Phase 5.4 |
| `Backups/etcd/` | `/Kubernetes/Backups/etcd` | inline NFS volume | `kube-system` | Phase 5.4 |
| `Backups/adguard/` | `/Kubernetes/Backups/adguard` | inline NFS volume | `adguard` | Phase 5.4 |
| `Backups/uptime-kuma/` | `/Kubernetes/Backups/uptime-kuma` | inline NFS volume | `monitoring` | Phase 5.4 |
| `Backups/grafana/` | `/Kubernetes/Backups/grafana` | inline NFS volume | `monitoring` | Phase 5.4 |
| `Backups/karakeep/` | `/Kubernetes/Backups/karakeep` | inline NFS volume | `karakeep` | Phase 5.4 |
| `Backups/myspeed/` | `/Kubernetes/Backups/myspeed` | inline NFS volume | `myspeed` | Phase 5.4 |
| `Backups/arr/` | `/Kubernetes/Backups/arr` | inline NFS volume | `arr-stack` | Phase 5.4 |
| `Backups/invoicetron/` | `/Kubernetes/Backups/invoicetron` | inline NFS volume | `invoicetron` | Phase 5.4 |
| `Backups/ghost-mysql/` | `/Kubernetes/Backups/ghost-mysql` | inline NFS volume | `ghost` | Phase 5.4 |
| `Documents/` | `/Kubernetes/Documents` | TBD | TBD | Future (Nextcloud/Paperless-ngx) |

**NFSv4 path note:** OMV has `/export` with `fsid=0` as the pseudo-root. Filesystem path `/export/Kubernetes/Media` becomes NFSv4 mount path `/Kubernetes/Media`.

### NFS PV Convention

All NFS PVs follow this pattern (established by `manifests/storage/nfs-immich.yaml`):

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: <service>-nfs
  labels:
    type: nfs
    app: <service>
spec:
  capacity:
    storage: <size>
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain    # ALWAYS Retain for NFS
  storageClassName: nfs
  mountOptions:
    - hard
    - nfsvers=4.1
    - rsize=65536
    - wsize=65536
    - timeo=600
  nfs:
    server: 10.10.30.4
    path: /Kubernetes/<Subdirectory>       # NFSv4 pseudo-root path
```

## Velero

Velero backs up Kubernetes resources (manifests, PV snapshots) to S3-compatible storage.

| Setting | Value |
|---------|-------|
| Namespace | `velero` |
| Backend | Garage S3 (`dxflrs/garage:v2.2.0`) |
| Scope | K8s resource backups (not application data) |

Garage is a lightweight self-hosted S3-compatible store running in the cluster. Velero uses it as the object store backend for schedule-based resource backups. Application data backups (SQLite dumps, PostgreSQL pg_dump, etcd snapshots) go to NFS under `Backups/` via CronJobs.

## When to Use What

| Storage | Use For |
|---------|---------|
| Longhorn | Databases, stateful apps (HA needed) |
| NFS | Media files, photos, backups (large, not HA-critical) |
| Velero + Garage S3 | K8s resource backups (manifests, namespace state) |

## Commands

```bash
# Check Longhorn pods
kubectl-homelab -n longhorn-system get pods

# List volumes
kubectl-homelab -n longhorn-system get volumes.longhorn.io

# List replicas
kubectl-homelab -n longhorn-system get replicas.longhorn.io

# Check PVCs
kubectl-homelab get pvc -A

# Check StorageClass
kubectl-homelab get storageclass
```

## Longhorn: Stuck Stopped Replicas Recovery

When a node reboots or goes NotReady briefly, Longhorn may mark some replicas as "stopped." The `LonghornVolumeAllReplicasStopped` alert fires when all replicas of a volume are stopped. The cluster janitor CronJob handles stopped replicas automatically, but manual intervention may be needed for edge cases.

```bash
# 1. Identify stopped replicas
kubectl-homelab -n longhorn-system get replicas.longhorn.io \
  -o custom-columns=NAME:.metadata.name,VOLUME:.spec.volumeName,NODE:.spec.nodeID,STATE:.status.currentState \
  | grep stopped

# 2. Verify the volume has at least 1 healthy replica before deleting
kubectl-homelab -n longhorn-system get replicas.longhorn.io \
  -o custom-columns=VOLUME:.spec.volumeName,STATE:.status.currentState \
  | sort | uniq -c

# 3. Delete stopped replicas (Longhorn auto-rebuilds replacement)
kubectl-admin -n longhorn-system delete replicas.longhorn.io <name>

# 4. Monitor rebuild progress
kubectl-homelab -n longhorn-system get volumes.longhorn.io -w
```

**Volumes used only by CronJobs** show as detached with stopped replicas between runs - this is normal, not an error. The cluster janitor cleans these automatically.

## Related

- [[Architecture]] - Why Longhorn on NVMe
- [[Cluster]] - Node storage specs
- [[Versions]] - Longhorn version
