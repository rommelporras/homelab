# Phase 4.26: ARR Companions

> **Status:** Planned
> **Target:** v0.25.0
> **Prerequisite:** Phase 4.25b complete (ARR core stack + QSV transcoding running)
> **Priority:** Medium (automation, discovery, monitoring, and transcoding for media stack)
> **DevOps Topics:** CronJobs, Prometheus exporters, Grafana dashboards, GPU scheduling, network saturation monitoring
> **CKA Topics:** CronJob, Deployment, Service, ServiceMonitor, PrometheusRule, ConfigMap, PVC, NetworkPolicy, anti-affinity

> **Purpose:** Deploy companion apps for the *ARR stack — media requests & discovery (Seerr), quality profile sync (Configarr), archive extraction (Unpackerr), Prometheus monitoring (Scraparr), library transcoding (Tdarr), AI recommendations (Recommendarr) — plus configure import lists in Radarr/Sonarr for automated content discovery.
>
> **Why:** The core stack (Phase 4.25) handles media management and Phase 4.25b added hardware transcoding. This phase adds the automation layer (set-and-forget maintenance), user-facing discovery (request & recommend), bulk transcoding (space savings + compatibility), and observability (know when something breaks, and whether your network is the bottleneck).

---

## Components

| App | Purpose | Type | Image |
|-----|---------|------|-------|
| **Seerr** | Media requests + discovery (replaces Jellyseerr/Overseerr) | Deployment | `ghcr.io/seerr-team/seerr:v3.0.1` |
| **Configarr** | TRaSH Guide quality profile sync | CronJob | `ghcr.io/raydak-labs/configarr` (pin at deploy) |
| **Unpackerr** | Extract RAR archives from downloads | Deployment | `ghcr.io/unpackerr/unpackerr` (pin at deploy) |
| **Scraparr** | Prometheus metrics for all *ARR apps | Deployment | `ghcr.io/thecfu/scraparr` (pin at deploy) |
| **Tdarr** | Library transcoding (QSV hardware) | Deployment | `ghcr.io/haveagitgat/tdarr:2.58.02` |
| **Recommendarr** | AI-powered media recommendations | Deployment | `tannermiddleton/recommendarr:latest` (pin at deploy) |

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
| FlareSolverr | **Skip (DEAD)** | Dead project. Byparr (v2.1.0) is the replacement if needed. |

---

## Target State

| App | Port | URL | Config PVC | NFS Mount |
|-----|------|-----|------------|-----------|
| Seerr | 5055 | `seerr.k8s.rommelporras.com` | 1Gi (`seerr-config`) | N/A |
| Configarr | N/A | N/A (CronJob, no web UI) | N/A | N/A |
| Unpackerr | N/A | N/A (daemon, no web UI) | N/A | `/data` (shared `arr-data` PVC) |
| Scraparr | 7100 | N/A (internal — metrics only) | N/A | N/A |
| Tdarr | 8265 (UI), 8266 (API) | `tdarr.k8s.rommelporras.com` | 5Gi (`tdarr-server`) + 2Gi (`tdarr-configs`) | `/media` (shared `arr-data` PVC) |
| Recommendarr | 3000 | `recommendarr.k8s.rommelporras.com` | 1Gi (`recommendarr-config`) | N/A |

---

## Tasks

### 4.26.1 Deploy Seerr (Media Requests + Discovery)

- [ ] 4.26.1.1 Verify image version — `ghcr.io/seerr-team/seerr:v3.0.1` (MIT, released Feb 14 2026)
- [ ] 4.26.1.2 Create `manifests/arr-stack/seerr/deployment.yaml`
  - Image: `ghcr.io/seerr-team/seerr:v3.0.1`
  - Replicas: 1
  - Port: 5055
  - Longhorn PVC `seerr-config` (1Gi) mounted at `/app/config` (SQLite DB)
  - No NFS needed — talks to Sonarr/Radarr/Jellyfin via API only
  - Security: Pattern B (official image, not LSIO) — `runAsUser: 1000`, `runAsGroup: 1000`, `runAsNonRoot: true`
  - Resources: `cpu: 50m/250m`, `memory: 128Mi/256Mi`
  - Health: `httpGet /api/v1/status` port 5055
