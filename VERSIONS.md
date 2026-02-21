# Versions

> Component versions for the homelab infrastructure.
> **Last Updated:** February 21, 2026

---

## Core Infrastructure (Stable)

| Component | Version | Role |
|-----------|---------|------|
| Proxmox VE | 9.1.4 | Hypervisor (2 nodes) |
| OPNsense | 25.7.5 | Firewall / Router |
| OpenMediaVault | 7.6.0-1 | NAS / NFS Storage |

---

## Kubernetes Cluster

| Component | Version | Status |
|-----------|---------|--------|
| Ubuntu Server | 24.04.3 LTS | Installed |
| Kernel | 6.8.0-90-generic | Installed |
| Kubernetes | v1.35.0 | Running (3 nodes) |
| containerd | 1.7.x | Installed |
| Cilium | 1.18.6 | Installed |
| Cilium CLI | v0.19.0 | Installed |
| Longhorn | 1.10.1 | Installed |
| kube-vip | v1.0.4 | Installed |

---

## Helm Charts

> **Why version pin?** Helm charts update independently of the apps they install.
> Running `helm install` without `--version` gives you "latest" which may break things.

| Chart | Version | App Version | Status | Namespace |
|-------|---------|-------------|--------|-----------|
| longhorn/longhorn | 1.10.1 | v1.10.1 | Installed | longhorn-system |
| cilium/cilium | 1.18.6 | v1.18.6 | Installed | kube-system |
| oci://quay.io/jetstack/charts/cert-manager | 1.19.2 | v1.19.2 | Installed | cert-manager |
| oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack | 81.0.0 | v0.88.0 | Installed | monitoring |
| oci://ghcr.io/grafana/helm-charts/loki | 6.49.0 | v3.6.3 | Installed | monitoring |
| grafana/alloy | 1.5.2 | v1.12.2 | Installed | monitoring |
| metrics-server/metrics-server | 3.13.0 | v0.8.0 | Installed | kube-system |
| gitlab/gitlab | 9.8.2 | v18.8.2 | Installed | gitlab |
| gitlab/gitlab-runner | 0.85.0 | v18.8.0 | Installed | gitlab-runner |
| prometheus-community/prometheus-blackbox-exporter | 11.7.0 | v0.28.0 | Installed | monitoring |
| tailscale/tailscale-operator | 1.94.1 | v1.94.1 | Installed | tailscale |
| oci://registry.k8s.io/nfd/charts/node-feature-discovery | 0.18.3 | v0.18.3 | Installed | node-feature-discovery |
| intel/intel-device-plugins-operator | 0.34.1 | v0.34.1 | Installed | intel-device-plugins |
| intel/intel-device-plugins-gpu | 0.34.1 | v0.34.1 | Installed | intel-device-plugins |
| prometheus-community/prometheus-smartctl-exporter | 0.16.0 | v0.14.0 | Installed | monitoring |

> **Note:** `grafana/loki-stack` is deprecated (Promtail EOL March 2026).
> Use `grafana/loki` + `grafana/alloy` instead.
>
> **Note:** cert-manager, kube-prometheus-stack, Loki, and NFD use OCI registry (recommended by upstream).
> No `helm repo add` needed - install directly from OCI URLs.
>
> **Note:** Grafana Alloy doesn't support OCI yet. Uses traditional Helm repo (`grafana`).

**Helm Repos:**
```bash
helm-homelab repo add longhorn https://charts.longhorn.io
helm-homelab repo add cilium https://helm.cilium.io/
helm-homelab repo add grafana https://grafana.github.io/helm-charts
helm-homelab repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm-homelab repo add gitlab https://charts.gitlab.io
helm-homelab repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm-homelab repo add tailscale https://pkgs.tailscale.com/helmcharts
helm-homelab repo add intel https://intel.github.io/helm-charts/
helm-homelab repo update
# Note: cert-manager, kube-prometheus-stack, Loki, and NFD use OCI - no repo add needed
```

---

## Gateway API

> **Why Gateway API?** Ingress API is feature-frozen; Gateway API is the successor.
> Cilium has native Gateway API support - no need for Traefik or NGINX.

