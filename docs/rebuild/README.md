# Rebuild Documentation

> Step-by-step guides to rebuild the homelab cluster, organized by release tag.

---

## Release Timeline

| Release | Phases | Description | Guide |
|---------|--------|-------------|-------|
| v0.1.0 | Phase 1 | Foundation (Ubuntu, SSH, networking) | [v0.1.0-foundation.md](v0.1.0-foundation.md) |
| v0.2.0 | Phase 2 | Kubernetes Bootstrap (kubeadm, Cilium) | [v0.2.0-bootstrap.md](v0.2.0-bootstrap.md) |
| v0.3.0 | Phase 3.1-3.4 | Storage Infrastructure (Longhorn) | [v0.3.0-storage.md](v0.3.0-storage.md) |
| v0.4.0 | Phase 3.5-3.8 | Observability (Gateway, Monitoring, Logging, UPS) | [v0.4.0-observability.md](v0.4.0-observability.md) |
| v0.5.0 | Phase 3.9 | Alerting (Discord, Email notifications) | [v0.5.0-alerting.md](v0.5.0-alerting.md) |
| v0.6.0 | Phase 3.10, 4.1-4.4 | Home Services (AdGuard DNS, Homepage, Dead Man's Switch) | [v0.6.0-home-services.md](v0.6.0-home-services.md) |
| v0.7.0 | Phase 4.5 | Cloudflare Tunnel (HA, CiliumNetworkPolicy) | [v0.7.0-cloudflare.md](v0.7.0-cloudflare.md) |
| v0.8.0 | Phase 4.6 | GitLab CI/CD (CE, Runner, Container Registry) | [v0.8.0-gitlab.md](v0.8.0-gitlab.md) |
| v0.9.0 | Phase 4.8.1 | DNS Alerting (Blackbox Exporter, Probe CRD) | [v0.9.0-dns-alerting.md](v0.9.0-dns-alerting.md) |
| v0.10.0 | Phase 4.7 | Portfolio CI/CD (3-env deployment, GitFlow) | [v0.10.0-portfolio-cicd.md](v0.10.0-portfolio-cicd.md) |
| v0.11.0 | Phase 4.12 | Ghost Blog (Ghost 6.14.0, MySQL 8.4.8, dev/prod) | [v0.11.0-ghost-blog.md](v0.11.0-ghost-blog.md) |
| v0.12.0 | Phase 4.13 | Domain Migration (tiered wildcards, cert-manager) | [v0.12.0-domain-migration.md](v0.12.0-domain-migration.md) |
| v0.13.0 | Phase 4.14 | Uptime Kuma (endpoint monitoring, public status page) | [v0.13.0-uptime-kuma.md](v0.13.0-uptime-kuma.md) |
| v0.14.0 | Phase 4.9 | Invoicetron (Next.js + PostgreSQL, GitLab CI/CD, Cloudflare Access) | [v0.14.0-invoicetron.md](v0.14.0-invoicetron.md) |
| v0.15.0 | Phase 4.15 | Claude Code Monitoring (OTel Collector, Grafana dashboard) | [v0.15.0-claude-monitoring.md](v0.15.0-claude-monitoring.md) |
| v0.16.0 | Phase 4.20 | MySpeed Migration (Proxmox LXC to K8s) | [v0.16.0-myspeed.md](v0.16.0-myspeed.md) |
| v0.17.0 | Phase 4.12.1 | Ghost Web Analytics (Tinybird, TrafficAnalytics proxy) | [v0.17.0-ghost-analytics.md](v0.17.0-ghost-analytics.md) |
| v0.18.0 | Phase 4.21 | Firefox Browser (KasmVNC, persistent session) | [v0.18.0-firefox-browser.md](v0.18.0-firefox-browser.md) |
| v0.19.0 | Phase 2.1 | kube-vip Upgrade + Monitoring (v1.0.3→v1.0.4, Prometheus) | [v0.19.0-kube-vip-upgrade.md](v0.19.0-kube-vip-upgrade.md) |
| v0.20.0 | Phase 4.23 | Ollama Local AI (CPU-only LLM inference) | [v0.20.0-ollama.md](v0.20.0-ollama.md) |
| v0.21.0 | Phase 4.24 | Karakeep Migration (bookmark manager + AI tagging) | [v0.21.0-karakeep.md](v0.21.0-karakeep.md) |
| v0.22.0 | Phase 4.10 | Tailscale Operator (subnet router for remote access) | [v0.22.0-tailscale-operator.md](v0.22.0-tailscale-operator.md) |
| v0.23.0 | Phase 4.25 | ARR Media Stack (Prowlarr, Sonarr, Radarr, qBit, Jellyfin, Bazarr) | [v0.23.0-arr-stack.md](v0.23.0-arr-stack.md) |
| v0.24.0 | Phase 4.25b | Intel QSV Hardware Transcoding (NFD, GPU Plugin, Jellyfin QSV) | [v0.24.0-intel-qsv.md](v0.24.0-intel-qsv.md) |
| v0.25.0 | Phase 4.26 | ARR Companions (Seerr, Configarr, Unpackerr, Scraparr, Tdarr, Recommendarr, Byparr) | [v0.25.0-arr-companions.md](v0.25.0-arr-companions.md) |
| v0.26.0 | Phase 4.27 | Version Automation & Upgrade Runbooks (version-checker, Nova CronJob, Renovate) | [v0.26.0-version-automation.md](v0.26.0-version-automation.md) |
| v0.27.0 | Phase 4.28 | Alerting & Observability Improvements (15 new alerts, 11 Blackbox probes, smartctl-exporter, Longhorn + cert-manager ServiceMonitors, 11 Grafana dashboards) | [v0.27.0-alerting-improvements.md](v0.27.0-alerting-improvements.md) |

---

## Quick Start

To rebuild the entire cluster from scratch, follow the guides in order:

```bash
# 1. Foundation - Install Ubuntu, configure networking
docs/rebuild/v0.1.0-foundation.md

# 2. Bootstrap - Initialize Kubernetes cluster
docs/rebuild/v0.2.0-bootstrap.md

# 3. Storage - Install Longhorn distributed storage
docs/rebuild/v0.3.0-storage.md

# 4. Observability - Gateway API, monitoring, logging, UPS
docs/rebuild/v0.4.0-observability.md

# 5. Alerting - Discord and Email notifications
docs/rebuild/v0.5.0-alerting.md

# 6. Home Services - AdGuard DNS, Homepage, Dead Man's Switch
docs/rebuild/v0.6.0-home-services.md

# 7. Cloudflare Tunnel - HA external access
docs/rebuild/v0.7.0-cloudflare.md

# 8. GitLab CI/CD - Git, Runner, Container Registry
docs/rebuild/v0.8.0-gitlab.md

# 9. DNS Alerting - Blackbox exporter, synthetic DNS monitoring
docs/rebuild/v0.9.0-dns-alerting.md

# 10. Portfolio CI/CD - 3-env deployment with GitFlow
docs/rebuild/v0.10.0-portfolio-cicd.md

# 11. Ghost Blog - Ghost CMS with dev/prod environments
docs/rebuild/v0.11.0-ghost-blog.md

# 12. Domain Migration - Tiered wildcards (base/dev/stg)
docs/rebuild/v0.12.0-domain-migration.md

# 13. Uptime Kuma - Endpoint monitoring with public status page
docs/rebuild/v0.13.0-uptime-kuma.md

# 14. Invoicetron - Stateful app with PostgreSQL, GitLab CI/CD
docs/rebuild/v0.14.0-invoicetron.md

# 15. Claude Code Monitoring - OTel Collector, Grafana dashboard
docs/rebuild/v0.15.0-claude-monitoring.md

# 16. MySpeed Migration - Internet speed tracker from Proxmox LXC
docs/rebuild/v0.16.0-myspeed.md

# 17. Ghost Web Analytics - Tinybird integration, TrafficAnalytics proxy
docs/rebuild/v0.17.0-ghost-analytics.md

# 18. Firefox Browser - Persistent Firefox via KasmVNC
docs/rebuild/v0.18.0-firefox-browser.md

# 19. kube-vip Upgrade - v1.0.3→v1.0.4 + Prometheus monitoring
docs/rebuild/v0.19.0-kube-vip-upgrade.md

# 20. Ollama Local AI - CPU-only LLM inference
docs/rebuild/v0.20.0-ollama.md

# 21. Karakeep Migration - Bookmark manager with AI tagging
docs/rebuild/v0.21.0-karakeep.md

# 22. Tailscale Operator - Subnet router for remote access
docs/rebuild/v0.22.0-tailscale-operator.md

# 23. ARR Media Stack - Prowlarr, Sonarr, Radarr, qBit, Jellyfin, Bazarr
docs/rebuild/v0.23.0-arr-stack.md

# 24. Intel QSV Hardware Transcoding - NFD, GPU Plugin, Jellyfin QSV
docs/rebuild/v0.24.0-intel-qsv.md

# 25. ARR Companions - Seerr, Configarr, Unpackerr, Scraparr, Tdarr, Recommendarr, Byparr
docs/rebuild/v0.25.0-arr-companions.md

# 26. Version Automation - version-checker, Nova CronJob, Renovate Bot
docs/rebuild/v0.26.0-version-automation.md

# 27. Alerting & Observability - 15 alerts, 11 Blackbox probes, smartctl-exporter
docs/rebuild/v0.27.0-alerting-improvements.md
```

---

## Prerequisites

Before starting any rebuild, ensure you have:

### Hardware

| Node | Role | IP | Hardware |
|------|------|-----|----------|
| k8s-cp1 | Control Plane | 10.10.30.11 | M80q i5-10400T, 16GB, 512GB NVMe |
| k8s-cp2 | Control Plane | 10.10.30.12 | M80q i5-10400T, 16GB, 512GB NVMe |
| k8s-cp3 | Control Plane | 10.10.30.13 | M80q i5-10400T, 16GB, 512GB NVMe |

**VIP:** 10.10.30.10 (api.k8s.rommelporras.com)

### Workstation Tools

```bash
# 1Password CLI (for secrets)
op --version
eval $(op signin)

# Verify access
op read "op://Kubernetes/Grafana/password" >/dev/null && echo "1Password OK"
```

### DNS Records

Ensure these DNS records exist (AdGuard/OPNsense):

| Record | Type | Value |
|--------|------|-------|
| api.k8s.rommelporras.com | A | 10.10.30.10 |
| cp1.k8s.rommelporras.com | A | 10.10.30.11 |
| cp2.k8s.rommelporras.com | A | 10.10.30.12 |
| cp3.k8s.rommelporras.com | A | 10.10.30.13 |
| *.k8s.rommelporras.com | A | 10.10.30.20 |

---

## Component Versions

| Component | Version | Release |
|-----------|---------|---------|
| Ubuntu | 24.04.3 LTS | v0.1.0 |
| Kubernetes | v1.35.0 | v0.2.0 |
| containerd | 1.7.x | v0.2.0 |
| Cilium | 1.18.6 | v0.2.0 |
| kube-vip | v1.0.4 | v0.19.0 |
| Longhorn | 1.10.1 | v0.3.0 |
| Gateway API CRDs | v1.4.1 | v0.4.0 |
| cert-manager | 1.19.2 | v0.4.0 |
| kube-prometheus-stack | 81.0.0 | v0.4.0 |
| Loki | 6.49.0 | v0.4.0 |
| Alloy | 1.5.2 | v0.4.0 |
| NUT | 2.8.1 | v0.4.0 |
| nut-exporter | 3.1.1 | v0.4.0 |
| Alertmanager | v0.30.1 | v0.5.0 |
| AdGuard Home | v0.107.71 | v0.6.0 |
| Homepage | v1.9.0 | v0.6.0 |
| metrics-server | v0.8.0 | v0.6.0 |
| cloudflared | 2026.1.1 | v0.7.0 |
| GitLab CE | v18.8.2 | v0.8.0 |
| GitLab Runner | v18.8.0 | v0.8.0 |
| blackbox-exporter | v0.28.0 | v0.9.0 |
| Ghost | 6.14.0 | v0.11.0 |
| MySQL (Ghost) | 8.4.8 | v0.11.0 |
| Uptime Kuma | v2.0.2 | v0.13.0 |
| Invoicetron | Next.js 16.1.0 | v0.14.0 |
| PostgreSQL (Invoicetron) | 18-alpine | v0.14.0 |
| OTel Collector | v0.144.0 | v0.15.0 |
| MySpeed | 1.0.9 | v0.16.0 |
| TrafficAnalytics | 1.0.72 | v0.17.0 |
| Firefox (KasmVNC) | 1147.0.3build1-1xtradeb1.2404.1-ls69 | v0.18.0 |
| Ollama | 0.15.6 | v0.20.0 |
| qwen3:1.7b | Q4_K_M | v0.20.0 |
| moondream | Q4_K_M | v0.20.0 |
| gemma3:1b | Q4_K_M | v0.20.0 |
| Karakeep | 0.30.0 | v0.21.0 |
| Chrome (Karakeep) | alpine-chrome:124 | v0.21.0 |
| Meilisearch | v1.13.3 | v0.21.0 |
| qwen2.5:3b | Q4_K_M | v0.21.0 |
| Tailscale Operator | v1.94.1 | v0.22.0 |
| Tailscale Proxy (Connector) | v1.94.1 | v0.22.0 |
| Prowlarr | 2.3.0 (LSIO) | v0.23.0 |
| Sonarr | 4.0.16.2944-ls303 (LSIO) | v0.23.0 |
| Radarr | 6.0.4.10291-ls293 (LSIO) | v0.23.0 |
| qBittorrent | 5.1.4 (LSIO) | v0.23.0 |
| Jellyfin | 10.11.6 (official) | v0.23.0 |
| Bazarr | v1.5.5-ls338 (LSIO) | v0.23.0 |
| Node Feature Discovery | v0.18.3 | v0.24.0 |
| Intel Device Plugins Operator | v0.34.1 | v0.24.0 |
| Intel GPU Plugin | v0.34.1 | v0.24.0 |
| Seerr | v3.0.1 | v0.25.0 |
| Configarr | 1.20.0 | v0.25.0 |
| Unpackerr | v0.14.5 | v0.25.0 |
| Scraparr | 3.0.3 | v0.25.0 |
| Tdarr | 2.58.02 | v0.25.0 |
| Recommendarr | v1.4.4 | v0.25.0 |
| Byparr | latest | v0.25.0 |
| version-checker | v0.10.0 | v0.26.0 |
| Nova (CronJob) | v3.11.10 | v0.26.0 |
| smartctl-exporter | v0.14.0 | v0.27.0 |
| tdarr-exporter | latest (homeylab) | v0.27.0 |
| qbittorrent-exporter | latest (esanchezm) | v0.27.0 |

---

## Key Files

```
homelab/
├── helm/
│   ├── cilium/values.yaml              # v0.2.0+
│   ├── longhorn/values.yaml            # v0.3.0
│   ├── prometheus/values.yaml          # v0.4.0
│   ├── loki/values.yaml                # v0.4.0
│   ├── alloy/values.yaml               # v0.4.0
│   ├── gitlab/values.yaml              # v0.8.0
│   ├── gitlab-runner/values.yaml       # v0.8.0
│   ├── blackbox-exporter/values.yaml   # v0.9.0
│   ├── tailscale-operator/values.yaml # v0.22.0
│   ├── intel-gpu-plugin/values.yaml  # v0.24.0
│   └── smartctl-exporter/values.yaml # v0.27.0
│
├── manifests/
│   ├── cert-manager/                   # v0.4.0
│   │   └── cluster-issuer.yaml
│   ├── cilium/                         # v0.4.0
│   │   ├── ip-pool.yaml
│   │   └── l2-announcement.yaml
│   ├── gateway/                        # v0.4.0
│   │   ├── homelab-gateway.yaml
│   │   └── routes/
│   │       ├── gitlab.yaml             # v0.8.0
│   │       ├── gitlab-registry.yaml    # v0.8.0
│   │       ├── portfolio-dev.yaml      # v0.10.0
│   │       ├── portfolio-staging.yaml  # v0.10.0
│   │       ├── portfolio-prod.yaml     # v0.10.0
│   │       ├── invoicetron-dev.yaml    # v0.14.0
│   │       └── invoicetron-prod.yaml   # v0.14.0
│   ├── gitlab/                         # v0.8.0
│   │   └── gitlab-shell-lb.yaml
│   ├── home/                           # v0.6.0
│   │   └── adguard/
│   ├── portfolio/                      # v0.10.0
│   │   ├── deployment.yaml
│   │   └── rbac.yaml
│   ├── ghost-dev/                      # v0.11.0
│   │   ├── namespace.yaml
│   │   ├── mysql-statefulset.yaml
│   │   ├── mysql-service.yaml
│   │   ├── ghost-deployment.yaml
│   │   ├── ghost-service.yaml
│   │   ├── ghost-pvc.yaml
│   │   └── httproute.yaml
│   ├── ghost-prod/                     # v0.11.0
│   │   └── (same structure as ghost-dev)
│   ├── uptime-kuma/                    # v0.13.0
│   │   ├── namespace.yaml
│   │   ├── statefulset.yaml
│   │   ├── service.yaml
│   │   ├── httproute.yaml
│   │   └── networkpolicy.yaml
│   ├── invoicetron/                    # v0.14.0
│   │   ├── deployment.yaml
│   │   ├── postgresql.yaml
│   │   ├── rbac.yaml
│   │   ├── secret.yaml
│   │   └── backup-cronjob.yaml
│   ├── ai/                             # v0.20.0
│   │   ├── namespace.yaml
│   │   ├── ollama-deployment.yaml
│   │   ├── ollama-service.yaml
│   │   └── networkpolicy.yaml
│   ├── browser/                        # v0.18.0
│   │   ├── namespace.yaml
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   ├── pvc.yaml
│   │   └── httproute.yaml
│   ├── karakeep/                       # v0.21.0
│   │   ├── namespace.yaml
│   │   ├── secret.yaml
│   │   ├── karakeep-deployment.yaml
│   │   ├── karakeep-service.yaml
│   │   ├── chrome-deployment.yaml
│   │   ├── chrome-service.yaml
│   │   ├── meilisearch-deployment.yaml
│   │   ├── meilisearch-service.yaml
│   │   ├── httproute.yaml
│   │   └── networkpolicy.yaml
│   ├── tailscale/                      # v0.22.0
│   │   ├── namespace.yaml
│   │   ├── connector.yaml
│   │   └── networkpolicy.yaml
│   ├── arr-stack/                      # v0.23.0
│   │   ├── namespace.yaml
│   │   ├── nfs-pv-pvc.yaml
│   │   ├── networkpolicy.yaml
│   │   ├── arr-api-keys-secret.yaml
│   │   ├── prowlarr/{deployment,service,httproute}.yaml
│   │   ├── sonarr/{deployment,service,httproute}.yaml
│   │   ├── radarr/{deployment,service,httproute}.yaml
│   │   ├── qbittorrent/{deployment,service,httproute}.yaml
│   │   ├── jellyfin/{deployment,service,httproute}.yaml
│   │   ├── bazarr/{deployment,service,httproute}.yaml
│   │   ├── seerr/{deployment,service,httproute}.yaml       # v0.25.0
│   │   ├── configarr/{cronjob,configmap}.yaml              # v0.25.0
│   │   ├── unpackerr/deployment.yaml                       # v0.25.0
│   │   ├── scraparr/{deployment,service,servicemonitor}.yaml  # v0.25.0
│   │   ├── tdarr/{deployment,service,httproute}.yaml       # v0.25.0
│   │   ├── tdarr/tdarr-exporter.yaml                       # v0.27.0
│   │   ├── recommendarr/{deployment,service,httproute}.yaml  # v0.25.0
│   │   ├── byparr/{deployment,service}.yaml                # v0.25.0
│   │   └── qbittorrent/qbittorrent-exporter.yaml           # v0.27.0
│   ├── cloudflare/                     # v0.7.0
│   │   ├── deployment.yaml
│   │   ├── networkpolicy.yaml
│   │   └── ...
│   ├── storage/                        # v0.4.0
│   │   ├── longhorn/httproute.yaml
│   │   └── nfs-immich.yaml
│   ├── network-policies/               # v0.7.0+
│   └── monitoring/                     # v0.4.0 (reorganized into subdirs v0.27.0)
│       ├── alerts/
│       │   ├── logging-alerts.yaml             # v0.5.0
│       │   ├── ups-alerts.yaml                 # v0.4.0
│       │   ├── test-alert.yaml                 # v0.5.0
│       │   ├── adguard-dns-alert.yaml          # v0.9.0
│       │   ├── claude-alerts.yaml              # v0.15.0
│       │   ├── kube-vip-alerts.yaml            # v0.19.0
│       │   ├── ollama-alerts.yaml              # v0.20.0
│       │   ├── karakeep-alerts.yaml            # v0.21.0
│       │   ├── tailscale-alerts.yaml           # v0.22.0
│       │   ├── arr-alerts.yaml                 # v0.25.0
│       │   ├── version-checker-alerts.yaml     # v0.26.0
│       │   ├── uptime-kuma-alerts.yaml         # v0.27.0
│       │   ├── ghost-alerts.yaml               # v0.27.0
│       │   ├── invoicetron-alerts.yaml         # v0.27.0
│       │   ├── portfolio-alerts.yaml           # v0.27.0
│       │   ├── storage-alerts.yaml             # v0.27.0
│       │   ├── cert-alerts.yaml                # v0.27.0
│       │   ├── cloudflare-alerts.yaml          # v0.27.0
│       │   ├── apiserver-alerts.yaml           # v0.27.0
│       │   └── service-health-alerts.yaml      # v0.27.0
│       ├── probes/
│       │   ├── adguard-dns-probe.yaml          # v0.9.0
│       │   ├── uptime-kuma-probe.yaml          # v0.13.0
│       │   ├── ollama-probe.yaml               # v0.20.0
│       │   ├── karakeep-probe.yaml             # v0.21.0
│       │   ├── jellyfin-probe.yaml             # v0.27.0
│       │   ├── ghost-probe.yaml                # v0.27.0
│       │   ├── invoicetron-probe.yaml          # v0.27.0
│       │   ├── portfolio-probe.yaml            # v0.27.0
│       │   ├── seerr-probe.yaml                # v0.27.0
│       │   ├── tdarr-probe.yaml                # v0.27.0
│       │   ├── byparr-probe.yaml               # v0.27.0
│       │   └── bazarr-probe.yaml               # v0.27.0
│       ├── servicemonitors/
│       │   ├── loki-servicemonitor.yaml        # v0.4.0
│       │   ├── alloy-servicemonitor.yaml       # v0.4.0
│       │   ├── otel-collector-servicemonitor.yaml  # v0.15.0
│       │   ├── version-checker-servicemonitor.yaml  # v0.26.0
│       │   ├── longhorn-servicemonitor.yaml    # v0.27.0
│       │   ├── certmanager-servicemonitor.yaml # v0.27.0
│       │   ├── tdarr-servicemonitor.yaml       # v0.27.0 (namespace: arr-stack)
│       │   └── qbittorrent-servicemonitor.yaml # v0.27.0 (namespace: arr-stack)
│       ├── dashboards/
│       │   ├── ups-dashboard-configmap.yaml    # v0.4.0
│       │   ├── claude-dashboard-configmap.yaml # v0.15.0
│       │   ├── kube-vip-dashboard-configmap.yaml  # v0.19.0
│       │   ├── tailscale-dashboard-configmap.yaml  # v0.22.0
│       │   ├── jellyfin-dashboard-configmap.yaml   # v0.24.0
│       │   ├── arr-stack-dashboard-configmap.yaml  # v0.24.0
│       │   ├── scraparr-dashboard-configmap.yaml   # v0.25.0
│       │   ├── network-dashboard-configmap.yaml    # v0.25.0
│       │   ├── version-checker-dashboard-configmap.yaml  # v0.26.0
│       │   ├── longhorn-dashboard-configmap.yaml   # v0.27.0
│       │   └── service-health-dashboard-configmap.yaml  # v0.27.0
│       ├── exporters/
│       │   ├── nut-exporter.yaml               # v0.4.0
│       │   └── kube-vip-monitoring.yaml        # v0.19.0
│       ├── grafana/
│       │   ├── grafana-httproute.yaml          # v0.4.0
│       │   ├── loki-datasource.yaml            # v0.4.0
│       │   ├── alertmanager-httproute.yaml     # v0.4.0
│       │   └── prometheus-httproute.yaml       # v0.4.0
│       ├── otel/
│       │   ├── otel-collector.yaml             # v0.15.0
│       │   ├── otel-collector-config.yaml      # v0.15.0
│       │   └── otel-collector-servicemonitor.yaml  # v0.15.0
│       └── version-checker/
│           ├── version-checker-deployment.yaml # v0.26.0
│           ├── version-checker-rbac.yaml       # v0.26.0
│           ├── version-check-cronjob.yaml      # v0.26.0
│           ├── version-check-script.yaml       # v0.26.0
│           └── version-check-rbac.yaml         # v0.26.0
│
├── scripts/
│   ├── upgrade-prometheus.sh           # v0.5.0
│   ├── sync-ghost-prod-to-dev.sh      # v0.11.0
│   ├── sync-ghost-prod-to-local.sh    # v0.11.0
│   ├── test-cloudflare-networkpolicy.sh  # v0.7.0
│   └── apply-arr-secrets.sh           # v0.23.0
│
├── renovate.json                      # v0.26.0
```

---

## 1Password Items

| Item | Vault | Used In |
|------|-------|---------|
| Grafana | Kubernetes | v0.4.0 |
| Cloudflare DNS API Token | Kubernetes | v0.4.0 |
| NUT Admin | Kubernetes | v0.4.0 |
| NUT Monitor | Kubernetes | v0.4.0 |
| Discord Webhook Incidents | Kubernetes | v0.5.0 |
| Discord Webhook Status | Kubernetes | v0.5.0 |
| iCloud SMTP | Kubernetes | v0.5.0 |
| Homepage | Kubernetes | v0.6.0 |
| Healthchecks Ping URL | Kubernetes | v0.6.0 |
| Cloudflare Tunnel | Kubernetes | v0.7.0 |
| GitLab | Kubernetes | v0.8.0 |
| GitLab Runner | Kubernetes | v0.8.0 |
| Ghost Dev MySQL | Kubernetes | v0.11.0 |
| Ghost Prod MySQL | Kubernetes | v0.11.0 |
| Ghost Dev Admin API | Kubernetes | v0.11.0 |
| Ghost Prod Admin API | Kubernetes | v0.11.0 |
| Uptime Kuma | Kubernetes | v0.13.0 |
| Invoicetron Dev | Kubernetes | v0.14.0 |
| Invoicetron Prod | Kubernetes | v0.14.0 |
| Invoicetron Deploy Token | Kubernetes | v0.14.0 |
| Ghost Tinybird | Kubernetes | v0.17.0 |
| Firefox Browser | Kubernetes | v0.18.0 |
| Karakeep | Kubernetes | v0.21.0 |
| Tailscale K8s Operator | Kubernetes | v0.22.0 |
| ARR Stack | Kubernetes | v0.23.0 |
| Opensubtitles | Kubernetes | v0.23.0 |
| Discord Webhook Versions | Kubernetes | v0.26.0 |
