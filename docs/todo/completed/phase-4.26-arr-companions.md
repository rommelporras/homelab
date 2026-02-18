# Phase 4.26: ARR Companions

> **Status:** Complete (v0.25.0)
> **Target:** v0.25.0
> **Prerequisite:** Phase 4.25b complete (ARR core stack + QSV transcoding running)
> **Priority:** Medium (automation, discovery, monitoring, and transcoding for media stack)
> **DevOps Topics:** CronJobs, Prometheus exporters, Grafana dashboards, GPU scheduling, network saturation monitoring
> **CKA Topics:** CronJob, Deployment, Service, ServiceMonitor, PrometheusRule, ConfigMap, PVC, NetworkPolicy, anti-affinity

> **Purpose:** Deploy companion apps for the *ARR stack — media requests & discovery (Seerr), quality profile sync (Configarr), archive extraction (Unpackerr), Prometheus monitoring (Scraparr), library transcoding (Tdarr), AI recommendations (Recommendarr), Cloudflare bypass (Byparr) — plus configure import lists in Radarr/Sonarr for automated content discovery.
>
> **Why:** The core stack (Phase 4.25) handles media management and Phase 4.25b added hardware transcoding. This phase adds the automation layer (set-and-forget maintenance), user-facing discovery (request & recommend), bulk transcoding (space savings + compatibility), and observability (know when something breaks, and whether your network is the bottleneck).

---

## Components

| App | Purpose | Type | Image |
|-----|---------|------|-------|
| **Seerr** | Media requests + discovery (replaces Jellyseerr/Overseerr) | Deployment | `ghcr.io/seerr-team/seerr:v3.0.1` |
| **Configarr** | TRaSH Guide quality profile sync | CronJob | `ghcr.io/raydak-labs/configarr:1.20.0` |
| **Unpackerr** | Extract RAR archives from downloads | Deployment | `ghcr.io/unpackerr/unpackerr:v0.14.5` |
| **Scraparr** | Prometheus metrics for all *ARR apps | Deployment | `ghcr.io/thecfu/scraparr:3.0.3` |
| **Tdarr** | Library transcoding (QSV hardware) | Deployment | `ghcr.io/haveagitgat/tdarr:2.58.02` |
| **Recommendarr** | AI-powered media recommendations | Deployment | `tannermiddleton/recommendarr:v1.4.4` |
| **Byparr** | Cloudflare bypass for Prowlarr indexers | Deployment | `ghcr.io/thephaseless/byparr:latest` |

### Why These (and Not Others)

| Considered | Verdict | Reason |
|------------|---------|--------|
| **Bazarr** | **Moved to Phase 4.25** | Deployed with core stack for day-one subtitles. |
| **Seerr** | **Deploy** | MIT license, 9.1k stars. Jellyseerr + Overseerr merged into Seerr (Feb 2026). Single app for media requests + TMDB discovery with Jellyfin auth. |
| **Configarr** | **Deploy** | Free TRaSH Guide sync as CronJob. Supports custom formats beyond TRaSH presets. |
| **Unpackerr** | **Deploy** | Many torrent releases are RAR-packed. Without this, Sonarr/Radarr can't import them. |
| **Scraparr** | **Deploy** | Single deployment monitors ALL *ARR apps. Better than Exportarr (which needs 1 deployment per app). |
| **Tdarr** | **Deploy** | QSV available on all nodes since Phase 4.25b. Bulk transcode existing library to save disk space + ensure compatibility. Internal node mode — no separate node pod needed. |
| **Recommendarr** | **Deploy** | AI recommendations via existing Ollama deployment (`ai` namespace). Connects to Jellyfin + Sonarr/Radarr for personalized suggestions. |
| Overseerr | **Skip (DEAD)** | Archived Feb 15, 2026. Merged into Seerr. |
| Jellyseerr | **Skip (DEAD)** | Merged into Seerr (Feb 2026). |
| Readarr | **Skip (DEAD)** | Archived Jun 2025. |
| Notifiarr | **Skip** | Paid service ($3-10/mo). Cloud-dependent. Replicable with native Discord webhooks (Sonarr/Radarr built-in) + Configarr (guide sync) + Prometheus/Grafana (monitoring). |
| Recyclarr | **Skip** | Configarr does the same thing + supports custom format creation beyond TRaSH presets. |
| Exportarr | **Skip** | Maintenance mode. Needs 5 separate deployments. Scraparr does it in 1. |
| Huntarr | **Defer** | Nice-to-have. Sonarr/Radarr built-in search covers most cases. |
| Maintainerr | **Defer** | Useful for auto-pruning but Plex-focused. Wait for Jellyfin support. |
| Sportarr | **Skip** | Alpha quality. Not production-ready. |
| Autobrr | **Skip** | Only for private tracker IRC racing. Overkill. |
| FlareSolverr | **Skip (DEAD)** | Dead project. Byparr (v2.1.0) is the active replacement. |
| **Byparr** | **Deploy** | Cloudflare bypass for Prowlarr indexers (1337x, TorrentGalaxy). Drop-in FlareSolverr replacement using Camoufox (Firefox). Unlocks best public indexers. |

---

## Target State

