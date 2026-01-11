# Existing Infrastructure & Integration Plan

> **Last Updated:** January 11, 2026
> **K8s cluster details:** See [CLUSTER_STATUS.md](CLUSTER_STATUS.md)

---

## Overview

This document covers the existing Dell 5090 infrastructure and how it integrates with the new K8s cluster.

---

## Dell OptiPlex 5090 (NAS Role)

| Spec | Value |
|------|-------|
| **Role** | NAS + Proxmox host (transition to dedicated NAS) |
| **CPU** | Intel i5-10500T (6c/12t @ 2.3GHz) |
| **RAM** | 32 GB DDR4 |
| **Boot Drive** | Samsung 894GB SSD |
| **Data Drive** | WD Black SN850X 2TB NVMe (passthrough to OMV) |

---

## Current Services on Dell 5090

| Service | Purpose |
|---------|---------|
| OpenMediaVault | NAS with NVMe passthrough |
| Immich | Photo management |
| Docker host | Homepage, misc containers |
| NPM | Reverse proxy |
| AdGuard Home | Primary DNS |

---

## Integration Strategy

**Why NOT add Dell 5090 to K8s cluster:**
- Already running critical services (NAS, photos)
- NAS should be independent of K8s state
- Simpler migration path

**Integration approach:**
- K8s workloads mount NFS shares from Dell 5090
- Media files stay on NAS
- Databases requiring HA use Longhorn instead

---

## NFS Integration

### Planned Exports from OMV

| Export | Purpose |
|--------|---------|
| /export/photos | Immich photo library |
| /export/media | Media files (movies, TV) |
| /export/backups | Cluster backups |

### K8s NFS PV Example

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
    server: <nas-ip>
    path: /export/media
```

---

## Migration Plan

### Phase 1: Keep on Dell 5090
- OpenMediaVault (NAS) — Critical dependency
- Immich — GPU passthrough, large storage needs
- NPM — Reverse proxy for all services

### Phase 2: Migrate to K8s
- Homepage dashboard
- AdGuard Home (run dual for DNS HA)
- Stateless services

### Phase 3: Evaluate
- Immich (if GPU not needed)
- Media stack (new deployment)

### Keep Separate
- OPNsense — Stays on dedicated Topton firewall

---

## Future Option

If external NAS storage is added, Dell 5090 could become a K8s worker node:
- Adds 6 cores + 32GB RAM
- Same 10th Gen architecture (consistent scheduling)
- Only consider after K8s cluster is stable

---

## Related Documents

- [CLUSTER_STATUS.md](CLUSTER_STATUS.md) — K8s node details
- [ARCHITECTURE.md](ARCHITECTURE.md) — Why NAS stays separate
- [STORAGE_SETUP.md](STORAGE_SETUP.md) — Longhorn + NFS setup
- [reference/PROXMOX_OPNSENSE_GUIDE.md](reference/PROXMOX_OPNSENSE_GUIDE.md) — Full infrastructure overview
