# Changelog

> Project decision history and revision tracking

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
