# Phase 4.25: ARR Media Stack

> **Status:** Complete
> **Target:** v0.23.0
> **Prerequisite:** Longhorn + Gateway API + NFS storage on OMV NAS running
> **Priority:** Medium (media automation platform)
> **DevOps Topics:** NFS storage, multi-app deployment, cross-app API integration, hardlinks
> **CKA Topics:** Deployment, Service, PVC, PV, HTTPRoute, Secret, NetworkPolicy, NFS volumes

> **Purpose:** Deploy the core *ARR media automation stack on Kubernetes — Prowlarr, Sonarr, Radarr, qBittorrent, Jellyfin, and Bazarr — with a shared NFS volume from the OMV NAS for media storage and Longhorn for app config.
>
> **Why:** Self-hosted media automation with full control. No cloud dependencies, no subscriptions. Centralized on K8s with monitoring, automatic restarts, and Longhorn-replicated config databases.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  arr-stack namespace                                                │
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
│                   │  │   └── series/        │                 │
│                   │  └── media/             │                 │
│                   │      ├── movies/  ◄─hardlinks              │
│                   │      └── series/  ◄─hardlinks              │
│                   └────────────┬────────────┘                 │
│                                │                               │
│                   ┌────────────▼────────────┐                 │
│                   │  Jellyfin :8096          │                 │
│                   │  (media server)          │                 │
│                   │                          │                 │
│                   │  Bazarr :6767            │                 │
│                   │  (subtitles)             │                 │
│                   └─────────────────────────┘                 │
│                                                                 │
│  Config PVCs (Longhorn 2Gi each, 5Gi Jellyfin):               │
│  prowlarr-config, sonarr-config, radarr-config,               │
│  qbittorrent-config, jellyfin-config, bazarr-config            │
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
| Prowlarr | 9696 | `prowlarr.k8s.rommelporras.com` | 2Gi Longhorn | `lscr.io/linuxserver/prowlarr:2.3.0` |
| Sonarr | 8989 | `sonarr.k8s.rommelporras.com` | 2Gi Longhorn | `lscr.io/linuxserver/sonarr:latest` |
| Radarr | 7878 | `radarr.k8s.rommelporras.com` | 2Gi Longhorn | `lscr.io/linuxserver/radarr:latest` |
| qBittorrent | 8080 | `qbit.k8s.rommelporras.com` | 2Gi Longhorn | `lscr.io/linuxserver/qbittorrent:5.1.4` |
| Jellyfin | 8096 | `jellyfin.k8s.rommelporras.com` | 5Gi Longhorn | `jellyfin/jellyfin:10.11.6` |
| Bazarr | 6767 | `bazarr.k8s.rommelporras.com` | 2Gi Longhorn | `lscr.io/linuxserver/bazarr:latest` |

| Shared Volume | Type | Mount | Access |
|---------------|------|-------|--------|
| NFS `/Kubernetes/Media` from `10.10.30.4` | PV + PVC | `/data` | ReadWriteMany |

---

## Prerequisites

- [x] Directory structure created on OMV NAS under existing `/export/Kubernetes` share:
  ```
  /export/Kubernetes/Media/
  ├── torrents/
  │   ├── movies/
  │   ├── series/
  │   └── music/
  └── media/
      ├── movies/
      ├── series/
      └── music/
  ```
- [x] Existing NFS export `/export/Kubernetes` already has correct options (`rw,no_subtree_check`)
- [x] Verify NFS mount from a K8s node: `mount -t nfs4 10.10.30.4:/Kubernetes/Media /mnt/test`

---

## Tasks

### 4.25.1 NAS Setup

- [x] 4.25.1.1 Create directory structure on OMV NAS (under existing `/export/Kubernetes` share):
  ```bash
  ssh omv
  mkdir -p /export/Kubernetes/Media/{torrents/{movies,series,music},media/{movies,series,music}}
  chown -R 1000:1000 /export/Kubernetes/Media
  ```
- [x] 4.25.1.2 No new NFS share needed — reuses existing `/export/Kubernetes` export
- [x] 4.25.1.3 Test NFS mount from a K8s node:
  ```bash
  sudo mount -t nfs4 10.10.30.4:/Kubernetes/Media /mnt/test
  ls /mnt/test/torrents /mnt/test/media
  sudo umount /mnt/test
  ```

### 4.25.2 Create Namespace & Shared Storage

- [x] 4.25.2.1 Create `manifests/arr-stack/namespace.yaml`
  - PSS label: `pod-security.kubernetes.io/enforce: baseline`
  - `audit: restricted`, `warn: restricted`
- [x] 4.25.2.2 Create `manifests/arr-stack/nfs-pv-pvc.yaml` — NFS PV + PVC (follow Immich NFS PV pattern)
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
    namespace: arr-stack
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

- [x] 4.25.3.1 Image: `lscr.io/linuxserver/prowlarr:2.3.0` (latest stable as of Feb 2026)
- [x] 4.25.3.2 Create `manifests/arr-stack/prowlarr/deployment.yaml`
  - Longhorn PVC 2Gi for `/config`
  - `strategy: Recreate` (RWO config PVC)
  - Env: `PUID=1000`, `PGID=1000`, `TZ=Asia/Manila`
  - Resource limits: `cpu: 50m/250m`, `memory: 128Mi/256Mi`
