---
tags: [homelab, kubernetes, storage, longhorn, nfs]
updated: 2026-02-16
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
├── Documents/                        (future — Nextcloud or Paperless-ngx)
└── (future services)/
```

| Subdirectory | NFSv4 Mount Path | K8s PV | Namespace | Status |
|-------------|-----------------|--------|-----------|--------|
| `Immich/` | `/Kubernetes/Immich` | `immich-nfs` | `immich` | Deployed |
| `Media/` | `/Kubernetes/Media` | `arr-data-nfs` | `arr-stack` | Deployed |
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

## When to Use What

| Storage | Use For |
|---------|---------|
| Longhorn | Databases, stateful apps (HA needed) |
| NFS | Media files, photos, backups (large, not HA-critical) |

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

## Related

- [[Architecture]] - Why Longhorn on NVMe
- [[Cluster]] - Node storage specs
- [[Versions]] - Longhorn version
