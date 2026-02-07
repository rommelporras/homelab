# Phase 4.25: ARR Media Stack

> **Status:** Planned
> **Target:** v0.21.0
> **Prerequisite:** Longhorn + Gateway API + NFS storage on OMV NAS running
> **Priority:** Medium (media automation platform)
> **DevOps Topics:** NFS storage, multi-app deployment, cross-app API integration, hardlinks
> **CKA Topics:** Deployment, Service, PVC, PV, HTTPRoute, Secret, NetworkPolicy, NFS volumes

> **Purpose:** Deploy the core *ARR media automation stack on Kubernetes — Prowlarr, Sonarr, Radarr, qBittorrent, and Jellyfin — with a shared NFS volume from the OMV NAS for media storage and Longhorn for app config.
>
> **Why:** Self-hosted media automation with full control. No cloud dependencies, no subscriptions. Centralized on K8s with monitoring, automatic restarts, and Longhorn-replicated config databases.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  media namespace                                                │
│                                                                 │
│  ┌───────────┐    ┌──────────┐    ┌──────────┐                │
│  │ Prowlarr  │───→│ Sonarr   │───→│          │                │
│  │ :9696     │    │ :8989    │    │ qBittor- │                │
│  │ (indexers)│───→│          │───→│ rent     │                │
│  └───────────┘    │ Radarr   │    │ :8080    │                │
│                   │ :7878    │    │          │                │
│                   └──────────┘    └────┬─────┘                │
│                        │               │                       │
│                   ┌────▼───────────────▼────┐                 │
│                   │  NFS PV: /data          │                 │
│                   │  ├── torrents/          │                 │
│                   │  │   ├── movies/        │                 │
│                   │  │   └── tv/            │                 │
│                   │  └── media/             │                 │
│                   │      ├── movies/  ◄─hardlinks              │
│                   │      └── tv/      ◄─hardlinks              │
│                   └────────────┬────────────┘                 │
│                                │                               │
│                   ┌────────────▼────────────┐                 │
│                   │  Jellyfin               │                 │
│                   │  :8096                   │                 │
│                   │  (media server)          │                 │
│                   └─────────────────────────┘                 │
│                                                                 │
│  Config PVCs (Longhorn 2Gi each):                              │
│  prowlarr-config, sonarr-config, radarr-config,               │
│  qbittorrent-config, jellyfin-config                           │
└─────────────────────────────────────────────────────────────────┘
                          │
                     OMV NAS (10.10.30.4)
                     └── /export/Kubernetes/Media/  (NFSv4: /Kubernetes/Media)
                         ├── torrents/
                         └── media/
