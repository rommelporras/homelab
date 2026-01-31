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

**VIP:** 10.10.30.10 (k8s-api.home.rommelporras.com)

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
| k8s-api.home.rommelporras.com | A | 10.10.30.10 |
| k8s-cp1.home.rommelporras.com | A | 10.10.30.11 |
| k8s-cp2.home.rommelporras.com | A | 10.10.30.12 |
| k8s-cp3.home.rommelporras.com | A | 10.10.30.13 |
| *.k8s.home.rommelporras.com | A | 10.10.30.20 |

---

## Component Versions

| Component | Version | Release |
|-----------|---------|---------|
| Ubuntu | 24.04.3 LTS | v0.1.0 |
| Kubernetes | v1.35.0 | v0.2.0 |
| containerd | 1.7.x | v0.2.0 |
| Cilium | 1.18.6 | v0.2.0 |
| kube-vip | v1.0.3 | v0.2.0 |
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
│   └── blackbox-exporter/values.yaml   # v0.9.0
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
│   │       └── portfolio-prod.yaml     # v0.10.0
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
│   ├── cloudflare/                     # v0.7.0
│   │   ├── deployment.yaml
│   │   ├── networkpolicy.yaml
│   │   └── ...
│   └── monitoring/                     # v0.4.0
│       ├── grafana-httproute.yaml
│       ├── loki-datasource.yaml
│       ├── loki-servicemonitor.yaml
│       ├── alloy-servicemonitor.yaml
│       ├── logging-alerts.yaml
│       ├── nut-exporter.yaml
│       ├── ups-alerts.yaml
│       ├── ups-dashboard-configmap.yaml
│       ├── test-alert.yaml             # v0.5.0
│       ├── adguard-dns-probe.yaml      # v0.9.0
│       └── adguard-dns-alert.yaml      # v0.9.0
│
├── scripts/
│   ├── upgrade-prometheus.sh           # v0.5.0
│   ├── sync-ghost-prod-to-dev.sh      # v0.11.0
│   └── sync-ghost-prod-to-local.sh    # v0.11.0
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
| Ghost Dev MySQL | Kubernetes | v0.11.0 |
| Ghost Prod MySQL | Kubernetes | v0.11.0 |
| Ghost Dev Admin API | Kubernetes | v0.11.0 |
| Ghost Prod Admin API | Kubernetes | v0.11.0 |