| Component | Version | Status |
|-----------|---------|--------|
| Gateway API CRDs | v1.4.1 | Installed |
| Cilium gatewayAPI.enabled | true | Installed |
| Cilium kubeProxyReplacement | true | Installed |
| Cilium L2 Announcements | true | Installed |
| Homelab Gateway | 10.10.30.20 | Installed |
| kube-proxy | N/A | Removed (Cilium eBPF replaces) |

---

## Home Services (Phase 4)

> **Status:** v0.27.0 released. v0.27.1 fix in progress: Relaxed WEB quality profile (Sonarr/Radarr/Seerr) + Tdarr resolution filter (skip ≤ 1080p).

| Component | Version | Status | Notes |
|-----------|---------|--------|-------|
| AdGuard Home | v0.107.71 | Running | PRIMARY DNS (10.10.30.53) for all VLANs |
| Homepage | v1.9.0 | Running | 2 replicas, multi-tab layout |
| Glances | v3.3.1 | Running | On OMV (apt), password auth |
| cloudflared | 2026.1.1 | Running | 2 replicas, HA tunnel to Cloudflare Edge |
| Ghost (Dev) | 6.14.0 | Running | Theme development, internal access |
| Ghost (Prod) | 6.14.0 | Running | Public blog via Cloudflare Tunnel |
| MySQL (Ghost) | 8.4.8 | Running | LTS, per-environment StatefulSets |
| Invoicetron | Next.js 16.1.0 | Running | Invoice management (Bun + Prisma) |
| PostgreSQL (Invoicetron) | 18-alpine | Running | Invoicetron database (StatefulSet) |
| Uptime Kuma | v2.0.2 (rootless) | Running | Self-hosted uptime monitoring |
| MySpeed | 1.0.9 | Running | Internet speed test tracker (migrated from LXC) |
| TrafficAnalytics | 1.0.72 | Running | Ghost analytics proxy (browser → Tinybird) |
| Firefox Browser | 1147.0.3build1-1xtradeb1.2404.1-ls69 (LSIO) | Running | Persistent browser via KasmVNC (LAN-only) |
| Karakeep | 0.30.0 | Running | Bookmark manager with AI tagging (SQLite + s6-overlay) |
| Chrome (Karakeep) | alpine-chrome:124 | Running | Headless browser for page crawling |
| Meilisearch | v1.13.3 | Running | Full-text search engine for Karakeep |
| Ollama | 0.15.6 | Running | CPU-only LLM inference server |
| qwen2.5:3b | Q4_K_M | Running | Text model for Karakeep tagging (1.9 GB) |
| qwen3:1.7b | Q4_K_M | Running | General text model (1.4 GB) |
| moondream | Q4_K_M | Running | Vision model for image tagging (1.7 GB) |
| gemma3:1b | Q4_K_M | Running | Fallback text model (0.8 GB) |
| Tailscale Operator | v1.94.1 | Running | Watches CRDs, manages proxy pods |
| Tailscale Proxy (Connector) | v1.94.1 | Running | WireGuard subnet router (homelab-subnet) |
| Prowlarr | 2.3.0 (LSIO) | Running | Indexer manager (arr-stack namespace) |
| Sonarr | 4.0.16.2944-ls303 (LSIO) | Running | TV show management |
| Radarr | 6.0.4.10291-ls293 (LSIO) | Running | Movie management |
| qBittorrent | 5.1.4 (LSIO) | Running | Download client (arr-stack namespace) |
| Jellyfin | 10.11.6 (official) | Running | Media server (Intel QSV hardware transcoding) |
| Node Feature Discovery | v0.18.3 | Running | Auto-labels GPU nodes (OCI Helm chart) |
| Intel Device Plugins Operator | v0.34.1 | Running | Manages GPU plugin lifecycle |
| Intel GPU Plugin | v0.34.1 | Running | Advertises gpu.intel.com/i915 (sharedDevNum=3) |
| Bazarr | v1.5.5-ls338 (LSIO) | Running | Subtitle management |
| Seerr | v3.0.1 | Running | Media requests + discovery (replaces Jellyseerr/Overseerr) |
| Configarr | 1.20.0 | Running | TRaSH Guide quality profile sync (CronJob, daily 3AM) |
| Unpackerr | v0.14.5 | Running | RAR archive extraction daemon (no web UI) |
| Scraparr | 3.0.3 | Running | Prometheus metrics exporter for *ARR apps |
| Tdarr | 2.58.02 | Running | Library transcoding server (Intel QSV, internal node) |
| Recommendarr | v1.4.4 | Running | AI media recommendations (Ollama qwen2.5:3b) |
| Byparr | latest (v2.1.0) | Running | Cloudflare bypass proxy for Prowlarr indexers |
| tdarr-exporter | latest (homeylab) | Running | Prometheus metrics for Tdarr library stats (arr-stack ns) |
| qbittorrent-exporter | latest (esanchezm) | Running | Prometheus metrics for qBittorrent downloads (arr-stack ns) |
| smartctl-exporter | v0.14.0 | Running | NVMe S.M.A.R.T. DaemonSet on all 3 nodes (monitoring ns) |

