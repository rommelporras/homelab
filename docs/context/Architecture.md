---
tags: [homelab, kubernetes, architecture, decisions, backup]
updated: 2026-04-14
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
| NAS (media) | No | Single Dell 3090 (acceptable) |
| GPU transcoding | Yes | All 3 nodes have UHD 630 iGPU |

## Why Intel Device Plugin (Not hostPath)

| Approach | Problem |
|----------|---------|
| hostPath /dev/dri | Requires privileged, bypasses PSS, no resource scheduling |
| Manual device mounts | Pod YAML complexity, no GPU slot tracking |
| **Intel Device Plugin** | **PSS compatible, proper `gpu.intel.com/i915` scheduling** |

Device plugin auto-mounts `/dev/dri` into pods that request `gpu.intel.com/i915`. `sharedDevNum: 3` allows 3 pods per node to share one iGPU. Kubernetes scheduler tracks GPU slots like CPU/memory.

Node Feature Discovery auto-labels nodes with `intel.feature.node.kubernetes.io/gpu: true`, so the GPU plugin DaemonSet only runs on GPU-equipped nodes.

## Cross-Namespace Service Pattern (Ollama)

Ollama runs in the `ai` namespace as an internal-only ClusterIP service. Consumers in other namespaces (e.g., Karakeep in `karakeep`) access it via cluster DNS:

```
http://ollama.ai.svc.cluster.local:11434
```

CiliumNetworkPolicy restricts ingress to only authorized namespaces (`monitoring`, `karakeep`, `arr-stack`). This pattern applies to any shared internal service consumed across namespaces.

## Dell 3090 Integration

**Decision:** Keep as dedicated NAS, don't add to K8s cluster.

| Reason |
|--------|
| Already running OMV + Immich |
| NAS should be independent of K8s state |
| K8s mounts NFS shares from it |

## Why ArgoCD (GitOps)

| Approach | Problem |
|----------|---------|
| `kubectl apply` | Manual, error-prone, no drift detection |
| Flux | Good option, but smaller community |
| **ArgoCD** | **UI for visibility, strong Helm support, app-of-apps pattern** |

Git is the single source of truth. ArgoCD watches the repo and syncs to the cluster automatically. 48 Applications managed via app-of-apps pattern (`manifests/argocd/apps/root.yaml` discovers all Application YAMLs in the directory). Six AppProjects enforce RBAC boundaries between service groups.

**Exception:** Cilium is ArgoCD-managed but manual-sync only (CNI chicken-and-egg - auto-sync could delete networking during failed reconciliation). All other services use automated sync with selfHeal.

## Why Vault + ESO (Not Direct K8s Secrets)

| Approach | Problem |
|----------|---------|
| `kubectl create secret` | Secrets in shell history, CI logs, or git |
| Sealed Secrets | Asymmetric key tied to cluster — rebuild requires key backup |
| **HashiCorp Vault + ESO** | **Centralized store, declarative ExternalSecret CRDs, K8s auth** |

1Password is the human-readable seed source — `scripts/vault/seed-vault-from-1password.sh` is run manually once. Vault serves secrets to ESO via Kubernetes auth (no credentials in automation). ESO creates K8s Secrets from ExternalSecret CRDs committed to git (no secret values, just references). Apps consume K8s Secrets unchanged — zero application changes needed.

**Only imperative secret:** `vault-unseal-keys` (bootstrap — Vault must exist before ESO can create secrets from it).

## Node Failure Recovery Times

Expected recovery timeline when a node goes down (e.g., reboot, hardware failure):

| Phase | Duration |
|-------|----------|
| M80q BIOS POST | ~5-7 min |
| Kubernetes node NotReady detection | ~40s |
| Pod eviction (default) | 300s |
| Pod eviction (tuned stateless) | 60s |
| Pod eviction (databases - keep default) | 300s |
| Total worst-case stateless (default) | ~11 min |
| Total worst-case stateless (tuned) | ~7 min |
| Total worst-case database | ~11 min |

Stateless services (Ghost, Portfolio, Homepage, ARR apps, etc.) use 60s tolerationSeconds for faster rescheduling. Databases (PostgreSQL, MySQL, Redis), Vault, and StatefulSets keep the default 300s to preserve data consistency.

## Why Three-Layer Backup

| Approach | Problem |
|----------|---------|
| Longhorn snapshots only | Corrupted data gets replicated - no logical backup |
| Database dumps only | No namespace/manifest state recovery |
| Velero only | No application data (Secrets excluded, volumes handled by Longhorn) |
| **All three** | **Defense in depth: volume, resource, and logical backups** |

Longhorn handles block-level volume snapshots to NFS. Velero handles K8s resource manifests to Garage S3. CronJobs handle application-level dumps (SQLite, PostgreSQL, MySQL, etcd) to NFS. Off-site: restic encrypts and syncs NAS backups to OneDrive.

## Why Garage S3 (Not MinIO)

| Approach | Problem |
|----------|---------|
| MinIO | Repository archived Feb 2026 |
| External S3 (AWS/Backblaze) | Adds external dependency, cost, latency |
| **Garage** | **21MB image, ~3MB idle RAM, S3-compatible, actively maintained** |

Garage runs as a single-replica StatefulSet in the velero namespace. Velero uses it as the S3 backend for daily resource backups.

## Related

- [[Cluster]] - Current nodes
- [[Storage]] - Longhorn details, NFS backup directories
- [[Networking]] - kube-vip, Gateway
- [[Secrets]] - Vault KV paths, ESO ExternalSecrets, 1Password items
- [[Security]] - Backup architecture, retention, recovery procedures