| App | Port | URL | Config PVC | NFS Mount |
|-----|------|-----|------------|-----------|
| Seerr | 5055 | `seerr.k8s.rommelporras.com` | 1Gi (`seerr-config`) | N/A |
| Configarr | N/A | N/A (CronJob, no web UI) | N/A | N/A |
| Unpackerr | N/A | N/A (daemon, no web UI) | N/A | `/data` (shared `arr-data` PVC) |
| Scraparr | 7100 | N/A (internal — metrics only) | N/A | N/A |
| Tdarr | 8265 (UI), 8266 (API) | `tdarr.k8s.rommelporras.com` | 5Gi (`tdarr-server`) + 2Gi (`tdarr-configs`) | `/media` (shared `arr-data` PVC, library source: `/media/media`) |
| Recommendarr | 3000 | `recommendarr.k8s.rommelporras.com` | 1Gi (`recommendarr-config`) | N/A |
| Byparr | 8191 | N/A (internal — Prowlarr proxy only) | N/A | N/A |

---

## Tasks

### 4.26.1 Deploy Seerr (Media Requests + Discovery)

- [x] 4.26.1.1 Verify image version — `ghcr.io/seerr-team/seerr:v3.0.1` (MIT, released Feb 14 2026)
- [x] 4.26.1.2 Create `manifests/arr-stack/seerr/deployment.yaml`
  - Image: `ghcr.io/seerr-team/seerr:v3.0.1`
  - Replicas: 1
  - Port: 5055
  - Longhorn PVC `seerr-config` (1Gi) mounted at `/app/config` (SQLite DB)
  - No NFS needed — talks to Sonarr/Radarr/Jellyfin via API only
  - Security: Pattern B (official image, not LSIO) — `runAsUser: 1000`, `runAsGroup: 1000`, `runAsNonRoot: true`
  - Resources: `cpu: 50m/250m`, `memory: 128Mi/256Mi`
  - Health: `httpGet /api/v1/status` port 5055
- [x] 4.26.1.3 Create `manifests/arr-stack/seerr/service.yaml` — ClusterIP (port 5055)
- [x] 4.26.1.4 Create `manifests/arr-stack/seerr/httproute.yaml` — `seerr.k8s.rommelporras.com`
- [x] 4.26.1.5 Apply and verify Seerr UI accessible
- [x] 4.26.1.6 Configure Seerr via UI:
  - Set Jellyfin as media server (auth source)
  - Add Sonarr connection (URL + API key, quality: WEB-1080p, Automatic Search: ON)
  - Add Radarr connection (URL + API key, quality: HD Bluray + WEB, Minimum Availability: Released, Automatic Search: ON)
  - Link TMDB for discovery/metadata
- [x] 4.26.1.7 Test request flow: search movie in Seerr → auto-approve → Radarr auto-search → Prowlarr finds release → qBittorrent downloads. Verified end-to-end with Bitsearch indexer returning 1080p BluRay release.

### 4.26.2 Deploy Configarr (TRaSH Guide Sync)

- [x] 4.26.2.1 Pin image — `ghcr.io/raydak-labs/configarr:1.20.0` (released Jan 10 2026, no `v` prefix on GHCR)
- [x] 4.26.2.2 Research Configarr config YAML format — uses `!env` tags for API key injection from K8s Secret env vars
- [x] 4.26.2.3 Create `manifests/arr-stack/configarr/cronjob.yaml` — CronJob
  - Schedule: `0 3 * * *` (daily at 3 AM — low-activity window)
  - Env: Sonarr/Radarr URLs + API keys from Secrets
  - Resource limits: `cpu: 100m/500m`, `memory: 128Mi/256Mi`
  - `restartPolicy: OnFailure`
- [x] 4.26.2.4 Create `manifests/arr-stack/configarr/configmap.yaml` — Configarr YAML config (TRaSH WEB-1080p for Sonarr, HD Bluray+Web for Radarr)
- [x] 4.26.2.5 Verify shared `arr-api-keys` Secret exists (created in Phase 4.25, task 4.25.9.5):
  ```bash
  kubectl-homelab get secret arr-api-keys -n arr-stack
  ```
  - Configarr references `SONARR_API_KEY` and `RADARR_API_KEY` from this shared secret
- [x] 4.26.2.6 Apply and trigger manual test run:
  ```bash
  kubectl-homelab create job --from=cronjob/configarr configarr-test -n arr-stack
  kubectl-homelab logs -n arr-stack job/configarr-test
  ```
- [x] 4.26.2.7 Verify quality profiles updated in Sonarr/Radarr UI

### 4.26.3 Deploy Unpackerr (Archive Extraction)

- [x] 4.26.3.1 Pin image — `ghcr.io/unpackerr/unpackerr:v0.14.5` (released Jul 31 2024)
- [x] 4.26.3.2 Create `manifests/arr-stack/unpackerr/deployment.yaml`
  - NFS PVC mounted at `/data` (needs access to `/data/torrents/` for extraction)
  - No Longhorn PVC needed (stateless daemon)
  - Env: Sonarr/Radarr URLs + API keys from shared `arr-api-keys` Secret (Phase 4.25)
  - Resource limits: `cpu: 50m/500m`, `memory: 64Mi/256Mi`
  - No web UI, no Service, no HTTPRoute
- [x] 4.26.3.3 Security context — Unpackerr is official Go binary (not LSIO), uses Pattern B: `runAsNonRoot: true`, no cap adds needed
- [x] 4.26.3.4 Apply and verify — check logs for successful connection to Sonarr/Radarr

