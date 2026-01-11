# Cluster Status — Single Source of Truth

> **Last Updated:** January 11, 2026
> **Status:** Ubuntu Installed — Ready for Kubernetes Bootstrap

**All other docs should reference this file for node/hardware/network values.**

---

## Nodes

| Node | Hostname | IP | MAC | DNS |
|------|----------|-----|-----|-----|
| 1 | k8s-cp1 | 10.10.30.11 | 88:a4:c2:9d:87:d6 | k8s-cp1.home.rommelporras.com |
| 2 | k8s-cp2 | 10.10.30.12 | 88:a4:c2:6b:1c:44 | k8s-cp2.home.rommelporras.com |
| 3 | k8s-cp3 | 10.10.30.13 | 88:a4:c2:64:2d:81 | k8s-cp3.home.rommelporras.com |

**VIP:** 10.10.30.10 — k8s-api.home.rommelporras.com (kube-vip, pending)

---

## Hardware

| Spec | Value | Verified |
|------|-------|----------|
| **Model** | Lenovo ThinkCentre M80q | dmidecode |
| **Product ID** | 11DN0054PC | dmidecode |
| **CPU** | Intel Core i5-10400T (6c/12t @ 2.0-3.6GHz, 35W TDP) | lscpu |
| **Architecture** | 10th Gen Comet Lake (uniform cores) | lscpu |
| **RAM** | 16GB DDR4-2666 SO-DIMM (2 slots, max 64GB) | dmidecode |
| **Storage** | 512GB NVMe (SK Hynix) + 1x 2.5" SATA bay (available) | lsblk |
| **NIC** | Intel I219-LM (1GbE) | ip link |
| **Interface** | eno1 | ip addr |
| **WiFi Slot** | M.2 A+E key (available for 2.5GbE upgrade) | Physical |

### Power Consumption

| State | Per Node | 3-Node Total |
|-------|----------|--------------|
| Idle | 4-7W | ~15-20W |
| Load | 25-35W | ~75-100W |

### Upgrade Paths

| Upgrade | Item | Notes |
|---------|------|-------|
| **Network** | Intel i225-V rev 3 (M.2 A+E) | Use rev 3, NOT i226-V (ASPM issues) |
| **Memory** | DDR4-2666 SO-DIMM 16GB | Upgrade to 32GB if memory pressure |
| **Storage** | Samsung 870 EVO 512GB SATA | Dedicated Longhorn disk (isolates from OS) |

---

## System

| Setting | Value |
|---------|-------|
| **OS** | Ubuntu 24.04.3 LTS |
| **Kernel** | 6.8.0-71-generic |
| **Username** | wawashi |
| **IP Assignment** | DHCP with OPNsense reservations |

---

## Network

| Resource | IP | DNS | Notes |
|----------|-----|-----|-------|
| Gateway | 10.10.30.1 | — | OPNsense VLAN 30 |
| DNS Primary | 10.10.30.53 | agh.home.rommelporras.com | AdGuard Home |
| DNS Secondary | 10.10.30.54 | fw-agh.home.rommelporras.com | Backup |
| NAS | 10.10.30.4 | omv.home.rommelporras.com | Dell 5090 OMV |
| NPM | 10.10.30.80 | *.home.rommelporras.com | Wildcard reverse proxy |

**VLAN:** 30 (SERVERS) — 10.10.30.0/24

---

## Switch Configuration

**Model:** LIANGUO LG-SG5T1 (5x 2.5GbE + 1x 10G SFP+)
**Management:** 10.10.69.3 (VLAN 69)

| Port | Device | Native VLAN | Trunk VLAN | Speed |
|------|--------|-------------|------------|-------|
| 1 | k8s-cp1 | 30 | 30,50 | 1GbE |
| 2 | k8s-cp2 | 30 | 30,50 | 1GbE |
| 3 | k8s-cp3 | 30 | 30,50 | 1GbE |
| 4 | Dell PVE | 1 | 30,50,69 | 2.5GbE |
| 5 | OPNsense | 1 | 30,50,69 | 2.5GbE |

**Lesson Learned:** On LIANGUO switch, VLAN must be in Trunk VLAN list even if set as Native VLAN.

---

## SSH Access

```bash
# By IP
ssh wawashi@10.10.30.11  # k8s-cp1
ssh wawashi@10.10.30.12  # k8s-cp2
ssh wawashi@10.10.30.13  # k8s-cp3

# By DNS
ssh wawashi@k8s-cp1.home.rommelporras.com
```

---

## Completion Status

### Phase 1: Hardware & OS
- [x] Hardware purchased (3x M80q + LIANGUO switch)
- [x] Switch VLANs configured
- [x] Ubuntu 24.04.3 LTS installed
- [x] DHCP reservations in OPNsense
- [x] DNS entries in AdGuard Home
- [x] SSH key authentication

### Phase 2: Kubernetes Prerequisites (Next)
- [ ] System updates
- [ ] Disable swap
- [ ] Kernel modules (overlay, br_netfilter)
- [ ] sysctl (ip_forward, bridge-nf-call)
- [ ] containerd
- [ ] kubeadm, kubelet, kubectl
- [ ] open-iscsi (Longhorn prereq)

### Phase 3: Cluster Bootstrap
- [ ] kube-vip for VIP
- [ ] kubeadm init on k8s-cp1
- [ ] Join k8s-cp2, k8s-cp3
- [ ] Cilium CNI
- [ ] Verify etcd quorum

### Phase 4: Storage & Workloads
- [ ] Longhorn
- [ ] NFS mounts from Dell 5090
- [ ] First workloads

---

## Verification Commands

```bash
# Hardware
sudo dmidecode -t system | grep -E "Manufacturer|Product"
lscpu | grep "Model name"

# Network
ip addr show eno1
ping -c 2 10.10.30.1

# SSH test (from workstation)
for i in 11 12 13; do ssh wawashi@10.10.30.$i "hostname"; done
```