- [x] 4.25.3.3 Security context (LinuxServer s6-overlay pattern — same for all LSIO apps in this phase):
  - Pod-level: `fsGroup: 1000`, `seccompProfile.type: RuntimeDefault`
  - Container-level: `allowPrivilegeEscalation: false`
  - `capabilities.drop: [ALL]` then `add: [CHOWN, SETUID, SETGID]` — s6-overlay needs CHOWN for `/var/run/s6` ownership, SETUID/SETGID for user switching. Matches existing Firefox deployment pattern.
  - PSS: `baseline` (not `restricted`) — LinuxServer images require these capabilities
  - Note: DAC_OVERRIDE and FOWNER are NOT needed for ARR apps (only Firefox needed those for nginx). If s6-init fails with permission errors, add them back.
- [x] 4.25.3.4 Health probes (same pattern for Prowlarr/Radarr — `/ping` is unauthenticated):
  ```yaml
  startupProbe:
    httpGet:
      path: /ping
      port: 9696
    periodSeconds: 10
    failureThreshold: 30    # 5 min for first boot + DB init
  livenessProbe:
    httpGet:
      path: /ping
      port: 9696
    periodSeconds: 30
    failureThreshold: 3
  readinessProbe:
    httpGet:
      path: /ping
      port: 9696
    periodSeconds: 10
    failureThreshold: 2
  ```
- [x] 4.25.3.5 Create `manifests/arr-stack/prowlarr/service.yaml` — ClusterIP (port 9696)
- [x] 4.25.3.6 Create `manifests/arr-stack/prowlarr/httproute.yaml` — `prowlarr.k8s.rommelporras.com`
- [x] 4.25.3.7 Apply and verify: `kubectl-homelab apply -f manifests/arr-stack/prowlarr/`
- [x] 4.25.3.8 Configure Prowlarr UI:
  - **Authentication:** Settings > General > Security
    - Authentication Method: **Forms (Login Page)**
    - Authentication Required: **Disabled for Local Addresses**
    - Username/Password: from 1Password `ARR Stack` item
  - **Indexers:** Indexers > Add Indexer
    - ~~**1337x** — skipped (Cloudflare DDoS bot protection blocks Prowlarr, needs FlareSolverr which is a dead project)~~
    - ~~**TheRARBG** — not in Prowlarr index (original RARBG shut down, community successor removed)~~
    - **EZTV** — TV-focused, no special settings needed
    - **YTS** — compact movie encodes, no special settings needed
    - **Nyaa.si** — anime, enable "Sonarr/Radarr compatibility" options in the indexer config (maps Nyaa categories to standard ones)
    - All public indexers, no account needed
  - **Apps (Sync to Sonarr/Radarr):** Settings > Apps > Add Application
    - **Sonarr:**
      - Sync Level: **Full Sync** (Prowlarr is single source of truth for indexers)
      - Prowlarr Server: `http://localhost:9696` (Prowlarr fills this in)
      - Sonarr Server: `http://sonarr.arr-stack.svc.cluster.local:8989`
      - API Key: Sonarr API key from 1Password
    - **Radarr:**
      - Sync Level: **Full Sync**
      - Prowlarr Server: `http://localhost:9696`
      - Radarr Server: `http://radarr.arr-stack.svc.cluster.local:7878`
      - API Key: Radarr API key from 1Password
    - After saving, click "Sync App Indexers" to push indexers immediately

### 4.25.4 Deploy qBittorrent (Download Client)

- [x] 4.25.4.1 Image: `lscr.io/linuxserver/qbittorrent:5.1.4` (latest stable as of Feb 2026)
- [x] 4.25.4.2 Create `manifests/arr-stack/qbittorrent/deployment.yaml`
  - Longhorn PVC 2Gi for `/config`
  - NFS PVC mounted at `/data` (shared `arr-data` PVC)
  - `strategy: Recreate`
  - Env: `PUID=1000`, `PGID=1000`, `TZ=Asia/Manila`, `WEBUI_PORT=8080`
  - Resource limits: `cpu: 250m/1`, `memory: 256Mi/1Gi`
- [x] 4.25.4.3 Security context (same LSIO s6-overlay pattern as Prowlarr)
- [x] 4.25.4.4 Health probes (tcpSocket — HTTP API returns 403 due to CSRF protection):
  ```yaml
  startupProbe:
    tcpSocket:
      port: 8080
    periodSeconds: 10
    failureThreshold: 30
  livenessProbe:
    tcpSocket:
      port: 8080
    periodSeconds: 30
    failureThreshold: 3
  readinessProbe:
    tcpSocket:
      port: 8080
    periodSeconds: 10
    failureThreshold: 2
  ```
