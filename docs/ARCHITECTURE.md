# Architecture & Design Decisions

> **Last Updated:** January 11, 2026
> **Node/Network details:** See [CLUSTER_STATUS.md](CLUSTER_STATUS.md)

This document explains the **why** behind architecture decisions.

---

## Why HA is Non-Negotiable

**Current Pain Point:**
> "I really hate it when I need to restart it since I only have 1 PVE node for compute and services"

**Requirement:** Zero downtime when a node dies — database pods must failover automatically.

**Solution:** 3-node cluster with Longhorn distributed storage provides **full HA from day one**.

---

## Why 3 Nodes (Not 2)

| Nodes | Quorum | What Happens When 1 Node Dies |
|-------|--------|-------------------------------|
| 1 | N/A | Everything down (expected) |
| **2** | **2 needed** | **Control plane DEAD** (no quorum!) |
| 3 | 2 needed | Cluster survives |

**2-node cluster is "the worst of all worlds":**
- You pay for 2 machines
- But get the reliability of 1 machine
- etcd requires majority quorum (2/2 = 100% required)

---

## Storage Strategy: Longhorn on Single NVMe

### The Key Insight

**You DON'T need separate SATA SSDs for HA storage!**

Longhorn replicates data across nodes. Even though each node has only one NVMe drive, data survives node failures because replicas exist on other nodes.

### How It Works

```
Node 1 NVMe          Node 2 NVMe          Node 3 NVMe
┌───────────────┐    ┌───────────────┐    ┌───────────────┐
│ OS: ~100GB    │    │ OS: ~100GB    │    │ OS: ~100GB    │
├───────────────┤    ├───────────────┤    ├───────────────┤
│ Longhorn      │    │ Longhorn      │    │ Longhorn      │
│   ┌─────────┐ │    │   ┌─────────┐ │    │               │
│   │Replica 1│◄┼────┼──►│Replica 2│ │    │               │
│   │ (PG DB) │ │    │   │ (PG DB) │ │    │               │
│   └─────────┘ │    │   └─────────┘ │    │               │
└───────────────┘    └───────────────┘    └───────────────┘

If Node 1's NVMe dies:
✅ Node 1 is GONE (OS + its Longhorn replica)
✅ BUT: Replica 2 still exists on Node 2!
✅ Cluster still has quorum (2/3 nodes)
✅ PostgreSQL pod moves to Node 2 or 3
✅ Data is SAFE
```

### Why 2 Replicas Instead of 3?

| Replicas | Usable Space | Fault Tolerance | Recommendation |
|----------|--------------|-----------------|----------------|
| 3 | ~350GB | Lose 2 nodes | Overkill for homelab |
| **2** | **~525GB** | **Lose 1 node** | **Best for homelab** |
| 1 | ~1050GB | No tolerance | Not HA! |

**2 replicas is sufficient because:**
- Losing 2 nodes simultaneously is rare
- If 2 nodes fail, you've lost etcd quorum anyway
- More usable storage space

---

## Why kube-vip Over HAProxy

| Option | Complexity | OPNsense Changes |
|--------|------------|------------------|
| HAProxy on OPNsense | Medium | Yes |
| HAProxy VM | High | No |
| **kube-vip (ARP)** | **Low** | **No** |

**Decision:** kube-vip (ARP mode) — no changes to OPNsense during learning phase.

**How kube-vip works:**
1. Runs as static pod on all control plane nodes
2. One node is elected LEADER via Raft consensus
3. Leader responds to ARP requests for VIP
4. If leader fails, another node takes over (~2-3 seconds)

---

## Why Cilium Over Other CNIs

| CNI | NetworkPolicy | Hubble | Performance |
|-----|---------------|--------|-------------|
| Flannel | No | No | Good |
| Calico | Yes | No | Good |
| **Cilium** | **Yes** | **Yes** | **Best (eBPF)** |

**Decision:** Cilium because:
- NetworkPolicy is **required for CKA exam**
- Hubble provides network observability
- eBPF-based = no iptables overhead

---

## Why kubeadm Over k3s/k0s

| Tool | CKA Exam | Learning | Production-like |
|------|----------|----------|-----------------|
| **kubeadm** | **Matches exam** | Full components | Yes |
| k3s | Different | Simplified | Somewhat |
| k0s | Different | Simplified | Somewhat |

**Decision:** kubeadm because CKA exam uses kubeadm. Learning with the same tool = less context switching.

---

## Why 1GbE Initially

| Speed | Cost | Bottleneck Risk |
|-------|------|-----------------|
| **1GbE (built-in)** | **₱0** | **Unknown** |
| 2.5GbE (adapters) | ₱4,500 | Lower |

**Decision:** Start with built-in 1GbE Intel I219-LM NICs.

**Rationale:**
- Don't solve problems you don't have yet
- Identify if network is actually a bottleneck first
- Upgrade path exists (Intel i225-V M.2 adapters)

---

## Memory Planning

**Current: 16GB per Node**

| Component | Per Node | 3 Nodes |
|-----------|----------|---------|
| K8s overhead | ~2.5GB | ~7.5GB |
| Longhorn | ~500MB | ~1.5GB |
| Available for workloads | ~13GB | ~39GB |

**Verdict:** 16GB per node is sufficient. Upgrade only if memory pressure observed.

---

## Dell 5090 Integration

**Decision:** Keep as dedicated NAS (Option A)

**Why NOT add to K8s cluster:**
- Already running critical services (OMV, Immich)
- NAS should be independent of K8s cluster state
- Simpler migration path — get K8s working first

**Integration:**
- K8s workloads mount NFS shares from Dell 5090
- Media files (photos, videos) stay on NAS
- Databases use Longhorn (needs HA)

---

## What IS HA in This Setup

| Component | HA? | How? |
|-----------|-----|------|
| API Server | Yes | kube-vip VIP + 3 instances |
| etcd | Yes | 3-node quorum (survives 1 failure) |
| Control Plane | Yes | Scheduler/Controller on all 3 nodes |
| Stateful Workloads | Yes | Longhorn 2x replication |
| Stateless Workloads | Yes | Replicas spread across nodes |
| NAS (media files) | No | Single Dell 5090 (acceptable) |

---

## Future Expansion Path

| Option | When | Benefit |
|--------|------|---------|
| Add 2.5GbE adapters | Network bottleneck observed | Faster Longhorn sync |
| Add RAM (32GB/node) | Memory pressure observed | More workloads |
| Add SATA SSD | etcd latency issues | Dedicated storage disk |
| Repurpose Dell 5090 | After external NAS | +6 cores, +32GB RAM |

---

## Related Documents

- [CLUSTER_STATUS.md](CLUSTER_STATUS.md) — Current node/network values
- [STORAGE_SETUP.md](STORAGE_SETUP.md) — Longhorn installation
- [NETWORK_INTEGRATION.md](NETWORK_INTEGRATION.md) — kube-vip setup
