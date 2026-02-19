# Changelog

> Project decision history and revision tracking

---

## February 19, 2026 — Phase 4.28 (In Progress): Alerting & Observability

### Summary

Phase 4.28 alerting infrastructure complete. Dashboards improved. Control plane bind addresses fixed. kube-vip VIP loss investigated and root-caused. KubeApiserverFrequentRestarts alert identified as remaining gap.

### Infrastructure Changes

| Change | Description |
|--------|-------------|
| monitoring/ reorganization | 55 flat files → 8 typed subdirectories (alerts/, dashboards/, exporters/, grafana/, otel/, probes/, servicemonitors/, version-checker/) |
| Prometheus HTTPRoute | Exposed Prometheus UI at `prometheus.k8s.rommelporras.com` |
| Alertmanager HTTPRoute | Exposed Alertmanager UI at `alertmanager.k8s.rommelporras.com` |
| Homepage widgets | Prometheus targets count + Alertmanager firing count (excludes Watchdog) |
| kubeadm bind addresses | Fixed etcd/kube-controller-manager/kube-scheduler to `0.0.0.0` so Prometheus can scrape |
| kubeProxy disabled | `kubeProxy.enabled: false` in Helm values — Cilium replaces kube-proxy |

### Alerting Infrastructure Completed (Phase 4.28)

| Item | Files | Status |
|------|-------|--------|
| Jellyfin probe (fixes broken JellyfinDown) | `probes/jellyfin-probe.yaml` | Done |
| Ghost probe + alert | `probes/ghost-probe.yaml`, `alerts/ghost-alerts.yaml` | Done |
| Invoicetron probe + alert | `probes/invoicetron-probe.yaml`, `alerts/invoicetron-alerts.yaml` | Done |
| Portfolio probe + alert | `probes/portfolio-probe.yaml`, `alerts/portfolio-alerts.yaml` | Done |
| Seerr probe + alert | `probes/seerr-probe.yaml`, `alerts/arr-alerts.yaml` | Done |
| Tdarr probe + alert | `probes/tdarr-probe.yaml`, `alerts/arr-alerts.yaml` | Done |
| Byparr probe + alert | `probes/byparr-probe.yaml`, `alerts/arr-alerts.yaml` | Done |
| Uptime Kuma alert | `alerts/uptime-kuma-alerts.yaml` | Done |
| Longhorn ServiceMonitor + alerts | `servicemonitors/longhorn-servicemonitor.yaml`, `alerts/storage-alerts.yaml` | Done |
| cert-manager ServiceMonitor + alerts | `servicemonitors/certmanager-servicemonitor.yaml`, `alerts/cert-alerts.yaml` | Done |
| Cloudflare Tunnel alerts | `alerts/cloudflare-alerts.yaml` | Done |
| AdGuard alert label fix | `alerts/adguard-dns-alert.yaml` | Done |
| LokiStorageLow removed | `alerts/logging-alerts.yaml` | Done |

### Dashboards Created/Updated

| Dashboard | Change |
|-----------|--------|
| Service Health (new) | 11 UP/DOWN probe stat panels for all monitored services |
| ARR Stack | Added Byparr companion panel; fixed Container Restarts to use `increase()` |

### kube-vip VIP Loss Investigation

**Root cause chain:**
1. etcd had a transient blip → API server `/livez` returned HTTP 500
2. Kubelet killed the API server after 7 consecutive liveness probe failures
3. kube-vip on cp1 (the leader) could not renew its lease lock → dropped the VIP
4. ~2 min gap with no VIP → all `kubectl` calls timed out
5. cp2 won leader election → VIP restored

**Restart counts (34 days):** cp1=7, cp2=21, cp3=30 — cp3 averaging ~1 restart/day.

**Gap identified:** No alert exists for frequent API server restarts. `KubeApiserverFrequentRestarts` to be added in Phase 4.28.

### Key Decisions

| Decision | Rationale |
|----------|-----------|
| `max()` on all probe stat panels | Prevents stale TSDB series from creating duplicate stat panels when probe targets change |
| `increase($__rate_interval)` for Container Restarts | Cumulative counter misleads at short time ranges; `increase()` shows new restarts per window |
| Expose Prometheus/Alertmanager via HTTPRoute | Needed for Homepage widgets and direct troubleshooting |
| Watchdog excluded from Homepage firing count | `alertname!="Watchdog"` — intentional dead man's switch, always fires |

---

## February 19, 2026 — v0.26.0: Version Automation & Upgrade Runbooks

### Summary

Phase 4.27 — three-tool automated version tracking covering container images, Helm charts, and Kubernetes version. Includes upgrade/rollback runbook for all component types.

### New Components

| Component | Version | Type | Purpose |
|-----------|---------|------|---------|
| version-checker | v0.10.0 | Deployment | Container + K8s version drift → Prometheus metrics |
| Nova CronJob | v3.11.10 | CronJob | Weekly Helm chart drift digest → Discord #versions |
| Renovate Bot | GitHub App | SaaS | Automated image update PRs with dependency dashboard |
| Nova CLI | v3.11.10 | Local binary | On-demand Helm chart analysis |

### Prerequisites Completed

| Image | Before | After |
|-------|--------|-------|
| bazarr | `:latest` | `v1.5.5-ls338` |
| radarr | `:latest` | `6.0.4.10291-ls293` |
| sonarr | `:latest` | `4.0.16.2944-ls303` |
| firefox | `:latest` | `1147.0.3build1-1xtradeb1.2404.1-ls69` |

All pinned images also got `match-regex` version-checker annotations for LinuxServer.io tag format and `imagePullPolicy: IfNotPresent`.

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Renovate over Dependabot | Renovate | Better K8s manifest support, weekly grouping, dependency dashboard |
| version-checker over custom | version-checker | Maintained project, Prometheus-native, includes K8s version tracking |
| `--test-all-containers` | Flag | Scans all pods without annotation opt-in |
| CronJob uses Nova | Nova JSON | Eliminates brittle bash semver parsing and API rate limits |
| Init container for Nova | Copy pattern | Avoids building custom image, CKA-relevant pattern |
| byparr cannot be pinned | Renovate ignore | Only publishes `latest`/`main`/`nightly` tags (no semver) |
| CronJob runs as root | Intentional | Alpine `apk` needs write access to `/lib/apk/db` |
| Nova CLI via tarball | GitHub release | Ubuntu WSL has no brew; installed to `~/.local/bin` |

### Files Created

| File | Purpose |
|------|---------|
| renovate.json | Renovate Bot configuration |
| manifests/monitoring/version-checker-rbac.yaml | ServiceAccount, ClusterRole, ClusterRoleBinding |
| manifests/monitoring/version-checker-deployment.yaml | Deployment + Service (port 8080) |
| manifests/monitoring/version-checker-servicemonitor.yaml | ServiceMonitor (1h scrape) |
| manifests/monitoring/version-checker-alerts.yaml | PrometheusRule (3 alerts) |
| manifests/monitoring/version-checker-dashboard-configmap.yaml | Grafana dashboard |
| manifests/monitoring/version-check-rbac.yaml | CronJob RBAC (secrets read) |
| manifests/monitoring/version-check-script.yaml | CronJob script ConfigMap |
| manifests/monitoring/version-check-cronjob.yaml | CronJob (Sunday 00:00 UTC) |
| docs/context/Upgrades.md | Upgrade/rollback runbook |

### Files Modified

| File | Change |
|------|--------|
| manifests/arr-stack/bazarr/deployment.yaml | Pin image, add match-regex annotation |
| manifests/arr-stack/radarr/deployment.yaml | Pin image, add match-regex annotation |
| manifests/arr-stack/sonarr/deployment.yaml | Pin image, add match-regex annotation |
| manifests/browser/deployment.yaml | Pin image, add match-regex annotation |
| docs/context/_Index.md | Add Upgrades.md to Quick Links |

---

## February 19, 2026 — v0.25.2: ARR Media Quality and Playback Fixes

### Summary

Fixed Italian-default audio in Jellyfin, added language release filtering, expanded Configarr quality profiles for better release availability, and raised minimum seeders to avoid stuck low-seed downloads.

### Bug Fixes

| Issue | Root Cause | Fix |
|-------|-----------|-----|
| Jellyfin defaulting to Italian audio on multi-language releases | Preferred Audio Language not set — Jellyfin respected MKV file's default track flag (Italian) over user preference | Set Preferred Audio Language to `Auto`, Subtitle Mode to `Smart`, Preferred Subtitle Language to `English` in Jellyfin user settings |
| Italian audio releases downloaded by Radarr/Sonarr | No language filtering — Italian-first multi-audio releases (e.g. `iTA-ENG`, CYBER/Licdom release groups) grabbed freely | Added Custom Format "Penalize Italian Dub" (Language = Italian, score -10000) to all quality profiles in both Radarr and Sonarr |
| K-pop Demon Hunters stuck on Italian 4K release | Movie assigned to unmanaged 4K profile, no replacement found at -10000 score | Changed quality profile to "HD Bluray + WEB", grabbed `KPop.Demon.Hunters.2025.1080p.WEB.h264-EDITH` |
| Mercy grabbed Italian release | `Mercy.2026.iTA-ENG.WEBDL.1080p.x264-CYBER.mkv` was the only available release | Penalize Italian Dub CF scored it -10000, triggered automatic search, grabbed `Mercy.Sotto.Accusa.2026.1080p.AMZN.WEB-DL.DDP5.1.H.264-FHC_CREW` |
| Konosuba episodes stuck downloading (<5 seeds) | minimumSeeders was 1 on all indexers — Sonarr grabbed the first available release regardless of seed count | Raised minimumSeeders from 1 → 10 on all Sonarr and Radarr indexers via API |
| No 4K quality profile in Radarr | Configarr only synced `radarr-quality-profile-hd-bluray-web` (1080p) | Added `radarr-quality-profile-uhd-bluray-web` + `radarr-custom-formats-uhd-bluray-web` templates to Configarr |
| Sonarr WEB-only releases (no BluRay sources) | Configarr only synced `sonarr-v4-quality-profile-web-1080p` | Added `sonarr-v4-quality-profile-hd-bluray-web` + `sonarr-v4-custom-formats-hd-bluray-web` templates to Configarr |

### Configuration Changes

| App | Setting | Before | After |
|-----|---------|--------|-------|
| Jellyfin | Preferred Audio Language | English | Auto (uses file default) |
| Jellyfin | Subtitle Mode | Default | Smart |
| Jellyfin | Preferred Subtitle Language | — | English |
| Radarr + Sonarr | All indexers minimumSeeders | 1 | 10 |
| Radarr | Quality profiles | HD Bluray + WEB only | + UHD Bluray + WEB |
| Sonarr | Quality profiles | WEB-1080p only | + HD Bluray + WEB |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Jellyfin audio preference | `Auto` (not `English`) | "English" would force English dub on Korean/Japanese movies; `Auto` respects original language when file is correctly flagged |
| Subtitle mode | `Smart` | Shows English subs only when audio is non-English — no subs on English content, subs on Korean/Japanese automatically |
| Language filter approach | Custom Format -10000 (not hard restriction) | Allows fallback to Italian release if no alternative exists; just heavily penalizes |
| minimumSeeders | 10 | Filters out sub-5-seed stuck torrents while still allowing niche content with moderate seeding |
| minimumSeeders set via API | Bulk API update | "Minimum Seeders" is a hidden field (requires "Show hidden" in UI) — API faster than editing 8 indexers manually |
| Configarr Custom Format scores | Manual per new profile | Configarr manages TRaSH CF scores but not user-added CFs — must manually set -10000 on each new profile Configarr creates |

### Files Modified

| File | Change |
|------|--------|
| manifests/arr-stack/configarr/configmap.yaml | Added UHD Bluray + WEB profile for Radarr; added HD Bluray + WEB profile for Sonarr |

---

## February 18, 2026 — v0.25.1: ARR Alert and Byparr Fixes

### Bug Fixes

| Issue | Root Cause | Fix |
|-------|-----------|-----|
| RadarrQueueStalled false positive (permanently firing) | Alert used `changes(radarr_movies_total[2h])` which tracks library size, not downloads — metric almost never changes | Rewrite to `radarr_queue_count > 0 and changes(radarr_missing_movies_total[2h]) == 0` — only fires when queue items exist but aren't completing |
| SonarrQueueStalled false positive (same issue) | Same flawed pattern using `sonarr_episodes_total` | Same fix using `sonarr_queue_count` and `sonarr_missing_episodes_total` |
| Byparr restart loop (16 restarts in 14h) | Liveness probe `/health` runs Playwright browser page load; 10s timeout too short when browser busy with real requests | Relaxed probe: 30s timeout, 60s period, 5 failures (5min grace vs 90s) |

### Files Modified

| File | Change |
|------|--------|
| manifests/monitoring/arr-alerts.yaml | Rewrite SonarrQueueStalled + RadarrQueueStalled expressions |
| manifests/arr-stack/byparr/deployment.yaml | Relax liveness probe timing |

---

## February 18, 2026 — Phase 4.26: ARR Companions

### Milestone: Complete Media Automation Platform

Deployed 7 companion apps to the ARR media stack: Seerr (media requests + discovery), Configarr (TRaSH Guide quality sync), Unpackerr (RAR extraction), Scraparr (Prometheus metrics), Tdarr (QSV library transcoding), Recommendarr (AI recommendations via Ollama), and Byparr (Cloudflare bypass for Prowlarr indexers). Added Grafana dashboards, alert rules, Homepage redesign, Discord notifications, and import list configuration.

| App | Version | Type | Purpose |
|-----|---------|------|---------|
| Seerr | v3.0.1 | Deployment | Media requests + discovery (replaces Jellyseerr/Overseerr) |
| Configarr | 1.20.0 | CronJob | TRaSH Guide quality profile sync (daily 3AM) |
| Unpackerr | v0.14.5 | Deployment | RAR archive extraction daemon |
| Scraparr | 3.0.3 | Deployment | Prometheus metrics exporter for all *ARR apps |
| Tdarr | 2.58.02 | Deployment | Library transcoding with Intel QSV (internal node) |
| Recommendarr | v1.4.4 | Deployment | AI recommendations via Ollama (qwen2.5:3b) |
| Byparr | latest (v2.1.0) | Deployment | Cloudflare bypass proxy (Camoufox/Firefox) |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Media requests | Seerr (not Overseerr/Jellyseerr) | Overseerr archived Feb 2026, Jellyseerr merged into Seerr |
| Quality sync | Configarr (not Recyclarr/Notifiarr) | Native K8s CronJob, no sidecar, Notifiarr is paid |
| Metrics exporter | Scraparr (not Exportarr) | Single deployment monitors all *ARR apps |
| Library transcoding | Tdarr (not manual) | QSV available on all nodes since Phase 4.25b |
| AI recommendations | Recommendarr | Reuses existing Ollama in `ai` namespace |
| Cloudflare bypass | Byparr (not FlareSolverr) | FlareSolverr dead, Byparr is active Camoufox replacement |
| Seeding policy | Ratio 0, auto-remove | NAS has single NVMe, no space for seeding |
| Import lists | TMDB Popular + Trakt Popular + AniList | MDBList skipped (user cancelled streaming subscriptions) |

### Integration Highlights

- **Homepage redesign:** 2-tab layout (Dashboard + Infrastructure), Seerr/Tdarr/Recommendarr widgets, Sonarr/Radarr calendar (agenda view)
- **Discord `#arr` channel:** Sonarr/Radarr webhook notifications (grab, import, health events)
- **NetworkPolicy:** arr-stack → ai namespace egress for Recommendarr → Ollama
- **NFS hardening:** Jellyfin mount set to `readOnly: true`
- **Tdarr QSV:** hevc_qsv encoding, 0.8 bitrate modifier, 2AM-8AM schedule, soft anti-affinity with Jellyfin

### Grafana Dashboards

| Dashboard | Purpose |
|-----------|---------|
| Scraparr ARR Metrics | Library size, queues, missing content, health per app |
| Network Throughput | 1GbE NIC utilization, saturation analysis (2.5GbE upgrade decision) |
| ARR Stack (updated) | Added companion app Pod Status panels + CPU/Memory queries |

### Files Added

