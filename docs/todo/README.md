# TODO

> **Latest Release:** v0.26.0 (Version Automation & Upgrade Runbooks)
> **Goals:** CKA Certification (Sep 2026) + DevOps Upskilling (CI/CD, GitOps)

---

## Release Mapping

| Version | Content | Phases | Status |
|---------|---------|--------|--------|
| v0.1.0 | Project setup, documentation | Phase 1 | ✅ Released |
| v0.2.0 | Kubernetes HA cluster bootstrap | Phase 2 | ✅ Released |
| v0.3.0 | Storage infrastructure (Longhorn + NFS) | Phase 3.1-3.4 | ✅ Released |
| v0.4.0 | Observability (Gateway, Monitoring, Logging, UPS) | Phase 3.5-3.8 | ✅ Released |
| v0.5.0 | Alerting (Discord + Email + Dead Man's Switch) | Phase 3.9-3.10 | ✅ Released |
| v0.6.0 | Home Services (AdGuard, Homepage, Metrics Server) | Phase 4.1-4.4 | ✅ Released |
| v0.7.0 | Cloudflare Tunnel HA | Phase 4.5 | ✅ Released |
| v0.8.0 | GitLab CI/CD Platform | Phase 4.6 | ✅ Released |
| v0.9.0 | DNS Alerting (Blackbox exporter) | Phase 4.8.1 | ✅ Released |
| v0.10.0 | Portfolio CI/CD (3-env deployment) | Phase 4.7 | ✅ Released |
| v0.11.0 | Ghost Blog (dev/prod environments) | Phase 4.12 | ✅ Released |
| v0.12.0 | Domain Migration (tiered wildcards) | Phase 4.13 | ✅ Released |
| v0.13.0 | Uptime Kuma (endpoint monitoring) | Phase 4.14 | ✅ Released |
| v0.14.0 | Invoicetron (Next.js + PostgreSQL) | Phase 4.9 | ✅ Released |
| v0.15.0 | Claude Code Monitoring (OTel Collector) | Phase 4.15 | ✅ Released |
| v0.16.0 | MySpeed Migration | Phase 4.20 | ✅ Released |
| v0.17.0 | Ghost Web Analytics (Tinybird) | Phase 4.12.1 | ✅ Released |
| v0.18.0 | Firefox Browser (KasmVNC) | Phase 4.21 | ✅ Released |
| v0.19.0 | kube-vip Upgrade + Monitoring | Phase 2.1 | ✅ Released |
| v0.20.0 | Ollama Local AI (CPU) | Phase 4.23 | ✅ Released |
| v0.21.0 | Karakeep Migration | Phase 4.24 | ✅ Released |
| v0.22.0 | Tailscale Operator | Phase 4.10 | ✅ Released |
| v0.23.0 | ARR Media Stack | Phase 4.25 | ✅ Released |
| v0.24.0 | Intel QSV Hardware Transcoding | Phase 4.25b | ✅ Released |
| v0.25.0 | ARR Companions | Phase 4.26 | ✅ Released |
| v0.25.1 | ARR Alert and Byparr Fixes | — | ✅ Released |
| v0.25.2 | ARR Media Quality and Playback Fixes | — | ✅ Released |
| v0.26.0 | Version Automation & Upgrade Runbooks | Phase 4.27 | ✅ Released |
| v0.27.0 | Alerting & Observability Improvements | Phase 4.28 | ⬜ Planned |
| v0.28.0 | Production Hardening | Phase 5 | ⬜ Planned |
| v1.0.0 | CKA-ready cluster | Phase 6 + exam prep | ⬜ Target: Sep 2026 |

---

## Phase Index

### Completed

| Phase | Description | File |
|-------|-------------|------|
| 1 | Foundation (hardware, VLANs, Ubuntu) | [phase-1-foundation.md](completed/phase-1-foundation.md) |
| 2 | Kubernetes Bootstrap (kubeadm, Cilium) | [phase-2-bootstrap.md](completed/phase-2-bootstrap.md) |
| 3.1-3.4 | Storage (Longhorn + NFS) | [phase-3.1-3.4-storage.md](completed/phase-3.1-3.4-storage.md) |
| 3.5-3.8 | Gateway API, Monitoring, Logging, UPS | [phase-3.5-3.8-monitoring.md](completed/phase-3.5-3.8-monitoring.md) |
| 3.9 | Alerting (Discord + Email) | [phase-3.9-alerting.md](completed/phase-3.9-alerting.md) |
| 3.10 | Dead Man's Switch | [phase-3.10-deadman-switch.md](completed/phase-3.10-deadman-switch.md) |
| 4.1-4.4 | Stateless Workloads (AdGuard, Homepage) | [phase-4.1-4.4-stateless.md](completed/phase-4.1-4.4-stateless.md) |
| 4.5 | Cloudflare Tunnel HA | [phase-4.5-cloudflare.md](completed/phase-4.5-cloudflare.md) |
| 4.6 | GitLab CI/CD Platform | [phase-4.6-gitlab.md](completed/phase-4.6-gitlab.md) |
| 4.7 | Portfolio Migration | [phase-4.7-portfolio.md](completed/phase-4.7-portfolio.md) |
| 4.8 | AdGuard Client IP Fix | [phase-4.8-adguard-client-ip.md](completed/phase-4.8-adguard-client-ip.md) |
| 4.8.1 | DNS Alerting (Blackbox exporter) | [phase-4.8.1-adguard-dns-alerting.md](completed/phase-4.8.1-adguard-dns-alerting.md) |
| 4.9 | Invoicetron Migration | [phase-4.9-invoicetron.md](completed/phase-4.9-invoicetron.md) |
| 4.12 | Ghost Blog (dev/prod) | [phase-4.12-ghost-blog.md](completed/phase-4.12-ghost-blog.md) |
| 4.13 | Domain Migration | [phase-4.13-domain-migration.md](completed/phase-4.13-domain-migration.md) |
| 4.14 | Uptime Kuma | [phase-4.14-uptime-kuma.md](completed/phase-4.14-uptime-kuma.md) |
| 4.15 | Claude Code Monitoring | [phase-4.15-claude-monitoring.md](completed/phase-4.15-claude-monitoring.md) |
| 4.20 | MySpeed Migration | [phase-4.20-myspeed.md](completed/phase-4.20-myspeed.md) |
| 4.12.1 | Ghost Web Analytics (Tinybird) | [phase-4.12.1-ghost-analytics.md](completed/phase-4.12.1-ghost-analytics.md) |
| 4.21 | Firefox Browser (KasmVNC) | [phase-4.21-firefox-browser.md](completed/phase-4.21-firefox-browser.md) |
| 2.1 | kube-vip Upgrade + Monitoring | [phase-2.1-kube-vip-upgrade.md](completed/phase-2.1-kube-vip-upgrade.md) |
| 4.23 | Ollama Local AI (CPU) | [phase-4.23-ollama.md](completed/phase-4.23-ollama.md) |
| 4.24 | Karakeep Migration | [phase-4.24-karakeep.md](completed/phase-4.24-karakeep.md) |
| 4.10 | Tailscale Operator | [phase-4.10-tailscale-operator.md](completed/phase-4.10-tailscale-operator.md) |
| 4.25 | ARR Media Stack | [phase-4.25-arr-stack.md](completed/phase-4.25-arr-stack.md) |
| 4.25b | Intel QSV Hardware Transcoding | [phase-4.25b-intel-qsv.md](completed/phase-4.25b-intel-qsv.md) |
| 4.26 | ARR Companions | [phase-4.26-arr-companions.md](completed/phase-4.26-arr-companions.md) |
| 4.27 | Version Automation & Upgrade Runbooks | [phase-4.27-version-automation.md](completed/phase-4.27-version-automation.md) |

### Planned

| Phase | Description | File |
|-------|-------------|------|
| 4.28 | Alerting & Observability Improvements | [phase-4.28-alerting-observability.md](phase-4.28-alerting-observability.md) |
| 5 | Production Hardening | [phase-5-hardening.md](phase-5-hardening.md) |
| 6 | CKA Focused Learning | [phase-6-cka.md](phase-6-cka.md) |

### Deferred

| Description | File |
|-------------|------|
| Immich, Firmware, Control Plane Metrics, NVMe S.M.A.R.T. | [deferred.md](deferred.md) |

---

## Namespace Strategy

> **Pattern:** Hybrid — shared infrastructure + self-contained projects

### System Namespaces (Shared Infrastructure)
| Namespace | Purpose |
|-----------|---------|
| `kube-system` | Control plane (exists) |
| `longhorn-system` | Distributed storage (exists) |
| `monitoring` | ALL observability (Prometheus, Grafana, Loki, exporters) |
| `cert-manager` | TLS certificate management |
| `cloudflare` | Cloudflare Tunnel (external access) |

### CI/CD Namespaces
| Namespace | Contents | Storage |
|-----------|----------|---------|
| `gitlab` | GitLab (web, sidekiq, gitaly, registry) | PostgreSQL, Redis, Git repos |
| `gitlab-runner` | GitLab Runner (Kubernetes executor) | Ephemeral (build caches) |

### Project Namespaces (Self-Contained Apps)
| Namespace | Contents | Database |
|-----------|----------|----------|
| `home` | AdGuard, Homepage, MySpeed | None (stateless) / SQLite |
| `ghost-prod` | Ghost Blog, MySQL, TrafficAnalytics | MySQL 8.4.8 |
| `ghost-dev` | Ghost Blog (dev), MySQL | MySQL 8.4.8 |
| `portfolio` | rommelporras.com (static Next.js) | None (static nginx) |
| `invoicetron` | Invoice processing app | Own PostgreSQL |
| `uptime-kuma` | Uptime Kuma endpoint monitoring | SQLite (PVC) |
| `browser` | Firefox browser (KasmVNC) | None (PVC for profile) |
| `ai` | Ollama LLM inference server | None (PVC for models) |
| `karakeep` | Karakeep bookmark manager (web, Chrome, Meilisearch) | SQLite (PVC) |
| `tailscale` | Tailscale Operator + Connector (subnet router) | None (stateless) |
| `immich` | Immich server, ML, Redis | Own PostgreSQL |
| `arr-stack` | Prowlarr, Sonarr, Radarr, qBittorrent, Jellyfin, Bazarr, Seerr, Configarr, Unpackerr, Scraparr, Tdarr, Recommendarr, Byparr | SQLite (config on Longhorn, media on NFS) |
| `node-feature-discovery` | NFD (auto-labels GPU nodes) | None (stateless) |
| `intel-device-plugins` | Intel GPU Plugin Operator + GPU Plugin DaemonSet | None (stateless) |

### Why This Pattern
- **Matches Docker Compose** — each project = one namespace
- **Simple service discovery** — `postgres:5432` works within namespace
- **Easy cleanup** — `kubectl delete namespace immich` removes everything
- **Isolated failures** — Immich DB issue doesn't affect ARR
- **Scoped NetworkPolicies** — each project controls its own access

### Database Strategy
- **Separate PostgreSQL per project** (not one shared instance)
- Each project's database lives in its own namespace
- Matches your Docker Compose setup

---

## Quick Reference

```bash
# Cluster health check
kubectl-homelab get nodes
kubectl-homelab get pods -A | grep -v Running

# Longhorn status
kubectl-homelab -n longhorn-system get pods
kubectl-homelab -n longhorn-system get volumes.longhorn.io

# Monitoring
kubectl-homelab -n monitoring port-forward svc/prometheus-grafana 3000:80

# etcd backup (CKA essential)
sudo etcdctl snapshot save /backup/etcd-$(date +%Y%m%d).db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key
```

---

## Learning Checkpoints

After each phase, you should be able to:

| Phase | Checkpoint |
|-------|------------|
| 3 | Explain PV/PVC binding, create StorageClass, troubleshoot PVC Pending |
| 4 | Deploy Deployments, configure Services, manage ConfigMaps, create Ingress |
| 5 | Write NetworkPolicies, configure RBAC, enforce Pod Security |
| 6 | Pass CKA with confidence |
| Deferred | Configure Immich (PostgreSQL + Redis + ML), expose control plane metrics |
