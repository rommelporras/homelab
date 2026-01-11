# Kubernetes Homelab Cluster Project

![License](https://img.shields.io/badge/license-MIT-blue)
![Status](https://img.shields.io/badge/status-Phase%201%20Complete-green)
![Kubernetes](https://img.shields.io/badge/kubernetes-v1.35-326CE5?logo=kubernetes&logoColor=white)
![Proxmox](https://img.shields.io/badge/proxmox-9.1-E57000?logo=proxmox&logoColor=white)
![OPNsense](https://img.shields.io/badge/opnsense-25.7-D94F00)
![Ubuntu](https://img.shields.io/badge/ubuntu-24.04-E95420?logo=ubuntu&logoColor=white)

> **Owner:** Rommel Porras
> **Location:** Philippines
> **Last Updated:** January 11, 2026

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
| K8s Prerequisites | 🔜 Next | Ansible playbook ready |
| Cluster Bootstrap | 📅 Upcoming | kubeadm HA setup |
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

### Reference

| Document | Purpose |
|----------|---------|
| [reference/PRE_INSTALLATION_CHECKLIST.md](docs/reference/PRE_INSTALLATION_CHECKLIST.md) | Completed setup steps |
| [reference/CHANGELOG.md](docs/reference/CHANGELOG.md) | Decision history |
| [reference/PROXMOX_OPNSENSE_GUIDE.md](docs/reference/PROXMOX_OPNSENSE_GUIDE.md) | Existing infrastructure overview |

---

## 🛤️ Project Journey

| Date | Milestone |
|------|-----------|
| **Jan 2026** | Hardware purchased (3x M80q + LIANGUO switch) |
| **Jan 2026** | Ubuntu 24.04 installed, SSH configured, network ready |
| **Coming** | Kubernetes bootstrap with kubeadm |
| **Coming** | Cilium CNI + Longhorn storage |
| **Coming** | Workload migration from Proxmox |

See [ROADMAP.md](docs/ROADMAP.md) for detailed timeline.

---

## 🚀 Next Steps

1. **Run Ansible playbook** for K8s prerequisites (swap, modules, containerd)
2. **Bootstrap cluster** using kubeadm on k8s-cp1
3. **Set up kube-vip** for API server VIP
4. **Join remaining nodes** as control planes
5. **Install Cilium CNI**
6. **Deploy Longhorn** for storage
7. **Migrate workloads** from Proxmox

---

## 🎯 Target HA Architecture

| Component | HA? | How |
|-----------|-----|-----|
| Control Plane | ✅ Planned | 3-node etcd quorum + kube-vip VIP |
| Stateless Workloads | ✅ Planned | Replicas spread across nodes |
| Stateful Workloads | ✅ Planned | Longhorn 2x replication |
| NAS (media) | ⚠️ No | Single Dell 5090 (acceptable for media) |