| File | Purpose |
|------|---------|
| manifests/arr-stack/seerr/{deployment,service,httproute}.yaml | Seerr media requests |
| manifests/arr-stack/configarr/{cronjob,configmap}.yaml | Configarr TRaSH sync |
| manifests/arr-stack/unpackerr/deployment.yaml | Unpackerr extraction daemon |
| manifests/arr-stack/scraparr/{deployment,service,servicemonitor}.yaml | Scraparr metrics |
| manifests/arr-stack/tdarr/{deployment,service,httproute}.yaml | Tdarr transcoding |
| manifests/arr-stack/recommendarr/{deployment,service,httproute}.yaml | Recommendarr AI |
| manifests/arr-stack/byparr/{deployment,service}.yaml | Byparr Cloudflare bypass |
| manifests/monitoring/scraparr-dashboard-configmap.yaml | Scraparr Grafana dashboard |
| manifests/monitoring/network-dashboard-configmap.yaml | Network throughput dashboard |
| manifests/monitoring/arr-alerts.yaml | ARR PrometheusRule alerts |

### Files Modified

| File | Change |
|------|--------|
| manifests/arr-stack/networkpolicy.yaml | Added egress to ai namespace (Ollama port 11434) |
| manifests/ai/networkpolicy.yaml | Added ingress from arr-stack namespace |
| manifests/arr-stack/jellyfin/deployment.yaml | NFS mount set to readOnly |
| manifests/arr-stack/arr-api-keys-secret.yaml | Added TDARR_API_KEY field |
| scripts/apply-arr-secrets.sh | Added Tdarr API key injection |
| manifests/home/homepage/config/services.yaml | 2-tab redesign, companion widgets, calendar |
| manifests/home/homepage/config/settings.yaml | New layout with Calendar row |
| manifests/home/homepage/secret.yaml | Added SEERR_API_KEY to docs |
| manifests/monitoring/arr-stack-dashboard-configmap.yaml | Added companion pod status panels |

---

## February 17, 2026 — Phase 4.25b: Intel QSV Hardware Transcoding

### Milestone: GPU-Accelerated Media Streaming

Enabled Intel Quick Sync Video (QSV) hardware transcoding on all 3 cluster nodes for Jellyfin. Mobile streaming now transcodes via the UHD 630 iGPU with near-zero CPU impact. Deployed Node Feature Discovery, Intel Device Plugins Operator, and GPU Plugin to manage GPU resources through the Kubernetes device plugin API.

| Component | Version | Namespace | Status |
|-----------|---------|-----------|--------|
| Node Feature Discovery | 0.18.3 | node-feature-discovery | Running |
| Intel Device Plugins Operator | 0.34.1 | intel-device-plugins | Running |
| Intel GPU Plugin | 0.34.1 | intel-device-plugins | Running (DaemonSet) |
| intel-media-va-driver-non-free | 24.1.0 | (node packages) | Installed |

### Codec Support (UHD 630 / Comet Lake)

