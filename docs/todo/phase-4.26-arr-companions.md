# Phase 4.26: ARR Stack Companions & Monitoring

> **Status:** Planned
> **Target:** v0.23.0
> **Prerequisite:** Phase 4.25 complete (ARR core stack running)
> **Priority:** Medium (automation + observability for media stack)
> **DevOps Topics:** CronJobs, Prometheus exporters, Grafana dashboards, network saturation monitoring
> **CKA Topics:** CronJob, Deployment, Service, ServiceMonitor, PrometheusRule, ConfigMap

> **Purpose:** Deploy companion apps for the *ARR stack — subtitle automation, quality profile sync, archive extraction, and Prometheus monitoring with Grafana dashboards including network throughput analysis for the 1GbE vs 2.5GbE upgrade decision.
>
> **Why:** The core stack (Phase 4.25) handles media management. This phase adds the automation layer (set-and-forget maintenance) and observability (know when something breaks, and whether your network is the bottleneck).

---

## Components

| App | Purpose | Type | Image |
|-----|---------|------|-------|
| **Bazarr** | Automatic subtitle downloads | Deployment | `lscr.io/linuxserver/bazarr` (pin at deploy) |
| **Configarr** | TRaSH Guide quality profile sync | CronJob | `ghcr.io/raydak-labs/configarr` (pin at deploy) |
| **Unpackerr** | Extract RAR archives from downloads | Deployment | `ghcr.io/unpackerr/unpackerr` (pin at deploy) |
| **Scraparr** | Prometheus metrics for all *ARR apps | Deployment | `ghcr.io/thecfu/scraparr` (pin at deploy) |

### Why These Four (and Not Others)

| Considered | Verdict | Reason |
|------------|---------|--------|
| **Bazarr** | Deploy | Set-and-forget subtitles. Low overhead. |
| **Configarr** | Deploy | Free TRaSH Guide sync as CronJob. Supports custom formats beyond TRaSH presets. |
| **Unpackerr** | Deploy | Many torrent releases are RAR-packed. Without this, Sonarr/Radarr can't import them. |
| **Scraparr** | Deploy | Single deployment monitors ALL *ARR apps. Better than Exportarr (which needs 1 deployment per app). |
| Notifiarr | **Skip** | Paid service ($3-10/mo). Cloud-dependent. Replicable with native Discord webhooks (Sonarr/Radarr built-in) + Configarr (guide sync) + Prometheus/Grafana (monitoring). |
| Recyclarr | **Skip** | Configarr does the same thing + supports custom format creation beyond TRaSH presets. |
| Exportarr | **Skip** | Maintenance mode. Needs 5 separate deployments. Scraparr does it in 1. |
| Jellyseerr | **Defer** | Only needed if others request media. Can add later. |
| Huntarr | **Defer** | Nice-to-have. Sonarr/Radarr built-in search covers most cases. |
| Maintainerr | **Defer** | Useful for auto-pruning but Plex-focused. Wait for Jellyfin support. |
| Sportarr | **Skip** | Alpha quality. Not production-ready. |
| Tdarr | **Skip** | No GPU on nodes. CPU transcoding would cripple the cluster. |
| Autobrr | **Skip** | Only for private tracker IRC racing. Overkill. |
| FlareSolverr | **Skip** | Dead project. Use Byparr only if specific indexers need it. |

---

## Target State

| App | Port | URL | Config PVC | NFS Mount |
|-----|------|-----|------------|-----------|
| Bazarr | 6767 | `bazarr.k8s.rommelporras.com` | 2Gi Longhorn | `/data` (shared `arr-data` PVC) |
| Configarr | N/A | N/A (CronJob, no web UI) | N/A | N/A |
| Unpackerr | N/A | N/A (daemon, no web UI) | N/A | `/data` (shared `arr-data` PVC) |
| Scraparr | 7100 | N/A (internal — metrics only) | N/A | N/A |

---

## Tasks

### 4.26.1 Deploy Bazarr (Subtitles)

- [ ] 4.26.1.1 Pin image — check latest stable at https://github.com/morpheus65535/bazarr/releases
- [ ] 4.26.1.2 Create `manifests/media/bazarr/deployment.yaml`
  - Longhorn PVC 2Gi for `/config`
  - NFS PVC mounted at `/data` (shared `arr-data` PVC)
  - `strategy: Recreate`
  - Env: `PUID=1000`, `PGID=1000`, `TZ=Asia/Manila`
  - Resource limits: `cpu: 50m/250m`, `memory: 128Mi/256Mi`