- [x] 4.25.4.5 Create `manifests/arr-stack/qbittorrent/service.yaml` — ClusterIP (port 8080)
- [x] 4.25.4.6 Create `manifests/arr-stack/qbittorrent/httproute.yaml` — `qbit.k8s.rommelporras.com`
- [x] 4.25.4.7 Apply and verify: `kubectl-homelab apply -f manifests/arr-stack/qbittorrent/`
- [x] 4.25.4.8 Configure qBittorrent UI:
  - **First login:** Default credentials are `admin` / check container logs for temporary password:
    ```bash
    kubectl-homelab logs -n arr-stack deploy/qbittorrent | grep "temporary password"
    ```
  - **Authentication:** Settings > Web UI
    - Change username/password to match 1Password `ARR Stack` credentials
  - **Downloads:** Settings > Downloads > Saving Management
    - **Default Torrent Management Mode:** `Automatic` (CRITICAL — `Manual` mode ignores category folders and saves to `/downloads` which doesn't exist)
    - **Default Save Path:** `/data/torrents`
    - **Uncheck "Keep incomplete torrents in"** — avoids unnecessary NFS-to-NFS moves
  - **Categories:** Right-click in category sidebar > Add category
    - `movies` (empty save path — inherits from default + category name = `/data/torrents/movies/`)
    - `series` (empty save path = `/data/torrents/series/`)
  - **Connection:** Settings > Connection
    - **Disable UPnP/NAT-PMP** — not useful inside K8s pod network
  - **BitTorrent:** Settings > BitTorrent > Seeding Limits
    - **When ratio reaches:** Check, set to `0` (stop seeding immediately — NAS has single NVMe, preserve TBW)
    - **then:** `Stop torrent`
    - Uncheck the other two (total seeding time, inactive seeding time)
- [x] 4.25.4.9 qBittorrent NFS tuning (Settings > Advanced > libtorrent Section):
  - **Asynchronous I/O threads:** `64` (default 10 — NFS has higher latency than local disk)
  - **Disk IO type:** `Simple pread/pwrite` (requires pod restart — better for NFS, avoids mmap issues)
  - **Disk queue size:** `65536` KiB (64 MiB buffer for NFS writes, default 1024 KiB)
  - After saving, restart pod: `kubectl-homelab rollout restart deployment/qbittorrent -n arr-stack`

### 4.25.5 Deploy Sonarr (TV)

- [x] 4.25.5.1 Image: `lscr.io/linuxserver/sonarr:latest` (pinned tag didn't exist on registry) (latest stable as of Feb 2026)
- [x] 4.25.5.2 Create `manifests/arr-stack/sonarr/deployment.yaml`
  - Longhorn PVC 2Gi for `/config`
  - NFS PVC mounted at `/data` (shared `arr-data` PVC)
  - `strategy: Recreate`
  - Env: `PUID=1000`, `PGID=1000`, `TZ=Asia/Manila`
  - Resource limits: `cpu: 100m/500m`, `memory: 256Mi/512Mi`
  - Note: 512Mi is tight for large libraries — monitor for OOM and bump to 768Mi-1Gi if needed
- [x] 4.25.5.3 Security context (same LSIO s6-overlay pattern as Prowlarr)
- [x] 4.25.5.4 Health probes:
  ```yaml
  # Sonarr v4 /ping may require auth (GitHub issue #5396) — test at deploy.
  # If /ping returns 401, fall back to tcpSocket probe on port 8989.
  startupProbe:
    httpGet:
      path: /ping
      port: 8989
    periodSeconds: 10
    failureThreshold: 30
  livenessProbe:
    httpGet:
      path: /ping
      port: 8989
    periodSeconds: 30
    failureThreshold: 3
  readinessProbe:
    httpGet:
      path: /ping
      port: 8989
    periodSeconds: 10
    failureThreshold: 2
  ```
- [x] 4.25.5.5 Create `manifests/arr-stack/sonarr/service.yaml` — ClusterIP (port 8989)
- [x] 4.25.5.6 Create `manifests/arr-stack/sonarr/httproute.yaml` — `sonarr.k8s.rommelporras.com`
- [x] 4.25.5.7 Apply and verify: `kubectl-homelab apply -f manifests/arr-stack/sonarr/`
- [x] 4.25.5.8 Configure Sonarr UI:
  - **Authentication:** Settings > General > Security
    - Authentication Method: **Forms (Login Page)**
    - Authentication Required: **Disabled for Local Addresses**
    - Username/Password: from 1Password `ARR Stack` item
  - **Download Client:** Settings > Download Clients > Add > qBittorrent
    - Host: `qbittorrent.arr-stack.svc.cluster.local`
    - Port: `8080`
    - Username/Password: from 1Password `ARR Stack` item
    - Category: `series` (maps to `/data/torrents/series/`)
    - Click Test, then Save
  - **Root Folder:** Settings > Media Management > Root Folders > Add
    - Path: `/data/media/series/`
  - **Prowlarr sync:** Automatic — indexers appear after Prowlarr Apps sync (step 4.25.3.8)
  - **API Key:** Settings > General > API Key — copy and store in 1Password `ARR Stack` > `sonarr-api-key`

### 4.25.6 Deploy Radarr (Movies)

- [x] 4.25.6.1 Image: `lscr.io/linuxserver/radarr:latest` (pinned tag didn't exist on registry) (latest stable as of Feb 2026)
- [x] 4.25.6.2 Create `manifests/arr-stack/radarr/deployment.yaml`
  - Longhorn PVC 2Gi for `/config`
  - NFS PVC mounted at `/data` (shared `arr-data` PVC)
  - `strategy: Recreate`
  - Env: `PUID=1000`, `PGID=1000`, `TZ=Asia/Manila`
  - Resource limits: `cpu: 100m/1`, `memory: 256Mi/1Gi` (Radarr is memory-hungry with large libraries)
- [x] 4.25.6.3 Security context (same LSIO s6-overlay pattern as Prowlarr)
- [x] 4.25.6.4 Health probes (Radarr `/ping` is unauthenticated — same as Prowlarr, port 7878)
- [x] 4.25.6.5 Create `manifests/arr-stack/radarr/service.yaml` — ClusterIP (port 7878)
- [x] 4.25.6.6 Create `manifests/arr-stack/radarr/httproute.yaml` — `radarr.k8s.rommelporras.com`
- [x] 4.25.6.7 Apply and verify: `kubectl-homelab apply -f manifests/arr-stack/radarr/`
- [x] 4.25.6.8 Configure Radarr UI:
  - **Authentication:** Settings > General > Security
    - Authentication Method: **Forms (Login Page)**
    - Authentication Required: **Disabled for Local Addresses**
    - Username/Password: from 1Password `ARR Stack` item
  - **Download Client:** Settings > Download Clients > Add > qBittorrent
    - Host: `qbittorrent.arr-stack.svc.cluster.local`
    - Port: `8080`
    - Username/Password: from 1Password `ARR Stack` item
    - Category: `movies` (maps to `/data/torrents/movies/`)
    - Click Test, then Save
  - **Root Folder:** Settings > Media Management > Root Folders > Add
    - Path: `/data/media/movies/`
  - **Prowlarr sync:** Automatic — indexers appear after Prowlarr Apps sync (step 4.25.3.8)
  - **API Key:** Settings > General > API Key — copy and store in 1Password `ARR Stack` > `radarr-api-key`

### 4.25.7 Deploy Jellyfin (Media Server)

- [x] 4.25.7.1 Image: `jellyfin/jellyfin:10.11.6` (official image, NOT LinuxServer — bundles jellyfin-ffmpeg with iHD driver for Phase 4.25b QSV)
- [x] 4.25.7.2 Create `manifests/arr-stack/jellyfin/deployment.yaml`
  - Longhorn PVC 5Gi for `/config` (metadata, thumbnails, transcoding cache)
  - NFS PVC mounted at `/data` (same shared `arr-data` PVC — Jellyfin reads from `/data/media/`)
  - Note: Mount the full PVC at `/data`, NOT a subPath. Jellyfin library paths point to `/data/media/movies/` and `/data/media/series/`
  - `strategy: Recreate`
  - Resource limits: `cpu: 500m/4`, `memory: 512Mi/2Gi`
  - Note: CPU transcoding only in this phase — Intel QSV hardware transcoding added in Phase 4.25b
- [x] 4.25.7.3 Security context (**different from LSIO apps** — official Jellyfin image has no s6-overlay):
  - Pod-level: `runAsUser: 1000`, `runAsGroup: 1000`, `fsGroup: 1000`, `seccompProfile.type: RuntimeDefault`
  - Container-level: `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`
  - No PUID/PGID env vars — use K8s `runAsUser`/`runAsGroup` instead (official image respects standard Linux UID)
  - No CHOWN/SETUID/SETGID needed — no s6-overlay init
  - Meets PSS `restricted` profile (stricter than the LSIO apps)
- [x] 4.25.7.4 Health probes:
  ```yaml
  startupProbe:
    httpGet:
      path: /health
      port: 8096
    periodSeconds: 10
    failureThreshold: 30    # 5 min — first boot scans media libraries
  livenessProbe:
    httpGet:
      path: /health
      port: 8096
    periodSeconds: 30
    failureThreshold: 3
  readinessProbe:
    httpGet:
      path: /health
      port: 8096
    periodSeconds: 10
    failureThreshold: 2
  ```
- [x] 4.25.7.5 Create `manifests/arr-stack/jellyfin/service.yaml` — ClusterIP (port 8096)
- [x] 4.25.7.6 Create `manifests/arr-stack/jellyfin/httproute.yaml` — `jellyfin.k8s.rommelporras.com`
- [x] 4.25.7.7 Apply and verify: `kubectl-homelab apply -f manifests/arr-stack/jellyfin/`
- [x] 4.25.7.8 Configure Jellyfin setup wizard (`https://jellyfin.k8s.rommelporras.com`):
  - **Language:** English
  - **Server name:** `Homelab Jellyfin` (not the pod hostname which changes on restart)
  - **Admin account:** Create with credentials from 1Password (separate `Jellyfin` or `ARR Stack` > `jellyfin-*` fields)
  - **Media Libraries:**
    - **Movies:** Content type = Movies, Display name = Movies, Folder = `/data/media/movies/`
      - Uncheck **Nfo** under Metadata savers (Jellyfin stores metadata in its own DB, Nfo writes clutter to NFS)
    - **Series:** Content type = Shows, Display name = Series, Folder = `/data/media/series/`
      - Uncheck **Nfo** under Metadata savers
  - **Preferred Metadata Language:** English
  - **Remote Access:** Enable "Allow remote connections to this server"
  - **API Key:** After wizard, go to Administration > API Keys (`/web/#/dashboard/keys`) > create key named `Homepage`
    - Store in 1Password `ARR Stack` > `jellyfin-api-key`

### 4.25.8 Bazarr (Subtitles)

- [x] 4.25.8.1 Create `manifests/arr-stack/bazarr/deployment.yaml` — Deployment + Longhorn PVC (2Gi)
  - Image: `lscr.io/linuxserver/bazarr:latest`
  - Longhorn PVC at `/config`, shared NFS PVC at `/data`
  - LSIO security context (CHOWN/SETUID/SETGID)
  - Resources: cpu 50m/250m, memory 128Mi/256Mi
  - Health probes: `/api/system/ping` on port 6767 (unauthenticated, added in v1.5.2)
- [x] 4.25.8.2 Create `manifests/arr-stack/bazarr/service.yaml` — ClusterIP (port 6767)
- [x] 4.25.8.3 Create `manifests/arr-stack/bazarr/httproute.yaml` — `bazarr.k8s.rommelporras.com`
- [x] 4.25.8.4 Apply and verify: `kubectl-homelab apply -f manifests/arr-stack/bazarr/`
- [x] 4.25.8.5 Configure Bazarr UI (`https://bazarr.k8s.rommelporras.com`):
  - **Authentication:** Settings > General > Security
    - Authentication Method: **Forms (Login Page)**
    - Authentication Required: **Disabled for Local Addresses**
    - Username/Password: from 1Password `ARR Stack` item
- [x] 4.25.8.6 Connect Sonarr: Settings > Sonarr
  - Enable: On
  - Host Address: `sonarr.arr-stack.svc.cluster.local`
  - Port: `8989`
  - API Key: from 1Password `ARR Stack` > `sonarr-api-key`
  - Click Test, then Save
- [x] 4.25.8.7 Connect Radarr: Settings > Radarr
  - Enable: On
  - Host Address: `radarr.arr-stack.svc.cluster.local`
  - Port: `7878`
  - API Key: from 1Password `ARR Stack` > `radarr-api-key`
  - Click Test, then Save
- [x] 4.25.8.8 Subtitle providers and languages:
  - **Providers:** Settings > Providers > Add
    - **OpenSubtitles.com** — requires free account (credentials in 1Password `Opensubtitles` item)
      - Uncheck "AI translation service" and "Machine translated by users" (low quality)
      - Keep "Use Hash" enabled (matches by file hash — more accurate)
    - **Podnapisi** — no account needed, good backup provider
      - Keep "Verify SSL certificate" enabled
  - **Languages:** Settings > Languages
    - Create Languages Profile: Name = `English`, Language = English, Subtitles Type = Normal or hearing-impaired, Search = Always
    - **Default Language Profiles For Newly Added Shows:**
      - Series: `English`
      - Movies: `English`
- [x] 4.25.8.9 Store API key in 1Password:
  - API Key location: Settings > General > Security > API Key
  - Update `ARR Stack` item with field `bazarr-api-key`

### 4.25.9 Jellyfin Mobile Client Setup

- [x] 4.25.9.1 **iPhone:** Install "Jellyfin" from the App Store (free, official app by Jellyfin)
- [x] 4.25.9.2 **Android:** Install "Jellyfin" from Google Play Store (free, official app by Jellyfin)
- [x] 4.25.9.3 Open the app → Add Server → enter `https://jellyfin.k8s.rommelporras.com`
  - This works on home WiFi via AdGuard DNS wildcard rewrite (`*.k8s.rommelporras.com` → Cilium VIP)
  - On mobile data / outside home: requires Tailscale VPN connected (subnet router advertises the K8s network)
- [x] 4.25.9.4 Log in with the Jellyfin account created during setup wizard (step 4.25.7.8)
- [x] 4.25.9.5 Test playback on WiFi — should direct play most formats
- [x] 4.25.9.6 Test playback on mobile data — works but CPU transcoding is slow (expected, QSV in Phase 4.25b will fix)
- [x] 4.25.9.7 Optional: Set "Maximum streaming bitrate" to a lower cap for mobile data to reduce transcoding load

### 4.25.10 Verify Hardlink Workflow

- [x] 4.25.10.1 Add a test movie in Radarr (Add New > search > enable "Start search for missing movie")
  - Test movie: One Piece Film Red (2022) — downloaded from YTS via qBittorrent
  - Radarr auto-imported once download completed
  - Bazarr auto-downloaded English subtitles (.en.srt)
- [x] 4.25.10.2 Verify import completed:
  ```bash
  kubectl-homelab exec -n arr-stack deploy/radarr -- ls -li /data/media/movies/
  # File at /data/media/movies/One Piece Film Red (2022)/ — 2.12 GiB + .en.srt
  ```
  - Note: With seeding disabled (ratio 0), Radarr's "Remove Completed Downloads" deletes the source from `/data/torrents/movies/` after import. File has link count 1 (not a hardlink). This is expected and correct — hardlinks only matter when seeding is active (file exists in both torrents/ and media/ simultaneously).
- [x] 4.25.10.3 Verify Jellyfin sees the imported media:
  - Triggered manual library scan: Administration > Scheduled Tasks > Scan All Libraries
  - Movie appeared in Jellyfin Movies library after scan
  - **Automatic scanning:** Added Jellyfin connection in both Radarr and Sonarr (Settings > Connect > Emby / Jellyfin):
    - Host: `jellyfin.arr-stack.svc.cluster.local`, Port: `8096`, Use SSL: off
    - API Key: from 1Password `ARR Stack` > `jellyfin-api-key`
    - Update Library: checked (triggers scan on import)
    - Send Notifications: unchecked
  - Default scheduled scan remains at every 12 hours as fallback
- [x] 4.25.10.4 Verify qBittorrent torrent was removed after import (seeding disabled — ratio limit 0, Radarr cleaned up completed download)

### 4.25.11 Integration

- [x] 4.25.11.1 Add all apps to Homepage dashboard (new "Media" group between Apps and Health):
  - Added widget entries in `manifests/home/homepage/config/services.yaml`:
    - Jellyfin (type: jellyfin, enableBlocks + enableNowPlaying, key from `HOMEPAGE_VAR_JELLYFIN_KEY`)
    - Sonarr (type: sonarr, key from `HOMEPAGE_VAR_SONARR_API_KEY`)
    - Radarr (type: radarr, key from `HOMEPAGE_VAR_RADARR_API_KEY`)
    - qBittorrent (type: qbittorrent, username/password from `HOMEPAGE_VAR_QBIT_USER`/`HOMEPAGE_VAR_QBIT_PASS`)
    - Bazarr (type: bazarr, key from `HOMEPAGE_VAR_BAZARR_API_KEY`)
    - Prowlarr (type: prowlarr, key from `HOMEPAGE_VAR_PROWLARR_API_KEY`)
  - Patched `homepage-secrets` Secret in `home` namespace with all 7 new env vars:
    ```bash
    kubectl-homelab -n home patch secret homepage-secrets --type merge -p "{\"stringData\":{
      \"HOMEPAGE_VAR_JELLYFIN_KEY\":\"$(op read 'op://Kubernetes/ARR Stack/jellyfin-api-key')\",
      \"HOMEPAGE_VAR_SONARR_API_KEY\":\"$(op read 'op://Kubernetes/ARR Stack/sonarr-api-key')\",
      \"HOMEPAGE_VAR_RADARR_API_KEY\":\"$(op read 'op://Kubernetes/ARR Stack/radarr-api-key')\",
      \"HOMEPAGE_VAR_PROWLARR_API_KEY\":\"$(op read 'op://Kubernetes/ARR Stack/prowlarr-api-key')\",
      \"HOMEPAGE_VAR_BAZARR_API_KEY\":\"$(op read 'op://Kubernetes/ARR Stack/bazarr-api-key')\",
      \"HOMEPAGE_VAR_QBIT_USER\":\"$(op read 'op://Kubernetes/ARR Stack/username')\",
      \"HOMEPAGE_VAR_QBIT_PASS\":\"$(op read 'op://Kubernetes/ARR Stack/password')\"
    }}"
    ```
  - Applied: `kubectl-homelab apply -k manifests/home/homepage/` (kustomize — regenerates ConfigMap with hash suffix, triggers pod rollout)
- [x] 4.25.11.2 Add all URLs to Uptime Kuma monitoring (`https://uptime.k8s.rommelporras.com`):
  - Group: **Media**, Tag: **Kubernetes**
  - All monitors use base HTTPS URLs with **403 accepted** (auth blocks unauthenticated requests through Gateway)
  - Note: Internal `/ping` endpoints return 200 but are blocked by NetworkPolicy from `uptime-kuma` namespace — using Gateway path instead tests the full stack
  | Monitor Name | URL | Accepted Codes |
  |---|---|---|
  | Jellyfin | `https://jellyfin.k8s.rommelporras.com` | 200-299, 403 |
  | Sonarr | `https://sonarr.k8s.rommelporras.com` | 200-299, 403 |
  | Radarr | `https://radarr.k8s.rommelporras.com` | 200-299, 403 |
  | Prowlarr | `https://prowlarr.k8s.rommelporras.com` | 200-299, 403 |
  | qBittorrent | `https://qbit.k8s.rommelporras.com` | 200-299, 403 |
  | Bazarr | `https://bazarr.k8s.rommelporras.com` | 200-299, 403 |
- [x] 4.25.11.3 Verify DNS resolution via existing `*.k8s.rommelporras.com` wildcard rewrite in AdGuard (confirmed — all 6 monitors green)
- [x] 4.25.11.4 Store all API keys in 1Password `ARR Stack` item (single item, shared credentials):
  - Fields: `username`, `password`, `prowlarr-api-key`, `sonarr-api-key`, `radarr-api-key`, `bazarr-api-key`, `jellyfin-api-key`
  - Separate item: `Opensubtitles` (for Bazarr subtitle provider login)
- [x] 4.25.11.5 Create `manifests/arr-stack/arr-api-keys-secret.yaml` — shared Secret for companion apps (Phase 4.26):
  ```yaml
  # Declarative Secret manifest — values injected from 1Password at apply time
  # Apply: scripts/apply-arr-secrets.sh (wrapper that reads from op:// and applies)
  apiVersion: v1
  kind: Secret
  metadata:
    name: arr-api-keys
    namespace: arr-stack
  type: Opaque
  stringData:
    PROWLARR_API_KEY: SET_VIA_SCRIPT
    SONARR_API_KEY: SET_VIA_SCRIPT
    RADARR_API_KEY: SET_VIA_SCRIPT
    BAZARR_API_KEY: SET_VIA_SCRIPT
  ```
  Apply script (`scripts/apply-arr-secrets.sh`):
  ```bash
  #!/bin/bash
  KUBECTL="kubectl --kubeconfig ${HOME}/.kube/homelab.yaml"
  $KUBECTL apply -f - <<EOF
  apiVersion: v1
  kind: Secret
  metadata:
    name: arr-api-keys
    namespace: arr-stack
  type: Opaque
  stringData:
    PROWLARR_API_KEY: "$(op read 'op://Kubernetes/ARR Stack/prowlarr-api-key')"
    SONARR_API_KEY: "$(op read 'op://Kubernetes/ARR Stack/sonarr-api-key')"
    RADARR_API_KEY: "$(op read 'op://Kubernetes/ARR Stack/radarr-api-key')"
    BAZARR_API_KEY: "$(op read 'op://Kubernetes/ARR Stack/bazarr-api-key')"
  EOF
  ```

### 4.25.12 NetworkPolicy

- [x] 4.25.12.1 Create `manifests/arr-stack/networkpolicy.yaml` — CiliumNetworkPolicy for `arr-stack` namespace
  - Allow intra-namespace traffic (all *ARR apps talk to each other)
  - Allow egress to internet (download clients need external access)
  - Allow ingress via `fromEntities: ingress` (Gateway API traffic via Cilium Envoy in kube-system)
  - Allow ingress from `monitoring` namespace (Prometheus scraping, Phase 4.26)
  - Allow egress to NFS NAS (`10.10.30.4:2049`)
  - Allow egress to DNS (kube-dns)
  - Deny all other ingress by default

### 4.25.13 Documentation & Release

> Second commit: documentation updates and audit.

- [x] 4.25.13.1 Update `docs/todo/README.md` — add Phase 4.25 to phase index + namespace table
- [x] 4.25.13.2 Update `README.md` (root) — add ARR stack to services list
- [x] 4.25.13.3 Update `VERSIONS.md` — add all app versions + HTTPRoutes
- [x] 4.25.13.4 Update `docs/reference/CHANGELOG.md` — add architecture decisions (NFS hardlinks, storage split, app selection)
- [x] 4.25.13.5 Update `docs/context/Cluster.md` — add `arr-stack` namespace
- [x] 4.25.13.6 Update `docs/context/Gateway.md` — add 6 HTTPRoutes (Prowlarr, Sonarr, Radarr, qBittorrent, Jellyfin, Bazarr)
- [x] 4.25.13.7 Update `docs/context/Storage.md` — add NFS PV/PVC for media
- [x] 4.25.13.8 Update `docs/context/Secrets.md` — add 1Password items (`ARR Stack` with 7 fields, `Opensubtitles` with credentials)
- [x] 4.25.13.9 Update `docs/context/Networking.md` — add CiliumNetworkPolicy for `arr-stack` namespace
- [x] 4.25.13.10 Create `docs/rebuild/v0.23.0-arr-stack.md`
- [x] 4.25.13.11 `/audit-docs`
- [x] 4.25.13.12 `/commit`
- [x] 4.25.13.13 `/release v0.23.0 "ARR Media Stack"`
- [x] 4.25.13.14 Move this file to `docs/todo/completed/`

---

## Resource Budget

| App | CPU Request | CPU Limit | Memory Request | Memory Limit | Config PVC |
|-----|-------------|-----------|----------------|--------------|------------|
| Prowlarr | 50m | 250m | 128Mi | 256Mi | 2Gi |
| qBittorrent | 250m | 1000m | 256Mi | 1Gi | 2Gi |
| Sonarr | 100m | 500m | 256Mi | 512Mi | 2Gi |
| Radarr | 100m | 1000m | 256Mi | 1Gi | 2Gi |
| Jellyfin | 500m | 4000m | 512Mi | 2Gi | 5Gi |
| Bazarr | 50m | 250m | 128Mi | 256Mi | 2Gi |
| **Total** | **1050m** | **7000m** | **1.5Gi** | **5Gi** | **15Gi** |

Fits comfortably on your 3-node cluster (~6% of total memory).

---

## Files to Create

| File | Type | Purpose |
|------|------|---------|
| `manifests/arr-stack/namespace.yaml` | Namespace | Media namespace with PSS labels |
| `manifests/arr-stack/nfs-pv-pvc.yaml` | PV + PVC | Shared NFS volume for media + downloads |
| `manifests/arr-stack/prowlarr/deployment.yaml` | Deployment + PVC | Prowlarr workload + config |
| `manifests/arr-stack/prowlarr/service.yaml` | Service | ClusterIP |
| `manifests/arr-stack/prowlarr/httproute.yaml` | HTTPRoute | `prowlarr.k8s.rommelporras.com` |
| `manifests/arr-stack/qbittorrent/deployment.yaml` | Deployment + PVC | qBittorrent workload + config |
| `manifests/arr-stack/qbittorrent/service.yaml` | Service | ClusterIP |
| `manifests/arr-stack/qbittorrent/httproute.yaml` | HTTPRoute | `qbit.k8s.rommelporras.com` |
| `manifests/arr-stack/sonarr/deployment.yaml` | Deployment + PVC | Sonarr workload + config |
| `manifests/arr-stack/sonarr/service.yaml` | Service | ClusterIP |
| `manifests/arr-stack/sonarr/httproute.yaml` | HTTPRoute | `sonarr.k8s.rommelporras.com` |
| `manifests/arr-stack/radarr/deployment.yaml` | Deployment + PVC | Radarr workload + config |
| `manifests/arr-stack/radarr/service.yaml` | Service | ClusterIP |
| `manifests/arr-stack/radarr/httproute.yaml` | HTTPRoute | `radarr.k8s.rommelporras.com` |
| `manifests/arr-stack/jellyfin/deployment.yaml` | Deployment + PVC | Jellyfin workload + config |
| `manifests/arr-stack/jellyfin/service.yaml` | Service | ClusterIP |
| `manifests/arr-stack/jellyfin/httproute.yaml` | HTTPRoute | `jellyfin.k8s.rommelporras.com` |
| `manifests/arr-stack/bazarr/deployment.yaml` | Deployment + PVC | Bazarr workload + config |
| `manifests/arr-stack/bazarr/service.yaml` | Service | ClusterIP |
| `manifests/arr-stack/bazarr/httproute.yaml` | HTTPRoute | `bazarr.k8s.rommelporras.com` |
| `manifests/arr-stack/networkpolicy.yaml` | CiliumNetworkPolicy | Namespace network rules |

## Files to Modify

| File | Change |
|------|--------|
| `manifests/home/homepage/config/services.yaml` | Add all ARR apps + Jellyfin entries |

---

## Verification Checklist

- [x] All 6 pods running in `arr-stack` namespace
- [x] NFS PV/PVC bound and accessible from all pods
- [x] Prowlarr indexers configured and synced to Sonarr/Radarr
- [x] qBittorrent accessible and download paths set to `/data/torrents/`
- [x] Sonarr root folder set to `/data/media/series/`, connected to Prowlarr + qBittorrent
- [x] Radarr root folder set to `/data/media/movies/`, connected to Prowlarr + qBittorrent
- [x] Import workflow verified (download → import → cleanup, hardlinks N/A with seeding disabled)
- [x] Jellyfin library scan finds media
- [x] All HTTPRoutes accessible
- [x] Homepage entries functional (widgets showing data)
- [x] Uptime Kuma monitoring all endpoints (Media group, 403 accepted)

---

## Rollback

```bash
kubectl-homelab delete namespace arr-stack
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
| Container images (ARR) | LinuxServer.io | Consistent PUID/PGID, active maintenance, community standard |
| Container image (Jellyfin) | `jellyfin/jellyfin` (official) | Bundles jellyfin-ffmpeg with Intel iHD driver for QSV — LinuxServer image needs Docker Mod for QSV |
| Subtitles | Bazarr (in this phase, not Phase 4.26) | Day-one subtitle support. Providers: OpenSubtitles.com + Podnapisi |
| Seeding | Disabled (ratio limit 0) | NAS has single NVMe — preserve TBW. Stop torrent immediately after download |
| Namespace | `arr-stack` (not `media`) | `media` is too generic — Immich is also media |
| Folder naming | `series` (not `tv`) | Clearer — "series" implies multi-episode content |

---

## 1Password Structure

All ARR credentials stored in 1Password `Kubernetes` vault.

### Item: `ARR Stack`

Shared credentials for all ARR apps (same username/password across Prowlarr, Sonarr, Radarr, qBittorrent, Bazarr).

| Field | Purpose |
|-------|---------|
| `username` | Shared login username for all ARR app UIs |
| `password` | Shared login password for all ARR app UIs |
| `prowlarr-api-key` | Prowlarr API key (Settings > General) |
| `sonarr-api-key` | Sonarr API key (Settings > General) |
| `radarr-api-key` | Radarr API key (Settings > General) |
| `bazarr-api-key` | Bazarr API key (Settings > General > Security) |
| `jellyfin-api-key` | Jellyfin API key (Administration > API Keys, named `Homepage`) |

### Item: `Opensubtitles`

Separate item for OpenSubtitles.com account (used by Bazarr subtitle provider).

| Field | Purpose |
|-------|---------|
| `user[username]` | OpenSubtitles.com username |
| `user[password_confirmation]` | OpenSubtitles.com password |
| `* Email` | Account email |

### Homepage Secret Keys

These env vars are patched into the `homepage-secrets` Secret in `home` namespace:

| Secret Key | 1Password Reference |
|------------|-------------------|
| `HOMEPAGE_VAR_JELLYFIN_KEY` | `op://Kubernetes/ARR Stack/jellyfin-api-key` |
| `HOMEPAGE_VAR_SONARR_API_KEY` | `op://Kubernetes/ARR Stack/sonarr-api-key` |
| `HOMEPAGE_VAR_RADARR_API_KEY` | `op://Kubernetes/ARR Stack/radarr-api-key` |
| `HOMEPAGE_VAR_PROWLARR_API_KEY` | `op://Kubernetes/ARR Stack/prowlarr-api-key` |
| `HOMEPAGE_VAR_BAZARR_API_KEY` | `op://Kubernetes/ARR Stack/bazarr-api-key` |
| `HOMEPAGE_VAR_QBIT_USER` | `op://Kubernetes/ARR Stack/username` |
| `HOMEPAGE_VAR_QBIT_PASS` | `op://Kubernetes/ARR Stack/password` |

---

## Inter-App Communication (K8s Service DNS)

All apps communicate via K8s service DNS within the `arr-stack` namespace:

| From | To | URL |
|------|----|-----|
| Prowlarr | Sonarr | `http://sonarr.arr-stack.svc.cluster.local:8989` |
| Prowlarr | Radarr | `http://radarr.arr-stack.svc.cluster.local:7878` |
| Sonarr | qBittorrent | `http://qbittorrent.arr-stack.svc.cluster.local:8080` |
| Radarr | qBittorrent | `http://qbittorrent.arr-stack.svc.cluster.local:8080` |
| Bazarr | Sonarr | `http://sonarr.arr-stack.svc.cluster.local:8989` |
| Bazarr | Radarr | `http://radarr.arr-stack.svc.cluster.local:7878` |
| Sonarr | Jellyfin | `http://jellyfin.arr-stack.svc.cluster.local:8096` |
| Radarr | Jellyfin | `http://jellyfin.arr-stack.svc.cluster.local:8096` |

---

## Gotchas & Lessons Learned

| Issue | Root Cause | Fix |
|-------|-----------|-----|
| Sonarr/Radarr pinned image tags not found | LSIO uses `-lsNNN` tag suffixes, not upstream versions | Use `latest` with `imagePullPolicy: Always` |
| qBittorrent health probes return 403 | CSRF protection on HTTP API endpoints | Use `tcpSocket` probes instead of `httpGet` |
| Gateway can't reach pods (NetworkPolicy) | Cilium Envoy runs as DaemonSet in `kube-system`, not in `default` namespace | Use `fromEntities: ingress` (not `fromEndpoints` with service account selector) |
| qBittorrent saves to `/downloads` (doesn't exist) | Default Torrent Management Mode was `Manual` | Must set to `Automatic` for category folders to work |
| 1337x indexer blocked | Cloudflare DDoS bot protection blocks automated tools | Skip — would need FlareSolverr (dead project) |
| TheRARBG not in Prowlarr | Original RARBG shut down, community successor removed from Prowlarr | Skip — use other indexers |
| Radarr shows "Error" status during download | Radarr lost connection to qBittorrent after pod restart (IP changed) | Self-resolves on next check cycle. Can force reconnect via Settings > Download Clients > Test |