| Codec | HW Decode | HW Encode | Notes |
|-------|-----------|-----------|-------|
| H.264 8-bit | Yes | Yes | Most common format |
| HEVC 8/10-bit | Yes | Yes | Low-power encode via HuC firmware |
| VP9 8/10-bit | Yes | No | Decode only on Comet Lake |
| MPEG-2 | Yes | Yes | Legacy format |
| AV1 | No | No | Requires 11th gen+ |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| HW transcoding | Intel QSV (VA-API) | Built into existing CPUs, best quality-per-watt |
| Device access | Intel Device Plugin | PSS compatible, no privileged containers, proper scheduling |
| Node labeling | Node Feature Discovery | Auto-detects GPU, standard K8s ecosystem tool |
| GPU sharing | sharedDevNum: 3 | Allow 3 pods per node to share iGPU |
| HuC firmware | enable_guc=2 | Required for HEVC low-power encode on Comet Lake |
| Transcode cache | Disk-backed emptyDir | Avoids OOM/node crash risk vs tmpfs |
| Tone mapping | VPP (not OpenCL) | OpenCL broken in Jellyfin 10.11.x (#15576) |
| Ansible rolling reboot | serial: 1 | One node at a time, verify all gates before proceeding |

### Grafana Dashboards

| Dashboard | Panels | Highlights |
|-----------|--------|------------|
| Jellyfin Media Server | 11 | GPU allocation, Transcode I/O, Tailscale tunnel traffic |
| ARR Media Stack | 11 | All 6 services overview, merged Pod Status + node placement |

### Files Added

| File | Purpose |
|------|---------|
| ansible/playbooks/08-intel-gpu.yml | Intel GPU drivers + HuC firmware (rolling reboot) |
| helm/intel-gpu-plugin/values.yaml | Intel GPU Plugin configuration |
| manifests/monitoring/jellyfin-dashboard-configmap.yaml | Jellyfin + GPU Grafana dashboard |
| manifests/monitoring/arr-stack-dashboard-configmap.yaml | ARR Stack overview Grafana dashboard |

### Files Modified

| File | Change |
|------|--------|
| manifests/arr-stack/jellyfin/deployment.yaml | GPU resource, supplementalGroups, transcode emptyDir, 4Gi memory |

### Issues Discovered

| Issue | Impact | Fix |
|-------|--------|-----|
| Intel GPU Plugin inotify exhaustion (#2075) | Pod CrashLoopBackOff | `fs.inotify.max_user_instances=512` on all nodes |
| OPNsense stale firewall states after reboot | Cross-VLAN SSH blocked | Manual state clearing (documented for Phase 5 hardening) |
| Ansible `serial` resolves task names at parse time | Misleading task output | Use static task names, Ansible already prefixes with host |
| M80q BIOS POST takes 5-7 min | Ansible reboot timeout too short | Increased `reboot_timeout` to 600s |

---

## February 16, 2026 — Phase 4.25: ARR Media Stack

### Milestone: Self-Hosted Media Automation Platform

Deployed 6-app ARR media automation stack to `arr-stack` namespace: Prowlarr (indexer manager), Sonarr (TV), Radarr (movies), qBittorrent (download client), Jellyfin (media server), and Bazarr (subtitles). All apps share a single NFS PV mounted at `/data` for hardlink support between downloads and media library. App config stored on Longhorn PVCs (2-5Gi each) for fast I/O and HA.

| Component | Version | Image | Status |
|-----------|---------|-------|--------|
| Prowlarr | 2.3.0 | lscr.io/linuxserver/prowlarr:2.3.0 | Running |
| Sonarr | latest | lscr.io/linuxserver/sonarr:latest | Running |
| Radarr | latest | lscr.io/linuxserver/radarr:latest | Running |
| qBittorrent | 5.1.4 | lscr.io/linuxserver/qbittorrent:5.1.4 | Running |
| Jellyfin | 10.11.6 | jellyfin/jellyfin:10.11.6 | Running |
| Bazarr | latest | lscr.io/linuxserver/bazarr:latest | Running |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Namespace | `arr-stack` (not `media`) | `media` too generic — Immich is also media |
| Media storage | NFS on OMV NAS | Hardlinks require single filesystem; NAS has 2TB NVMe |
| Config storage | Longhorn PVCs | Fast SQLite I/O, 2x replicated, off the single-drive NAS |
| NFS mount | Single PV/PVC at `/data` for all pods | Required for hardlinks between torrents/ and media/ |
| Jellyfin image | Official (not LSIO) | Bundles jellyfin-ffmpeg with Intel iHD driver for QSV (Phase 4.25b). Also meets PSS restricted (no root) |
| LSIO apps | s6-overlay v3 with PUID/PGID | Requires CHOWN+SETUID+SETGID capabilities, runs as root |
| Sonarr/Radarr/Bazarr tags | `:latest` with `imagePullPolicy: Always` | Rapid release cycle, LSIO rebuilds frequently |
| Seeding | Disabled (ratio 0, Stop torrent) | NAS has single NVMe — preserve TBW |
| Subtitle provider | OpenSubtitles.com + Podnapisi | Free accounts, public providers |
| Prowlarr indexers | EZTV, YTS, Nyaa.si | All public, no account. Skipped: 1337x (Cloudflare blocks), TheRARBG (removed from Prowlarr) |
| Jellyfin Connect | Radarr + Sonarr → Jellyfin | Auto library scan on import (instead of 12h schedule) |

### Files Added

| File | Purpose |
|------|---------|
| manifests/arr-stack/namespace.yaml | Namespace (PSS baseline enforce, restricted audit/warn) |
| manifests/arr-stack/nfs-pv-pvc.yaml | NFS PV/PVC for shared media storage |
| manifests/arr-stack/networkpolicy.yaml | CiliumNetworkPolicy (intra-namespace, gateway, monitoring, NFS) |
| manifests/arr-stack/arr-api-keys-secret.yaml | Shared API keys placeholder for Phase 4.26 companions |
| manifests/arr-stack/prowlarr/ | Deployment, Service, HTTPRoute |
| manifests/arr-stack/sonarr/ | Deployment, Service, HTTPRoute |
| manifests/arr-stack/radarr/ | Deployment, Service, HTTPRoute |
| manifests/arr-stack/qbittorrent/ | Deployment, Service, HTTPRoute |
| manifests/arr-stack/jellyfin/ | Deployment, Service, HTTPRoute |
| manifests/arr-stack/bazarr/ | Deployment, Service, HTTPRoute |
| scripts/apply-arr-secrets.sh | 1Password → K8s Secret injection script |

### Files Modified

| File | Change |
|------|--------|
| manifests/home/homepage/config/services.yaml | Added Media section with 6 ARR widgets |
| .gitignore | Un-ignored apply-arr-secrets.sh and arr-api-keys-secret.yaml |
| CLAUDE.md | Added 1Password CLI limitation note |

### Critical Gotchas Discovered

1. **qBittorrent Torrent Management Mode** — Must be set to `Automatic` (not `Manual`) for category-based save paths to work. Default `Manual` saves to `/downloads` which doesn't exist in the container.
2. **qBittorrent CSRF on HTTP API** — Health endpoint returns 403 due to CSRF protection. Use `tcpSocket` probes on port 8080, not `httpGet`.
3. **Seeding disabled = no hardlinks** — With ratio 0 + "Remove Completed Downloads" in Radarr, source is deleted after import. File has link count 1 (effectively a move, not a hardlink). Expected behavior when seeding is disabled.
4. **Jellyfin no auto-scan on NFS** — NFS doesn't support inotify. Must add Jellyfin Connect integration in Radarr/Sonarr (Settings → Connect → Emby/Jellyfin) for automatic library refresh on import.
5. **NetworkPolicy blocks Uptime Kuma** — Internal K8s service URLs timeout from uptime-kuma namespace. Use HTTPS URLs with 403 accepted status codes for monitoring.
6. **`kubectl-homelab` alias unavailable in bash scripts** — Alias is zsh-only. Scripts must use `kubectl --kubeconfig ${HOME}/.kube/homelab.yaml`.
7. **1GbE NIC bottleneck** — K8s nodes have 1GbE NICs, NAS has 2.5GbE. Download speeds may be limited by node NIC (investigation deferred to Phase 4.26).

### 1Password Items

| Item | Vault | Fields |
|------|-------|--------|
| ARR Stack | Kubernetes | username, password, prowlarr-api-key, sonarr-api-key, radarr-api-key, bazarr-api-key, jellyfin-api-key |
| Opensubtitles | Kubernetes | username, user[password_confirmation] |

---

## February 13, 2026 — Phase 4.10: Tailscale Operator (Subnet Router)

### Milestone: Secure Remote Access via WireGuard Mesh VPN

Deployed Tailscale Kubernetes Operator v1.94.1 with a Connector CRD that advertises the entire 10.10.30.0/24 subnet to the tailnet. All existing K8s services are now accessible from any Tailscale-connected device (phone, laptop) via WireGuard tunnel — zero per-service manifests needed. AdGuard DNS set as global nameserver for ad-blocking on all tailnet devices.

| Component | Version | Status |
|-----------|---------|--------|
| Tailscale Operator | v1.94.1 | Running (tailscale namespace) |
| Tailscale Proxy (Connector) | v1.94.1 | Running (homelab-subnet, 100.109.196.53) |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Architecture | Connector (subnet router) over per-service Ingress | 1 pod for all services, zero per-service manifests, mirrors old Proxmox Tailscale pattern |
| DNS strategy | Global nameserver (not Split DNS) | All tailnet DNS through AdGuard for ad-blocking + custom rewrites on every device |
| PSS | Privileged enforce | Proxy pods require NET_ADMIN + NET_RAW for WireGuard tunnel (hard requirement) |
| Cilium fix | `socketLB.hostNamespaceOnly: true` | Cilium eBPF socket LB intercepts traffic in proxy pod netns, breaking WireGuard routing |
| Network policy | Operator-only (no connector proxy policy) | CiliumNetworkPolicy filters forwarded/routed packets, breaking subnet routing entirely |
| HTTPS certs | Existing Let's Encrypt (via Cilium Gateway) | Traffic enters through Gateway after subnet route — no Tailscale HTTPS certs needed |
| immich VM | Disabled Tailscale on VM | K8s subnet route (10.10.30.0/24) caused immich VM's Tailscale to intercept LAN traffic |

### Files Added

| File | Purpose |
|------|---------|
| manifests/tailscale/namespace.yaml | tailscale namespace (PSS privileged) |
| manifests/tailscale/connector.yaml | Connector CRD (subnet router, 10.10.30.0/24) |
| manifests/tailscale/networkpolicy.yaml | CiliumNetworkPolicy (operator ingress/egress only) |
| manifests/monitoring/tailscale-alerts.yaml | PrometheusRule (TailscaleConnectorDown, TailscaleOperatorDown) |
| manifests/monitoring/tailscale-dashboard-configmap.yaml | Grafana dashboard (pod status, VPN/pod traffic split by interface, resource usage with request/limit lines) |
| helm/tailscale-operator/values.yaml | Helm values (resources, tags, API proxy disabled) |

### Files Modified

| File | Change |
|------|--------|
| helm/cilium/values.yaml | Added `socketLB.hostNamespaceOnly: true` (Tailscale compatibility) |
| manifests/home/homepage/config/services.yaml | Added Tailscale widget with device status monitoring |

### Critical Gotchas Discovered

1. **Cilium socketLB breaks WireGuard** — Must add `socketLB.hostNamespaceOnly: true` BEFORE installing operator
2. **CiliumNetworkPolicy blocks subnet routing** — Connector forwards packets via IP forwarding; CNP filters forwarded packets, not just pod-originated traffic
3. **Operator uses ClusterIP (10.96.0.1)** — Egress policy needs `toEntities: kube-apiserver`, not CIDR-based node IP rules
4. **`proxyConfig.defaultTags` must be string** — YAML array causes `cannot unmarshal array into Go struct field EnvVar`
5. **immich VM routing conflict** — VM's Tailscale saw K8s subnet route and intercepted LAN traffic (TTL 64→61)
6. **OAuth clients renamed** — Now under `Settings → Trust credentials` in Tailscale admin console
7. **Connector is a StatefulSet, not Deployment** — Alerts/dashboard queries must use `kube_statefulset_status_replicas_ready`, not `kube_deployment_status_replicas_available`

---

## February 12, 2026 — Phase 4.24: Karakeep Migration

### Milestone: Bookmark Manager with AI Tagging

Migrated Karakeep 0.30.0 bookmark manager from Proxmox Docker to Kubernetes. Three-service deployment (Karakeep AIO + Chrome + Meilisearch) connected to Ollama in the `ai` namespace for AI-powered bookmark tagging using qwen2.5:3b (text) and moondream (vision). Migrated 119 bookmarks, 423 tags, and 17 lists from Proxmox using karakeep-cli.

| Component | Version | Status |
|-----------|---------|--------|
| Karakeep | 0.30.0 | Running (karakeep namespace) |
| Chrome | alpine-chrome:124 | Running (headless browser) |
| Meilisearch | v1.13.3 | Running (search engine) |
| qwen2.5:3b | Q4_K_M | Text tagging model (1.9 GB) |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Text model | qwen2.5:3b over qwen3:1.7b | qwen3 thinking mode breaks Ollama structured output ([#10538](https://github.com/ollama/ollama/issues/10538)) |
| Architecture | AIO image (not split web/workers) | SQLite = single writer, no benefit to splitting |
| Database | SQLite (embedded) | No Redis needed — liteque replaces Redis since v0.16.0 |
| Chrome security | `--no-sandbox` + CIDR egress restriction | Standard for containerized Chromium + blocks SSRF to internal networks |
| Crawler timeout | 120s (default 60s) | Content-type check + banner download needs headroom |
| Ollama probes | Widened timeouts (liveness 10s, readiness 5s) | CPU inference saturates cores, HTTP may be slow during active inference |
| Migration | karakeep-cli `migrate` subcommand | Server-to-server API migration preserves all data (bookmarks, tags, lists) |

### Files Added

| File | Purpose |
|------|---------|
| manifests/karakeep/namespace.yaml | karakeep namespace (PSS baseline enforce, restricted warn/audit) |
| manifests/karakeep/karakeep-deployment.yaml | Karakeep AIO Deployment + 2Gi PVC |
| manifests/karakeep/karakeep-service.yaml | ClusterIP on port 3000 |
| manifests/karakeep/httproute.yaml | HTTPRoute for karakeep.k8s.rommelporras.com |
| manifests/karakeep/chrome-deployment.yaml | Headless Chrome Deployment |
| manifests/karakeep/chrome-service.yaml | ClusterIP on port 9222 |
| manifests/karakeep/meilisearch-deployment.yaml | Meilisearch Deployment + 1Gi PVC |
| manifests/karakeep/meilisearch-service.yaml | ClusterIP on port 7700 |
| manifests/karakeep/networkpolicy.yaml | 6 CiliumNetworkPolicies (ingress/egress for all 3 services) |
| manifests/monitoring/karakeep-probe.yaml | Blackbox HTTP probe for /api/health |
| manifests/monitoring/karakeep-alerts.yaml | PrometheusRule (KarakeepDown, KarakeepHighRestarts) |

### Files Modified

| File | Change |
|------|--------|
| manifests/ai/ollama-deployment.yaml | Widened probe timeouts for CPU inference + updated model comment |
| manifests/home/homepage/config/services.yaml | Updated Karakeep widget URL to k8s.rommelporras.com |

### Network Policies (6 CiliumNetworkPolicies)

| Policy | Direction | Rules |
|--------|-----------|-------|
| karakeep-ingress | Ingress | Gateway (reserved:ingress) + host (probes) + monitoring |
| karakeep-egress | Egress | Chrome (9222) + Meilisearch (7700) + Ollama (11434) + external HTTPS + DNS |
| chrome-ingress | Ingress | Karakeep pods + host (probes) |
| chrome-egress | Egress | External internet only (CIDR blocks private networks for SSRF protection) + DNS |
| meilisearch-ingress | Ingress | Karakeep pods + host (probes) |
| meilisearch-egress | Egress | DNS only (defense-in-depth) |

### Lessons Learned

1. **qwen3 + structured output = broken** — Ollama's structured output suppresses the `<think>` token, breaking qwen3 models. Use qwen2.5:3b for Karakeep.
2. **Karakeep needs internet egress** — Content-type checks, banner image downloads, and favicon fetches all require outbound HTTPS from Karakeep pods (not just Chrome).
3. **Ollama probe timeouts matter during inference** — CPU inference saturates all cores (~4000m). HTTP health probes can time out during active inference, causing false restarts. Widened liveness to 10s timeout, readiness to 5s.
4. **karakeep-cli `migrate` needs `-it` flag** — Interactive confirmation prompt requires TTY allocation.
5. **s6-overlay requires root init** — Karakeep AIO uses s6-overlay which needs root during init (manages /run), then drops to app user. `runAsNonRoot: false` with `fsGroup: 0`.

---

## February 11, 2026 — Phase 4.23: Ollama Local AI

### Milestone: CPU-Only LLM Inference Server

Deployed Ollama 0.15.6 for local AI inference, primarily as foundation for Karakeep's AI-powered bookmark tagging (Phase 4.24). All inference runs on CPU (Intel i5-10400T, no GPU).

| Component | Version | Status |
|-----------|---------|--------|
| Ollama | 0.15.6 | Running (ai namespace) |
| qwen3:1.7b | Q4_K_M | Text model (1.4 GB) |
| moondream | Q4_K_M | Vision model (1.7 GB) |
| gemma3:1b | Q4_K_M | Fallback text (0.8 GB) |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Text model | qwen3:1.7b over qwen2.5:3b | Same quality (official Qwen benchmark), half the size, faster |
| Vision model | moondream (1.8B) over llava (7B) | 3x smaller — both loaded = 4.5 GB vs 8.5 GB (critical on 16GB nodes) |
| Quantization | Q4_K_M (Ollama default) | Classification/tagging retains 96-99% accuracy at 4-bit (Red Hat 500K evaluations) |
| Memory limit | 6Gi (not 3Gi) | Ollama mmap's models + kernel page cache fills cgroup — 3Gi caused OOM |
| Network policy | CiliumNetworkPolicy ingress | Only monitoring + karakeep namespaces can reach Ollama |
| Monitoring | Blackbox probe + PrometheusRule | No native /metrics endpoint; 3 alerts (Down, MemoryHigh, HighRestarts) |

### Files Added

| File | Purpose |
|------|---------|
| manifests/ai/namespace.yaml | ai namespace (PSS baseline enforce, restricted warn/audit) |
| manifests/ai/ollama-deployment.yaml | Deployment + 10Gi PVC for model storage |
| manifests/ai/ollama-service.yaml | ClusterIP on port 11434 |
| manifests/ai/networkpolicy.yaml | CiliumNetworkPolicy (ingress from monitoring + karakeep) |
| manifests/monitoring/ollama-probe.yaml | Blackbox HTTP probe (60s interval) |
| manifests/monitoring/ollama-alerts.yaml | 3 PrometheusRule alerts |

---

## February 11, 2026 — Phase 2.1: kube-vip Upgrade + Monitoring

### Milestone: kube-vip v1.0.4 + Prometheus Monitoring

Upgraded kube-vip from v1.0.3 to v1.0.4 across all 3 control plane nodes via rolling upgrade (non-leaders first, leader last). Fixed stalled leader election errors (PRs #1383, #1386) that caused cp3 to spam `Failed to update lock optimistically` every second with 19 container restarts. Added Prometheus monitoring using Headless Service + manual Endpoints + ServiceMonitor pattern (standard for static pods).

| Component | Version | Status |
|-----------|---------|--------|
| kube-vip | v1.0.4 | Running (all 3 nodes) |
| ServiceMonitor | kube-vip | monitoring namespace |
| PrometheusRule | 4 alerts | monitoring namespace |
| Grafana Dashboard | kube-vip VIP Health | ConfigMap auto-provisioned |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Upgrade strategy | Rolling (non-leaders first, leader last) | Maintains VIP availability throughout |
| Monitoring pattern | Headless Service + Endpoints + ServiceMonitor | Standard for static pods (no selector); Endpoints over EndpointSlice because Prometheus Operator uses Endpoints-based discovery |
| Leader monitoring | kube-state-metrics lease metrics | kube-vip has no custom Prometheus metrics; `kube_lease_owner` and `kube_lease_renew_time` provide leader identity |
| Alert routing | Existing convention (critical → #incidents + email, warning → #status) | Consistent with all other monitoring |

### Files Added

| File | Purpose |
|------|---------|
| manifests/monitoring/kube-vip-monitoring.yaml | Headless Service + Endpoints + ServiceMonitor |
| manifests/monitoring/kube-vip-alerts.yaml | PrometheusRule with 4 alerts |
| manifests/monitoring/kube-vip-dashboard-configmap.yaml | Grafana dashboard ConfigMap |

### Files Modified

| File | Change |
|------|--------|
| ansible/group_vars/all.yml | kubevip_version: v1.0.3 → v1.0.4 |

### Alerts

| Alert | Severity | Condition |
|-------|----------|-----------|
| KubeVipInstanceDown | warning | One instance unreachable for 2m |
| KubeVipAllDown | critical | All instances unreachable for 1m |
| KubeVipLeaseStale | critical | Lease not renewed in 30s for 1m |
| KubeVipHighRestarts | warning | >3 restarts in 1h for 5m |

### Lessons Learned

1. **kube-vip has no custom Prometheus metrics** (v1.0.3 and v1.0.4) — only Go runtime + process metrics. Monitor leader election via kube-state-metrics lease metrics instead.
2. **Prometheus Operator uses Endpoints, not EndpointSlice** — K8s 1.33+ deprecates v1 Endpoints, but the deprecation is cosmetic. The API still works and Prometheus Operator requires it for ServiceMonitor discovery.
3. **Optimistic lock errors don't mean VIP is down** — cp3 maintained the VIP despite constant lease update errors. The VIP worked fine; only log noise and wasted API server resources.
4. **Pre-pull images before static pod upgrades** — minimizes VIP downtime window during kubelet pod restart.

---

## February 9, 2026 — Phase 4.21: Containerized Firefox Browser

### Milestone: Persistent Browser Session via KasmVNC

Deployed containerized Firefox accessible from any LAN device via `browser.k8s.rommelporras.com`. Uses KasmVNC for WebSocket-based display streaming — close the tab on one device, open the URL on another, same session. Firefox profile (bookmarks, cookies, extensions, open tabs) persists on Longhorn PVC.

| Component | Version | Status |
|-----------|---------|--------|
| linuxserver/firefox | latest (lscr.io) | Running (browser namespace) |

### Key Decisions

- **`latest` tag instead of pinning** — Browser security patches are frequent; `imagePullPolicy: Always` ensures fresh pulls on restart
- **AdGuard DNS routing** — Pod uses `dnsPolicy: None` with AdGuard primary (10.10.30.53) + failover (10.10.30.54) for ad-blocking and privacy
- **LAN-only access** — NOT exposed via Cloudflare Tunnel (browser session = full machine access to logged-in accounts)
- **TCP probes instead of HTTP** — Basic auth returns 401 on unauthenticated requests, so HTTP probes would always fail
- **Least-privilege capabilities** — `drop: ALL` + add back only CHOWN, SETUID, SETGID, DAC_OVERRIDE, FOWNER (required by LinuxServer s6 init)

### Files Added

| File | Purpose |
|------|---------|
| manifests/browser/namespace.yaml | Browser namespace with baseline PSS (audit/warn restricted) |
| manifests/browser/deployment.yaml | Firefox Deployment with KasmVNC, AdGuard DNS, auth from Secret |
| manifests/browser/pvc.yaml | Longhorn PVC (2Gi) for Firefox profile persistence |
| manifests/browser/service.yaml | ClusterIP Service (port 3000) |
| manifests/browser/httproute.yaml | HTTPRoute for browser.k8s.rommelporras.com |

### Files Modified

| File | Change |
|------|--------|
| manifests/home/homepage/config/services.yaml | Added Firefox Browser to Apps, Uptime Kuma widget to Health section |

---

## February 9, 2026 — Phase 4.12.1: Ghost Web Analytics (Tinybird)

### Milestone: Native Web Analytics for Ghost Blog

Integrated Ghost's cookie-free, privacy-preserving web analytics powered by Tinybird. Deployed TrafficAnalytics proxy (`ghost/traffic-analytics:1.0.72`) that enriches page hit data (user agent parsing, referrer, privacy-preserving signatures) before forwarding to Tinybird's event ingestion API.

| Component | Version | Status |
|-----------|---------|--------|
| TrafficAnalytics | 1.0.72 | Running (ghost-prod namespace) |
| Tinybird | Free tier (us-east-1 AWS) | Active |

### Files Added

| File | Purpose |
|------|---------|
| manifests/ghost-prod/analytics-deployment.yaml | TrafficAnalytics proxy Deployment (Fastify/Node.js) |
| manifests/ghost-prod/analytics-service.yaml | ClusterIP Service for Ghost → TrafficAnalytics |

### Files Modified

| File | Change |
|------|--------|
| manifests/ghost-prod/ghost-deployment.yaml | Added Tinybird env vars (`analytics__*`, `tinybird__*`) using `__` nested config convention |
| manifests/cloudflare/networkpolicy.yaml | Added port 3000 (TrafficAnalytics) to ghost-prod egress rule for cloudflared |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Analytics provider | Tinybird (Ghost native) | Built-in admin dashboard, cookie-free, no additional Grafana dashboards needed |
| Tinybird region | US-East-1 (AWS) | No Asia-Pacific regions available; server pushes to Tinybird (not browser), latency acceptable |
| Proxy memory | 128Mi/256Mi | Container uses ~145MB idle; 128Mi causes OOM kill with zero logs |
| Public hostname | blog-api.rommelporras.com | Ad-blocker-friendly (avoids "analytics", "tracking", "stats" keywords) |
| Subdomain level | Single-level | Cloudflare free SSL covers `*.rommelporras.com` only; two-level (`*.blog.rommelporras.com`) fails TLS |
| Config convention | `tinybird__workspaceId` | Ghost maps `__` to nested config; flat env vars like `TINYBIRD_WORKSPACE_ID` don't work |

### Architecture

```
Browser (ghost-stats.js)
    │ POST page hit
    ▼
blog-api.rommelporras.com (Cloudflare Tunnel)
    │
    ▼
TrafficAnalytics proxy (ghost-prod:3000)
    │ Enriches: user agent, referrer, privacy signatures
    ▼
Tinybird Events API (us-east-1 AWS)
    │
    ▼
Ghost Admin Dashboard (reads Tinybird stats endpoint)
```

### CKA Learnings

| Topic | Concept |
|-------|---------|
| OOM debugging | Zero `kubectl logs` output = container OOM'd before writing stdout |
| Nested env vars | Ghost `__` convention maps `a__b__c` → `config.a.b.c` |
| CiliumNetworkPolicy | New services in existing namespaces need port additions to cloudflared egress |
| Cloudflare Tunnel | Each service needing browser-direct access needs its own public hostname |
| TLS wildcard scope | Free Cloudflare SSL covers one subdomain level only |

### Lessons Learned

1. **OOM kill produces zero logs** — A container that exceeds its memory limit before writing any stdout gives empty `kubectl logs`. Diagnose by running the image locally with `docker stats`.

2. **Ghost `__` config convention** — Ghost maps env vars with double-underscore to nested config objects. `tinybird__workspaceId` → `config.tinybird.workspaceId`. The `web_analytics_configured` field checks `_isValidTinybirdConfig()` which validates these nested values.

3. **Ghost does NOT proxy `/.ghost/analytics/`** — In Docker Compose, Caddy handles this routing. In Kubernetes without a reverse proxy, a separate Cloudflare Tunnel hostname is required for browser-facing POST requests.

4. **Cloudflare free SSL subdomain limit** — Universal SSL covers `*.rommelporras.com` but NOT `*.blog.rommelporras.com`. Two-level subdomains fail TLS handshake.

5. **Ad-blocker-friendly naming** — Browser ad blockers filter subdomains containing "analytics", "tracking", "stats". `blog-api` passes through ad blockers.

6. **CiliumNetworkPolicy port additions** — Adding TrafficAnalytics (port 3000) to ghost-prod required updating the cloudflared egress policy. Without it, Cloudflare Tunnel returned 502.

### 1Password Items

| Item | Vault | Fields |
|------|-------|--------|
| Ghost Tinybird | Kubernetes | workspace-id, admin-token, tracker-token, api-url |

---

## February 8, 2026 — Phase 4.20: MySpeed Migration

### Milestone: Internet Speed Tracker Migrated from Proxmox LXC to Kubernetes

Migrated MySpeed internet speed test tracker from Proxmox LXC (10.10.30.6) to Kubernetes cluster. Fresh start with no data migration — K8s instance builds its own speed test history.

| Component | Version | Status |
|-----------|---------|--------|
| MySpeed | 1.0.9 | Running (home namespace) |

### Files Added

| File | Purpose |
|------|---------|
| manifests/home/myspeed/deployment.yaml | Deployment with security context (seccomp, drop ALL) |
| manifests/home/myspeed/pvc.yaml | Longhorn PVC 1Gi for SQLite data |
| manifests/home/myspeed/service.yaml | ClusterIP Service with named port reference |
| manifests/home/myspeed/httproute.yaml | HTTPRoute for myspeed.k8s.rommelporras.com |

### Files Modified

| File | Change |
|------|--------|
| manifests/home/homepage/config/services.yaml | Updated Speed Test widget from LXC IP to K8s URL |
| manifests/uptime-kuma/networkpolicy.yaml | Added port 5216 to CiliumNetworkPolicy for MySpeed monitoring |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Image registry | Docker Hub (`germannewsmaker/myspeed`) | GHCR (`ghcr.io/gnmyt/myspeed`) returned 403 Forbidden |
| Data migration | Fresh start | SQLite history on LXC during soak period, K8s builds own |
| Security context | Partial restricted PSS | Image requires root — `runAsNonRoot` breaks data folder creation |
| Resource limits | 100m/500m CPU, 128Mi/256Mi memory | Peak observed at 78Mi during speed test |
| Named ports | `http` reference in probes + service | Single source of truth for port number |
| Uptime Kuma monitors | Standardized all to external URLs | Full chain testing (DNS → Gateway → TLS → Service) over internal URLs for consistency |

### CKA Learnings

| Topic | Concept |
|-------|---------|
| PVC access modes | RWO (Longhorn) vs RWX (NFS) — RWO requires Recreate strategy |
| Named ports | Reference `port: http` in probes/services instead of hardcoded numbers |
| Pod Security Standards | Not all images support restricted PSS — apply what you can |
| Kustomize | Homepage uses `-k` flag, not `-f` — `kubectl apply -f` overwrites imperative secrets |
| Resource right-sizing | Use Prometheus `max_over_time()` to measure peak usage before setting limits |

### Lessons Learned

1. **Always verify container registry** — The phase plan listed `ghcr.io/gnmyt/myspeed` but the image is actually on Docker Hub as `germannewsmaker/myspeed`. GHCR returned 403 Forbidden.

2. **runAsNonRoot breaks some images** — MySpeed needs root to create its `/myspeed/data` folder. Keep other security settings (seccomp, drop ALL, no privilege escalation) even when you can't run as non-root.

3. **kubectl apply -f on Kustomize directories overwrites secrets** — Homepage uses Kustomize with `configMapGenerator`. Running `kubectl apply -f` instead of `kubectl apply -k` applied the placeholder `secret.yaml`, overwriting real credentials. This caused all Homepage widgets to fail with 401 errors.

4. **Rate limiting from bad credentials** — When placeholder secrets triggered repeated 401s, AdGuard and OMV rate-limited the Homepage pod IP. Had to wait for lockout expiry and reset failed counters.

5. **Homepage rebuild guide was incomplete** — The v0.6.0 secret creation command was missing fields added in later phases (AdGuard failover, Karakeep, OpenWRT, Glances user). Also had wrong variable names for OPNsense (USER/PASS vs KEY/SECRET).

---

## February 6, 2026 — v0.15.1: Dashboard Fixes and Alert Tuning

### Claude Code Dashboard Query Fixes

Fixed broken PromQL queries for one-time counters (sessions, commits, PRs showed 0) and reorganized dashboard layout. Tuned alert thresholds based on real usage data.

### Dashboard Fixes

| Fix | Problem | Solution |
|-----|---------|----------|
| Sessions/Commits/PRs showing 0 | `increase()` on one-time counters always returns 0 | Use `last_over_time()` with `count by (session_id)` |
| Code Edit Decisions showing 0 | Same one-time counter pattern | Same fix |
| API Error Rate wrong grouping | Grouped by missing `status_code` field | Group by `error` field |
| Avg Session Length denominator | Incorrect calculation | Fixed denominator |

### Layout Changes

- Productivity and Performance sections open by default
- Token & Efficiency section auto-collapsed
- Cost Analysis tables side-by-side (w=8, h=5)

### Alert Threshold Tuning

Previous $25/$50 thresholds triggered on normal daily usage (~$52 avg, ~$78 peak observed).

| Alert | Before | After |
|-------|--------|-------|
| ClaudeCodeHighDailySpend | >$25/day | >$100/day |
| ClaudeCodeCriticalDailySpend | >$50/day | >$150/day |

### Configuration Change

- `OTEL_METRIC_EXPORT_INTERVAL` reduced from 60s to 5s to prevent one-time counter data loss when sessions end before next export

### Files Modified

| File | Change |
|------|--------|
| manifests/monitoring/claude-dashboard-configmap.yaml | Fixed PromQL queries, reorganized panel layout |
| manifests/monitoring/claude-alerts.yaml | Raised cost thresholds ($25/$50 → $100/$150) |

---

## February 5, 2026 — Phase 4.15: Claude Code Monitoring

### Milestone: Centralized Claude Code Telemetry on Kubernetes

Deployed OpenTelemetry Collector to receive Claude Code metrics and events via OTLP, exporting metrics to Prometheus and structured events to Loki. Grafana dashboard and cost alerts auto-provisioned via ConfigMap and PrometheusRule.

| Component | Version | Status |
|-----------|---------|--------|
| OTel Collector (contrib) | v0.144.0 | Running (monitoring namespace) |
| Grafana Dashboard | ConfigMap | 33 panels, 8 sections |
| PrometheusRule | claude-code-alerts | 4 rules (cost, availability) |

### Files Added

| File | Purpose |
|------|---------|
| manifests/monitoring/otel-collector-config.yaml | OTel pipeline config (OTLP → Prometheus + Loki) |
| manifests/monitoring/otel-collector.yaml | Deployment + LoadBalancer Service (VIP 10.10.30.22) |
| manifests/monitoring/otel-collector-servicemonitor.yaml | ServiceMonitor for Prometheus scraping |
| manifests/monitoring/claude-dashboard-configmap.yaml | Grafana dashboard (33 panels, 8 sections) |
| manifests/monitoring/claude-alerts.yaml | PrometheusRule (4 cost/availability alerts) |
| docs/rebuild/v0.15.0-claude-monitoring.md | Rebuild guide |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Service type | LoadBalancer (Cilium L2) | Stable VIP for any machine on trusted VLANs |
| VIP | 10.10.30.22 | Next free in Cilium IP pool |
| OTLP transport | Plain HTTP (no TLS) | Trusted LAN only, telemetry counters not credentials |
| Loki ingestion | Native OTLP (`otlphttp/loki`) | Not deprecated `loki` exporter |
| Alert thresholds | $25 warning, $50 critical | Tuned from real usage data |
| Machine identification | `OTEL_RESOURCE_ATTRIBUTES="machine.name=$HOST"` | Auto-resolves hostname |

### Architecture

```
Client Machines (TRUSTED_WIFI / LAN)
  Claude Code ──OTLP gRPC──→ 10.10.30.22:4317
                                    │
                              OTel Collector
                              ├──→ Prometheus (:8889)
                              └──→ Loki (:3100/otlp)
                                    │
                                 Grafana
                          Claude Code Dashboard
```

### Dashboard Sections (33 panels)

| Section | Panels | Datasource |
|---------|--------|------------|
| Overview | 6 | Prometheus |
| Productivity | 7 | Prometheus |
| Sessions & Activity | 4 | Prometheus |
| Trends | 2 | Prometheus |
| Cost Analysis | 3 | Prometheus |
| Performance (Events) | 2 | Loki |
| Token & Efficiency | 2 | Prometheus |
| Insights | 7 | Mixed |

### Alert Rules

| Alert | Severity | Condition |
|-------|----------|-----------|
| ClaudeCodeHighDailySpend | warning | >$100/day |
| ClaudeCodeCriticalDailySpend | critical | >$150/day |
| ClaudeCodeNoActivity | info | No usage at end of weekday (5-6pm) |
| OTelCollectorDown | critical | Collector unreachable for 2m |

### Security Hardening

OTel Collector fully hardened:
- `runAsNonRoot: true` (UID 10001)
- `readOnlyRootFilesystem: true`
- `allowPrivilegeEscalation: false`
- `capabilities.drop: ALL`
- `seccompProfile: RuntimeDefault`
- `automountServiceAccountToken: false`

### CKA Learnings

| Topic | Concept |
|-------|---------|
| ConfigMap | Dashboard JSON as ConfigMap with Grafana sidecar auto-provisioning |
| ServiceMonitor | Custom scrape targets for non-Helm workloads |
| PrometheusRule | Custom alert rules with PromQL time functions (`hour()`, `day_of_week()`) |
| LoadBalancer | Cilium L2 announcement with `lbipam.cilium.io/ips` annotation |
| Security context | Full pod hardening for non-root OTel Collector |

### Lessons Learned

1. **Loki OTLP native ingestion stores attributes as structured metadata** — Query with `| event_name="api_request"`, not `| json`. The `| json` parser is for unstructured log lines.

2. **OTel Collector memory limit must exceed memory_limiter** — Container limit (600Mi) must be higher than the `memory_limiter` processor setting (512 MiB) or the pod OOM-kills.

3. **OTLP metric names transform in Prometheus** — Dots become underscores, counters get `_total` suffix. Always verify after deployment.

4. **Grafana `joinByLabels` transformation fails with Loki metric queries** — Causes "Value label not found" error. Use bar charts with `sum by` instead of tables with join transformations for Loki data.

5. **One-time counters need `last_over_time()`, not `increase()`** — `session_count`, `commit_count`, and `pull_request_count` increment once and never change, so `increase()` always returns 0. Use `count(count by (session_id) (last_over_time(metric[$__range])))` for counts. Continuously-incrementing counters (cost, tokens, active_time) still use `increase()`.

6. **5s metric export interval prevents data loss** — The default 60s `OTEL_METRIC_EXPORT_INTERVAL` causes one-time counters (commits, PRs, sessions) to be lost if a session ends before the next export. Use 5000ms to match the logs interval.

### Open-Source Project

Dashboard and configs developed in parallel with [claude-code-monitoring](https://github.com/rommelporras/claude-code-monitoring) v2.0.0 (Loki events, updated dashboard, Docker version bumps).

---

## February 5, 2026 — Phase 4.9: Invoicetron Migration

### Milestone: Stateful Application with Database Migrated to Kubernetes

Migrated Invoicetron (Next.js 16 + Bun 1.3.4 + PostgreSQL 18 + Prisma 7.2.0 + Better Auth 1.4.7) from Docker Compose on reverse-mountain VM to Kubernetes. Two environments (dev + prod) with GitLab CI/CD pipeline, Cloudflare Tunnel public access, and Cloudflare Access email OTP protection.

| Component | Version | Status |
|-----------|---------|--------|
| Invoicetron | Next.js 16.1.0 | Running (invoicetron-dev, invoicetron-prod) |
| PostgreSQL | 18-alpine | Running (StatefulSet per environment) |

### Files Added

| File | Purpose |
|------|---------|
| manifests/invoicetron/deployment.yaml | App Deployment + ClusterIP Service |
| manifests/invoicetron/postgresql.yaml | PostgreSQL StatefulSet + headless Service |
| manifests/invoicetron/rbac.yaml | ServiceAccount, Role, RoleBinding for CI/CD |
| manifests/invoicetron/secret.yaml | Placeholder (1Password imperative) |
| manifests/invoicetron/backup-cronjob.yaml | Daily pg_dump CronJob + 2Gi PVC |
| manifests/gateway/routes/invoicetron-dev.yaml | HTTPRoute for dev (internal) |
| manifests/gateway/routes/invoicetron-prod.yaml | HTTPRoute for prod (internal) |

### Files Modified

| File | Change |
|------|--------|
| manifests/cloudflare/networkpolicy.yaml | Added invoicetron-prod egress on port 3000; removed temporary DMZ rule; fixed namespace from `invoicetron` to `invoicetron-prod` |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Per-environment builds | Separate Docker images | NEXT_PUBLIC_APP_URL baked at build time |
| Database passwords | Hex-only (`openssl rand -hex 20`) | Avoid URL-special characters breaking Prisma |
| Registry auth | Deploy token + imagePullSecrets | Private GitLab project = private container registry |
| Migration strategy | K8s Job before deploy | Prisma migrations run as one-shot Job in CI/CD |
| Auth client baseURL | `window.location.origin` fallback | Login works on any URL, not just build-time URL |
| Cloudflare Access | Reused "Allow Admin" policy | Email OTP gate, same policy as Uptime Kuma |
| Backup | Daily CronJob (9 AM, 30-day retention) | ~14MB database, lightweight pg_dump |

### Architecture

```
┌───────────────────────────────────────────────────────────────┐
│            invoicetron-prod namespace                         │
├───────────────────────────────────────────────────────────────┤
│                                                               │
│  PostgreSQL 18         Invoicetron App                        │
│  StatefulSet    ◄────  Deployment (1 replica)                 │
│  (10Gi Longhorn) SQL   Next.js 16 + Bun                      │
│                                                               │
│  Daily:                On deploy:                             │
│  pg_dump CronJob       Prisma Migrate Job                    │
│  → Longhorn PVC                                              │
│                                                               │
│  Secrets: database-url, better-auth-secret (1Password)       │
│  Registry: gitlab-registry imagePullSecret (deploy token)    │
└───────────────────────────────────────────────────────────────┘
```

### CI/CD Pipeline (GitLab)

```
develop → validate → test → build:dev → deploy:dev → verify:dev
main    → validate → test → build:prod → deploy:prod → verify:prod
```

- **validate:** type-check (tsc), lint, security-audit
- **test:** unit tests (vitest on node:22-slim)
- **build:** per-environment Docker image (NEXT_PUBLIC_APP_URL as build-arg)
- **deploy:** Prisma migration Job + kubectl set image
- **verify:** curl health check

### Access

| Environment | Internal URL | Public URL |
|-------------|-------------|------------|
| Dev | invoicetron.dev.k8s.rommelporras.com | — |
| Prod | invoicetron.k8s.rommelporras.com | invoicetron.rommelporras.com (Cloudflare) |

### Cloudflare Access

| Application | Policy | Authentication |
|-------------|--------|----------------|
| Invoicetron | Allow Admin (reused) | Email OTP (2 addresses) |

### CKA Learnings

| Topic | Concept |
|-------|---------|
| StatefulSet | PostgreSQL with volumeClaimTemplates, headless Service |
| Jobs | One-shot Prisma migration Job before deployment |
| CronJobs | Daily pg_dump backup with retention |
| Init containers | wait-for-db pattern with busybox nc |
| imagePullSecrets | Private registry auth with deploy tokens |
| Security context | runAsNonRoot, drop ALL, seccompProfile |
| RollingUpdate | maxSurge: 1, maxUnavailable: 0 |
| CiliumNetworkPolicy | Per-namespace egress with exact namespace names |

### Lessons Learned

1. **Private GitLab projects need imagePullSecrets** — Container registry inherits project visibility. Deploy token with `read_registry` scope + `docker-registry` secret in each namespace.

2. **envFrom injects hyphenated keys** — K8s secret keys like `database-url` become env vars with hyphens. Prisma expects `DATABASE_URL`. Use explicit `env` with `valueFrom.secretKeyRef`, not `envFrom`.

3. **PostgreSQL 18+ mount path** — Mount at `/var/lib/postgresql` (parent), not `/var/lib/postgresql/data`. PG creates the data subdirectory itself.

4. **DATABASE_URL passwords must avoid special chars** — Passwords with `/` break Prisma URL parsing. URL-encoding (`%2F`) works for CLI but not runtime. Use hex-only passwords.

5. **PostgreSQL only reads POSTGRES_PASSWORD on first init** — Changing the secret requires `ALTER USER` inside the running pod.

6. **kubectl apply reverts CI/CD image** — Manifest has placeholder image. CI/CD sets actual image via `kubectl set image`. Applying manifest reverts it. Use `kubectl set env` for runtime changes.

7. **CiliumNetworkPolicy needs exact namespace names** — `invoicetron` ≠ `invoicetron-prod`. Caused 502 through Cloudflare Tunnel until fixed.

8. **Better Auth client baseURL** — Hardcoded `NEXT_PUBLIC_APP_URL` means login only works on that domain. Removing baseURL lets Better Auth use `window.location.origin` automatically. Server-side `ADDITIONAL_TRUSTED_ORIGINS` validates allowed origins.

9. **1Password CLI session scope** — `op read` returns empty if session expired. Always `eval $(op signin)` before creating secrets. Verify secrets after creation.

### 1Password Items

| Item | Vault | Fields |
|------|-------|--------|
| Invoicetron Dev | Kubernetes | postgres-password, better-auth-secret, database-url |
| Invoicetron Prod | Kubernetes | postgres-password, better-auth-secret, database-url |

### DMZ Rule Removed

With both Portfolio and Invoicetron running in K8s, the temporary DMZ rule (`10.10.50.10/32`) in the cloudflared NetworkPolicy has been removed. Security validation: 35 passed, 0 failed.

---

## February 4, 2026 — Cloudflare WAF: RSS Feed Access

### Fix: GitHub Actions Blog RSS Fetch (403)

Added Cloudflare WAF skip rule and disabled Bot Fight Mode to allow the GitHub Profile README blog-post workflow to fetch the Ghost RSS feed from GitHub Actions.

| Component | Change |
|-----------|--------|
| Cloudflare WAF Rule 1 | New: Skip + Super Bot Fight Mode for `/rss/` |
| Cloudflare WAF Rule 2 | Renumbered: Allow `/ghost/api/content` (was Rule 1) |
| Cloudflare WAF Rule 3 | Renumbered: Block `/ghost` paths (was Rule 2) |
| Bot Fight Mode | Disabled globally (Security → Settings) |

### Key Decision

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Bot Fight Mode | Disabled globally | Free Cloudflare tier cannot create path-specific exceptions; blocks all cloud provider IPs including GitHub Actions |

### Lesson Learned

WAF custom rule "Skip all remaining custom rules" does **not** skip Bot Fight Mode — they are separate systems. To skip bot protection for a specific path, you must also check "All Super Bot Fight Mode Rules" in the WAF skip action **and** disable the global Bot Fight Mode toggle.

---

## February 3, 2026 — Phase 4.14: Uptime Kuma Monitoring

### Milestone: Self-hosted Endpoint Monitoring with Public Status Page

Deployed Uptime Kuma v2.0.2 for HTTP(s) endpoint monitoring of personal websites, homelab services, and infrastructure. Public status page exposed via Cloudflare Tunnel with Access policies blocking admin routes. Discord notifications on the #incidents channel.

| Component | Version | Status |
|-----------|---------|--------|
| Uptime Kuma | v2.0.2 (rootless) | Running (uptime-kuma namespace) |

### Files Added

| File | Purpose |
|------|---------|
| manifests/uptime-kuma/namespace.yaml | Namespace with PSS labels (baseline enforce, restricted audit/warn) |
| manifests/uptime-kuma/statefulset.yaml | StatefulSet with volumeClaimTemplates (Longhorn 1Gi) |
| manifests/uptime-kuma/service.yaml | Headless + ClusterIP services on port 3001 |
| manifests/uptime-kuma/httproute.yaml | Gateway API HTTPRoute for `uptime.k8s.rommelporras.com` |
| manifests/uptime-kuma/networkpolicy.yaml | CiliumNetworkPolicy (DNS, internet HTTPS, cluster-internal, home network) |
| manifests/monitoring/uptime-kuma-probe.yaml | Blackbox HTTP probe for Prometheus |
| docs/rebuild/v0.13.0-uptime-kuma.md | Full rebuild guide |

### Files Modified

| File | Change |
|------|--------|
| manifests/cloudflare/networkpolicy.yaml | Added uptime-kuma namespace egress on port 3001 |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Workload type | StatefulSet | Stable identity + persistent SQLite storage |
| Image variant | rootless (not slim-rootless) | Includes Chromium for browser-engine monitors |
| Database | SQLite | Single-instance, no external DB dependency |
| Storage | volumeClaimTemplates (1Gi) | Auto-creates PVC per pod, no separate manifest |
| Public access | Cloudflare Tunnel + block-admin | SPA-compatible; block `/dashboard`, `/manage-status-page`, `/settings` |
| Notifications | Reuse #incidents channel | Unified incident channel, no channel sprawl |
| Monitor retries | 1 for public/prod, 3 for internal/dev | Faster alerting for critical services |

### Architecture

```
uptime-kuma namespace
┌───────────────────────────────────┐
│ StatefulSet (1 replica)           │
│ - Image: 2.0.2-rootless           │
│ - SQLite on Longhorn PVC (1Gi)   │
│ - Non-root (UID 1000)            │
└───────────────┬───────────────────┘
                │
     ┌──────────┼──────────┐
     │          │          │
  Headless   ClusterIP   HTTPRoute
  Service    Service     uptime.k8s.rommelporras.com
                          │
               Cloudflare Tunnel
               status.rommelporras.com/status/homelab
```

### Access

| Environment | URL | Access |
|-------------|-----|--------|
| Admin | https://uptime.k8s.rommelporras.com | Internal (HTTPRoute) |
| Status Page | https://status.rommelporras.com/status/homelab | Public (Cloudflare Tunnel) |

### Monitors Configured

| Group | Monitors |
|-------|----------|
| Website | rommelporras.com, beta.rommelporras.com (Staging), Blog Prod, Blog Dev |
| Apps | Grafana, Homepage Dashboard, Longhorn Storage, Immich, Karakeep, MySpeed, Homepage (Proxmox) |
| Infrastructure | Proxmox PVE, Proxmox Firewall, OPNsense, OpenMediaVault, NAS Glances |
| DNS | AdGuard Primary, AdGuard Failover |

Tags: Kubernetes (Blue), Proxmox (Orange), Network (Purple), Storage (Pink), Public (Green)

### Cloudflare Access (Block Admin)

| Path | Action |
|------|--------|
| `status.rommelporras.com/dashboard` | Blocked (Everyone) |
| `status.rommelporras.com/manage-status-page` | Blocked (Everyone) |
| `status.rommelporras.com/settings` | Blocked (Everyone) |
| `status.rommelporras.com/status/homelab` | Public (no policy) |

### CKA Learnings

| Topic | Concept |
|-------|---------|
| StatefulSet | volumeClaimTemplates auto-create PVCs, headless Service for stable DNS |
| CiliumNetworkPolicy | Uses pod ports not service ports; private IP exclusion requires explicit toCIDR for home network |
| Gateway API | HTTPRoute sectionName for listener selection |
| Cloudflare Access | Block-admin simpler than allowlist for SPAs (JS/CSS/API paths) |
| Hairpin routing | Cilium Gateway returns 403 for pod-to-VIP-to-pod traffic |

### Lessons Learned

1. **StatefulSet vs Deployment for SQLite** — StatefulSet provides stable pod identity (`uptime-kuma-0`) and volumeClaimTemplates auto-create PVCs. No separate PVC manifest needed.

2. **CiliumNetworkPolicy uses pod ports, not service ports** — A service mapping port 80→3000 requires the network policy to allow port 3000 (the pod port). Service port abstraction doesn't apply at the CNI level.

3. **Private IP exclusion blocks home network** — `toCIDRSet` with `except: 10.0.0.0/8` blocks home network devices (AdGuard failover, OPNsense, NAS). Must add explicit `toCIDR` rules for specific IPs.

4. **Hairpin routing with Cilium Gateway** — Pods accessing their own service via the Gateway VIP (pod→VIP→pod) get 403. Use internal service URLs for self-monitoring or accept the limitation.

5. **Cloudflare Access: block-admin > allowlist for SPAs** — Allowlisting only `/status/homelab` blocks JS/CSS/API paths the SPA needs. Blocking only admin paths (`/dashboard`, `/manage-status-page`, `/settings`) is simpler and SPA-compatible.

6. **rootless vs slim-rootless** — The `rootless` image includes Chromium for browser-engine monitors (real browser rendering checks). `slim-rootless` saves ~200MB but loses this capability. Memory limits need bumping (256Mi→768Mi).

7. **HTTPRoute BackendNotFound timing issue** — Cilium Gateway controller may report `Service "uptime-kuma" not found` even when the service exists. Delete and re-apply the HTTPRoute to force re-reconciliation.

8. **Cloudflare Zero Trust requires payment method** — Even the free plan ($0/month, 50 seats) requires a credit card or PayPal for identity verification. Standard anti-abuse measure.

### 1Password Items

| Item | Vault | Fields |
|------|-------|--------|
| Uptime Kuma | Kubernetes | username, password, website |

---

## February 2, 2026 — Phase 4.13: Domain Migration

### Milestone: Corporate-Style Domain Hierarchy

Migrated all Kubernetes services from `*.k8s.home.rommelporras.com` to a tiered domain scheme under `*.k8s.rommelporras.com`. Introduced corporate-style environment tiers (base, dev, stg) with scoped wildcard TLS certificates.

| Component | Change |
|-----------|--------|
| Gateway | 3 HTTPS listeners (base, dev, stg) with scoped wildcards |
| TLS | 3 wildcard certs via cert-manager DNS-01 |
| API Server | New SAN `api.k8s.rommelporras.com` on all 3 nodes |
| DNS (K8s AdGuard) | New rewrites for all tiers + node hostnames |
| DNS (Failover LXC) | Matching rewrites for failover safety |

### Domain Scheme

| Tier | Wildcard | Purpose |
|------|----------|---------|
| Base | `*.k8s.rommelporras.com` | Infrastructure + production |
| Dev | `*.dev.k8s.rommelporras.com` | Development environments |
| Stg | `*.stg.k8s.rommelporras.com` | Staging environments |

### Service Migration

| Service | Old Domain | New Domain |
|---------|-----------|------------|
| Homepage | portal.k8s.home.rommelporras.com | portal.k8s.rommelporras.com |
| Grafana | grafana.k8s.home.rommelporras.com | grafana.k8s.rommelporras.com |
| GitLab | gitlab.k8s.home.rommelporras.com | gitlab.k8s.rommelporras.com |
| Registry | registry.k8s.home.rommelporras.com | registry.k8s.rommelporras.com |
| Blog Prod | blog.k8s.home.rommelporras.com | blog.k8s.rommelporras.com |
| Blog Dev | blog-dev.k8s.home.rommelporras.com | blog.dev.k8s.rommelporras.com |
| Portfolio Prod | portfolio-prod.k8s.home.rommelporras.com | portfolio.k8s.rommelporras.com |
| Portfolio Dev | portfolio-dev.k8s.home.rommelporras.com | portfolio.dev.k8s.rommelporras.com |
| Portfolio Stg | portfolio-staging.k8s.home.rommelporras.com | portfolio.stg.k8s.rommelporras.com |
| K8s API | k8s-api.home.rommelporras.com | api.k8s.rommelporras.com |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Tier convention | prod=default, non-prod=qualified | Corporate pattern: `blog.k8s` is prod, `blog.dev.k8s` is dev |
| Wildcard scope | Per-tier wildcards | `*.k8s`, `*.dev.k8s`, `*.stg.k8s` — no broad `*.rommelporras.com` |
| Legacy boundary | `*.home.rommelporras.com` untouched | Proxmox, OPNsense, OMV stay on NPM |
| Node hostnames | `cp{1,2,3}.k8s.rommelporras.com` | Hierarchical, consistent with service naming |
| API hostname | `api.k8s.rommelporras.com` | Short, follows corporate convention |

### Lessons Learned

1. **kubeadm `certs renew` does NOT add new SANs** — It only renews expiration, reusing existing SANs. To add a new SAN: delete the cert+key, then run `kubeadm init phase certs apiserver --config /path/to/config.yaml`.

2. **Local kubeadm config takes priority over ConfigMap** — If `/etc/kubernetes/kubeadm-config.yaml` exists on a node, `kubeadm init phase certs` uses it instead of the kube-system ConfigMap. Must update (or create) the local file on each node.

3. **AdGuard configmap is only an init template** — The init container copies config to PVC only on first boot (`if [ ! -f ... ]`). Runtime changes must be made via web UI. Configmap should still be updated as rebuild source of truth.

4. **RWO PVC + RollingUpdate = deadlock** — Grafana's Longhorn RWO volume caused a stuck rollout: new pod scheduled on different node couldn't attach the volume, old pod couldn't terminate (rolling update). Fix: scale to 0 then back to 1.

5. **Gateway API multi-listener migration pattern** — Add new listeners alongside old ones, switch HTTPRoutes to new listeners, verify, then remove old listeners in cleanup phase. Zero-downtime migration.

### CKA Learnings

| Topic | Concept |
|-------|---------|
| Gateway API | Multi-listener pattern, scoped wildcards, sectionName routing |
| cert-manager | Automatic Certificate creation from Gateway annotations, DNS-01 challenges |
| kubeadm | certSANs management, cert regeneration vs renewal, ConfigMap vs local config |
| TLS | Wildcard scope (one subdomain level only), multi-cert Gateway |

### Files Modified

| Category | Files |
|----------|-------|
| Gateway | manifests/gateway/homelab-gateway.yaml |
| HTTPRoutes (8) | gitlab, gitlab-registry, portfolio-prod, ghost-prod, longhorn, adguard, homepage, grafana |
| HTTPRoutes (3) | portfolio-dev, portfolio-staging, ghost-dev |
| Helm | gitlab/values.yaml, gitlab-runner/values.yaml, prometheus/values.yaml |
| Manifests | portfolio/deployment.yaml, ghost-dev/ghost-deployment.yaml, homepage/deployment.yaml |
| Config | homepage/config/services.yaml, homepage/config/settings.yaml |
| DNS | home/adguard/configmap.yaml |
| Scripts | scripts/sync-ghost-prod-to-dev.sh |
| Ansible | group_vars/all.yml, group_vars/control_plane.yml |

---

## January 31, 2026 — Phase 4.12: Ghost Blog Platform

### Milestone: Self-hosted Ghost CMS with Dev/Prod Environments

Deployed Ghost 6.14.0 blog platform with MySQL 8.4.8 LTS backend in two environments (ghost-dev, ghost-prod). Includes database sync scripts for prod-to-dev and prod-to-local workflows.

| Component | Version | Status |
|-----------|---------|--------|
| Ghost | 6.14.0 | Running (ghost-dev, ghost-prod) |
| MySQL | 8.4.8 LTS | Running (StatefulSet per environment) |

### Files Added

| File | Purpose |
|------|---------|
| manifests/ghost-dev/namespace.yaml | Dev namespace with PSA labels |
| manifests/ghost-dev/secret.yaml | Placeholder (1Password imperative) |
| manifests/ghost-dev/mysql-statefulset.yaml | MySQL StatefulSet with Longhorn 10Gi |
| manifests/ghost-dev/mysql-service.yaml | Headless Service for MySQL DNS |
| manifests/ghost-dev/ghost-pvc.yaml | Ghost content PVC (Longhorn 5Gi) |
| manifests/ghost-dev/ghost-deployment.yaml | Ghost Deployment with init container |
| manifests/ghost-dev/ghost-service.yaml | ClusterIP Service for Ghost |
| manifests/ghost-dev/httproute.yaml | Gateway API route (internal) |
| manifests/ghost-prod/* | Same structure for production |
| scripts/sync-ghost-prod-to-dev.sh | Database + content sync utility |
| scripts/sync-ghost-prod-to-local.sh | Prod database to local docker-compose |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Ghost version | 6.14.0 (Debian) | glibc compatibility, Sharp image library |
| MySQL version | 8.4.8 LTS | 5yr premier support, 8.0.x EOL April 2026 |
| Character set | utf8mb4 | Full unicode/emoji support in blog posts |
| Deployment strategy | Recreate | RWO PVC cannot be mounted by two pods |
| Gateway parentRefs | namespace: default | Corrected from plan (was kube-system) |
| MySQL security | No container restrictions | Entrypoint requires root (chown, gosu) |
| Ghost security | runAsNonRoot, uid 1000 | Full hardening with drop ALL capabilities |
| Mail config | Reused iCloud SMTP | Same app-specific password as Alertmanager |

### Access

| Environment | Internal URL | Public URL |
|-------------|-------------|------------|
| Dev | blog-dev.k8s.home.rommelporras.com | — |
| Prod | blog.k8s.home.rommelporras.com | blog.rommelporras.com (Cloudflare) |

### Public Access & Security (February 1)

Configured Cloudflare Tunnel for public access and WAF custom rules to protect the Ghost admin panel.

| Component | Change |
|-----------|--------|
| Cloudflare Tunnel | Added `blog.rommelporras.com` → `http://ghost.ghost-prod.svc.cluster.local:2368` |
| CiliumNetworkPolicy | Added ghost-prod:2368 egress rule for cloudflared |
| Cloudflare WAF Rule 1 | Skip: Allow `/rss/` (public RSS feed for GitHub Actions blog-post workflow) |
| Cloudflare WAF Rule 2 | Skip: Allow `/ghost/api/content` (public Content API for search) |
| Cloudflare WAF Rule 3 | Block: All other `/ghost` paths (admin panel, Admin API) |

### Files Modified

| File | Change |
|------|--------|
| manifests/cloudflare/networkpolicy.yaml | Added ghost-prod namespace egress on port 2368 |

### Key Decisions (Public Access)

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Tunnel protocol | HTTP (not HTTPS) | Ghost serves plain HTTP on 2368; cloudflared sends X-Forwarded-Proto: https |
| Admin protection | WAF custom rules | Cloudflare Access has known path precedence bugs; WAF evaluates in strict order |
| RSS feed | Skip rule (allow) + skip Super Bot Fight Mode | Cloudflare Bot Management blocks GitHub Actions IPs; `/rss/` is public read-only |
| Bot Fight Mode | Disabled globally | Free tier cannot create path-specific exceptions; blocks all cloud provider IPs |
| Content API | Skip rule (allow) | Sodo Search widget calls /ghost/api/content/ from browser; blocking breaks search |
| Admin API | Block rule | /ghost/api/admin/ is write-capable; original plan would have bypassed it |

### Lessons Learned (Public Access)

1. **Ghost 301-redirects HTTP when url is HTTPS** — Ghost checks `X-Forwarded-Proto` header. Cloudflare Tunnel with HTTP type sends this header automatically. Using HTTPS type causes cloudflared to attempt TLS to Ghost (which doesn't support it).

2. **CiliumNetworkPolicy blocks cross-namespace by default** — The cloudflared egress policy blocks all private IPs and whitelists per-namespace. New tunnel backends require an explicit egress rule.

3. **Cloudflare Access path precedence is unreliable** — "Most specific path wins" has [known bugs](https://community.cloudflare.com/t/policy-inheritance-not-prioritizing-most-specific-path/820213). WAF custom rules with Skip + Block pattern is deterministic.

4. **Ghost Content API vs Admin API** — Only `/ghost/api/content/` needs public access (read-only, API key auth). `/ghost/api/admin/` is write-capable (JWT auth) and should be blocked publicly.

### CKA Learnings

| Topic | Concept |
|-------|---------|
| StatefulSet | volumeClaimTemplates, headless Service, stable network identity |
| Pod Security Admission | 3 modes (enforce/audit/warn), baseline vs restricted |
| Init containers | wait-for pattern with busybox nc |
| Security context | runAsNonRoot, capabilities drop/add, seccompProfile |
| Gateway API | HTTPRoute parentRefs, cross-namespace routing |
| Secrets | Imperative creation from 1Password, placeholder pattern |
| CiliumNetworkPolicy | Per-namespace egress whitelisting for cross-namespace traffic |

---

## January 30, 2026 — Phase 4.8.1: AdGuard DNS Alerting

### Milestone: Synthetic DNS Monitoring for L2 Lease Misalignment

Deployed blackbox exporter with DNS probe to detect when AdGuard is running but unreachable due to Cilium L2 lease misalignment. This directly addresses the 3-day unnoticed outage (Jan 25-28) identified in Phase 4.8.

| Component | Version | Status |
|-----------|---------|--------|
| blackbox-exporter | v0.28.0 | Running (monitoring namespace) |
| Probe CRD (adguard-dns) | — | Scraping every 30s |
| PrometheusRule (AdGuardDNSUnreachable) | — | Loaded, severity: critical |

### Files Added/Modified

| File | Purpose |
|------|---------|
| helm/blackbox-exporter/values.yaml | Blackbox exporter config with dns_udp module |
| helm/prometheus/values.yaml | Added probeSelectorNilUsesHelmValues: false |
| manifests/monitoring/adguard-dns-probe.yaml | Probe CRD targeting 10.10.30.53 |
| manifests/monitoring/adguard-dns-alert.yaml | PrometheusRule with runbook |
| scripts/upgrade-prometheus.sh | Fixed Healthchecks Ping URL field name |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Blackbox exporter deployment | Separate Helm chart | kube-prometheus-stack does NOT bundle it |
| Probe target | LoadBalancer IP (10.10.30.53) | Tests full path including L2 lease alignment |
| DNS query domain | google.com | Universal, always resolvable |
| Alert threshold | 2 minutes | Avoids flapping while catching real outages |
| Alert severity | Critical | DNS is foundational; failure affects all VLANs |

### Architecture

```
Prometheus → Blackbox Exporter → DNS query to 10.10.30.53 → AdGuard
                                         │
                                         ├─ Success: probe_success=1
                                         └─ Failure: probe_success=0 → Alert
```

### CKA Learnings

| Topic | Concept |
|-------|---------|
| Probe CRD | Custom resource for blackbox exporter targets |
| PrometheusRule | Custom alert rules with PromQL expressions |
| Synthetic monitoring | Testing from outside the system under test |
| jobName field | Controls the `job` label in Prometheus metrics |

### Lessons Learned

1. **kube-prometheus-stack does NOT include blackbox exporter** — Despite the `prometheusBlackboxExporter` key existing in chart values, it requires a separate Helm chart installation.

2. **probeSelectorNilUsesHelmValues must be set** — Without `probeSelectorNilUsesHelmValues: false`, Prometheus ignores Probe CRDs. Silently fails with no error.

3. **Blackbox exporter has NO default DNS module** — Must explicitly configure `dns_udp` with `query_name` (required field). Without it, probe errors with no useful message.

4. **Service name follows `<release>-prometheus-blackbox-exporter` pattern** — Not `<release>-kube-prometheus-blackbox-exporter` as initially assumed.

5. **1Password field names must be exact** — `credential` vs `url` vs `password` — always verify with `op item get <name> --format json | jq '.fields[]'`.

### Alert Runbook

```
1. Check pod node:
   kubectl-homelab get pods -n home -l app=adguard-home -o wide

2. Check L2 lease holder:
   kubectl-homelab get leases -n kube-system cilium-l2announce-home-adguard-dns -o jsonpath='{.spec.holderIdentity}'

3. If pod node != lease holder, delete lease:
   kubectl-homelab delete lease -n kube-system cilium-l2announce-home-adguard-dns

4. Verify DNS restored:
   dig @10.10.30.53 google.com
```

### Alert Pipeline Verified

| Test | Result |
|------|--------|
| Test probe (non-existent IP) | probe_success=0 |
| Alert pending after 15s | ✓ |
| Alert firing after 1m | ✓ |
| Discord #status notification | ✓ Received |
| Cleanup + resolved notification | ✓ Received |

---

## January 29, 2026 — Phase 4.8: AdGuard Client IP Preservation

### Milestone: Fixed Client IP Visibility in AdGuard Logs

Resolved issue where AdGuard showed node IPs instead of real client IPs. Root cause was `externalTrafficPolicy: Cluster` combined with Cilium L2 lease on wrong node.

| Component | Change |
|-----------|--------|
| AdGuard DNS Service | externalTrafficPolicy: Cluster → Local |
| AdGuard Deployment | nodeSelector pinned to k8s-cp2 |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Traffic policy | Local | Preserves client IP (no SNAT) |
| Pod placement | Node pinning | Simpler than DaemonSet, keeps UI config |
| L2 alignment | Manual lease delete | Force re-election to pod node |

### CKA Learnings

| Topic | Concept |
|-------|---------|
| externalTrafficPolicy | Cluster (SNAT, any node) vs Local (preserve IP, pod node only) |
| Cilium L2 Announcement | Leader election via Kubernetes Leases |
| Health Check Node Port | Auto-created for Local policy services |

### Lessons Learned

1. **L2 lease must match pod node for Local policy** - Traffic dropped if mismatch occurs.

2. **Cilium agent restart can move L2 lease** - Caused 3-day outage (Jan 25-28) with no alerts.

3. **CoreDNS IPs in AdGuard are expected** - Pods query CoreDNS which forwards to AdGuard.

4. **General L2 policies can conflict with specific ones** - Delete conflicting policies before creating service-specific ones.

---

## January 28, 2026 — Phase 4.7: Portfolio CI/CD Migration

### Milestone: First App Deployed via GitLab CI/CD

Migrated portfolio website from PVE VM Docker Compose to Kubernetes with full GitLab CI/CD pipeline. Three environments (dev, staging, prod) with GitFlow branching strategy.

| Component | Status |
|-----------|--------|
| Portfolio (Next.js) | Running (3 environments) |
| GitLab CI/CD | 4-stage pipeline (validate, test, build, deploy) |
| Container Registry | Public project for anonymous pulls |

### Files Added

| File | Purpose |
|------|---------|
| manifests/portfolio/deployment.yaml | Deployment + Service (2 replicas) |
| manifests/portfolio/rbac.yaml | ServiceAccount for CI/CD deploys |
| manifests/gateway/routes/portfolio-*.yaml | HTTPRoutes for 3 environments |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Environments | dev/staging/prod | Corporate pattern learning |
| Branching | GitFlow | develop → dev (auto), staging (manual), main → prod (auto) |
| Registry auth | Public project | Simpler than imagePullSecrets for personal portfolio |
| URL pattern | Flat subdomains | portfolio-dev vs portfolio.dev for wildcard TLS |

### Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    GitLab CI/CD Pipeline                        │
├─────────────────────────────────────────────────────────────────┤
│  develop branch ──► validate ──► test ──► build ──► deploy:dev  │
│                                                    ──► deploy:staging (manual)
│  main branch ────► validate ──► test ──► build ──► deploy:prod  │
└─────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────┐
│  portfolio-dev        portfolio-staging      portfolio-prod     │
│  (internal only)      beta.rommelporras.com  www.rommelporras.com│
└─────────────────────────────────────────────────────────────────┘
```

### Cloudflare Tunnel Routes

| Subdomain | Target |
|-----------|--------|
| beta.rommelporras.com | portfolio.portfolio-staging.svc:80 |
| www.rommelporras.com | portfolio.portfolio-prod.svc:80 |

### Lessons Learned

1. **RBAC needs list/watch for rollout status** - `kubectl rollout status` requires list and watch verbs on deployments and replicasets.

2. **kubectl context order matters** - `set-context` must come before `use-context` in CI/CD scripts.

3. **Wildcard TLS only covers one level** - `*.k8s.home...` doesn't cover `portfolio.dev.k8s.home...`. Use flat subdomains like `portfolio-dev.k8s.home...`.

4. **CiliumNetworkPolicy for tunnel egress** - Cloudflared egress policy must explicitly allow each namespace it needs to reach.

5. **Docker-in-Docker needs wait loop** - Add `until docker info; do sleep 2; done` before docker commands in CI.

---

## January 25, 2026 — Phase 4.6: GitLab CE

### Milestone: Self-hosted DevOps Platform

Deployed GitLab CE v18.8.2 with GitLab Runner for CI/CD pipelines, Container Registry, and SSH access.

| Component | Version | Status |
|-----------|---------|--------|
| GitLab CE | v18.8.2 | Running |
| GitLab Runner | v18.8.0 | Running (Kubernetes executor) |
| PostgreSQL | 16.6 | Running (bundled) |
| Container Registry | v4.x | Running |

### Files Added

| File | Purpose |
|------|---------|
| helm/gitlab/values.yaml | GitLab Helm configuration |
| helm/gitlab-runner/values.yaml | Runner with Kubernetes executor |
| manifests/gateway/routes/gitlab.yaml | HTTPRoute for web UI |
| manifests/gateway/routes/gitlab-registry.yaml | HTTPRoute for container registry |
| manifests/gitlab/gitlab-shell-lb.yaml | LoadBalancer for SSH (10.10.30.21) |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Edition | Community Edition (CE) | Free, sufficient for homelab |
| Storage | Bundled PostgreSQL/Redis | Learning/PoC, not production |
| SSH Access | Dedicated LoadBalancer IP (.21) | Separate from Gateway, avoids port conflicts |
| SMTP | Shared iCloud SMTP | Reuses existing Alertmanager credentials |
| Secrets | SET_VIA_HELM pattern | Matches Alertmanager, no email in public repo |

### Architecture

```
                         Internet
                             │
          ┌──────────────────┴──────────────────┐
          ▼                                     ▼
┌───────────────────┐                ┌───────────────────┐
│  Gateway API      │                │  LoadBalancer     │
│  10.10.30.20:443  │                │  10.10.30.21:22   │
│  (HTTPS)          │                │  (SSH)            │
└─────────┬─────────┘                └─────────┬─────────┘
          │                                    │
    ┌─────┴─────┐                              │
    ▼           ▼                              ▼
┌───────┐  ┌──────────┐                ┌─────────────┐
│GitLab │  │ Registry │                │ gitlab-shell│
│  Web  │  │  :5000   │                │   :2222     │
│ :8181 │  └──────────┘                └─────────────┘
└───────┘
```

### 1Password Items

| Item | Vault | Fields |
|------|-------|--------|
| GitLab | Kubernetes | username, password, postgresql-password |
| GitLab Runner | Kubernetes | runner-token |
| iCloud SMTP | Kubernetes | username, password (renamed from "iCloud SMTP Alertmanager") |

### Access

| Type | URL |
|------|-----|
| Web UI | https://gitlab.k8s.home.rommelporras.com |
| Registry | https://registry.k8s.home.rommelporras.com |
| SSH | ssh://git@ssh.gitlab.k8s.home.rommelporras.com (10.10.30.21) |

### Lessons Learned

1. **gitlab-shell listens on 2222, not 22** - Container runs as non-root, uses high port internally. LoadBalancer maps 22→2222.

2. **Cilium L2 sharing requires annotation** - To share IP with Gateway, both services need `lro.io/sharing-key`. Used separate IP instead for simplicity.

3. **PostgreSQL secret needs two keys** - Chart expects both `postgresql-password` and `postgresql-postgres-password` in the secret.

4. **SET_VIA_HELM pattern** - Placeholders in values.yaml with `--set` injection at install time keeps credentials out of git.

---

## January 24, 2026 — Phase 4.5: Cloudflare Tunnel

### Milestone: HA Cloudflare Tunnel on Kubernetes

Migrated cloudflared from DMZ LXC to Kubernetes for high availability. Tunnel now survives node failures and Proxmox reboots.

| Component | Version | Status |
|-----------|---------|--------|
| cloudflared | 2026.1.1 | Running (2 replicas, HA) |

### Files Added

| File | Purpose |
|------|---------|
| manifests/cloudflare/deployment.yaml | 2-replica deployment with anti-affinity |
| manifests/cloudflare/networkpolicy.yaml | CiliumNetworkPolicy egress rules |
| manifests/cloudflare/pdb.yaml | PodDisruptionBudget (minAvailable: 1) |
| manifests/cloudflare/service.yaml | ClusterIP for Prometheus metrics |
| manifests/cloudflare/servicemonitor.yaml | Prometheus scraping |
| manifests/cloudflare/secret.yaml | Documentation placeholder for imperative secret |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Replicas | 2 with required anti-affinity | HA across nodes, survives single node failure |
| Security | CiliumNetworkPolicy | Block NAS/internal, allow only Cloudflare Edge + public services |
| DMZ access | Temporary 10.10.50.10/32 rule | Transition period until portfolio/invoicetron migrate to K8s |
| Secrets | 1Password → imperative kubectl | GitOps-friendly, future ESO migration path |
| Namespace PSS | restricted | Matches official cloudflared security recommendations |

### Architecture

```
                    Cloudflare Edge
         (mnl01, hkg11, sin02, sin11, etc.)
                         │
                    8 QUIC connections
                         │
         ┌───────────────┴───────────────┐
         ▼                               ▼
┌─────────────────┐             ┌─────────────────┐
│  cloudflared    │             │  cloudflared    │
│  k8s-cp1        │             │  k8s-cp2        │
│  4 connections  │             │  4 connections  │
└────────┬────────┘             └────────┬────────┘
         │                               │
         └───────────────┬───────────────┘
                         ▼
               ┌─────────────────┐
               │ reverse-mountain│
               │  10.10.50.10    │
               │ (DMZ - temporary)│
               └─────────────────┘
```

### CiliumNetworkPolicy Rules

| Rule | Target | Ports | Purpose |
|------|--------|-------|---------|
| DNS | kube-dns | 53/UDP | Service discovery |
| Cloudflare | 0.0.0.0/0 except RFC1918 | 443, 7844 | Tunnel traffic |
| Portfolio (K8s) | portfolio namespace | 80 | Future K8s service |
| Invoicetron (K8s) | invoicetron namespace | 3000 | Future K8s service |
| DMZ (temporary) | 10.10.50.10/32 | 3000, 3001 | Current Proxmox VM |

### Security Validation

Verified via test pod with `app=cloudflared` label:

| Test | Target | Result |
|------|--------|--------|
| NAS | 10.10.30.4:5000 | BLOCKED |
| Router | 10.10.30.1:80 | BLOCKED |
| Grafana | monitoring namespace | BLOCKED |
| Cloudflare Edge | 104.16.132.229:443 | ALLOWED |
| DMZ VM | 10.10.50.10:3000,3001 | ALLOWED |

### Lessons Learned

1. **CiliumNetworkPolicy blocks private IPs by design** - `toCIDRSet` with `except` for 10.0.0.0/8 blocks DMZ too. Added specific /32 rule for transition period.

2. **Pod Security Standards enforcement** - Test pods in `restricted` namespace need full securityContext (runAsNonRoot, capabilities.drop, seccompProfile).

3. **Loki log retention is 90 days** - Logs auto-delete after 2160h. Old tunnel errors will naturally expire.

4. **OPNsense allows SERVERS→DMZ** - But Cilium blocks it at K8s layer. Network segmentation works at multiple levels.

### 1Password Items

| Item | Vault | Field | Purpose |
|------|-------|-------|---------|
| Cloudflare Tunnel | Kubernetes | token | cloudflared tunnel authentication |

### Public Services (via Tunnel)

| Service | URL | Backend |
|---------|-----|---------|
| Portfolio | https://www.rommelporras.com | 10.10.50.10:3001 (temporary) |
| Invoicetron | https://invoicetron.rommelporras.com | 10.10.50.10:3000 (temporary) |

---

## January 22, 2026 — Phase 4.1-4.4: Stateless Workloads

### Milestone: Home Services Running on Kubernetes

Successfully deployed stateless home services to Kubernetes with full monitoring integration.

| Component | Version | Status |
|-----------|---------|--------|
| AdGuard Home | v0.107.71 | Running (PRIMARY DNS for all VLANs) |
| Homepage | v1.9.0 | Running (2 replicas, multi-tab layout) |
| Glances | v3.3.1 | Running (on OMV, apt install) |
| Metrics Server | v0.8.0 | Running (Helm chart 3.13.0) |

### Files Added

| File | Purpose |
|------|---------|
| manifests/home/adguard/ | AdGuard Home deployment (ConfigMap, Deployment, Service, HTTPRoute, PVC) |
| manifests/home/homepage/ | Homepage dashboard (Kustomize with configMapGenerator) |
| manifests/storage/longhorn/httproute.yaml | Longhorn UI exposure for Homepage widget |
| helm/metrics-server/values.yaml | Metrics server Helm values |
| docs/todo/phase-4.9-tailscale-operator.md | Future Tailscale K8s operator planning |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| DNS IP | 10.10.30.55 (LoadBalancer) | Cilium L2 announcement, separate from FW failover |
| AdGuard storage | Init container + Longhorn PVC | ConfigMap → PVC on first boot, runtime changes preserved |
| Homepage storage | ConfigMap only (stateless) | Kustomize hash suffix for automatic rollouts |
| Secrets | 1Password CLI (imperative) | Never commit secrets to git |
| Settings env vars | Init container substitution | Homepage doesn't substitute `{{HOMEPAGE_VAR_*}}` in providers section |
| Longhorn widget | HTTPRoute exposure | Widget needs direct API access to Longhorn UI |

### Architecture

```
                    ┌─────────────────────────────────────────┐
                    │         Home Namespace (home)           │
                    └─────────────────────────────────────────┘
                                      │
        ┌─────────────────────────────┼─────────────────────────────┐
        │                             │                             │
┌───────▼───────┐            ┌────────▼────────┐           ┌────────▼────────┐
│  AdGuard Home │            │    Homepage     │           │  Metrics Server │
│  v0.107.71    │            │    v1.9.0       │           │    v0.8.0       │
├───────────────┤            ├─────────────────┤           ├─────────────────┤
│ LoadBalancer  │            │ ClusterIP       │           │ ClusterIP       │
│ 10.10.30.55   │            │ → HTTPRoute     │           │ (kube-system)   │
│ DNS :53/udp   │            │                 │           │                 │
│ HTTP :3000    │            │ 2 replicas      │           │ metrics.k8s.io  │
└───────────────┘            └─────────────────┘           └─────────────────┘
        │                             │
        ▼                             ▼
  All VLAN DHCP              Grafana-style dashboard
  Primary DNS                with K8s/Longhorn widgets
```

### DNS Cutover

| VLAN | Primary DNS | Secondary DNS |
|------|-------------|---------------|
| GUEST | 10.10.30.55 | 10.10.30.54 |
| IOT | 10.10.30.55 | 10.10.30.54 |
| LAN | 10.10.30.55 | 10.10.30.54 |
| SERVERS | 10.10.30.55 | 10.10.30.54 |
| TRUSTED_WIFI | 10.10.30.55 | 10.10.30.54 |

### 1Password Items Created

| Item | Vault | Fields |
|------|-------|--------|
| Homepage | Kubernetes | proxmox-pve-user/token, proxmox-fw-user/token, opnsense-username/password, immich-key, omv-user/pass, glances-pass, adguard-user/pass, weather-key, grafana-user/pass, etc. |

### Lessons Learned

1. **Homepage env var substitution limitation:** `{{HOMEPAGE_VAR_*}}` works in `services.yaml` but NOT in `settings.yaml` `providers` section. Used init container with sed to substitute at runtime.

2. **Longhorn widget requires HTTPRoute:** The Homepage Longhorn info widget fetches data via HTTP from Longhorn UI. Must expose via Gateway API even for internal use.

3. **Security context for init containers:** Don't forget `allowPrivilegeEscalation: false` and `capabilities.drop: ALL` on init containers, not just main containers.

4. **Glances version matters:** OMV apt installs v3.x. Homepage widget config needs `version: 3`, not `version: 4`.

5. **ConfigMap hash suffix:** Kustomize `configMapGenerator` adds hash suffix, enabling automatic pod rollouts when config changes. Don't use `generatorOptions.disableNameSuffixHash`.

### HTTPRoutes Configured

| Service | URL |
|---------|-----|
| AdGuard | adguard.k8s.home.rommelporras.com |
| Homepage | portal.k8s.home.rommelporras.com |
| Longhorn | longhorn.k8s.home.rommelporras.com |

---

## January 20, 2026 — Phase 3.9: Alertmanager Notifications

### Milestone: Discord + Email Alerting Configured

Configured Alertmanager to send notifications via Discord and Email, with intelligent routing based on severity.

| Component | Status |
|-----------|--------|
| Discord #incidents | Webhook configured (critical alerts) |
| Discord #status | Webhook configured (warnings, info, resolved) |
| iCloud SMTP | Configured (noreply@rommelporras.com) |
| Email recipients | 3 addresses for critical alerts |

### Files Added/Modified

| File | Purpose |
|------|---------|
| helm/prometheus/values.yaml | Alertmanager config with routes and receivers |
| scripts/upgrade-prometheus.sh | Helm upgrade script with 1Password integration |
| manifests/monitoring/test-alert.yaml | Test alerts for verification |
| docs/rebuild/v0.5.0-alerting.md | Rebuild guide for alerting setup |
| docs/todo/deferred.md | Added kubeadm scraping issue |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Discord channel naming | #incidents + #status | Clear action expectation: incidents need action, status is FYI |
| Category naming | Notifications | Honest about purpose (notification inbox, not observability tool) |
| Email recipients | 3 addresses for critical | Redundancy: iCloud issues won't prevent delivery to Gmail |
| SMTP authentication | @icloud.com email | Apple requires Apple ID for SMTP auth, not custom domain |
| kubeadm alerts | Silenced (null receiver) | False positives from localhost-bound components; cluster works fine |
| Secrets management | 1Password + temp file | --set breaks array structures; temp file with cleanup is safer |

### Alert Routing

```
┌─────────────────────────────────────────────────┐
│                 Alertmanager                    │
└─────────────────────┬───────────────────────────┘
                      │
    ┌─────────────────┼─────────────────┐
    │                 │                 │
┌───▼───┐        ┌────▼────┐       ┌────▼────┐
│Silenced│        │Critical │       │Warning/ │
│kubeadm │        │         │       │  Info   │
└───┬───┘        └────┬────┘       └────┬────┘
    │                 │                 │
┌───▼───┐        ┌────▼────┐       ┌────▼────┐
│ null  │        │#incidents│       │#status  │
│       │        │+ 3 emails│       │  only   │
└───────┘        └─────────┘       └─────────┘
```

### Silenced Alerts (Deferred)

| Alert | Reason | Fix Location |
|-------|--------|--------------|
| KubeProxyDown | kube-proxy metrics not exposed | docs/todo/deferred.md |
| etcdInsufficientMembers | etcd bound to localhost | docs/todo/deferred.md |
| etcdMembersDown | etcd bound to localhost | docs/todo/deferred.md |
| TargetDown (kube-*) | Control plane bound to localhost | docs/todo/deferred.md |

### 1Password Items Created

| Item | Vault | Purpose |
|------|-------|---------|
| Discord Webhook Incidents | Kubernetes | #incidents webhook URL |
| Discord Webhook Status | Kubernetes | #status webhook URL |
| iCloud SMTP | Kubernetes | SMTP credentials |

### Lessons Learned

1. **Helm --set breaks arrays** - Using `--set 'receivers[0].webhook_url=...'` overwrites the entire array structure. Use multiple `--values` files instead.
2. **iCloud SMTP auth** - Must use @icloud.com email for authentication, not custom domain. From address can be custom domain.
3. **Port 587 = STARTTLS** - Not SSL. Common misconfiguration in email clients.
4. **kubeadm metrics** - Control plane components bind to localhost by default. Fixing requires modifying static pod manifests (risky, low value for homelab).

---

## January 20, 2026 — Documentation: Rebuild Guides

### Milestone: Split Rebuild Documentation by Release Tag

Created comprehensive step-by-step rebuild guides split by release tag for better organization and versioning.

| Document | Release | Phases |
|----------|---------|--------|
| [docs/rebuild/README.md](../rebuild/README.md) | Index | Overview, prerequisites, versions |
| [docs/rebuild/v0.1.0-foundation.md](../rebuild/v0.1.0-foundation.md) | v0.1.0 | Phase 1: Ubuntu, SSH |
| [docs/rebuild/v0.2.0-bootstrap.md](../rebuild/v0.2.0-bootstrap.md) | v0.2.0 | Phase 2: kubeadm, Cilium |
| [docs/rebuild/v0.3.0-storage.md](../rebuild/v0.3.0-storage.md) | v0.3.0 | Phase 3.1-3.4: Longhorn |
| [docs/rebuild/v0.4.0-observability.md](../rebuild/v0.4.0-observability.md) | v0.4.0 | Phase 3.5-3.8: Gateway, Monitoring, Logging, UPS |

### Benefits

- Each release is self-contained and versioned
- Can rebuild to a specific milestone
- Easier to maintain and update individual phases
- Aligns with git tags for reproducibility

---

## January 20, 2026 — Phase 3.8: UPS Monitoring (NUT)

### Milestone: NUT + Prometheus UPS Monitoring Running

Successfully installed Network UPS Tools (NUT) for graceful cluster shutdown during power outages, with Prometheus/Grafana integration for historical metrics and alerting.

| Component | Version | Status |
|-----------|---------|--------|
| NUT (Network UPS Tools) | 2.8.1 | Running (server on cp1, clients on cp2/cp3) |
| nut-exporter (DRuggeri) | 3.1.1 | Running (Deployment in monitoring namespace) |
| CyberPower UPS | CP1600EPFCLCD | Connected (USB to k8s-cp1) |

### Files Added

| File | Purpose |
|------|---------|
| manifests/monitoring/nut-exporter.yaml | Deployment, Service, ServiceMonitor for UPS metrics |
| manifests/monitoring/ups-alerts.yaml | PrometheusRule with 8 UPS alerts |
| manifests/monitoring/dashboards/ups-monitoring.json | Custom UPS dashboard (improved from Grafana.com #19308) |
| manifests/monitoring/ups-dashboard-configmap.yaml | ConfigMap for Grafana auto-provisioning |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| NUT server location | k8s-cp1 (bare metal) | Must run outside K8s to shutdown the node itself |
| Staggered shutdown | Time-based (10/20 min) | NUT upssched timers are native and reliable; percentage-based requires custom polling scripts |
| Exporter | DRuggeri/nut_exporter | Actively maintained (Dec 2025), better documentation, TLS support |
| Dashboard | Custom (repo-stored) | Grafana.com #19308 had issues; custom dashboard with ConfigMap auto-provisioning |
| Metric prefix | network_ups_tools_* | DRuggeri exporter uses this prefix (not nut_*) |
| UPS label | ServiceMonitor relabeling | Exporter doesn't add `ups` label; added via relabeling for dashboard compatibility |

### Architecture

```
CyberPower UPS ──USB──► k8s-cp1 (NUT Server + Master)
                              │
                    TCP 3493 (nutserver)
                              │
              ┌───────────────┼───────────────┐
              ▼               ▼               ▼
          k8s-cp2         k8s-cp3        K8s Cluster
        (upssched)      (upssched)     ┌─────────────────┐
       20min→shutdown  10min→shutdown  │  nut-exporter   │
                                       │  (Deployment)   │
                                       └────────┬────────┘
                                                │ :9995
                                       ┌────────▼────────┐
                                       │   Prometheus    │
                                       │ (ServiceMonitor)│
                                       └────────┬────────┘
                                                │
                                       ┌────────▼────────┐
                                       │    Grafana      │
                                       │  (Dashboard)    │
                                       └────────┬────────┘
                                                │
                                       ┌────────▼────────┐
                                       │  Alertmanager   │
                                       │(PrometheusRule) │
                                       └─────────────────┘
```

### Staggered Shutdown Strategy

| Node | Trigger | Timer | Reason |
|------|---------|-------|--------|
| k8s-cp3 | ONBATT event | 10 minutes | First to shutdown, reduce load early |
| k8s-cp2 | ONBATT event | 20 minutes | Second to shutdown, maintain quorum longer |
| k8s-cp1 | Low Battery (LB) | Native NUT | Last node, sends UPS power-off command |

With ~70 minute runtime at 9% load, these timers provide ample safety margin.

### Kubelet Graceful Shutdown

Configured on all nodes to evict pods gracefully before power-off:

```yaml
shutdownGracePeriod: 120s           # Total time for pod eviction
shutdownGracePeriodCriticalPods: 30s # Reserved for critical pods
```

### Alerts Configured

| Alert | Severity | Trigger |
|-------|----------|---------|
| UPSOnBattery | warning | On battery for 1m |
| UPSLowBattery | critical | LB flag set (immediate) |
| UPSBatteryCritical | critical | Battery < 30% for 1m |
| UPSBatteryWarning | warning | Battery 30-50% for 2m |
| UPSHighLoad | warning | Load > 80% for 5m |
| UPSExporterDown | critical | Exporter unreachable for 2m |
| UPSOffline | critical | Neither OL nor OB status for 2m |
| UPSBackOnline | info | Returns to line power |

### Lessons Learned

**USB permissions require udev rules:** The NUT driver couldn't access the USB device due to permissions. Created `/etc/udev/rules.d/90-nut-ups.rules` to grant the `nut` group access to CyberPower USB devices.

**DRuggeri Helm chart doesn't exist:** Despite documentation suggesting otherwise, there's no working Helm repository. Created manual manifests instead (Deployment, Service, ServiceMonitor).

**Metric names differ from documentation:** DRuggeri exporter uses `network_ups_tools_*` prefix, not `nut_*`. The status metric uses `{flag="OB"}` syntax, not `{status="OB"}`. Had to query the actual exporter to discover correct metric names.

**1Password CLI session scope:** The `op` CLI session is terminal-specific. Running `eval $(op signin)` in one terminal doesn't affect others. Each terminal needs its own session.

**Exporter doesn't add `ups` label:** The DRuggeri exporter doesn't include an `ups` label for single-UPS setups. Dashboard queries with `{ups="$ups"}` returned no data. Fixed with ServiceMonitor relabeling to inject `ups=cyberpower` label.

**Grafana.com dashboard had issues:** Dashboard #19308 showed "No Data" for several panels due to missing `--nut.vars_enable` metrics (battery.runtime, output.voltage). Created custom dashboard stored in repo with ConfigMap auto-provisioning.

**Grafana thresholdsStyle modes:** Setting `thresholdsStyle.mode: "line"` draws horizontal threshold lines on graphs; `"area"` fills background with threshold colors. Both can clutter graphs if overused.

### Access

- UPS Dashboard: https://grafana.k8s.home.rommelporras.com/d/ups-monitoring
- NUT Server: 10.10.30.11:3493
- nut-exporter (internal): nut-exporter.monitoring.svc.cluster.local:9995

### Sample PromQL Queries

```promql
network_ups_tools_battery_charge                        # Battery percentage
network_ups_tools_ups_load                              # Current load %
network_ups_tools_ups_status{flag="OL"}                 # Online status (1=true)
network_ups_tools_ups_status{flag="OB"}                 # On battery status
network_ups_tools_battery_runtime_seconds               # Estimated runtime
```

---

## January 19, 2026 — Phase 3.7: Logging Stack

### Milestone: Loki + Alloy Running

Successfully installed centralized logging with Loki for storage and Alloy for log collection.

| Component | Version | Status |
|-----------|---------|--------|
| Loki | v3.6.3 | Running (SingleBinary, 10Gi PVC) |
| Alloy | v1.12.2 | Running (DaemonSet, 3 pods) |

### Files Added

| File | Purpose |
|------|---------|
| helm/loki/values.yaml | Loki SingleBinary mode, 90-day retention, Longhorn storage |
| helm/alloy/values.yaml | Alloy DaemonSet with K8s API log collection + K8s events |
| manifests/monitoring/loki-datasource.yaml | Grafana datasource ConfigMap for Loki |
| manifests/monitoring/loki-servicemonitor.yaml | Prometheus scraping for Loki metrics |
| manifests/monitoring/alloy-servicemonitor.yaml | Prometheus scraping for Alloy metrics |
| manifests/monitoring/logging-alerts.yaml | PrometheusRule with Loki/Alloy alerts |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Loki mode | SingleBinary | Cluster generates ~4MB/day logs, far below 20GB/day threshold |
| Storage backend | Filesystem (Longhorn PVC) | SimpleScalable/Distributed require S3, overkill for homelab |
| Retention | 90 days | Storage analysis showed ~360-810MB needed, 10Gi provides headroom |
| Log collection | loki.source.kubernetes | Uses K8s API, no volume mounts or privileged containers needed |
| Alloy controller | DaemonSet | One pod per node ensures all logs collected |
| OCI registry | Loki only | Alloy doesn't support OCI yet, uses traditional Helm repo |
| K8s events | Single collector | Only k8s-cp1's Alloy forwards events to avoid triplicates |
| Observability | ServiceMonitors + Alerts | Monitor the monitors - Prometheus scrapes Loki/Alloy |
| Alloy memory | 256Mi limit | Increased from 128Mi to handle events collection safely |

### Lessons Learned

**Loki OCI available but undocumented:** Official docs still show `helm repo add grafana`, but Loki chart is available via OCI at `oci://ghcr.io/grafana/helm-charts/loki`. Alloy is not available via OCI (403 denied).

**lokiCanary is top-level setting:** The Loki chart has `lokiCanary.enabled` at the top level, NOT under `monitoring.lokiCanary`. This caused unwanted canary pods until fixed.

**loki.source.kubernetes vs loki.source.file:** The newer `loki.source.kubernetes` component tails logs via K8s API instead of mounting `/var/log/pods`. Benefits: no volume mounts, no privileged containers, works with restrictive Pod Security Standards.

**Grafana sidecar auto-discovery:** Creating a ConfigMap with label `grafana_datasource: "1"` automatically adds the datasource to Grafana. No manual configuration needed.

### Architecture

```
Pod stdout ──────► Alloy (DaemonSet) ──► Loki (SingleBinary) ──► Longhorn PVC
K8s Events ──────►        │                      │
                          │                      ▼
                          │                  Grafana
                          │                      ▲
                          ▼                      │
                    Prometheus ◄── ServiceMonitors (loki, alloy)
                          │
                          ▼
                    Alertmanager ◄── PrometheusRule (logging-alerts)
```

### Alerts Configured

| Alert | Severity | Trigger |
|-------|----------|---------|
| LokiDown | critical | Loki unreachable for 5m |
| LokiIngestionStopped | warning | No logs received for 15m |
| LokiHighErrorRate | warning | Error rate > 10% for 10m |
| LokiStorageLow | warning | PVC < 20% free for 30m |
| AlloyNotOnAllNodes | warning | Alloy pods < node count for 10m |
| AlloyNotSendingLogs | warning | No logs sent for 15m |
| AlloyHighMemory | warning | Memory > 80% limit for 10m |

### Access

- Grafana Explore: https://grafana.k8s.home.rommelporras.com/explore
- Loki (internal): loki.monitoring.svc.cluster.local:3100

### Sample LogQL Queries

```logql
{namespace="monitoring"}                    # All monitoring logs
{namespace="kube-system", container="etcd"} # etcd logs
{cluster="homelab"} |= "error"              # Search for errors
{source="kubernetes_events"}                # All K8s events
{source="kubernetes_events"} |= "Warning"   # Warning events only
```

---

## January 18, 2026 — Phase 3.6: Monitoring Stack

### Milestone: kube-prometheus-stack Running

Successfully installed complete monitoring stack with Prometheus, Grafana, Alertmanager, and node-exporter.

| Component | Version | Status |
|-----------|---------|--------|
| kube-prometheus-stack | v81.0.0 | Running |
| Prometheus | v0.88.0 | Running (50Gi PVC) |
| Grafana | latest | Running (10Gi PVC) |
| Alertmanager | latest | Running (5Gi PVC) |
| node-exporter | latest | Running (DaemonSet, 3 pods) |

### Files Added

| File | Purpose |
|------|---------|
| helm/prometheus/values.yaml | Helm values with 90-day retention, Longhorn storage |
| manifests/monitoring/grafana-httproute.yaml | Gateway API route for HTTPS access |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Pod Security | privileged | node-exporter needs hostNetwork, hostPID, hostPath |
| OCI registry | Yes | Recommended by upstream, no helm repo add needed |
| Retention | 90 days | Balance between history and storage usage |
| Storage | Longhorn | Consistent with cluster storage strategy |

### Lessons Learned

**Pod Security Standards block node-exporter:** The `baseline` PSS level rejects pods with hostNetwork/hostPID/hostPath. node-exporter requires these for host-level metrics collection.

**Solution:** Use `privileged` PSS for monitoring namespace: `kubectl label namespace monitoring pod-security.kubernetes.io/enforce=privileged`

**DaemonSet backoff requires restart:** After fixing PSS, the DaemonSet controller was in backoff. Required `kubectl rollout restart daemonset` to retry pod creation.

### Access

- Grafana: https://grafana.k8s.home.rommelporras.com
- Prometheus (internal): prometheus-kube-prometheus-prometheus:9090
- Alertmanager (internal): prometheus-kube-prometheus-alertmanager:9093

---

## January 17, 2026 — Phase 3: Storage Infrastructure

### Milestone: Longhorn Distributed Storage Running

Successfully installed Longhorn for persistent storage across all 3 nodes.

| Component | Version | Status |
|-----------|---------|--------|
| Longhorn | v1.10.1 | Running |
| StorageClass | longhorn (default) | Active |
| Replicas | 2 per volume | Configured |

### Ansible Playbooks Added

| Playbook | Purpose |
|----------|---------|
| 06-storage-prereqs.yml | Create /var/lib/longhorn, verify iscsid, install nfs-common |
| 07-remove-taints.yml | Remove control-plane taints for homelab workloads |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Replica count | 2 | With 3 nodes, survives 1 node failure. 3 replicas would waste storage. |
| Storage path | /var/lib/longhorn | Standard location, ~432GB available per node |
| Taint removal | All nodes | Homelab has no dedicated workers, workloads must run on control plane |
| Helm values file | helm/longhorn/values.yaml | GitOps-friendly, version controlled |

### Lessons Learned

**Control-plane taints block workloads:** By default, kubeadm taints control plane nodes with `NoSchedule`. In a homelab cluster with no dedicated workers, this prevents Longhorn (and all other workloads) from scheduling.

**Solution:** Remove taints with `kubectl taint nodes --all node-role.kubernetes.io/control-plane:NoSchedule-`

**Helm needs KUBECONFIG:** When using a non-default kubeconfig (like homelab.yaml), Helm requires the correct kubeconfig. Created `helm-homelab` alias in ~/.zshrc alongside `kubectl-homelab`.

**NFSv4 pseudo-root path format:** When OMV exports `/export` with `fsid=0`, it becomes the NFSv4 pseudo-root. Mount paths must be relative to this root:
- Filesystem path: `/export/Kubernetes/Immich`
- NFSv4 mount path: `/Kubernetes/Immich` (not `/export/Kubernetes/Immich`!)

This caused "No such file or directory" errors until the path format was corrected.

### Storage Strategy Documented

| Storage Type | Use Case | Example Apps |
|--------------|----------|--------------|
| Longhorn (block) | App data, databases, runtime state | AdGuard logs, PostgreSQL |
| NFS (file) | Bulk media, photos | Immich, *arr stack |
| ConfigMap (K8s) | Static config files | Homepage settings |

### NFS Status

- NAS (10.10.30.4) is network reachable
- NFS export /export/Kubernetes enabled on OMV
- NFSv4 mount tested and verified from cluster nodes
- Manifest ready at `manifests/storage/nfs-immich.yaml`
- PV name: `immich-nfs`, PVC name: `immich-media`

---

## January 16, 2026 — Kubernetes HA Cluster Bootstrap Complete

### Milestone: 3-Node HA Cluster Running

Successfully bootstrapped a 3-node high-availability Kubernetes cluster using kubeadm.

| Component | Version | Status |
|-----------|---------|--------|
| Kubernetes | v1.35.0 | Running |
| kube-vip | v1.0.3 | Active (VIP: 10.10.30.10) |
| Cilium | 1.18.6 | Healthy |
| etcd | 3 members | Quorum established |

### Ansible Playbooks Created

Full automation for cluster bootstrap:

| Playbook | Purpose |
|----------|---------|
| 00-preflight.yml | Pre-flight checks (cgroup v2, network, DNS) |
| 01-prerequisites.yml | System prep (swap, modules, containerd, kubeadm) |
| 02-kube-vip.yml | VIP setup with K8s 1.29+ workaround |
| 03-init-cluster.yml | kubeadm init with config generation |
| 04-cilium.yml | CNI installation with checksum verification |
| 05-join-cluster.yml | Control plane join with post-join reboot |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Post-join reboot | Enabled | Resolves Cilium init timeouts and kube-vip leader election conflicts |
| Workstation config | ~/.kube/homelab.yaml | Separate from work EKS (~/.kube/config) |
| kubectl alias | `kubectl-homelab` | Work wiki copy-paste compatibility |

### Lessons Learned

**Cascading restart issue:** Joining multiple control planes can cause cascading failures:
- Cilium init timeouts ("failed to sync configmap cache")
- kube-vip leader election conflicts
- Accumulated backoff timers on failed containers

**Solution:** Reboot each node after join to clear state and backoff timers.

### Workstation Setup

```bash
# Homelab cluster (separate from work)
kubectl-homelab get nodes

# Work EKS (unchanged)
kubectl get pods
```

---

## January 11, 2026 — Node Preparation & Project Setup

### Ubuntu Pro Attached

All 3 nodes attached to Ubuntu Pro (free personal subscription, 5 machine limit).

| Service | Status | Benefit |
|---------|--------|---------|
| ESM Apps | Enabled | Extended security for universe packages |
| ESM Infra | Enabled | Extended security for main packages |
| Livepatch | Enabled | Kernel patches without reboot |

### Firmware Updates

| Node | NVMe | BIOS | EC | Notes |
|------|------|------|-----|-------|
| cp1 | 41730C20 | 1.99 | 256.24 | All updates applied |
| cp2 | 41730C20 | 1.90 | 256.20 | Boot Order Lock blocking BIOS/EC |
| cp3 | 41730C20 | 1.82 | 256.20 | Boot Order Lock blocking BIOS/EC |

**NVMe update (High urgency):** Applied to all nodes.
**BIOS/EC updates (Low urgency):** Deferred for cp2/cp3 - requires physical access to disable Boot Order Lock in BIOS. Tracked in TODO.md.

### Claude Code Configuration

Created `.claude/` directory structure:

| Component | Purpose |
|-----------|---------|
| commands/commit.md | Conventional commits with `infra:` type |
| commands/release.md | Semantic versioning and GitHub releases |
| commands/validate.md | YAML and K8s manifest validation |
| commands/cluster-status.md | Cluster health checks |
| agents/kubernetes-expert | K8s troubleshooting and best practices |
| skills/kubeadm-patterns | Bootstrap issues and upgrade patterns |
| hooks/protect-sensitive.sh | Block edits to secrets/credentials |

### GitHub Repository

Recreated repository with clean commit history and proper conventional commit messages.

**Description:** From Proxmox VMs/LXCs to GitOps-driven Kubernetes. Proxmox now handles NAS and OPNsense only. Production workloads run on 3-node HA bare-metal K8s. Lenovo M80q nodes, kubeadm, Cilium, kube-vip, Longhorn. Real HA for real workloads. CKA-ready.

### Rules Added to CLAUDE.md

- No AI attribution in commits
- No automatic git commits/pushes (require explicit request or /commit, /release)

---

## January 11, 2026 — Ubuntu Installation Complete

### Milestone: Phase 1 Complete

All 3 nodes running Ubuntu 24.04.3 LTS with SSH access configured.

### Hardware Verification

**Actual hardware is M80q, not M70q Gen 1** as originally thought.

| Spec | Documented | Actual |
|------|------------|--------|
| Model | M70q Gen 1 | **M80q** |
| Product ID | — | 11DN0054PC |
| CPU | i5-10400T | i5-10400T |
| NIC | I219-V | **I219-LM** |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Hostnames | k8s-cp1/2/3 | Industry standard k8s prefix |
| Username | wawashi | Consistent across all nodes |
| IP Scheme | .11/.12/.13 | Node number matches last octet |
| VIP | 10.10.30.10 | "Base" cluster address |
| Filesystem | ext4 | Most stable for containers |
| LVM | Full disk | Manually expanded from 100GB default |

### Issues Resolved

| Issue | Cause | Solution |
|-------|-------|----------|
| DHCP not working in installer | Gateway/DNS not persisting | Use OPNsense DHCP reservations |
| Nodes can't reach gateway | VLAN 30 not in trunk list | Add VLAN to Native AND Trunk |
| LVM only 100GB | Ubuntu installer bug | Edit ubuntu-lv size to max |
| Interface name | Docs said enp0s31f6 | Actual is eno1 (Intel I219-LM) |

### Documentation Refactor

Consolidated documentation to reduce redundancy:

**Files Consolidated:**
- HARDWARE_SPECS.md → Merged into CLUSTER_STATUS.md
- SWITCH_CONFIG.md → Merged into NETWORK_INTEGRATION.md
- PRE_INSTALLATION_CHECKLIST.md → Lessons in CHANGELOG.md
- KUBEADM.md → Split into KUBEADM_BOOTSTRAP.md (project-specific)

**Key Principle:** CLUSTER_STATUS.md is the single source of truth for all node/hardware values.

---

## January 10, 2026 — Switch Configuration

### VLAN Configuration

Configured LIANGUO LG-SG5T1 managed switch.

### Critical Learning

**VLAN must be in Trunk VLAN list even if set as Native VLAN** on this switch model.

---

## January 4, 2026 — Pre-Installation Decisions

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Network Speed | 1GbE initially | Identify bottlenecks first |
| VIP Strategy | kube-vip (ARP) | No OPNsense changes needed |
| Switch Type | Managed | VLAN support required |
| Ubuntu Install | Full disk + LVM | Simple, Longhorn uses directory |

---

## January 3, 2026 — Hardware Purchase

### Hardware Purchased

| Item | Qty | Specs |
|------|-----|-------|
| Lenovo M80q | 3 | i5-10400T, 16GB, 512GB NVMe |
| LIANGUO LG-SG5T1 | 1 | 5x 2.5GbE + 1x 10G SFP+ |

### Decision: M80q over M70q Gen 3

| Factor | M70q Gen 3 | M80q (purchased) |
|--------|------------|------------------|
| CPU Gen | 12th (hybrid) | 10th (uniform) |
| RAM | DDR5 | DDR4 |
| Price | Higher | **Lower** |
| Complexity | P+E cores | Simple |

10th gen uniform cores simpler for Kubernetes scheduling.

---

## December 31, 2025 — Network Adapter Correction

### Correction Applied

| Previous | Corrected |
|----------|-----------|
| Intel i226-V | **Intel i225-V rev 3** |

**Reason:** i226-V has ASPM + NVMe conflicts causing stability issues.

---

## December 2025 — Initial Planning

### Project Goals Defined

1. Learn Kubernetes via hands-on homelab
2. Master AWS EKS monitoring for work
3. Pass CKA certification by September 2026

### Key Requirements

- High availability (3-node minimum for etcd quorum)
- Stateful workload support (Longhorn)
- CKA exam alignment (kubeadm, not k3s)