**DNS Configuration:**
- Primary: 10.10.30.53 (K8s AdGuard via Cilium LoadBalancer)
- Secondary: 10.10.30.54 (FW LXC failover)

**HTTPRoutes:**
| Service | URL | Tier | Namespace |
|---------|-----|------|-----------|
| AdGuard | adguard.k8s.rommelporras.com | base | home |
| Homepage | portal.k8s.rommelporras.com | base | home |
| Grafana | grafana.k8s.rommelporras.com | base | monitoring |
| Longhorn | longhorn.k8s.rommelporras.com | base | longhorn-system |
| GitLab | gitlab.k8s.rommelporras.com | base | gitlab |
| GitLab Registry | registry.k8s.rommelporras.com | base | gitlab |
| Portfolio Prod | portfolio.k8s.rommelporras.com | base | portfolio-prod |
| Portfolio Dev | portfolio.dev.k8s.rommelporras.com | dev | portfolio-dev |
| Portfolio Stg | portfolio.stg.k8s.rommelporras.com | stg | portfolio-staging |
| Ghost Prod | blog.k8s.rommelporras.com | base | ghost-prod |
| Ghost Dev | blog.dev.k8s.rommelporras.com | dev | ghost-dev |
| Ghost Prod (public) | blog.rommelporras.com (Cloudflare Tunnel) | — | ghost-prod |
| Ghost Analytics (public) | blog-api.rommelporras.com (Cloudflare Tunnel) | — | ghost-prod |
| Invoicetron Prod | invoicetron.k8s.rommelporras.com | base | invoicetron-prod |
| Invoicetron Dev | invoicetron.dev.k8s.rommelporras.com | dev | invoicetron-dev |
| Invoicetron (public) | invoicetron.rommelporras.com (Cloudflare Tunnel) | — | invoicetron-prod |
| Uptime Kuma | uptime.k8s.rommelporras.com | base | uptime-kuma |
| Uptime Kuma (public) | status.rommelporras.com (Cloudflare Tunnel) | — | uptime-kuma |
| MySpeed | myspeed.k8s.rommelporras.com | base | home |
| Firefox Browser | browser.k8s.rommelporras.com | base | browser |
| Karakeep | karakeep.k8s.rommelporras.com | base | karakeep |
| Prowlarr | prowlarr.k8s.rommelporras.com | base | arr-stack |
| Sonarr | sonarr.k8s.rommelporras.com | base | arr-stack |
| Radarr | radarr.k8s.rommelporras.com | base | arr-stack |
| qBittorrent | qbit.k8s.rommelporras.com | base | arr-stack |
| Jellyfin | jellyfin.k8s.rommelporras.com | base | arr-stack |
| Bazarr | bazarr.k8s.rommelporras.com | base | arr-stack |
| Seerr | seerr.k8s.rommelporras.com | base | arr-stack |
| Tdarr | tdarr.k8s.rommelporras.com | base | arr-stack |
| Recommendarr | recommendarr.k8s.rommelporras.com | base | arr-stack |
| Alertmanager | alertmanager.k8s.rommelporras.com | base | monitoring |
| Prometheus | prometheus.k8s.rommelporras.com | base | monitoring |

**LoadBalancer Services:**
| Service | IP | Port | Namespace |
|---------|-----|------|-----------|
| AdGuard DNS | 10.10.30.53 | 53/UDP, 53/TCP | home |
| GitLab SSH | 10.10.30.21 | 22/TCP | gitlab |
| OTel Collector | 10.10.30.22 | 4317/TCP, 4318/TCP, 8889/TCP | monitoring |

---

## GitLab (Phase 4.6)

> **Status:** Running. Full DevOps platform with CI/CD pipelines.