```

### NFS Directory Convention

All K8s NFS storage uses the existing `/export/Kubernetes` export with one subdirectory per service group. No new OMV shares needed — just `mkdir` a new subdirectory and create a PV pointing to it.

```
/export/Kubernetes/                   (existing OMV NFS export)
├── Immich/                           (deployed — photos/videos)
├── Media/                            (this phase — ARR torrents + media library)
├── Documents/                        (future — Nextcloud or Paperless-ngx)
└── (future services)/
```

**Isolation:** Each PV mounts a specific subdirectory (e.g., `/Kubernetes/Media`). Pods cannot traverse above their mount point. K8s PV/PVC binding + namespace isolation + NetworkPolicy enforce access boundaries. See `docs/context/Storage.md` for full convention.

### Storage Strategy

| Data Type | Storage | Why |
|-----------|---------|-----|
| **Media files** (movies, TV, downloads) | NFS on OMV NAS (`10.10.30.4:/Kubernetes/Media`) | Large capacity, hardlinks work within single subdirectory, reuses existing NFS export |
| **App config** (SQLite DBs, settings, logs) | Longhorn PVC per app (2Gi each) | Fast writes, 2x replicated, keeps DB I/O off the NAS single drive |

### Hardlinks & Download Workflow (TRaSH Guides Best Practice)

All *ARR apps and qBittorrent mount the **same NFS export** at `/data`. This enables:

1. qBittorrent downloads to `/data/torrents/movies/`
2. Radarr creates a **hardlink** at `/data/media/movies/` (instant, zero extra space)
3. qBittorrent keeps seeding from `torrents/`, Jellyfin reads from `media/`
4. Both paths point to the same data on disk — 50GB movie uses 50GB, not 100GB

**Critical rule:** Downloads and media MUST be on the same NFS export for hardlinks to work. One PV, one PVC, mounted by all pods.

---

## Target State

| App | Port | URL | Config PVC | Image |
|-----|------|-----|------------|-------|
| Prowlarr | 9696 | `prowlarr.k8s.rommelporras.com` | 2Gi Longhorn | `lscr.io/linuxserver/prowlarr` (pin at deploy) |
| Sonarr | 8989 | `sonarr.k8s.rommelporras.com` | 2Gi Longhorn | `lscr.io/linuxserver/sonarr` (pin at deploy) |
| Radarr | 7878 | `radarr.k8s.rommelporras.com` | 2Gi Longhorn | `lscr.io/linuxserver/radarr` (pin at deploy) |
| qBittorrent | 8080 | `qbit.k8s.rommelporras.com` | 2Gi Longhorn | `lscr.io/linuxserver/qbittorrent` (pin at deploy) |
| Jellyfin | 8096 | `jellyfin.k8s.rommelporras.com` | 5Gi Longhorn | `jellyfin/jellyfin` (pin at deploy) |

| Shared Volume | Type | Mount | Access |
|---------------|------|-------|--------|
| NFS `/Kubernetes/Media` from `10.10.30.4` | PV + PVC | `/data` | ReadWriteMany |

---

## Prerequisites

- [ ] Directory structure created on OMV NAS under existing `/export/Kubernetes` share:
  ```
  /export/Kubernetes/Media/
  ├── torrents/
  │   ├── movies/
  │   └── tv/
  └── media/
      ├── movies/
      └── tv/
  ```
- [ ] Existing NFS export `/export/Kubernetes` already has correct options (`rw,no_subtree_check`)
- [ ] Verify NFS mount from a K8s node: `mount -t nfs4 10.10.30.4:/Kubernetes/Media /mnt/test`

---

## Tasks

### 4.25.1 NAS Setup

- [ ] 4.25.1.1 Create directory structure on OMV NAS (under existing `/export/Kubernetes` share):
  ```bash
  ssh omv
  mkdir -p /export/Kubernetes/Media/{torrents/{movies,tv,music},media/{movies,tv,music}}
  chown -R 1000:1000 /export/Kubernetes/Media
  ```
- [ ] 4.25.1.2 No new NFS share needed — reuses existing `/export/Kubernetes` export
- [ ] 4.25.1.3 Test NFS mount from a K8s node:
  ```bash
  sudo mount -t nfs4 10.10.30.4:/Kubernetes/Media /mnt/test
  ls /mnt/test/torrents /mnt/test/media
  sudo umount /mnt/test
  ```

### 4.25.2 Create Namespace & Shared Storage

- [ ] 4.25.2.1 Create `manifests/media/namespace.yaml`
  - PSS label: `pod-security.kubernetes.io/enforce: baseline`
  - `audit: restricted`, `warn: restricted`
- [ ] 4.25.2.2 Create `manifests/media/nfs-pv-pvc.yaml` — NFS PV + PVC (follow Immich NFS PV pattern)
  ```yaml
  apiVersion: v1
  kind: PersistentVolume
  metadata:
    name: arr-data-nfs
    labels:
      type: nfs
      app: arr
  spec:
    capacity:
      storage: 2Ti
    accessModes:
      - ReadWriteMany
    persistentVolumeReclaimPolicy: Retain
    storageClassName: nfs
    mountOptions:
      - hard
      - nfsvers=4.1
      - rsize=65536
      - wsize=65536
      - timeo=600
    nfs:
      server: 10.10.30.4
      # NFSv4 pseudo-root: OMV has /export with fsid=0
      # Filesystem path: /export/Kubernetes/Media → NFSv4 mount path: /Kubernetes/Media
      # Reuses existing /export/Kubernetes share (same as Immich PV)
      path: /Kubernetes/Media
  ---
  apiVersion: v1
  kind: PersistentVolumeClaim
  metadata:
    name: arr-data
    namespace: media
    labels:
      app: arr
  spec:
    accessModes:
      - ReadWriteMany
    storageClassName: nfs
    resources:
      requests:
        storage: 2Ti
    selector:
      matchLabels:
        app: arr
  ```

### 4.25.3 Deploy Prowlarr (First — Indexer Hub)

- [ ] 4.25.3.1 Pin image — check latest stable at https://github.com/Prowlarr/Prowlarr/releases
- [ ] 4.25.3.2 Create `manifests/media/prowlarr/deployment.yaml`
  - Longhorn PVC 2Gi for `/config`
  - `strategy: Recreate` (RWO config PVC)
  - Env: `PUID=1000`, `PGID=1000`, `TZ=Asia/Manila`
  - Resource limits: `cpu: 50m/250m`, `memory: 128Mi/256Mi`
- [ ] 4.25.3.3 Security context:
  - `allowPrivilegeEscalation: false`
  - `seccompProfile.type: RuntimeDefault`
  - `capabilities.drop: [ALL]` then add back `SETUID` + `SETGID` — LinuxServer images use `s6-overlay` init which calls `usermod`/`groupmod` to set PUID/PGID. Dropping ALL capabilities breaks container startup. Test at deploy time; if `s6-init` fails with permission errors, add `CHOWN` as well.
  - PSS: `baseline` (not `restricted`) — LinuxServer images require these capabilities
- [ ] 4.25.3.4 Create `manifests/media/prowlarr/service.yaml` — ClusterIP (port 9696)
- [ ] 4.25.3.5 Create `manifests/media/prowlarr/httproute.yaml` — `prowlarr.k8s.rommelporras.com`
- [ ] 4.25.3.6 Apply and verify, configure indexers in UI

### 4.25.4 Deploy qBittorrent (Download Client)

- [ ] 4.25.4.1 Pin image — check latest stable at https://github.com/linuxserver/docker-qbittorrent/releases
- [ ] 4.25.4.2 Create `manifests/media/qbittorrent/deployment.yaml`
  - Longhorn PVC 2Gi for `/config`
  - NFS PVC mounted at `/data` (shared `arr-data` PVC)
  - `strategy: Recreate`
  - Env: `PUID=1000`, `PGID=1000`, `TZ=Asia/Manila`, `WEBUI_PORT=8080`
  - Resource limits: `cpu: 250m/1`, `memory: 256Mi/1Gi`
  - Note: Set download paths in qBittorrent UI to `/data/torrents/movies/`, `/data/torrents/tv/`
- [ ] 4.25.4.3 Security context (same pattern as Prowlarr)
- [ ] 4.25.4.4 Create `manifests/media/qbittorrent/service.yaml` — ClusterIP (port 8080)
- [ ] 4.25.4.5 Create `manifests/media/qbittorrent/httproute.yaml` — `qbit.k8s.rommelporras.com`
- [ ] 4.25.4.6 Apply and verify, configure download paths in UI
- [ ] 4.25.4.7 qBittorrent NFS tuning (if seeding issues):
  - Set Disk I/O type to "Simple pread/pwrite" in advanced settings
  - Increase async I/O threads from 10 to 64

### 4.25.5 Deploy Sonarr (TV)

- [ ] 4.25.5.1 Pin image — check latest stable at https://github.com/Sonarr/Sonarr/releases
- [ ] 4.25.5.2 Create `manifests/media/sonarr/deployment.yaml`
  - Longhorn PVC 2Gi for `/config`
  - NFS PVC mounted at `/data` (shared `arr-data` PVC)
  - `strategy: Recreate`
  - Env: `PUID=1000`, `PGID=1000`, `TZ=Asia/Manila`
  - Resource limits: `cpu: 100m/500m`, `memory: 256Mi/512Mi`
- [ ] 4.25.5.3 Security context (same pattern)
- [ ] 4.25.5.4 Create `manifests/media/sonarr/service.yaml` — ClusterIP (port 8989)
- [ ] 4.25.5.5 Create `manifests/media/sonarr/httproute.yaml` — `sonarr.k8s.rommelporras.com`
- [ ] 4.25.5.6 Apply and verify
- [ ] 4.25.5.7 Configure: connect Prowlarr (indexers auto-sync), connect qBittorrent, set root folder to `/data/media/tv/`

### 4.25.6 Deploy Radarr (Movies)

- [ ] 4.25.6.1 Pin image — check latest stable at https://github.com/Radarr/Radarr/releases
- [ ] 4.25.6.2 Create `manifests/media/radarr/deployment.yaml`
  - Longhorn PVC 2Gi for `/config`
  - NFS PVC mounted at `/data` (shared `arr-data` PVC)
  - `strategy: Recreate`
  - Env: `PUID=1000`, `PGID=1000`, `TZ=Asia/Manila`
  - Resource limits: `cpu: 100m/1`, `memory: 256Mi/1Gi` (Radarr is memory-hungry with large libraries)
- [ ] 4.25.6.3 Security context (same pattern)
- [ ] 4.25.6.4 Create `manifests/media/radarr/service.yaml` — ClusterIP (port 7878)
- [ ] 4.25.6.5 Create `manifests/media/radarr/httproute.yaml` — `radarr.k8s.rommelporras.com`
- [ ] 4.25.6.6 Apply and verify
- [ ] 4.25.6.7 Configure: connect Prowlarr, connect qBittorrent, set root folder to `/data/media/movies/`

### 4.25.7 Deploy Jellyfin (Media Server)

- [ ] 4.25.7.1 Pin image — check latest stable at https://github.com/jellyfin/jellyfin/releases
- [ ] 4.25.7.2 Create `manifests/media/jellyfin/deployment.yaml`
  - Longhorn PVC 5Gi for `/config` (metadata, thumbnails, transcoding cache)
  - NFS PVC mounted at `/data` (same shared `arr-data` PVC — Jellyfin reads from `/data/media/`)
  - Note: Mount the full PVC at `/data`, NOT a subPath. Jellyfin library paths point to `/data/media/movies/` and `/data/media/tv/`
  - `strategy: Recreate`
  - Resource limits: `cpu: 500m/4`, `memory: 512Mi/2Gi`
  - Note: No GPU passthrough — CPU transcoding only (or direct play preferred)
- [ ] 4.25.7.3 Security context (same pattern)
- [ ] 4.25.7.4 Create `manifests/media/jellyfin/service.yaml` — ClusterIP (port 8096)
- [ ] 4.25.7.5 Create `manifests/media/jellyfin/httproute.yaml` — `jellyfin.k8s.rommelporras.com`
- [ ] 4.25.7.6 Apply and verify
- [ ] 4.25.7.7 Configure: add media libraries pointing to `/data/media/movies/` and `/data/media/tv/`

### 4.25.8 Verify Hardlink Workflow

- [ ] 4.25.8.1 Add a test item to Radarr, let it download via qBittorrent
- [ ] 4.25.8.2 Verify hardlink created (file appears in both `/data/torrents/` and `/data/media/`):
  ```bash
  kubectl-homelab exec -n media deploy/radarr -- ls -li /data/media/movies/
  kubectl-homelab exec -n media deploy/radarr -- ls -li /data/torrents/movies/
  # Inode numbers should match = hardlink working
  ```
- [ ] 4.25.8.3 Verify Jellyfin sees the imported media
- [ ] 4.25.8.4 Verify qBittorrent is still seeding the file

### 4.25.9 Integration

- [ ] 4.25.9.1 Add all apps to Homepage dashboard
- [ ] 4.25.9.2 Add all URLs to Uptime Kuma monitoring
- [ ] 4.25.9.3 Verify DNS resolution via existing `*.k8s.rommelporras.com` wildcard rewrite in AdGuard
- [ ] 4.25.9.4 Store API keys in 1Password: `op://Kubernetes/Prowlarr/api-key`, `op://Kubernetes/Sonarr/api-key`, `op://Kubernetes/Radarr/api-key`
- [ ] 4.25.9.5 Create shared K8s Secret for companion apps (Phase 4.26):
  ```bash
  kubectl-homelab create secret generic arr-api-keys \
    --from-literal=PROWLARR_API_KEY="$(op read 'op://Kubernetes/Prowlarr/api-key')" \
    --from-literal=SONARR_API_KEY="$(op read 'op://Kubernetes/Sonarr/api-key')" \
    --from-literal=RADARR_API_KEY="$(op read 'op://Kubernetes/Radarr/api-key')" \
    -n media
  ```

