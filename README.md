# Kubernetes Homelab Cluster Project

![License](https://img.shields.io/badge/license-MIT-blue)
![Status](https://img.shields.io/badge/status-Cluster%20Running-brightgreen)
![Kubernetes](https://img.shields.io/badge/kubernetes-v1.35-326CE5?logo=kubernetes&logoColor=white)
![Cilium](https://img.shields.io/badge/cilium-1.18.6-F8C517?logo=cilium&logoColor=white)
![Ubuntu](https://img.shields.io/badge/ubuntu-24.04-E95420?logo=ubuntu&logoColor=white)

> **Owner:** Rommel Porras
> **Last Updated:** January 20, 2026

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
| CKA Prep | 📚 In Progress | 36-week roadmap |

**Current State:** [docs/CLUSTER_STATUS.md](docs/CLUSTER_STATUS.md) - Single source of truth

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
                             │   Dell 5090   │
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
| NFS | Dell 5090 | Media files (Immich photos, ARR) |

---

## Documentation

**[CLUSTER_STATUS.md](docs/CLUSTER_STATUS.md) is the single source of truth for all values.**

| Document | Purpose |
|----------|---------|
| [CLUSTER_STATUS.md](docs/CLUSTER_STATUS.md) | **Source of truth** — nodes, IPs, hardware |
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | Design decisions and rationale |
| [NETWORK_INTEGRATION.md](docs/NETWORK_INTEGRATION.md) | Network, VLANs, switch, kube-vip |
| [KUBEADM_BOOTSTRAP.md](docs/KUBEADM_BOOTSTRAP.md) | Cluster bootstrap commands |
| [STORAGE_SETUP.md](docs/STORAGE_SETUP.md) | Longhorn installation |
| [EXISTING_INFRA.md](docs/EXISTING_INFRA.md) | Dell 5090 NAS integration |
| [ROADMAP.md](docs/ROADMAP.md) | Timeline and CKA schedule |
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
| **Coming** | AdGuard Home, Uptime Kuma, workload migration |

See [ROADMAP.md](docs/ROADMAP.md) for detailed timeline.

---

## 🚀 Next Steps

1. **Deploy AdGuard Home** on K8s (DNS)
2. **Self-host Uptime Kuma** for uptime monitoring
3. **Migrate workloads** from Proxmox (Immich, ARR stack)
4. **Set up GitLab + Runner** for CI/CD

---

## 🎯 HA Architecture Status

| Component | Status | Implementation |
|-----------|--------|----------------|
| Control Plane | ✅ Running | 3-node etcd quorum + kube-vip VIP |
| Stateless Workloads | ✅ Ready | Replicas spread across nodes |
| Stateful Workloads | ✅ Running | Longhorn 2x replication |
| Monitoring | ✅ Running | Prometheus + Grafana + Loki |
| Alerting | ✅ Running | Discord + Email (3 recipients) |
| UPS Protection | ✅ Running | NUT + staggered graceful shutdown |
| NAS (media) | ⚠️ No HA | Single Dell 5090 (acceptable for media) |