| Component | Version | Status |
|-----------|---------|--------|
| GitLab CE | v18.8.2 | Running |
| GitLab Runner | v18.8.0 | Running |
| PostgreSQL (bundled) | 16.6 | Running |
| Redis (bundled) | 7.x | Running |
| Container Registry | v4.x | Running |

**Access:**
| Type | URL/IP |
|------|--------|
| Web UI | https://gitlab.k8s.rommelporras.com |
| Container Registry | https://registry.k8s.rommelporras.com |
| SSH (git clone) | ssh://git@ssh.gitlab.k8s.rommelporras.com (→ 10.10.30.21:22) |

**Storage (Longhorn):**
| PVC | Size |
|-----|------|
| gitlab-gitaly | 50Gi |
| gitlab-postgresql | 15Gi |
| gitlab-redis | 5Gi |
| gitlab-minio | 10Gi |

---

## UPS Monitoring (NUT)

> **Why NUT over PeaNUT?** PeaNUT has no data persistence (resets on refresh).
> NUT + Prometheus + Grafana provides 90-day history, alerting, and correlation with cluster metrics.

| Component | Version | Status | Location |
|-----------|---------|--------|----------|
| NUT (Network UPS Tools) | 2.8.1 | Installed | k8s-cp1 (server), cp2/cp3 (clients) |
| nut-exporter (DRuggeri) | 3.1.1 | Installed | monitoring namespace |
| CyberPower UPS | CP1600EPFCLCD | Connected | USB to k8s-cp1 |
| UPS Dashboard | custom | Installed | ConfigMap auto-provisioned |

**Staggered Shutdown Timers:**
| Node | Timer | Trigger |
|------|-------|---------|
| k8s-cp3 | 10 min | First to shutdown (reduce load) |
| k8s-cp2 | 20 min | Second to shutdown |
| k8s-cp1 | Low Battery | Last (sends UPS power-off) |

**Kubelet Graceful Shutdown:**
- `shutdownGracePeriod: 120s`
- `shutdownGracePeriodCriticalPods: 30s`

---

## Cluster Nodes

| Node | Role | IP | Hardware |
|------|------|-----|----------|
| k8s-cp1 | Control Plane | 10.10.30.11 | M80q i5-10400T |
| k8s-cp2 | Control Plane | 10.10.30.12 | M80q i5-10400T |
| k8s-cp3 | Control Plane | 10.10.30.13 | M80q i5-10400T |

**VIP:** 10.10.30.10 (api.k8s.rommelporras.com)

---

## Alerting & Notifications

> **Why Discord + Email?** Discord for real-time visibility, Email as redundant backup for critical alerts.
> Multiple email recipients ensure you get woken up at 3am when something critical breaks.

| Component | Value | Status |
|-----------|-------|--------|
| Alertmanager | v0.30.1 | Configured |
| Discord #incidents | Webhook | Configured |
| Discord #status | Webhook | Configured |
| Discord #versions | Webhook | Configured |
| SMTP Server | smtp.mail.me.com:587 | Configured |
| SMTP From | noreply@rommelporras.com | Configured |
| healthchecks.io | K8s Alertmanager check | Configured |

**Alert Routing:**

| Severity | Discord | Email |
|----------|---------|-------|
| Critical | #incidents | critical@, r3mmel023@, rommelcporras@ |
| Warning | #status | None |
| Info | (silenced) | None |

**Silenced Alerts (kubeadm false positives):**
- `KubeProxyDown`, `etcdInsufficientMembers`, `etcdMembersDown`
- `TargetDown` (kube-scheduler, kube-controller-manager, kube-etcd)

See `docs/todo/deferred.md` for future fix.

---

## Version Automation (Phase 4.27)

> **Status:** Deployed. Three-tool version tracking covering images, charts, and K8s itself.

| Component | Version | Status | Purpose |
|-----------|---------|--------|---------|
| version-checker | v0.10.0 | Running | Container + K8s version drift (Prometheus metrics) |
| Nova (CronJob) | v3.11.10 | Running | Weekly Helm chart drift digest (Discord) |
| Nova (CLI) | v3.11.10 | Installed | Local Helm chart analysis |
| Renovate Bot | GitHub App | Active | Automated image update PRs |

> **Note:** For detailed change history with decisions and rationale, see [docs/reference/CHANGELOG.md](docs/reference/CHANGELOG.md).
