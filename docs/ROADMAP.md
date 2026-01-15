# Project Roadmap & CKA Timeline

> **Last Updated:** January 16, 2026
> **Target:** CKA Certification by September 2026
> **Current state:** See [CLUSTER_STATUS.md](CLUSTER_STATUS.md)

---

## Current Progress

```
[██████████████░░░░░░] 70% — Kubernetes HA Cluster Running
```

| Milestone | Status | Completed |
|-----------|--------|-----------|
| Hardware purchased | Done | Jan 3, 2026 |
| Switch configured | Done | Jan 10, 2026 |
| Ubuntu installed | Done | Jan 11, 2026 |
| SSH access working | Done | Jan 11, 2026 |
| K8s prerequisites | Done | Jan 16, 2026 |
| Cluster bootstrap | Done | Jan 16, 2026 |
| CNI (Cilium) | Done | Jan 16, 2026 |
| Storage (Longhorn) | Next | — |

---

## 12-Month Cluster Build Roadmap

### Phase 1: Foundation — COMPLETE

- [x] Purchase nodes (3x M80q)
- [x] Purchase network switch (LIANGUO)
- [x] Configure switch VLANs
- [x] Install Ubuntu 24.04 on all nodes
- [x] Configure DHCP/DNS
- [x] Verify SSH access

### Phase 2: Kubernetes Bootstrap — COMPLETE

**Completed:** January 16, 2026

- [x] Run prerequisites (swap, modules, containerd)
- [x] Set up kube-vip for VIP (10.10.30.10)
- [x] Initialize cluster on k8s-cp1
- [x] Join remaining control planes (cp2, cp3)
- [x] Install Cilium CNI (v1.18.6)
- [x] Verify etcd quorum (3 members)
- [x] Workstation kubectl-homelab alias configured

### Phase 3: Storage & Monitoring

**Target:** February 2026

- [ ] Install Longhorn
- [ ] Configure 2x replication
- [ ] Set up NFS mounts from Dell 5090
- [ ] Deploy Prometheus + Grafana
- [ ] Deploy Loki for logs

### Phase 4: Workload Migration

**Target:** March-April 2026

Migration order:
1. [ ] AdGuard Home (simple, low risk)
2. [ ] Homepage dashboard
3. [ ] PostgreSQL (StatefulSet)
4. [ ] Immich (depends on PostgreSQL + NFS)
5. [ ] ARR stack

### Phase 5: Production Hardening

**Target:** May-June 2026

- [ ] RBAC policies
- [ ] NetworkPolicies (Cilium)
- [ ] Resource quotas
- [ ] Pod security standards
- [ ] Backup strategy (Velero)

### Phase 6: CKA Focused Learning

**Target:** July-September 2026

- [ ] Review all exam topics
- [ ] Practice with dedicated VMs
- [ ] killer.sh practice exams
- [ ] Pass CKA exam

---

## CKA Certification Timeline

**Target:** September 2026

| Phase | Weeks | Focus |
|-------|-------|-------|
| Core Concepts | 1-8 | Pods, Deployments, Services |
| Storage & Config | 9-16 | PV/PVC, ConfigMaps, Secrets |
| Cluster Ops | 17-24 | RBAC, NetworkPolicy, Scheduling |
| kubeadm & DR | 25-30 | Bootstrap, upgrade, etcd backup |
| Exam Prep | 31-36 | killer.sh, practice exams |

### Learning Resources

| Resource | Purpose |
|----------|---------|
| Mumshad's Udemy Course | Primary video content |
| KodeKloud Labs | Hands-on practice |
| killer.sh | Exam simulation |
| This homelab | Real-world experience |

---

## Key Milestones

| Date | Milestone |
|------|-----------|
| Jan 3, 2026 | Hardware purchased |
| Jan 10, 2026 | Switch configured |
| Jan 11, 2026 | Ubuntu installed |
| Jan 16, 2026 | **Kubernetes HA cluster running** |
| Feb 2026 | Longhorn + monitoring deployed |
| Apr 2026 | Workloads migrated |
| Sep 2026 | CKA passed |

---

## Optional Upgrades (When Needed)

| Upgrade | Trigger |
|---------|---------|
| Intel i225-V (2.5GbE) | Network bottleneck |
| RAM (32GB/node) | Memory pressure |
| SATA SSD (Longhorn) | etcd isolation |

---

## Related Documents

- [CLUSTER_STATUS.md](CLUSTER_STATUS.md) — Current state
- [KUBEADM_BOOTSTRAP.md](KUBEADM_BOOTSTRAP.md) — Bootstrap guide
- [K8S_LEARNING_GUIDE.md](K8S_LEARNING_GUIDE.md) — CKA study material