- [ ] 4.26.1.3 Security context (same pattern as Phase 4.25 apps)
- [ ] 4.26.1.4 Create `manifests/media/bazarr/service.yaml` — ClusterIP (port 6767)
- [ ] 4.26.1.5 Create `manifests/media/bazarr/httproute.yaml` — `bazarr.k8s.rommelporras.com`
- [ ] 4.26.1.6 Apply and verify
- [ ] 4.26.1.7 Configure: connect to Sonarr + Radarr, set subtitle providers and language preferences

### 4.26.2 Deploy Configarr (TRaSH Guide Sync)

- [ ] 4.26.2.1 Pin image — check latest at https://github.com/raydak-labs/configarr/releases
- [ ] 4.26.2.2 Research Configarr config YAML format — defines which TRaSH profiles to sync to which Sonarr/Radarr instances
- [ ] 4.26.2.3 Create `manifests/media/configarr/cronjob.yaml` — CronJob
  - Schedule: `0 3 * * *` (daily at 3 AM — low-activity window)
  - Env: Sonarr/Radarr URLs + API keys from Secrets
  - Resource limits: `cpu: 100m/500m`, `memory: 128Mi/256Mi`
  - `restartPolicy: OnFailure`
- [ ] 4.26.2.4 Create `manifests/media/configarr/configmap.yaml` — Configarr YAML config
- [ ] 4.26.2.5 Verify shared `arr-api-keys` Secret exists (created in Phase 4.25, task 4.25.9.5):
  ```bash
  kubectl-homelab get secret arr-api-keys -n media
  ```
  - Configarr references `SONARR_API_KEY` and `RADARR_API_KEY` from this shared secret
- [ ] 4.26.2.6 Apply and trigger manual test run:
  ```bash
  kubectl-homelab create job --from=cronjob/configarr configarr-test -n media
  kubectl-homelab logs -n media job/configarr-test
  ```
- [ ] 4.26.2.7 Verify quality profiles updated in Sonarr/Radarr UI

### 4.26.3 Deploy Unpackerr (Archive Extraction)

- [ ] 4.26.3.1 Pin image — check latest at https://github.com/unpackerr/unpackerr/releases
- [ ] 4.26.3.2 Create `manifests/media/unpackerr/deployment.yaml`
  - NFS PVC mounted at `/data` (needs access to `/data/torrents/` for extraction)
  - No Longhorn PVC needed (stateless daemon)
  - Env: Sonarr/Radarr URLs + API keys from shared `arr-api-keys` Secret (Phase 4.25)
  - Resource limits: `cpu: 50m/500m`, `memory: 64Mi/256Mi`
  - No web UI, no Service, no HTTPRoute
- [ ] 4.26.3.3 Security context (same pattern as Phase 4.25 — `SETUID`/`SETGID` caps for LinuxServer images if applicable, check Unpackerr base image)
- [ ] 4.26.3.4 Apply and verify — check logs for successful connection to Sonarr/Radarr

### 4.26.4 Deploy Scraparr (Prometheus Metrics)

- [ ] 4.26.4.1 Pin image — check latest at https://github.com/thecfu/scraparr/releases
- [ ] 4.26.4.2 Create `manifests/media/scraparr/deployment.yaml`
  - No PVC needed (stateless)
  - Env: connection details for all *ARR apps (URLs + API keys from shared `arr-api-keys` Secret)
  - Resource limits: `cpu: 50m/250m`, `memory: 64Mi/128Mi`
  - Port: 7100 (`/metrics`)
- [ ] 4.26.4.3 Create `manifests/media/scraparr/service.yaml` — ClusterIP (port 7100)
- [ ] 4.26.4.4 Create `manifests/media/scraparr/servicemonitor.yaml` — ServiceMonitor for Prometheus
  - `interval: 5m` (no point scraping faster than *ARR app refresh cycles)
- [ ] 4.26.4.5 Apply and verify: `up{job="scraparr"} == 1` in Prometheus
- [ ] 4.26.4.6 Verify *ARR metrics appear: `sonarr_*`, `radarr_*`, `prowlarr_*`

### 4.26.5 Build Grafana Dashboards

#### ARR Stack Dashboard