- [ ] 4.26.1.3 Create `manifests/arr-stack/seerr/service.yaml` — ClusterIP (port 5055)
- [ ] 4.26.1.4 Create `manifests/arr-stack/seerr/httproute.yaml` — `seerr.k8s.rommelporras.com`
- [ ] 4.26.1.5 Apply and verify Seerr UI accessible
- [ ] 4.26.1.6 Configure Seerr via UI:
  - Set Jellyfin as media server (auth source)
  - Add Sonarr connection (URL + API key)
  - Add Radarr connection (URL + API key)
  - Link TMDB for discovery/metadata
- [ ] 4.26.1.7 Test request flow: search movie in Seerr → approve → appears in Radarr queue

### 4.26.2 Deploy Configarr (TRaSH Guide Sync)

- [ ] 4.26.2.1 Pin image — check latest at https://github.com/raydak-labs/configarr/releases
- [ ] 4.26.2.2 Research Configarr config YAML format — defines which TRaSH profiles to sync to which Sonarr/Radarr instances
- [ ] 4.26.2.3 Create `manifests/arr-stack/configarr/cronjob.yaml` — CronJob
  - Schedule: `0 3 * * *` (daily at 3 AM — low-activity window)
  - Env: Sonarr/Radarr URLs + API keys from Secrets
  - Resource limits: `cpu: 100m/500m`, `memory: 128Mi/256Mi`
  - `restartPolicy: OnFailure`
- [ ] 4.26.2.4 Create `manifests/arr-stack/configarr/configmap.yaml` — Configarr YAML config
- [ ] 4.26.2.5 Verify shared `arr-api-keys` Secret exists (created in Phase 4.25, task 4.25.9.5):
  ```bash
  kubectl-homelab get secret arr-api-keys -n arr-stack
  ```
  - Configarr references `SONARR_API_KEY` and `RADARR_API_KEY` from this shared secret
- [ ] 4.26.2.6 Apply and trigger manual test run:
  ```bash
  kubectl-homelab create job --from=cronjob/configarr configarr-test -n arr-stack
  kubectl-homelab logs -n arr-stack job/configarr-test
  ```
- [ ] 4.26.2.7 Verify quality profiles updated in Sonarr/Radarr UI

### 4.26.3 Deploy Unpackerr (Archive Extraction)

- [ ] 4.26.3.1 Pin image — check latest at https://github.com/unpackerr/unpackerr/releases
- [ ] 4.26.3.2 Create `manifests/arr-stack/unpackerr/deployment.yaml`
  - NFS PVC mounted at `/data` (needs access to `/data/torrents/` for extraction)
  - No Longhorn PVC needed (stateless daemon)
  - Env: Sonarr/Radarr URLs + API keys from shared `arr-api-keys` Secret (Phase 4.25)
  - Resource limits: `cpu: 50m/500m`, `memory: 64Mi/256Mi`
  - No web UI, no Service, no HTTPRoute
- [ ] 4.26.3.3 Security context (same pattern as Phase 4.25 — `SETUID`/`SETGID` caps for LinuxServer images if applicable, check Unpackerr base image)
- [ ] 4.26.3.4 Apply and verify — check logs for successful connection to Sonarr/Radarr

### 4.26.4 Deploy Scraparr (Prometheus Metrics)

- [ ] 4.26.4.1 Pin image — check latest at https://github.com/thecfu/scraparr/releases
- [ ] 4.26.4.2 Create `manifests/arr-stack/scraparr/deployment.yaml`
  - No PVC needed (stateless)
  - Env: connection details for all *ARR apps (URLs + API keys from shared `arr-api-keys` Secret)
  - Resource limits: `cpu: 50m/250m`, `memory: 64Mi/128Mi`
  - Port: 7100 (`/metrics`)
- [ ] 4.26.4.3 Create `manifests/arr-stack/scraparr/service.yaml` — ClusterIP (port 7100)
- [ ] 4.26.4.4 Create `manifests/arr-stack/scraparr/servicemonitor.yaml` — ServiceMonitor for Prometheus
  - `interval: 5m` (no point scraping faster than *ARR app refresh cycles)
- [ ] 4.26.4.5 Apply and verify: `up{job="scraparr"} == 1` in Prometheus
- [ ] 4.26.4.6 Verify *ARR metrics appear: `sonarr_*`, `radarr_*`, `prowlarr_*`

### 4.26.5 Deploy Tdarr (Library Transcoding)