### 4.25.10 NetworkPolicy

- [ ] 4.25.10.1 Create `manifests/media/networkpolicy.yaml` — CiliumNetworkPolicy for `media` namespace
  - Allow intra-namespace traffic (all *ARR apps talk to each other)
  - Allow egress to internet (download clients need external access)
  - Allow ingress from `gateway` namespace (HTTPRoute traffic)
  - Allow ingress from `monitoring` namespace (Prometheus scraping, Phase 4.26)
  - Deny all other ingress by default

### 4.25.11 Documentation & Release

> Second commit: documentation updates and audit.

- [ ] 4.25.11.1 Update `docs/todo/README.md` — add Phase 4.25 to phase index + namespace table
- [ ] 4.25.11.2 Update `README.md` (root) — add ARR stack to services list
- [ ] 4.25.11.3 Update `VERSIONS.md` — add all app versions + HTTPRoutes
- [ ] 4.25.11.4 Update `docs/reference/CHANGELOG.md` — add architecture decisions (NFS hardlinks, storage split, app selection)
- [ ] 4.25.11.5 Update `docs/context/Cluster.md` — add `media` namespace
- [ ] 4.25.11.6 Update `docs/context/Gateway.md` — add 5 HTTPRoutes
- [ ] 4.25.11.7 Update `docs/context/Storage.md` — add NFS PV/PVC for media
- [ ] 4.25.11.8 Update `docs/context/Secrets.md` — add *ARR API keys + shared `arr-api-keys` secret
- [ ] 4.25.11.9 Update `docs/context/Networking.md` — add CiliumNetworkPolicy for `media` namespace
- [ ] 4.25.11.10 Create `docs/rebuild/v0.21.0-arr-stack.md`
- [ ] 4.25.11.11 `/audit-docs`
- [ ] 4.25.11.12 `/commit`
- [ ] 4.25.11.13 `/release v0.21.0 "ARR Media Stack"`
- [ ] 4.25.11.14 Move this file to `docs/todo/completed/`

