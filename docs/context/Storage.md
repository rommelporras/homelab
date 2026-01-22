---
tags: [homelab, kubernetes, storage, longhorn, nfs]
updated: 2026-01-22
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

Or via: https://longhorn.k8s.home.rommelporras.com

## NFS (Dell 5090)

| Setting | Value |
|---------|-------|
| Server | 10.10.30.4 (omv.home.rommelporras.com) |
| System | OpenMediaVault 7.6.0-1 |

### Planned Exports

| Export | Purpose |
|--------|---------|
| /export/photos | Immich photo library |
| /export/media | Movies, TV |
| /export/backups | Cluster backups |

### NFS PV Example

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: media-nfs
spec:
  capacity:
    storage: 1Ti
  accessModes:
    - ReadWriteMany
  nfs:
    server: 10.10.30.4
    path: /export/media
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
