# Kubernetes Homelab Cluster Project

![License](https://img.shields.io/badge/license-MIT-blue)
![Status](https://img.shields.io/badge/status-Cluster%20Running-brightgreen)
![Kubernetes](https://img.shields.io/badge/kubernetes-v1.35-326CE5?logo=kubernetes&logoColor=white)
![Cilium](https://img.shields.io/badge/cilium-1.18.6-F8C517?logo=cilium&logoColor=white)
![Ubuntu](https://img.shields.io/badge/ubuntu-24.04-E95420?logo=ubuntu&logoColor=white)
![Alertmanager](https://healthchecks.io/badge/e8a6a1d7-c42b-428a-901e-5f28d9/EOi8irKL.svg)

> **Owner:** Rommel Porras
> **Last Updated:** February 9, 2026

---

## 🎯 Project Goals (2026)

1. **Learn Kubernetes fundamentals** via hands-on homelab cluster
2. **Master AWS EKS monitoring** for work projects
3. **Pass CKA certification** by September 2026

---

## 📊 Current Status

| Phase | Status | Notes |
|-------|--------|-------|
| Hardware Purchase | ✅ Complete | 3x M80q + LIANGUO switch |
| Switch Configuration | ✅ Complete | VLANs configured |
| Ubuntu Installation | ✅ Complete | All 3 nodes running |
| K8s Prerequisites | ✅ Complete | Ansible automated |
| Cluster Bootstrap | ✅ Complete | 3-node HA with kubeadm |
| Cilium CNI | ✅ Complete | v1.18.6 with Gateway API |
| Longhorn Storage | ✅ Complete | Distributed storage (2x replication) |
| Gateway API + TLS | ✅ Complete | Let's Encrypt wildcard certs |
| Monitoring | ✅ Complete | Prometheus + Grafana |
| Logging | ✅ Complete | Loki + Alloy |
| UPS Monitoring | ✅ Complete | NUT + graceful shutdown |
| Alerting | ✅ Complete | Discord + Email notifications |
| Home Services | ✅ Complete | AdGuard DNS, Homepage dashboard |
| Cloudflare Tunnel | ✅ Complete | HA tunnel (2 replicas), zero-trust access |
| GitLab CI/CD | ✅ Complete | GitLab CE + Runner + Container Registry |
| Portfolio CI/CD | ✅ Complete | 3-env deployment (dev/staging/prod) |
| DNS Alerting | ✅ Complete | Blackbox exporter + synthetic DNS probe |
| Ghost Blog | ✅ Complete | Dev + Prod environments, Cloudflare Tunnel |
| Domain Migration | ✅ Complete | Tiered wildcards (base/dev/stg) |
| Uptime Kuma | ✅ Complete | Endpoint monitoring + public status page |
| Invoicetron | ✅ Complete | Stateful app (Next.js + PostgreSQL) with GitLab CI/CD |
| Claude Code Monitoring | ✅ Complete | OTel Collector → Prometheus + Loki + Grafana dashboard |
| MySpeed Migration | ✅ Complete | Internet speed tracker migrated from Proxmox LXC |
| Ghost Web Analytics | ✅ Complete | Cookie-free Tinybird analytics for blog |
| Firefox Browser | ✅ Complete | Persistent browser via KasmVNC (LAN-only) |
| CKA Prep | 📚 In Progress | 36-week roadmap |

**Current State:** [docs/context/Cluster.md](docs/context/Cluster.md) - Single source of truth

---

## 🖥️ Cluster Hardware

| Node | Hostname | IP | MAC |
|------|----------|-----|-----|
| 1 | k8s-cp1 | 10.10.30.11 | 88:a4:c2:9d:87:d6 |
| 2 | k8s-cp2 | 10.10.30.12 | 88:a4:c2:6b:1c:44 |
| 3 | k8s-cp3 | 10.10.30.13 | 88:a4:c2:64:2d:81 |

### Hardware Specs (Verified)

| Spec | Value |
|------|-------|
| **Model** | Lenovo ThinkCentre M80q |
| **CPU** | Intel Core i5-10400T (6c/12t) |
| **RAM** | 16GB DDR4 |
| **Storage** | 512GB NVMe |
| **NIC** | Intel I219-LM (1GbE) |

### Network Switch

| Spec | Value |
|------|-------|
| **Model** | LIANGUO LG-SG5T1 |
| **Ports** | 5x 2.5GbE + 1x 10G SFP+ |
| **Type** | Managed |
| **Management IP** | 10.10.69.3 |

---

## 🗂️ Target Architecture

```
                    ┌─────────────────────────────────────────┐
                    │       K8s HA Control Plane              │
                    │          VIP: 10.10.30.10               │
                    │         (kube-vip ARP mode)             │
                    └────────────────┬────────────────────────┘
                                     │
        ┌────────────────────────────┼────────────────────────────┐
        │                            │                            │
   ┌────┴─────┐                 ┌────┴─────┐                 ┌────┴─────┐
   │  k8s-cp1 │                 │  k8s-cp2 │                 │  k8s-cp3 │
   │   M80q   │                 │   M80q   │                 │   M80q   │
   │i5-10400T │                 │i5-10400T │                 │i5-10400T │
   ├──────────┤                 ├──────────┤                 ├──────────┤
   │ Control  │                 │ Control  │                 │ Control  │
   │ + etcd   │                 │ + etcd   │                 │ + etcd   │
   │ + Work   │                 │ + Work   │                 │ + Work   │
   ├──────────┤                 ├──────────┤                 ├──────────┤
   │ Longhorn │◄───────────────►│ Longhorn │◄───────────────►│ Longhorn │
   │ (NVMe)   │    Sync (2x)    │ (NVMe)   │    Sync (2x)    │ (NVMe)   │
   └────┬─────┘                 └────┬─────┘                 └────┬─────┘
        │                            │                            │
        └────────────────────────────┼────────────────────────────┘
                                     │
                             ┌───────┴───────┐
                             │  1GbE Network │
                             │  VLAN 30      │
                             └───────┬───────┘
                                     │
                             ┌───────┴───────┐
                             │   Dell 3090   │
                             │   NAS (OMV)   │
                             │  NFS Shares   │
                             └───────────────┘
```

---

## 🔑 Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| **Hardware** | M80q (i5-10400T) | Best value, uniform cores, CKA sufficient |
| **OS** | Ubuntu 24.04 LTS + kubeadm | CKA exam alignment |
| **CNI** | Cilium | NetworkPolicy support for CKA |
| **Storage** | Longhorn on NVMe | Full HA from day one, no extra hardware |
| **Network** | 1GbE built-in | Identify bottlenecks before upgrading |
| **VIP** | kube-vip (ARP mode) | No OPNsense changes needed |

---

## 💾 Storage Strategy

| Storage Type | Location | Purpose |
|--------------|----------|---------|
| OS + etcd | NVMe (~50GB) | Ubuntu, container images, etcd |
| Longhorn | NVMe (~400GB) | Distributed replicated storage |
| NFS | Dell 3090 | Media files (Immich photos, ARR) |

---

## Documentation

**[Cluster.md](docs/context/Cluster.md) is the single source of truth for all values.**

| Document | Purpose |
|----------|---------|
| [Cluster.md](docs/context/Cluster.md) | **Source of truth** — nodes, IPs, hardware |
| [Architecture.md](docs/context/Architecture.md) | Design decisions and rationale |
| [Networking.md](docs/context/Networking.md) | Network, VLANs, switch, kube-vip |
| [KUBEADM_BOOTSTRAP.md](docs/KUBEADM_BOOTSTRAP.md) | Cluster bootstrap commands |
| [Storage.md](docs/context/Storage.md) | Longhorn and NFS storage |
| [Gateway.md](docs/context/Gateway.md) | HTTPRoutes, TLS, cert-manager |
| [Monitoring.md](docs/context/Monitoring.md) | Prometheus, Grafana, Alerting |
| [ExternalServices.md](docs/context/ExternalServices.md) | GA4, GTM, Cloudflare, SMTP, domain |
| [K8S_LEARNING_GUIDE.md](docs/K8S_LEARNING_GUIDE.md) | CKA study material |

### Rebuild Guides

Step-by-step instructions to rebuild the cluster from scratch:

| Guide | Phases | Description |
|-------|--------|-------------|
| [v0.1.0-foundation](docs/rebuild/v0.1.0-foundation.md) | Phase 1 | Ubuntu, SSH, networking |
| [v0.2.0-bootstrap](docs/rebuild/v0.2.0-bootstrap.md) | Phase 2 | kubeadm, Cilium |
| [v0.3.0-storage](docs/rebuild/v0.3.0-storage.md) | Phase 3.1-3.4 | Longhorn |
| [v0.4.0-observability](docs/rebuild/v0.4.0-observability.md) | Phase 3.5-3.8 | Gateway, Monitoring, Logging, UPS |
| [v0.5.0-alerting](docs/rebuild/v0.5.0-alerting.md) | Phase 3.9 | Discord + Email notifications |
| [v0.6.0-home-services](docs/rebuild/v0.6.0-home-services.md) | Phase 3.10, 4.1-4.4 | AdGuard, Homepage, Metrics Server, Dead Man's Switch |
| [v0.7.0-cloudflare](docs/rebuild/v0.7.0-cloudflare.md) | Phase 4.5 | Cloudflare Tunnel (HA, CiliumNetworkPolicy) |
| [v0.8.0-gitlab](docs/rebuild/v0.8.0-gitlab.md) | Phase 4.6 | GitLab CE, Runner, Container Registry |
| [v0.9.0-dns-alerting](docs/rebuild/v0.9.0-dns-alerting.md) | Phase 4.8.1 | Blackbox exporter, synthetic DNS monitoring |
| [v0.10.0-portfolio-cicd](docs/rebuild/v0.10.0-portfolio-cicd.md) | Phase 4.7 | Portfolio CI/CD with 3-env deployment |
| [v0.11.0-ghost-blog](docs/rebuild/v0.11.0-ghost-blog.md) | Phase 4.12 | Ghost CMS with dev/prod environments |
| [v0.12.0-domain-migration](docs/rebuild/v0.12.0-domain-migration.md) | Phase 4.13 | Domain migration to `*.k8s.rommelporras.com` with tiered wildcards |
| [v0.13.0-uptime-kuma](docs/rebuild/v0.13.0-uptime-kuma.md) | Phase 4.14 | Uptime Kuma endpoint monitoring + public status page |
| [v0.14.0-invoicetron](docs/rebuild/v0.14.0-invoicetron.md) | Phase 4.9 | Invoicetron (Next.js + PostgreSQL) with GitLab CI/CD |
| [v0.15.0-claude-monitoring](docs/rebuild/v0.15.0-claude-monitoring.md) | Phase 4.15 | Claude Code monitoring via OTel Collector |
| [v0.16.0-myspeed](docs/rebuild/v0.16.0-myspeed.md) | Phase 4.20 | MySpeed internet speed tracker migration |
| [v0.17.0-ghost-analytics](docs/rebuild/v0.17.0-ghost-analytics.md) | Phase 4.12.1 | Ghost web analytics with Tinybird |
| [v0.18.0-firefox-browser](docs/rebuild/v0.18.0-firefox-browser.md) | Phase 4.21 | Containerized Firefox browser (KasmVNC) |

### Reference

| Document | Purpose |
|----------|---------|
| [reference/PRE_INSTALLATION_CHECKLIST.md](docs/reference/PRE_INSTALLATION_CHECKLIST.md) | Completed setup steps |
| [reference/CHANGELOG.md](docs/reference/CHANGELOG.md) | Decision history |
| [reference/PROXMOX_OPNSENSE_GUIDE.md](docs/reference/PROXMOX_OPNSENSE_GUIDE.md) | Existing infrastructure overview |

---

## 🤖 Ansible Automation

Full cluster bootstrap is automated via Ansible playbooks in `ansible/playbooks/`:

| Playbook | Purpose |
|----------|---------|
| 00-preflight.yml | Pre-flight checks (cgroup v2, network, DNS) |
| 01-prerequisites.yml | System prep (swap, modules, containerd, kubeadm) |
| 02-kube-vip.yml | VIP setup with K8s 1.29+ workaround |
| 03-init-cluster.yml | kubeadm init with config generation |
| 04-cilium.yml | CNI installation with checksum verification |
| 05-join-cluster.yml | Control plane join with post-join reboot |

```bash
# Run a playbook
cd ansible && ansible-playbook -i inventory.yml playbooks/00-preflight.yml
```

---

## 🛤️ Project Journey

| Date | Milestone |
|------|-----------|
| **Jan 3, 2026** | Hardware purchased (3x M80q + LIANGUO switch) |
| **Jan 10, 2026** | Switch VLANs configured |
| **Jan 11, 2026** | Ubuntu 24.04 installed, SSH configured |
| **Jan 16, 2026** | **Kubernetes HA cluster running** (v1.35.0 + Cilium) |
| **Jan 17, 2026** | Longhorn distributed storage deployed |
| **Jan 18, 2026** | Gateway API + Let's Encrypt TLS configured |
| **Jan 18, 2026** | Prometheus + Grafana monitoring stack deployed |
| **Jan 19, 2026** | Loki + Alloy logging stack deployed |
| **Jan 20, 2026** | NUT UPS monitoring + graceful shutdown configured |
| **Jan 20, 2026** | **Alertmanager notifications** (Discord + Email) |
| **Jan 22, 2026** | **Home Services deployed** (AdGuard DNS, Homepage dashboard) |
| **Jan 22, 2026** | DNS cutover - K8s AdGuard now PRIMARY for all VLANs |
| **Jan 22, 2026** | **Dead Man's Switch** - healthchecks.io monitors alerting health |
| **Jan 24, 2026** | **Cloudflare Tunnel** migrated to K8s (HA, CiliumNetworkPolicy) |
| **Jan 25, 2026** | **GitLab CE** deployed with Runner, Registry, SSH access (Phase 4.6) |
| **Jan 28, 2026** | **Portfolio CI/CD** migrated from PVE VM to K8s (Phase 4.7) |
| **Jan 30, 2026** | **DNS Alerting** — Blackbox exporter + synthetic DNS monitoring (Phase 4.8.1) |
| **Jan 31, 2026** | **Ghost Blog** — Ghost 6.14.0 + MySQL 8.4.8 with dev/prod environments (Phase 4.12) |
| **Feb 2, 2026** | **Domain Migration** — `*.k8s.rommelporras.com` with tiered wildcards (Phase 4.13) |
| **Feb 3, 2026** | **Uptime Kuma** — Endpoint monitoring + public status page via Cloudflare Tunnel (Phase 4.14) |
| **Feb 5, 2026** | **Invoicetron** — Stateful app (Next.js + PostgreSQL) migrated to K8s with GitLab CI/CD (Phase 4.9) |
| **Feb 5, 2026** | **Claude Code Monitoring** — OTel Collector + Grafana dashboard + cost alerts (Phase 4.15) |
| **Feb 8, 2026** | **MySpeed Migration** — Internet speed tracker from Proxmox LXC to K8s (Phase 4.20) |
| **Feb 9, 2026** | **Ghost Web Analytics** — Tinybird integration with TrafficAnalytics proxy for cookie-free blog analytics (Phase 4.12.1) |
| **Feb 9, 2026** | **Firefox Browser** — Persistent Firefox via KasmVNC with AdGuard DNS, basic auth, session persistence (Phase 4.21) |
| **Coming** | Cloudflare Analytics, Ollama AI, Karakeep Migration |

See rebuild guides below for detailed project history.

---

## 🚀 Next Steps

1. **Deploy Cloudflare Traffic Analytics** for infrastructure-level metrics (Phase 4.22)
2. **Deploy Ollama Local AI** for CPU-based local AI inference (Phase 4.23)
3. **CKA Certification** - September 2026 target

---

## 🎯 HA Architecture Status

| Component | Status | Implementation |
|-----------|--------|----------------|
| Control Plane | ✅ Running | 3-node etcd quorum + kube-vip VIP |
| Stateless Workloads | ✅ Running | AdGuard, Homepage (replicas spread) |
| Stateful Workloads | ✅ Running | Longhorn 2x replication |
| Monitoring | ✅ Running | Prometheus + Grafana + Loki |
| Alerting | ✅ Running | Discord + Email + synthetic DNS probing |
| UPS Protection | ✅ Running | NUT + staggered graceful shutdown |
| External Access | ✅ Running | Cloudflare Tunnel (2 replicas, anti-affinity) |
| NAS (media) | ⚠️ No HA | Single Dell 3090 (acceptable for media) |