---

## Resource Budget

| App | CPU Request | CPU Limit | Memory Request | Memory Limit | Config PVC |
|-----|-------------|-----------|----------------|--------------|------------|
| Prowlarr | 50m | 250m | 128Mi | 256Mi | 2Gi |
| qBittorrent | 250m | 1000m | 256Mi | 1Gi | 2Gi |
| Sonarr | 100m | 500m | 256Mi | 512Mi | 2Gi |
| Radarr | 100m | 1000m | 256Mi | 1Gi | 2Gi |
| Jellyfin | 500m | 4000m | 512Mi | 2Gi | 5Gi |
| **Total** | **1000m** | **6750m** | **1.4Gi** | **4.75Gi** | **13Gi** |

Fits comfortably on your 3-node cluster (~6% of total memory).

---

## Files to Create

| File | Type | Purpose |
|------|------|---------|
| `manifests/media/namespace.yaml` | Namespace | Media namespace with PSS labels |
| `manifests/media/nfs-pv-pvc.yaml` | PV + PVC | Shared NFS volume for media + downloads |
| `manifests/media/prowlarr/deployment.yaml` | Deployment + PVC | Prowlarr workload + config |
| `manifests/media/prowlarr/service.yaml` | Service | ClusterIP |
| `manifests/media/prowlarr/httproute.yaml` | HTTPRoute | `prowlarr.k8s.rommelporras.com` |
| `manifests/media/qbittorrent/deployment.yaml` | Deployment + PVC | qBittorrent workload + config |
| `manifests/media/qbittorrent/service.yaml` | Service | ClusterIP |
| `manifests/media/qbittorrent/httproute.yaml` | HTTPRoute | `qbit.k8s.rommelporras.com` |
| `manifests/media/sonarr/deployment.yaml` | Deployment + PVC | Sonarr workload + config |
| `manifests/media/sonarr/service.yaml` | Service | ClusterIP |
| `manifests/media/sonarr/httproute.yaml` | HTTPRoute | `sonarr.k8s.rommelporras.com` |
| `manifests/media/radarr/deployment.yaml` | Deployment + PVC | Radarr workload + config |
| `manifests/media/radarr/service.yaml` | Service | ClusterIP |
| `manifests/media/radarr/httproute.yaml` | HTTPRoute | `radarr.k8s.rommelporras.com` |
| `manifests/media/jellyfin/deployment.yaml` | Deployment + PVC | Jellyfin workload + config |
| `manifests/media/jellyfin/service.yaml` | Service | ClusterIP |
| `manifests/media/jellyfin/httproute.yaml` | HTTPRoute | `jellyfin.k8s.rommelporras.com` |
| `manifests/media/networkpolicy.yaml` | CiliumNetworkPolicy | Namespace network rules |