- [ ] 4.26.5.1 Verify image version — `ghcr.io/haveagitgat/tdarr:2.58.02` (server with internal node)
- [ ] 4.26.5.2 Create 1Password item `Tdarr` in `Kubernetes` vault with `seeded-api-key` field
- [ ] 4.26.5.3 Create `manifests/arr-stack/tdarr/deployment.yaml`
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
  - Key env: `internalNode=true`, `inContainer=true`, `ffmpegVersion=7`, `auth=true`, `seededApiKey` from 1Password
  - Anti-affinity: soft anti-affinity against Jellyfin to reduce GPU contention
- [ ] 4.26.5.4 Create `manifests/arr-stack/tdarr/service.yaml` — ClusterIP (ports 8265, 8266)
- [ ] 4.26.5.5 Create `manifests/arr-stack/tdarr/httproute.yaml` — `tdarr.k8s.rommelporras.com`
- [ ] 4.26.5.6 Apply and verify:
  - Tdarr web UI accessible at `tdarr.k8s.rommelporras.com`
  - Internal node shows as connected in web UI
  - QSV hardware detected (check Tdarr node info for GPU)
- [ ] 4.26.5.7 Configure Tdarr via UI:
  - Add media library pointing to `/media`
  - Set transcode cache to `/temp`
  - Enable QSV hardware encoding in flow plugins
  - Configure scheduler to run during off-hours (2AM-8AM Manila time) to reduce GPU contention with Jellyfin
- [ ] 4.26.5.8 Test transcode: pick a single file, run QSV transcode, verify output quality

### 4.26.6 Deploy Recommendarr (AI Recommendations)

- [ ] 4.26.6.1 Pin image — check latest at https://github.com/tannermiddleton/recommendarr/releases (pin `latest` to specific version at deploy)
- [ ] 4.26.6.2 Create `manifests/arr-stack/recommendarr/deployment.yaml`
  - Image: `tannermiddleton/recommendarr:latest` (pin version)
  - Replicas: 1
  - Port: 3000
  - Longhorn PVC `recommendarr-config` (1Gi) for persistent config
  - No NFS needed — reads from Sonarr/Radarr/Jellyfin APIs + Ollama API
  - Security: Pattern B (non-root), `runAsUser: 1000`, `runAsGroup: 1000`
  - Resources: `cpu: 50m/250m`, `memory: 64Mi/256Mi`
  - Integration: Ollama at `http://ollama.ai.svc.cluster.local:11434`
  - Default login: `admin` / `1234` (change on first setup)
- [ ] 4.26.6.3 Create `manifests/arr-stack/recommendarr/service.yaml` — ClusterIP (port 3000)
- [ ] 4.26.6.4 Create `manifests/arr-stack/recommendarr/httproute.yaml` — `recommendarr.k8s.rommelporras.com`
- [ ] 4.26.6.5 Apply and verify Recommendarr UI accessible
- [ ] 4.26.6.6 Configure Recommendarr via UI:
  - Connect to Jellyfin (watch history source)
  - Connect to Sonarr + Radarr (library source)
  - Set Ollama endpoint: `http://ollama.ai.svc.cluster.local:11434`
  - Change default admin password
- [ ] 4.26.6.7 Test: verify recommendations generate based on existing Jellyfin library

### 4.26.7 Configure Import Lists (UI-Only — No Manifests)

> Configure Radarr/Sonarr built-in import lists + MDBList for automated content discovery. Do this after Seerr is deployed to avoid duplicate request handling.

- [ ] 4.26.7.1 **Radarr import lists** (Settings > Lists):
  - Add TMDB Popular Movies list
  - Add TMDB Upcoming Movies list
  - Add Trakt Trending Movies list
- [ ] 4.26.7.2 **Sonarr import lists** (Settings > Import Lists):
  - Add Trakt Popular Shows list
  - Add Trakt Trending Shows list
  - Add Trakt Anticipated Shows list
- [ ] 4.26.7.3 **MDBList integration**:
  - Create free account at mdblist.com
  - Build streaming-filtered lists (Netflix, Disney+, Amazon Prime)
  - Feed list URLs into Radarr/Sonarr as custom import lists
- [ ] 4.26.7.4 Verify import lists showing in Radarr/Sonarr and auto-adding content

### 4.26.8 Update NetworkPolicy

> The existing egress policy (`manifests/arr-stack/networkpolicy.yaml`) blocks all RFC1918 traffic except NFS at `10.10.30.4:2049`. Recommendarr needs to reach Ollama in the `ai` namespace on port 11434.

