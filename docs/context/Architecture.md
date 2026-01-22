---
tags: [homelab, kubernetes, architecture, decisions]
updated: 2026-01-22
---

# Architecture

Key design decisions and rationale.

## Why 3 Nodes (Not 2)

| Nodes | Quorum | Node Failure |
|-------|--------|--------------|
| 2 | 2/2 = 100% needed | Control plane DEAD |
| **3** | **2/3 = 67% needed** | **Cluster survives** |

2-node cluster is worst of all worlds: cost of 2, reliability of 1.

## Why Cilium

| CNI | NetworkPolicy | Why It Matters |
|-----|---------------|----------------|
| Flannel | No | CKA requires NetworkPolicy |
| Calico | Yes | Good option |
| **Cilium** | **Yes** | **eBPF performance + Hubble observability** |

Cilium also provides Gateway API implementation (no need for Traefik/NGINX).

## Why Longhorn on NVMe

| Approach | Problem |
|----------|---------|
| Separate SATA SSD | Extra hardware cost |
| NFS only | Single point of failure |
| **Longhorn on NVMe** | **2x replication, no extra hardware** |

Longhorn replicates across nodes. If Node 1 NVMe dies, data exists on Node 2.

## Why kube-vip (ARP)

| VIP Option | Complexity |
|------------|------------|
| HAProxy on OPNsense | Requires firewall changes |
| HAProxy VM | Extra VM to manage |
| **kube-vip (ARP)** | **Zero external dependencies** |

kube-vip runs as static pod, provides VIP via ARP. No OPNsense changes needed.

## Why kubeadm

| Tool | CKA Alignment |
|------|---------------|
| k3s | Different from exam |
| k0s | Different from exam |
| **kubeadm** | **Matches CKA exam** |

Learning with kubeadm = less context switching for CKA.

## Why Gateway API (Not Ingress)

| Approach | Status |
|----------|--------|
| NGINX Ingress | EOL March 2026 |
| Traefik | Extra component |
| **Gateway API + Cilium** | **Native, future-proof** |

Cilium has built-in Gateway API support. No extra ingress controller needed.

## What IS HA

| Component | HA? | How? |
|-----------|-----|------|
| API Server | Yes | kube-vip VIP + 3 instances |
| etcd | Yes | 3-node quorum |
| Control Plane | Yes | Scheduler/Controller on all 3 |
| Stateful Workloads | Yes | Longhorn 2x replication |
| Stateless Workloads | Yes | Replicas spread across nodes |
| Monitoring | Yes | Longhorn-backed storage |
| Alerting | Yes | Discord + Email redundancy |
| UPS Protection | Yes | Staggered graceful shutdown |
| NAS (media) | No | Single Dell 5090 (acceptable) |

## Dell 5090 Integration

**Decision:** Keep as dedicated NAS, don't add to K8s cluster.

| Reason |
|--------|
| Already running OMV + Immich |
| NAS should be independent of K8s state |
| K8s mounts NFS shares from it |

## Related

- [[Cluster]] - Current nodes
- [[Storage]] - Longhorn details
- [[Networking]] - kube-vip, Gateway