## Files to Modify

| File | Change |
|------|--------|
| `manifests/home/homepage/config/services.yaml` | Add all ARR apps + Jellyfin entries |

---

## Verification Checklist

- [ ] All 5 pods running in `media` namespace
- [ ] NFS PV/PVC bound and accessible from all pods
- [ ] Prowlarr indexers configured and synced to Sonarr/Radarr
- [ ] qBittorrent accessible and download paths set to `/data/torrents/`
- [ ] Sonarr root folder set to `/data/media/tv/`, connected to Prowlarr + qBittorrent
- [ ] Radarr root folder set to `/data/media/movies/`, connected to Prowlarr + qBittorrent
- [ ] Hardlinks verified (matching inodes between `/data/torrents/` and `/data/media/`)
- [ ] Jellyfin library scan finds media
- [ ] All HTTPRoutes accessible
- [ ] Homepage entries functional
- [ ] Uptime Kuma monitoring all endpoints

---

## Rollback

```bash
kubectl-homelab delete namespace media
# NFS data on OMV NAS is preserved
# Longhorn config PVCs will be deleted with the namespace
```

---

## Technology Decisions

| Decision | Choice | Why |
|----------|--------|-----|
| Media server | Jellyfin over Plex | Free, open-source, no telemetry, no subscription |
| Download client | qBittorrent | Community standard, best *ARR API integration |
| Indexer manager | Prowlarr | Replaces Jackett, auto-syncs to all *ARR apps |
| Download storage | NFS (not Longhorn) | Hardlinks require same filesystem for downloads + media |
| Config storage | Longhorn | Fast SQLite writes, 2x replicated, keeps I/O off NAS single drive |
| NFS location | `/export/Kubernetes/Media` subdirectory | Reuses existing NFS export, K8s PV/PVC provides isolation from Immich |
| Container images | LinuxServer.io | Consistent PUID/PGID, active maintenance, community standard |