- [ ] 4.26.8.1 Add egress rule to `manifests/arr-stack/networkpolicy.yaml` allowing traffic to `ai` namespace:
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
- [ ] 4.26.8.2 Apply and verify Recommendarr can reach Ollama:
  ```bash
  kubectl-homelab apply -f manifests/arr-stack/networkpolicy.yaml
  # Verify from Recommendarr pod:
  kubectl-homelab exec -n arr-stack deploy/recommendarr -- wget -qO- http://ollama.ai.svc.cluster.local:11434/api/version
  ```

### 4.26.9 Build Grafana Dashboards

> Note: `arr-stack-dashboard-configmap.yaml` and `jellyfin-dashboard-configmap.yaml` already exist from Phase 4.25/4.25b. The Scraparr dashboard below is a NEW dashboard, not replacing existing ones.

#### Scraparr ARR Metrics Dashboard

- [ ] 4.26.9.1 Import Scraparr dashboard [#22934](https://grafana.com/grafana/dashboards/22934) as starting point
- [ ] 4.26.9.2 Customize with panels for:
  - Queue size and download rates per app
  - Library size (movies, episodes, artists)
  - Missing content count
  - Health check status per app
  - Recent imports
- [ ] 4.26.9.3 Create `manifests/monitoring/scraparr-dashboard-configmap.yaml` (sidecar label `grafana_dashboard: "1"`)

#### Network Throughput Dashboard (1GbE vs 2.5GbE Decision)

- [ ] 4.26.9.4 Create network saturation dashboard with panels:

| Panel | Type | PromQL |
|-------|------|--------|
| NIC Utilization % | Gauge | `(rate(node_network_receive_bytes_total{device!~"lo\|cni.*\|veth.*\|cilium.*"}[5m]) + rate(node_network_transmit_bytes_total{...}[5m])) / node_network_speed_bytes{...} * 100` |
| Throughput (Mbps) | Timeseries | `(rate(node_network_receive_bytes_total{...}[5m]) + rate(node_network_transmit_bytes_total{...}[5m])) * 8 / 1000000` |
| RX vs TX per Node | Timeseries (stacked) | `rate(node_network_receive_bytes_total{...}[5m]) * 8 / 1000000` (separate for RX/TX) |
| Peak Utilization (24h) | Stat | `max_over_time(...)` |
| Time Above 80% (24h) | Stat | `count_over_time((nic_utilization > 80)[24h:5m])` (subquery syntax) |
| NAS Traffic (to/from 10.10.30.4) | Timeseries | Filter by destination if available via Cilium Hubble |

- [ ] 4.26.9.5 Verify `node_network_speed_bytes` metric exists in Prometheus (required for NIC utilization % — depends on NIC driver; if missing, hardcode 125000000 for 1GbE)
- [ ] 4.26.9.6 Create `manifests/monitoring/network-dashboard-configmap.yaml`
- [ ] 4.26.9.7 Investigate NFS download speed bottleneck observed during Phase 4.25:
  - K8s nodes have **1GbE NICs**, OMV NAS has **2.5GbE NIC** — nodes are the bottleneck
  - qBittorrent downloads via NFS were slow (~500 KiB/s-1 MiB/s) — unclear if NFS overhead, 1GbE saturation, or torrent seeder availability
  - Compare: download speed via qBittorrent (NFS write) vs Longhorn (local NVMe write) to isolate NFS as the variable
  - Use this dashboard's data to determine if 2.5GbE NIC upgrade for K8s nodes is justified

### 4.26.10 Alert Rules

- [ ] 4.26.10.1 Create `manifests/monitoring/arr-alerts.yaml` (PrometheusRule):

| Alert | Expression | Severity | Notes |
|-------|-----------|----------|-------|
| `ArrAppDown` | `up{job="scraparr"} == 0` for 5m | critical | Scraparr exporter unreachable |
| `SonarrQueueStalled` | Sonarr queue items stuck > 2h | warning | Downloads may be stuck |
| `RadarrQueueStalled` | Radarr queue items stuck > 2h | warning | Downloads may be stuck |
| `NetworkInterfaceSaturated` | NIC utilization > 80% for 10m | warning | Consider 2.5GbE upgrade |
| `NetworkInterfaceCritical` | NIC utilization > 95% for 5m | critical | Network bottleneck active |
| `JellyfinDown` | Jellyfin health check fails for 5m | critical | Media server unreachable |

### 4.26.11 Integration

- [ ] 4.26.11.1 Configure Discord webhooks in Sonarr/Radarr for download/import notifications (native, no Notifiarr needed)

### 4.26.12 Harden NFS Mounts

> After all companion apps are deployed and verified working, lock down NFS access.

- [ ] 4.26.12.1 Set Jellyfin NFS volume mount to `readOnly: true` — only reads from `/data/media/`, never writes
  ```yaml
  volumeMounts:
    - name: data
      mountPath: /data
      readOnly: true
  ```
- [ ] 4.26.12.2 Verify Jellyfin still plays media after read-only change
- [ ] 4.26.12.3 Verify Bazarr can still write `.srt` files next to media (needs RW — confirm not broken by Jellyfin change)
- [ ] 4.26.12.4 Review all NFS volume mounts in `arr-stack` namespace:

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

- [ ] 4.26.13.1 Update `docs/todo/README.md` — add Phase 4.26 to phase index
- [ ] 4.26.13.2 Update `README.md` (root) — add companion apps to services list (Seerr, Configarr, Unpackerr, Scraparr, Tdarr, Recommendarr)
- [ ] 4.26.13.3 Update `VERSIONS.md` — add all companion app versions
- [ ] 4.26.13.4 Update `docs/reference/CHANGELOG.md` — add companion selection decisions (Scraparr over Exportarr, Configarr over Recyclarr/Notifiarr, Seerr over Overseerr/Jellyseerr, Tdarr now viable with QSV)
- [ ] 4.26.13.5 Update `docs/context/Monitoring.md` — add Scraparr exporter + network dashboard
- [ ] 4.26.13.6 Update `docs/context/Gateway.md` — add Seerr, Tdarr, Recommendarr HTTPRoutes
- [ ] 4.26.13.7 Update `docs/context/Secrets.md` — document Tdarr 1Password item + shared `arr-api-keys` secret usage by companion apps
- [ ] 4.26.13.8 Create `docs/rebuild/v0.25.0-arr-companions.md`
- [ ] 4.26.13.9 `/audit-docs`
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
| **Total** | **800m** | **3750m** | **960Mi** | **3200Mi** | **9Gi** |

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
7. **Import list config** — UI-only, do after Seerr to avoid duplicate requests
8. **NetworkPolicy update** — required for Recommendarr → Ollama
9. **Grafana dashboards + alerts**
10. **NFS hardening**
11. **Documentation + release**

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
| `manifests/monitoring/arr-alerts.yaml` | PrometheusRule | Alert rules |

### Files to Modify

| File | Change |
|------|--------|
| `manifests/arr-stack/networkpolicy.yaml` | Add egress rule for `ai` namespace (Ollama port 11434) |

---

## Verification Checklist

- [ ] Seerr UI accessible at `seerr.k8s.rommelporras.com`
- [ ] Seerr Jellyfin auth working, request flow to Sonarr/Radarr verified
- [ ] Configarr CronJob ran successfully — quality profiles synced
- [ ] Unpackerr running, connected to Sonarr + Radarr (check logs)
- [ ] Scraparr exposing metrics (`up{job="scraparr"} == 1`)
- [ ] Tdarr web UI accessible at `tdarr.k8s.rommelporras.com`
- [ ] Tdarr internal node connected, test QSV transcode succeeds
- [ ] Recommendarr UI accessible at `recommendarr.k8s.rommelporras.com`
- [ ] Recommendarr Ollama connection verified, recommendations generating
- [ ] Import lists showing in Radarr/Sonarr, auto-adding content
- [ ] Grafana Scraparr dashboard rendering with real data
- [ ] Network throughput dashboard showing NIC utilization
- [ ] Alert rules loaded in Alertmanager
- [ ] Discord notifications working from Sonarr/Radarr native webhooks
- [ ] NetworkPolicy updated — Recommendarr can reach Ollama

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
kubectl-homelab delete -f manifests/monitoring/scraparr-dashboard-configmap.yaml
kubectl-homelab delete -f manifests/monitoring/network-dashboard-configmap.yaml
kubectl-homelab delete -f manifests/monitoring/arr-alerts.yaml
# Revert networkpolicy.yaml changes (git checkout)
git checkout -- manifests/arr-stack/networkpolicy.yaml
kubectl-homelab apply -f manifests/arr-stack/networkpolicy.yaml
```