### 4.26.4 Deploy Scraparr (Prometheus Metrics)

- [x] 4.26.4.1 Pin image — `ghcr.io/thecfu/scraparr:3.0.3` (released Feb 12 2026, no `v` prefix on GHCR)
- [x] 4.26.4.2 Create `manifests/arr-stack/scraparr/deployment.yaml`
  - No PVC needed (stateless)
  - Env: connection details for all *ARR apps (URLs + API keys from shared `arr-api-keys` Secret)
  - Resource limits: `cpu: 50m/250m`, `memory: 64Mi/128Mi`
  - Port: 7100 (`/metrics`)
- [x] 4.26.4.3 Create `manifests/arr-stack/scraparr/service.yaml` — ClusterIP (port 7100)
- [x] 4.26.4.4 Create `manifests/arr-stack/scraparr/servicemonitor.yaml` — ServiceMonitor for Prometheus
  - `interval: 5m` (no point scraping faster than *ARR app refresh cycles)
- [x] 4.26.4.5 Apply and verify: `up{job="scraparr"} == 1` in Prometheus
- [x] 4.26.4.6 Verify *ARR metrics appear: `sonarr_*`, `radarr_*`, `prowlarr_*`

### 4.26.5 Deploy Tdarr (Library Transcoding)

- [x] 4.26.5.1 Verify image version — `ghcr.io/haveagitgat/tdarr:2.58.02` (server with internal node)
- [x] 4.26.5.2 Add `tdarr-api-key` field to existing `ARR Stack` item in `Kubernetes` 1Password vault
- [x] 4.26.5.3 Create `manifests/arr-stack/tdarr/deployment.yaml`
  - Image: `ghcr.io/haveagitgat/tdarr:2.58.02`
  - Replicas: 1
  - Ports: 8265 (WebUI), 8266 (Server API)
  - Storage:
    - Longhorn PVC `tdarr-server` (5Gi) at `/app/server` (embedded DB)
    - Longhorn PVC `tdarr-configs` (2Gi) at `/app/configs` + `/app/logs`
    - NFS PVC `arr-data` mounted at `/media` (same path pattern, read/write for in-place transcode)
    - `emptyDir` at `/temp` (transcode cache, disk-backed on NVMe)
  - GPU: `gpu.intel.com/i915: "1"` + `supplementalGroups: [44, 993]` (same as Jellyfin)
  - Security: PUID/PGID env vars (Pattern A style), `fsGroup: 1000`
  - Resources: `cpu: 500m/2000m`, `memory: 512Mi/2Gi`
  - Health: `httpGet /api/v2/status` port 8266
  - Key env: `internalNode=true`, `inContainer=true`, `ffmpegVersion=7`, `auth=true`, `seededApiKey` from 1Password (`op://Kubernetes/ARR Stack/tdarr-api-key`)
  - Anti-affinity: soft anti-affinity against Jellyfin to reduce GPU contention
- [x] 4.26.5.4 Create `manifests/arr-stack/tdarr/service.yaml` — ClusterIP (ports 8265, 8266)
- [x] 4.26.5.5 Create `manifests/arr-stack/tdarr/httproute.yaml` — `tdarr.k8s.rommelporras.com`
- [x] 4.26.5.6 Apply and verify:
  - Tdarr web UI accessible at `tdarr.k8s.rommelporras.com`
  - Internal node shows as connected in web UI
  - QSV hardware detected (check Tdarr node info for GPU)
