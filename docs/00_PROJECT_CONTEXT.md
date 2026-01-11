# Project Context

> **Purpose:** Quick orientation and project snapshot
> **Last Updated:** January 11, 2026
> **Source of Truth:** [CLUSTER_STATUS.md](CLUSTER_STATUS.md)

---

## Quick Facts

| Item | Value |
|------|-------|
| **Owner** | Rommel Porras (Philippines) |
| **Goal** | Learn Kubernetes, pass CKA by September 2026 |
| **Hardware** | 3x Lenovo M80q (i5-10400T, 16GB, 512GB NVMe) |
| **OS** | Ubuntu 24.04.3 LTS |
| **Current Phase** | Ready for Kubernetes bootstrap |

---

## Single Source of Truth

**All canonical values (IPs, MACs, hostnames, hardware specs) live in [CLUSTER_STATUS.md](CLUSTER_STATUS.md).**

Do NOT duplicate values across files. Reference CLUSTER_STATUS.md instead.

---

## Document Map

| Doc | Purpose | When to Reference |
|-----|---------|-------------------|
| [CLUSTER_STATUS.md](CLUSTER_STATUS.md) | **Source of truth** — nodes, IPs, hardware, current state | Always check first |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Design decisions (why) | "Why did we choose X?" |
| [NETWORK_INTEGRATION.md](NETWORK_INTEGRATION.md) | Network setup, kube-vip, switch config | Networking questions |
| [KUBEADM_BOOTSTRAP.md](KUBEADM_BOOTSTRAP.md) | Cluster bootstrap commands | How to init cluster |
| [STORAGE_SETUP.md](STORAGE_SETUP.md) | Longhorn installation | Storage questions |
| [EXISTING_INFRA.md](EXISTING_INFRA.md) | Dell 5090 NAS, migration plan | NAS integration |
| [ROADMAP.md](ROADMAP.md) | Timeline, CKA schedule | Planning questions |
| [K8S_LEARNING_GUIDE.md](K8S_LEARNING_GUIDE.md) | CKA study material | Learning concepts |

---

## Implementation Status

### Completed
- [x] Hardware purchased (3x M80q + LIANGUO switch)
- [x] Switch configured (VLANs 30, 50, 69)
- [x] Ubuntu 24.04.3 LTS installed on all nodes
- [x] DHCP reservations in OPNsense
- [x] DNS entries configured
- [x] SSH key authentication

### Not Yet Implemented
- [ ] Kubernetes prerequisites (swap, modules, containerd)
- [ ] kubeadm cluster bootstrap
- [ ] kube-vip for API VIP
- [ ] Cilium CNI
- [ ] Longhorn storage
- [ ] Any workloads

---

## Architecture Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Nodes | 3 (not 2) | etcd quorum requires 3 minimum |
| Storage | Longhorn on NVMe | 2x replication, no extra hardware |
| VIP | kube-vip (ARP) | No OPNsense changes needed |
| CNI | Cilium | NetworkPolicy for CKA |
| Install method | kubeadm | CKA exam alignment |

---

## Next Steps

1. Create Ansible playbook for K8s prerequisites
2. Run prerequisites (swap, modules, containerd, kubeadm)
3. Bootstrap cluster on k8s-cp1
4. Set up kube-vip for VIP
5. Join remaining nodes
6. Install Cilium CNI
7. Deploy Longhorn