- [ ] 4.26.5.1 Import Scraparr dashboard [#22934](https://grafana.com/grafana/dashboards/22934) as starting point
- [ ] 4.26.5.2 Customize with panels for:
  - Queue size and download rates per app
  - Library size (movies, episodes, artists)
  - Missing content count
  - Health check status per app
  - Recent imports
- [ ] 4.26.5.3 Create `manifests/monitoring/arr-dashboard-configmap.yaml` (sidecar label `grafana_dashboard: "1"`)

#### Network Throughput Dashboard (1GbE vs 2.5GbE Decision)

- [ ] 4.26.5.4 Create network saturation dashboard with panels:

| Panel | Type | PromQL |
|-------|------|--------|
| NIC Utilization % | Gauge | `(rate(node_network_receive_bytes_total{device!~"lo\|cni.*\|veth.*\|cilium.*"}[5m]) + rate(node_network_transmit_bytes_total{...}[5m])) / node_network_speed_bytes{...} * 100` |
| Throughput (Mbps) | Timeseries | `(rate(node_network_receive_bytes_total{...}[5m]) + rate(node_network_transmit_bytes_total{...}[5m])) * 8 / 1000000` |
| RX vs TX per Node | Timeseries (stacked) | `rate(node_network_receive_bytes_total{...}[5m]) * 8 / 1000000` (separate for RX/TX) |
| Peak Utilization (24h) | Stat | `max_over_time(...)` |
| Time Above 80% (24h) | Stat | `count_over_time((nic_utilization > 80)[24h:5m])` (subquery syntax — `count_over_time` cannot take a comparison directly) |
| NAS Traffic (to/from 10.10.30.4) | Timeseries | Filter by destination if available via Cilium Hubble |

- [ ] 4.26.5.5 Verify `node_network_speed_bytes` metric exists in Prometheus (required for NIC utilization % — depends on NIC driver; if missing, hardcode 125000000 for 1GbE)
- [ ] 4.26.5.6 Create `manifests/monitoring/network-dashboard-configmap.yaml`

### 4.26.6 Alert Rules

- [ ] 4.26.6.1 Create `manifests/monitoring/arr-alerts.yaml` (PrometheusRule):

| Alert | Expression | Severity | Notes |
|-------|-----------|----------|-------|
| `ArrAppDown` | `up{job="scraparr"} == 0` for 5m | critical | Scraparr exporter unreachable |
| `SonarrQueueStalled` | Sonarr queue items stuck > 2h | warning | Downloads may be stuck |
| `RadarrQueueStalled` | Radarr queue items stuck > 2h | warning | Downloads may be stuck |
| `NetworkInterfaceSaturated` | NIC utilization > 80% for 10m | warning | Consider 2.5GbE upgrade |
| `NetworkInterfaceCritical` | NIC utilization > 95% for 5m | critical | Network bottleneck active |
| `JellyfinDown` | Jellyfin health check fails for 5m | critical | Media server unreachable |

### 4.26.7 Integration

- [ ] 4.26.7.1 Add Bazarr to Homepage dashboard
- [ ] 4.26.7.2 Add Bazarr URL to Uptime Kuma monitoring
- [ ] 4.26.7.3 Verify DNS resolution for `bazarr.k8s.rommelporras.com` via existing wildcard rewrite
- [ ] 4.26.7.4 Configure Discord webhooks in Sonarr/Radarr for download/import notifications (native, no Notifiarr needed)

### 4.26.8 Harden NFS Mounts

> After all companion apps are deployed and verified working, lock down NFS access.

- [ ] 4.26.8.1 Set Jellyfin NFS volume mount to `readOnly: true` — only reads from `/data/media/`, never writes
  ```yaml
  volumeMounts:
    - name: data
      mountPath: /data
      readOnly: true
  ```
- [ ] 4.26.8.2 Verify Jellyfin still plays media after read-only change
- [ ] 4.26.8.3 Verify Bazarr can still write `.srt` files next to media (needs RW — confirm not broken by Jellyfin change)
- [ ] 4.26.8.4 Review all NFS volume mounts in `media` namespace:

| App | NFS Access | Reason |
|-----|-----------|--------|
| qBittorrent | Read-Write | Writes downloads to `/data/torrents/` |
| Sonarr | Read-Write | Creates hardlinks `torrents/` → `media/` |
| Radarr | Read-Write | Creates hardlinks `torrents/` → `media/` |
| Jellyfin | **Read-Only** | Only reads from `/data/media/` |
| Bazarr | Read-Write | Writes subtitle `.srt` files next to media |
| Unpackerr | Read-Write | Extracts RAR archives in `/data/torrents/` |

### 4.26.9 Documentation & Release

> Second commit: documentation updates and audit.

- [ ] 4.26.9.1 Update `docs/todo/README.md` — add Phase 4.26 to phase index
- [ ] 4.26.9.2 Update `README.md` (root) — add companion apps to services list
- [ ] 4.26.9.3 Update `VERSIONS.md` — add all companion app versions + Bazarr HTTPRoute
- [ ] 4.26.9.4 Update `docs/reference/CHANGELOG.md` — add companion selection decisions (Scraparr over Exportarr, Configarr over Recyclarr/Notifiarr, skip Tdarr reasoning)
- [ ] 4.26.9.5 Update `docs/context/Monitoring.md` — add Scraparr exporter + network dashboard
- [ ] 4.26.9.6 Update `docs/context/Gateway.md` — add Bazarr HTTPRoute
- [ ] 4.26.9.7 Update `docs/context/Secrets.md` — document shared `arr-api-keys` secret usage by companion apps
- [ ] 4.26.9.8 Create `docs/rebuild/v0.23.0-arr-companions.md`
- [ ] 4.26.9.9 `/audit-docs`
- [ ] 4.26.9.10 `/commit`
- [ ] 4.26.9.11 `/release v0.23.0 "ARR Stack Companions & Monitoring"`
- [ ] 4.26.9.12 Move this file to `docs/todo/completed/`

---

## Resource Budget

| App | CPU Request | CPU Limit | Memory Request | Memory Limit | Config PVC |
|-----|-------------|-----------|----------------|--------------|------------|
| Bazarr | 50m | 250m | 128Mi | 256Mi | 2Gi |
| Configarr | 100m | 500m | 128Mi | 256Mi | N/A (CronJob) |
| Unpackerr | 50m | 500m | 64Mi | 256Mi | N/A (stateless) |
| Scraparr | 50m | 250m | 64Mi | 128Mi | N/A (stateless) |
| **Total** | **250m** | **1500m** | **384Mi** | **896Mi** | **2Gi** |

Combined with Phase 4.25 totals: ~1.77Gi requests, ~5.65Gi limits — still well within your cluster capacity.

---

## Files to Create

| File | Type | Purpose |
|------|------|---------|
| `manifests/media/bazarr/deployment.yaml` | Deployment + PVC | Bazarr workload + config |
| `manifests/media/bazarr/service.yaml` | Service | ClusterIP |
| `manifests/media/bazarr/httproute.yaml` | HTTPRoute | `bazarr.k8s.rommelporras.com` |
| `manifests/media/configarr/cronjob.yaml` | CronJob | TRaSH Guide sync (daily) |
| `manifests/media/configarr/configmap.yaml` | ConfigMap | Configarr YAML config |
| `manifests/media/unpackerr/deployment.yaml` | Deployment | Archive extraction daemon |
| `manifests/media/scraparr/deployment.yaml` | Deployment | Prometheus exporter |
| `manifests/media/scraparr/service.yaml` | Service | ClusterIP (port 7100) |
| `manifests/media/scraparr/servicemonitor.yaml` | ServiceMonitor | Prometheus scrape config |
| `manifests/monitoring/arr-dashboard-configmap.yaml` | ConfigMap | Grafana dashboard JSON |
| `manifests/monitoring/network-dashboard-configmap.yaml` | ConfigMap | Network throughput dashboard JSON |
| `manifests/monitoring/arr-alerts.yaml` | PrometheusRule | Alert rules |

---

## Verification Checklist

- [ ] Bazarr running, connected to Sonarr + Radarr, subtitle providers configured
- [ ] Configarr CronJob ran successfully — quality profiles synced
- [ ] Unpackerr running, connected to Sonarr + Radarr (check logs)
- [ ] Scraparr exposing metrics (`up{job="scraparr"} == 1`)
- [ ] Grafana ARR dashboard rendering with real data
- [ ] Network throughput dashboard showing NIC utilization
- [ ] Alert rules loaded in Alertmanager
- [ ] Discord notifications working from Sonarr/Radarr native webhooks
- [ ] Homepage entries for Bazarr
- [ ] Uptime Kuma monitoring Bazarr

---

## Rollback

```bash
# Companions only — core ARR stack (Phase 4.25) stays
kubectl-homelab delete -f manifests/media/bazarr/
kubectl-homelab delete -f manifests/media/configarr/
kubectl-homelab delete -f manifests/media/unpackerr/
kubectl-homelab delete -f manifests/media/scraparr/
kubectl-homelab delete -f manifests/monitoring/arr-dashboard-configmap.yaml
kubectl-homelab delete -f manifests/monitoring/network-dashboard-configmap.yaml
kubectl-homelab delete -f manifests/monitoring/arr-alerts.yaml
```