- [x] 4.26.5.7 Configure Tdarr via UI:
  - Created "Media" library — source: `/media/media` (NFS mounts at `/media`, actual media at `media/` subdir), transcode cache: `/temp`, output: `/media/media` (in-place)
  - Folder Watch: OFF (NFS doesn't support inotify), Scan on Start: ON, Run hourly Scan: ON
  - Classic Plugin Stack: Migz Remove Image Formats → Lmg1 Reorder Streams → Boosh-Transcode Using QSV GPU & FFMPEG (hevc_qsv, mkv, target_bitrate_modifier 0.8, slow preset, reconvert_hevc=false) → New File Size Check
  - Removed default CPU + Nvidia GPU transcode plugins
  - Schedule: 2AM-8AM daily (off-hours to reduce GPU contention with Jellyfin)
  - Health Check: Thorough (FFmpeg frame-by-frame, works with GPU workers)
  - InternalNode: Transcode GPU=1, Health Check GPU=1, CPU workers=0 (QSV only)
  - Auto accept successful transcodes: enabled
  - Note: 3 nodes each have QSV GPU — can add external Tdarr Node deployments later if nightly window isn't enough
- [x] 4.26.5.8 Test transcode: initial test at 0.6 bitrate modifier looked poor on 1440p monitor — changed to 0.8. Re-queued both files. Jellyfin hourly scheduled scan picks up transcoded files (no Tdarr Jellyfin notify plugin exists — only Plex plugins available).

### 4.26.6 Deploy Recommendarr (AI Recommendations)

- [x] 4.26.6.1 Pin image — `tannermiddleton/recommendarr:v1.4.4` (released Apr 13 2025, repo: TannerMidd/recommendarr)
- [x] 4.26.6.2 Create `manifests/arr-stack/recommendarr/deployment.yaml`
  - Image: `tannermiddleton/recommendarr:v1.4.4`
  - Replicas: 1
  - Port: 3000
  - Longhorn PVC `recommendarr-config` (1Gi) for persistent config
  - No NFS needed — reads from Sonarr/Radarr/Jellyfin APIs + Ollama API
  - Security: Pattern B (non-root), `runAsUser: 1000`, `runAsGroup: 1000`
  - Resources: `cpu: 50m/250m`, `memory: 64Mi/256Mi`
  - Integration: Ollama at `http://ollama.ai.svc.cluster.local:11434`
  - Default login: `admin` / `1234` (change on first setup)
- [x] 4.26.6.3 Create `manifests/arr-stack/recommendarr/service.yaml` — ClusterIP (port 3000)
- [x] 4.26.6.4 Create `manifests/arr-stack/recommendarr/httproute.yaml` — `recommendarr.k8s.rommelporras.com`
- [x] 4.26.6.5 Apply and verify Recommendarr UI accessible
- [x] 4.26.6.6 Configure Recommendarr via UI:
  - Connected Jellyfin (`http://jellyfin.arr-stack.svc:8096`) — watch history source
  - Connected Sonarr (`http://sonarr.arr-stack.svc:8989`) + Radarr (`http://radarr.arr-stack.svc:7878`)
  - Set Ollama endpoint: `http://ollama.ai.svc.cluster.local:11434/v1` (OpenAI-compatible format)
  - Selected model: `qwen2.5:3b` (best balance of capability/speed among loaded models)
  - Fixed: Ollama ingress policy (`manifests/ai/networkpolicy.yaml`) was missing `arr-stack` namespace — added
  - Fixed: PVC mount path was `/app/config` but app writes to `/app/server/data` — corrected in deployment
  - Changed default admin password
- [x] 4.26.6.7 Test: verify recommendations generate based on existing Jellyfin library — TV shows and movies both generate 10 recommendations via qwen2.5:3b (CPU inference ~4 cores, ~2min per batch). "Add" button sends to Sonarr/Radarr.

### 4.26.7 Configure Import Lists (UI-Only — No Manifests)

> Configure Radarr/Sonarr built-in import lists + MDBList for automated content discovery. Do this after Seerr is deployed to avoid duplicate request handling.

- [x] 4.26.7.1 **Radarr import lists** (Settings > Lists):
  - Added TMDB Popular (min vote avg 6, min votes 100, quality: HD Bluray + WEB, search on add: off)
  - Added Trakt Popular (rating 60-100, limit 25, quality: HD Bluray + WEB, search on add: off, OAuth authenticated)
  - Note: TMDB Upcoming not available as list type — only Company, Keyword, List, Person, Popular, User
  - Note: Trakt only offers List, Popular List, User — no Trending/Anticipated for movies in Radarr
- [x] 4.26.7.2 **Sonarr import lists** (Settings > Import Lists):
  - Added Trakt Popular Shows (rating 60-100, limit 25, quality: WEB-1080p, monitor: First Season, search on add: off, OAuth authenticated)
  - Added AniList (import: Watching + Planning + Finished, quality: WEB-1080p, series type: Anime, monitor: First Season)
- [x] 4.26.7.3 **MDBList integration** — Skipped. MDBList filters by streaming subscriptions (Netflix, Disney+, Amazon). User cancelled all streaming services in favor of ARR stack. TMDB Popular + Trakt Popular + AniList import lists provide sufficient discovery.
- [x] 4.26.7.4 Verify import lists showing in Radarr/Sonarr and auto-adding content — confirmed new movies and series appearing from TMDB Popular, Trakt Popular, and AniList

### 4.26.8 Update NetworkPolicy

> The existing egress policy (`manifests/arr-stack/networkpolicy.yaml`) blocks all RFC1918 traffic except NFS at `10.10.30.4:2049`. Recommendarr needs to reach Ollama in the `ai` namespace on port 11434.

- [x] 4.26.8.1 Add egress rule to `manifests/arr-stack/networkpolicy.yaml` allowing traffic to `ai` namespace + add ingress rule to `manifests/ai/networkpolicy.yaml` allowing `arr-stack` namespace (both sides needed):
  ```yaml
  # Ollama access for Recommendarr (AI recommendations)
  - toEndpoints:
      - matchLabels:
          k8s:io.kubernetes.pod.namespace: ai
    toPorts:
      - ports:
          - port: "11434"
            protocol: TCP
  ```
- [x] 4.26.8.2 Apply and verify Recommendarr can reach Ollama:
  ```bash
  kubectl-homelab apply -f manifests/arr-stack/networkpolicy.yaml
  # Verify from Recommendarr pod:
  kubectl-homelab exec -n arr-stack deploy/recommendarr -- wget -qO- http://ollama.ai.svc.cluster.local:11434/api/version
  ```

### 4.26.8b Deploy Byparr (Cloudflare Bypass for Prowlarr)

> Drop-in FlareSolverr replacement using Camoufox (hardened Firefox). Unlocks Cloudflare-protected indexers (1337x, TorrentGalaxy) for Prowlarr. Stateless — no persistent storage needed.

- [x] 4.26.8b.1 Create `manifests/arr-stack/byparr/deployment.yaml`
  - Image: `ghcr.io/thephaseless/byparr:latest` (v2.1.0, no semver tags on GHCR)
  - Replicas: 1
  - Port: 8191
  - No PVC needed (stateless — cookies returned per-request, not cached)
  - Security: Pattern B — `runAsUser: 1000`, `runAsGroup: 1000`, `runAsNonRoot: true` (uses Camoufox/Firefox, no SYS_ADMIN needed unlike Chromium-based FlareSolverr)
  - Resources: `cpu: 500m/2000m`, `memory: 512Mi/4Gi` (browser sessions ~200-500MB each, OOMKilled at 2Gi — needs 4Gi)
  - Health: `httpGet /health` port 8191, `timeoutSeconds: 10` (default 1s too short for browser init)
  - Env: `TZ=Asia/Manila`, `LOG_LEVEL=INFO`
  - No HTTPRoute needed (internal Prowlarr proxy only, no user-facing UI)
- [x] 4.26.8b.2 Create `manifests/arr-stack/byparr/service.yaml` — ClusterIP (port 8191)
- [x] 4.26.8b.3 Apply and verify health endpoint — `{"msg":"Byparr is working!","version":"2.1.0"}`
- [x] 4.26.8b.4 Configure Prowlarr FlareSolverr proxy:
  - Settings > Indexers > Add > FlareSolverr
  - Host: `http://byparr.arr-stack.svc:8191`
  - Request Timeout: 60 seconds
  - Tag: `flaresolverr`
- [x] 4.26.8b.5 Add Cloudflare-protected indexers in Prowlarr:
  - 1337x (tag: `flaresolverr`) — added successfully, best general-purpose public indexer
  - TorrentGalaxy — skipped, redirect issue even with Byparr
  - Current indexers: EZTV (TV), Nyaa.si (anime), YTS (movies), Bitsearch (general), 1337x (general + flaresolverr)
- [x] 4.26.8b.6 Verified: RSS sync with 1337x found 237 releases (vs 217 before), auto-grabbed Tron Ares and Muzzle as 1080p BluRay from 1337x. Madame Web also auto-downloaded from Bitsearch. Radarr Minimum CF Score kept at -10000 (YTS as fallback — auto-upgrades to better release when available via Upgrade Until CF Score: 10000).

### 4.26.9 Build Grafana Dashboards

> Note: `arr-stack-dashboard-configmap.yaml` and `jellyfin-dashboard-configmap.yaml` already exist from Phase 4.25/4.25b. The Scraparr dashboard below is a NEW dashboard. The existing ARR Stack dashboard was updated to add companion app Pod Status panels (Seerr, Tdarr, Unpackerr, Scraparr, Recommendarr, Configarr) and include all companion containers in CPU/Memory/Restart queries.

#### Scraparr ARR Metrics Dashboard

- [x] 4.26.9.1 Import Scraparr dashboard [#22934](https://grafana.com/grafana/dashboards/22934) as starting point
- [x] 4.26.9.2 Customize with panels for:
  - Queue size and download rates per app
  - Library size (movies, episodes, artists)
  - Missing content count
  - Health check status per app
  - Recent imports
- [x] 4.26.9.3 Create `manifests/monitoring/scraparr-dashboard-configmap.yaml` (sidecar label `grafana_dashboard: "1"`)

#### Network Throughput Dashboard (1GbE vs 2.5GbE Decision)

- [x] 4.26.9.4 Create network saturation dashboard with panels:

| Panel | Type | PromQL |
|-------|------|--------|
| NIC Utilization % | Gauge | `(rate(node_network_receive_bytes_total{device!~"lo\|cni.*\|veth.*\|cilium.*"}[5m]) + rate(node_network_transmit_bytes_total{...}[5m])) / node_network_speed_bytes{...} * 100` |
| Throughput (Mbps) | Timeseries | `(rate(node_network_receive_bytes_total{...}[5m]) + rate(node_network_transmit_bytes_total{...}[5m])) * 8 / 1000000` |
| RX vs TX per Node | Timeseries (stacked) | `rate(node_network_receive_bytes_total{...}[5m]) * 8 / 1000000` (separate for RX/TX) |
| Peak Utilization (24h) | Stat | `max_over_time(...)` |
| Time Above 80% (24h) | Stat | `count_over_time((nic_utilization > 80)[24h:5m])` (subquery syntax) |
| NAS Traffic (to/from 10.10.30.4) | Timeseries | Filter by destination if available via Cilium Hubble |

- [x] 4.26.9.5 Verify `node_network_speed_bytes` metric exists in Prometheus — confirmed: `eno1` reports 125000000 (1 Gbps) on all 3 nodes. No hardcoding needed.
- [x] 4.26.9.6 Create `manifests/monitoring/network-dashboard-configmap.yaml`
- [x] 4.26.9.7 NFS speed investigation — no bottleneck found. Superman 4K (2160p WEBRip) downloaded via qBittorrent to NFS in ~2 minutes. Previous slow speeds (Phase 4.25) were likely torrent seeder availability, not NFS or 1GbE. No NIC upgrade needed.

### 4.26.10 Alert Rules

- [x] 4.26.10.1 Create `manifests/monitoring/arr-alerts.yaml` (PrometheusRule):

| Alert | Expression | Severity | Notes |
|-------|-----------|----------|-------|
| `ArrAppDown` | `up{job="scraparr"} == 0` for 5m | critical | Scraparr exporter unreachable |
| `SonarrQueueStalled` | Sonarr queue items stuck > 2h | warning | Downloads may be stuck |
| `RadarrQueueStalled` | Radarr queue items stuck > 2h | warning | Downloads may be stuck |
| `NetworkInterfaceSaturated` | NIC utilization > 80% for 10m | warning | Consider 2.5GbE upgrade |
| `NetworkInterfaceCritical` | NIC utilization > 95% for 5m | critical | Network bottleneck active |
| `JellyfinDown` | Jellyfin health check fails for 5m | critical | Media server unreachable |

### 4.26.11 Integration

- [x] 4.26.11.1 ~~Configure Discord webhooks~~ → Moved to 4.26.11.5 (dedicated Discord channel)
- [x] 4.26.11.2 Create user accounts for girlfriend (Tailscale network access):
  - Jellyfin: Created "Diane" user — media playback + transcoding enabled, admin/deletion/downloads disabled, visible on login screen
  - Seerr: Jellyfin auth auto-sync — verified login works, set Auto-Approve Movies + Series permissions
  - Tested: Diane requested Superman (2025) → auto-approved → Radarr auto-searched → grabbed 2160p WEBRip from YTS (digital release July 2025)
- [x] 4.26.11.2b Prowlarr indexer improvements + Radarr/Sonarr quality tuning:
  - Prowlarr: Added Bitsearch (general, no Cloudflare) + 1337x (general, via Byparr Cloudflare bypass). TorrentGalaxy skipped (redirect issue even with Byparr).
  - Current indexers: EZTV (TV), Nyaa.si (anime), YTS (movies), Bitsearch (general), 1337x (general + flaresolverr tag)
  - Radarr: Minimum Custom Format Score set to -10000 (YTS as fallback with score -10000; proper BluRay/WEB-DL from 1337x/Bitsearch score higher and are preferred; auto-upgrades via Upgrade Until CF Score: 10000)
  - Sonarr: Minimum Custom Format Score set to -10000 (same fix — TRaSH `x265 (HD)` CF scores -10000 and most anime on Nyaa.si is x265 encoded, which is ideal for anime content)
  - qBittorrent: Configured torrent queueing (max 5 active downloads, 10 active torrents), slow torrent thresholds (10 KiB/s, 600s inactivity), seeding limits (ratio 0, 1440 min, auto-remove torrent)
  - Tested end-to-end: Seerr request → auto-approve → Radarr/Sonarr auto-search → 1337x/Bitsearch/Nyaa.si find releases → qBittorrent downloads automatically
  - Anime test: Frieren Season 1 (28 episodes) — requested via Seerr, auto-approved, Sonarr grabbed DSNP/AMZN/CR WEB-DL releases from Nyaa.si, 19/28 imported (remaining 9 downloading)
- [x] 4.26.11.3 Add Homepage widgets + full layout redesign (kustomize — `manifests/home/homepage/`):
  - Added: Seerr (overseerr widget + API key), Tdarr (tdarr widget), Recommendarr (bookmark + status dot)
  - Redesigned layout: 2-tab design — **Dashboard** (Media, Media Tools, Apps, Health) + **Infrastructure** (Compute, Network, Storage, Proxmox, K8s)
  - Media is now row 1 on Dashboard tab — no scrolling needed on 1440p
  - Split Media into core (Jellyfin, Seerr, Sonarr, Radarr, qBit — 5 cols) + tools (Bazarr, Prowlarr, Tdarr, Recommendarr — 4 cols)
  - Moved Compute/Network/Storage from main tab to Infrastructure tab
  - Added `HOMEPAGE_VAR_SEERR_API_KEY` to homepage-secrets (patched via kubectl)
  - Note: Configarr (CronJob), Unpackerr (daemon), Scraparr (metrics-only) have no web UI — skip widgets
- [x] 4.26.11.4 Sonarr/Radarr calendar integration:
  - Added Homepage `calendar` service widget to `services.yaml` — agenda view (compact list, max 7 events) in dedicated Calendar row
  - Uses `service_group: Media` + `service_name: Sonarr/Radarr` to reuse existing API keys (no extra secrets)
  - Events are clickable links to Sonarr/Radarr via `baseUrl` parameter
  - Timezone: `Asia/Manila`, first day: Sunday
  - Note: Calendar is a service widget (not info widget) — goes in `services.yaml`, not `widgets.yaml`
  - Note: Sonarr/Radarr also expose iCal feeds (`/feed/v3/calendar/Sonarr.ics?apikey=KEY`) for optional Google Calendar/phone sync
- [x] 4.26.11.5 Create dedicated Discord channel for ARR notifications:
  - Created `#arr` channel under Notification group in Discord (alongside `#incidents` and `#status`)
  - Webhook URL saved to 1Password (`op://Kubernetes/ARR Stack/discord-webhook-url`)
  - Sonarr: Discord connection configured — On Grab, File Import, File Upgrade, Import Complete, Health Issue, Health Restored, Manual Interaction Required
  - Radarr: Discord connection configured — same triggers as Sonarr
  - Disabled noisy triggers: Rename, Series Add/Delete, Episode File Delete, Health Warnings, Application Update

### 4.26.12 Harden NFS Mounts

> After all companion apps are deployed and verified working, lock down NFS access.

- [x] 4.26.12.1 Set Jellyfin NFS volume mount to `readOnly: true` — only reads from `/data/media/`, never writes
- [x] 4.26.12.2 Verify Jellyfin still plays media after read-only change — confirmed, Frieren plays fine
- [x] 4.26.12.3 Verify Bazarr can still write `.srt` files next to media — Bazarr has its own RW NFS mount, unaffected by Jellyfin's readOnly change. Bazarr healthy and connected to Sonarr/Radarr SignalR feeds.
- [x] 4.26.12.4 Review all NFS volume mounts in `arr-stack` namespace:

| App | NFS Access | Reason |
|-----|-----------|--------|
| qBittorrent | Read-Write | Writes downloads to `/data/torrents/` |
| Sonarr | Read-Write | Creates hardlinks `torrents/` → `media/` |
| Radarr | Read-Write | Creates hardlinks `torrents/` → `media/` |
| Jellyfin | **Read-Only** | Only reads from `/data/media/` |
| Bazarr | Read-Write | Writes subtitle `.srt` files next to media |
| Unpackerr | Read-Write | Extracts RAR archives in `/data/torrents/` |
| Tdarr | Read-Write | In-place transcoding of media files |

### 4.26.13 Documentation & Release

> Second commit: documentation updates and audit.

- [x] 4.26.13.1 Update `docs/todo/README.md` — added Phase 4.28 to release mapping + phase index, updated arr-stack namespace description with companion apps
- [x] 4.26.13.2 Update `README.md` (root) — added ARR Companions line to services list, updated Next Steps
- [x] 4.26.13.3 Update `VERSIONS.md` — added all 7 companion app versions + 3 new HTTPRoutes
- [x] 4.26.13.4 Update `docs/reference/CHANGELOG.md` — added Phase 4.26 entry with key decisions, integration highlights, dashboards, files added/modified
- [x] 4.26.13.5 Update `docs/context/Monitoring.md` — added Scraparr dashboard, network dashboard, ARR alerts to config files table
- [x] 4.26.13.6 Update `docs/context/Gateway.md` — added Seerr, Tdarr, Recommendarr HTTPRoutes to exposed services table
- [x] 4.26.13.7 Update `docs/context/Secrets.md` — added tdarr-api-key + discord-webhook-url to ARR Stack item, seerr-api-key to Homepage paths
- [x] 4.26.13.8 Create `docs/rebuild/v0.25.0-arr-companions.md` — 14-step rebuild guide
- [x] 4.26.13.9 `/audit-docs` — fixed 10 doc issues (dates, descriptions, rebuild README) + 9 rebuild guide issues (order, TZ, indexers, CF scores, qBit settings, Tdarr details, user accounts)
- [ ] 4.26.13.10 `/commit`
- [ ] 4.26.13.11 `/release v0.25.0 "ARR Companions"`
- [ ] 4.26.13.12 Move this file to `docs/todo/completed/`

---

## Resource Budget

| App | CPU Req | CPU Limit | Mem Req | Mem Limit | PVC |
|-----|---------|-----------|---------|-----------|-----|
| Seerr | 50m | 250m | 128Mi | 256Mi | 1Gi |
| Configarr | 100m | 500m | 128Mi | 256Mi | N/A |
| Unpackerr | 50m | 500m | 64Mi | 256Mi | N/A |
| Scraparr | 50m | 250m | 64Mi | 128Mi | N/A |
| Tdarr | 500m | 2000m | 512Mi | 2Gi | 7Gi |
| Recommendarr | 50m | 250m | 64Mi | 256Mi | 1Gi |
| Byparr | 500m | 2000m | 512Mi | 4Gi | N/A |
| **Total** | **1300m** | **5750m** | **1472Mi** | **7296Mi** | **9Gi** |

Combined with Phase 4.25/4.25b totals — still well within cluster capacity.

---

## Deployment Order

Recommended order (dependencies flow downward):

1. **Seerr** — needs Sonarr/Radarr/Jellyfin running (already deployed)
2. **Configarr** — needs Sonarr/Radarr API keys
3. **Unpackerr** — needs Sonarr/Radarr API keys + NFS
4. **Scraparr** — needs all *ARR apps running for metrics
5. **Tdarr** — needs NFS + GPU (heaviest, deploy last among apps)
6. **Recommendarr** — needs Jellyfin + Ollama (independent)
7. **Byparr** — Cloudflare bypass for Prowlarr (independent)
8. **Import list config** — UI-only, do after Seerr to avoid duplicate requests
9. **NetworkPolicy update** — required for Recommendarr → Ollama
10. **Grafana dashboards + alerts**
11. **NFS hardening**
12. **Documentation + release**

---

## Files to Create

| File | Type | Purpose |
|------|------|---------|
| `manifests/arr-stack/seerr/deployment.yaml` | Deployment | Media requests + discovery |
| `manifests/arr-stack/seerr/service.yaml` | Service | ClusterIP (port 5055) |
| `manifests/arr-stack/seerr/httproute.yaml` | HTTPRoute | `seerr.k8s.rommelporras.com` |
| `manifests/arr-stack/configarr/cronjob.yaml` | CronJob | TRaSH Guide sync (daily) |
| `manifests/arr-stack/configarr/configmap.yaml` | ConfigMap | Configarr YAML config |
| `manifests/arr-stack/unpackerr/deployment.yaml` | Deployment | Archive extraction daemon |
| `manifests/arr-stack/scraparr/deployment.yaml` | Deployment | Prometheus exporter |
| `manifests/arr-stack/scraparr/service.yaml` | Service | ClusterIP (port 7100) |
| `manifests/arr-stack/scraparr/servicemonitor.yaml` | ServiceMonitor | Prometheus scrape config |
| `manifests/arr-stack/tdarr/deployment.yaml` | Deployment | Library transcoding server + node |
| `manifests/arr-stack/tdarr/service.yaml` | Service | ClusterIP (ports 8265, 8266) |
| `manifests/arr-stack/tdarr/httproute.yaml` | HTTPRoute | `tdarr.k8s.rommelporras.com` |
| `manifests/arr-stack/recommendarr/deployment.yaml` | Deployment | AI recommendation engine |
| `manifests/arr-stack/recommendarr/service.yaml` | Service | ClusterIP (port 3000) |
| `manifests/arr-stack/recommendarr/httproute.yaml` | HTTPRoute | `recommendarr.k8s.rommelporras.com` |
| `manifests/monitoring/scraparr-dashboard-configmap.yaml` | ConfigMap | Scraparr Grafana dashboard JSON |
| `manifests/monitoring/network-dashboard-configmap.yaml` | ConfigMap | Network throughput dashboard JSON |
| `manifests/arr-stack/byparr/deployment.yaml` | Deployment | Cloudflare bypass proxy |
| `manifests/arr-stack/byparr/service.yaml` | Service | ClusterIP (port 8191) |
| `manifests/monitoring/arr-alerts.yaml` | PrometheusRule | Alert rules |

### Files to Modify

| File | Change |
|------|--------|
| `manifests/arr-stack/networkpolicy.yaml` | Add egress rule for `ai` namespace (Ollama port 11434) |
| `manifests/ai/networkpolicy.yaml` | Add ingress rule from `arr-stack` namespace (Ollama port 11434) |
| `manifests/arr-stack/arr-api-keys-secret.yaml` | Add TDARR_API_KEY field |
| `scripts/apply-arr-secrets.sh` | Add tdarr-api-key to op read + kubectl create |
| `manifests/arr-stack/jellyfin/deployment.yaml` | NFS volumeMount → readOnly: true |
| `manifests/monitoring/arr-stack-dashboard-configmap.yaml` | Add companion pod status panels |
| `manifests/home/homepage/config/services.yaml` | Add Seerr, Tdarr, Recommendarr widgets |
| `manifests/home/homepage/secret.yaml` | Add SEERR_API_KEY field |

---

## Verification Checklist

- [x] Seerr UI accessible at `seerr.k8s.rommelporras.com`
- [x] Seerr Jellyfin auth working, request flow to Sonarr/Radarr verified (auto-approve + auto-search)
- [x] Configarr CronJob ran successfully — quality profiles synced (HD Bluray + WEB, WEB-1080p)
- [x] Unpackerr running, connected to Sonarr + Radarr (check logs)
- [x] Scraparr exposing metrics (`up{job="scraparr"} == 1`)
- [x] Tdarr web UI accessible at `tdarr.k8s.rommelporras.com`
- [x] Tdarr internal node connected, test QSV transcode succeeds (0.8 bitrate modifier)
- [x] Recommendarr UI accessible at `recommendarr.k8s.rommelporras.com`
- [x] Recommendarr Ollama connection verified, recommendations generating (qwen2.5:3b)
- [x] Import lists showing in Radarr/Sonarr, auto-adding content (TMDB Popular, Trakt Popular, AniList)
- [x] Grafana Scraparr dashboard rendering with real data
- [x] Network throughput dashboard showing NIC utilization
- [x] Alert rules loaded in Alertmanager
- [x] Discord notifications working from Sonarr/Radarr native webhooks (`#arr` channel)
- [x] NetworkPolicy updated — Recommendarr can reach Ollama
- [x] GF account (Diane) — Jellyfin + Seerr access verified
- [x] NFS speed — no bottleneck, 4K downloads in ~2 minutes
- [x] Byparr healthy, Prowlarr FlareSolverr proxy configured, 1337x working via Byparr

---

## Rollback

```bash
# Companions only — core ARR stack (Phase 4.25/4.25b) stays
kubectl-homelab delete -f manifests/arr-stack/seerr/
kubectl-homelab delete -f manifests/arr-stack/configarr/
kubectl-homelab delete -f manifests/arr-stack/unpackerr/
kubectl-homelab delete -f manifests/arr-stack/scraparr/
kubectl-homelab delete -f manifests/arr-stack/tdarr/
kubectl-homelab delete -f manifests/arr-stack/recommendarr/
kubectl-homelab delete -f manifests/arr-stack/byparr/
kubectl-homelab delete -f manifests/monitoring/scraparr-dashboard-configmap.yaml
kubectl-homelab delete -f manifests/monitoring/network-dashboard-configmap.yaml
kubectl-homelab delete -f manifests/monitoring/arr-alerts.yaml
# Revert networkpolicy.yaml changes (git checkout)
git checkout -- manifests/arr-stack/networkpolicy.yaml
kubectl-homelab apply -f manifests/arr-stack/networkpolicy.yaml
```
