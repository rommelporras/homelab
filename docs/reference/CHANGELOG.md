# Changelog

> Project decision history and revision tracking

---

## January 19, 2026 — Phase 3.7: Logging Stack

### Milestone: Loki + Alloy Running

Successfully installed centralized logging with Loki for storage and Alloy for log collection.

| Component | Version | Status |
|-----------|---------|--------|
| Loki | v3.6.3 | Running (SingleBinary, 10Gi PVC) |
| Alloy | v1.12.2 | Running (DaemonSet, 3 pods) |

### Files Added

| File | Purpose |
|------|---------|
| helm/loki/values.yaml | Loki SingleBinary mode, 90-day retention, Longhorn storage |
| helm/alloy/values.yaml | Alloy DaemonSet with K8s API log collection + K8s events |
| manifests/monitoring/loki-datasource.yaml | Grafana datasource ConfigMap for Loki |
| manifests/monitoring/loki-servicemonitor.yaml | Prometheus scraping for Loki metrics |
| manifests/monitoring/alloy-servicemonitor.yaml | Prometheus scraping for Alloy metrics |
| manifests/monitoring/logging-alerts.yaml | PrometheusRule with Loki/Alloy alerts |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Loki mode | SingleBinary | Cluster generates ~4MB/day logs, far below 20GB/day threshold |
| Storage backend | Filesystem (Longhorn PVC) | SimpleScalable/Distributed require S3, overkill for homelab |
| Retention | 90 days | Storage analysis showed ~360-810MB needed, 10Gi provides headroom |
| Log collection | loki.source.kubernetes | Uses K8s API, no volume mounts or privileged containers needed |
| Alloy controller | DaemonSet | One pod per node ensures all logs collected |
| OCI registry | Loki only | Alloy doesn't support OCI yet, uses traditional Helm repo |
| K8s events | Single collector | Only k8s-cp1's Alloy forwards events to avoid triplicates |
| Observability | ServiceMonitors + Alerts | Monitor the monitors - Prometheus scrapes Loki/Alloy |
| Alloy memory | 256Mi limit | Increased from 128Mi to handle events collection safely |

### Lessons Learned

**Loki OCI available but undocumented:** Official docs still show `helm repo add grafana`, but Loki chart is available via OCI at `oci://ghcr.io/grafana/helm-charts/loki`. Alloy is not available via OCI (403 denied).

**lokiCanary is top-level setting:** The Loki chart has `lokiCanary.enabled` at the top level, NOT under `monitoring.lokiCanary`. This caused unwanted canary pods until fixed.

**loki.source.kubernetes vs loki.source.file:** The newer `loki.source.kubernetes` component tails logs via K8s API instead of mounting `/var/log/pods`. Benefits: no volume mounts, no privileged containers, works with restrictive Pod Security Standards.

**Grafana sidecar auto-discovery:** Creating a ConfigMap with label `grafana_datasource: "1"` automatically adds the datasource to Grafana. No manual configuration needed.

### Architecture

```
Pod stdout ──────► Alloy (DaemonSet) ──► Loki (SingleBinary) ──► Longhorn PVC
K8s Events ──────►        │                      │
                          │                      ▼
                          │                  Grafana
                          │                      ▲
                          ▼                      │
                    Prometheus ◄── ServiceMonitors (loki, alloy)
                          │
                          ▼
                    Alertmanager ◄── PrometheusRule (logging-alerts)
```

### Alerts Configured

| Alert | Severity | Trigger |
|-------|----------|---------|
| LokiDown | critical | Loki unreachable for 5m |
| LokiIngestionStopped | warning | No logs received for 15m |
| LokiHighErrorRate | warning | Error rate > 10% for 10m |
| LokiStorageLow | warning | PVC < 20% free for 30m |
| AlloyNotOnAllNodes | warning | Alloy pods < node count for 10m |
| AlloyNotSendingLogs | warning | No logs sent for 15m |
| AlloyHighMemory | warning | Memory > 80% limit for 10m |

### Access

- Grafana Explore: https://grafana.k8s.home.rommelporras.com/explore
- Loki (internal): loki.monitoring.svc.cluster.local:3100

### Sample LogQL Queries

```logql
{namespace="monitoring"}                    # All monitoring logs
{namespace="kube-system", container="etcd"} # etcd logs
{cluster="homelab"} |= "error"              # Search for errors
{source="kubernetes_events"}                # All K8s events
{source="kubernetes_events"} |= "Warning"   # Warning events only
```

---

## January 18, 2026 — Phase 3.6: Monitoring Stack

### Milestone: kube-prometheus-stack Running

Successfully installed complete monitoring stack with Prometheus, Grafana, Alertmanager, and node-exporter.

| Component | Version | Status |
|-----------|---------|--------|
| kube-prometheus-stack | v81.0.0 | Running |
| Prometheus | v0.88.0 | Running (50Gi PVC) |
| Grafana | latest | Running (10Gi PVC) |
| Alertmanager | latest | Running (5Gi PVC) |
| node-exporter | latest | Running (DaemonSet, 3 pods) |

### Files Added

| File | Purpose |
|------|---------|
| helm/prometheus/values.yaml | Helm values with 90-day retention, Longhorn storage |
| manifests/monitoring/grafana-httproute.yaml | Gateway API route for HTTPS access |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Pod Security | privileged | node-exporter needs hostNetwork, hostPID, hostPath |
| OCI registry | Yes | Recommended by upstream, no helm repo add needed |
| Retention | 90 days | Balance between history and storage usage |
| Storage | Longhorn | Consistent with cluster storage strategy |

### Lessons Learned

**Pod Security Standards block node-exporter:** The `baseline` PSS level rejects pods with hostNetwork/hostPID/hostPath. node-exporter requires these for host-level metrics collection.

**Solution:** Use `privileged` PSS for monitoring namespace: `kubectl label namespace monitoring pod-security.kubernetes.io/enforce=privileged`

**DaemonSet backoff requires restart:** After fixing PSS, the DaemonSet controller was in backoff. Required `kubectl rollout restart daemonset` to retry pod creation.

### Access

- Grafana: https://grafana.k8s.home.rommelporras.com
- Prometheus (internal): prometheus-kube-prometheus-prometheus:9090
- Alertmanager (internal): prometheus-kube-prometheus-alertmanager:9093

---

## January 17, 2026 — Phase 3: Storage Infrastructure

### Milestone: Longhorn Distributed Storage Running

Successfully installed Longhorn for persistent storage across all 3 nodes.

| Component | Version | Status |
|-----------|---------|--------|
| Longhorn | v1.10.1 | Running |
| StorageClass | longhorn (default) | Active |
| Replicas | 2 per volume | Configured |

### Ansible Playbooks Added

| Playbook | Purpose |
|----------|---------|
| 06-storage-prereqs.yml | Create /var/lib/longhorn, verify iscsid, install nfs-common |
| 07-remove-taints.yml | Remove control-plane taints for homelab workloads |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Replica count | 2 | With 3 nodes, survives 1 node failure. 3 replicas would waste storage. |
| Storage path | /var/lib/longhorn | Standard location, ~432GB available per node |
| Taint removal | All nodes | Homelab has no dedicated workers, workloads must run on control plane |
| Helm values file | helm/longhorn/values.yaml | GitOps-friendly, version controlled |

### Lessons Learned

**Control-plane taints block workloads:** By default, kubeadm taints control plane nodes with `NoSchedule`. In a homelab cluster with no dedicated workers, this prevents Longhorn (and all other workloads) from scheduling.

**Solution:** Remove taints with `kubectl taint nodes --all node-role.kubernetes.io/control-plane:NoSchedule-`

**Helm needs KUBECONFIG:** When using a non-default kubeconfig (like homelab.yaml), Helm requires the correct kubeconfig. Created `helm-homelab` alias in ~/.zshrc alongside `kubectl-homelab`.

**NFSv4 pseudo-root path format:** When OMV exports `/export` with `fsid=0`, it becomes the NFSv4 pseudo-root. Mount paths must be relative to this root:
- Filesystem path: `/export/Kubernetes/Immich`
- NFSv4 mount path: `/Kubernetes/Immich` (not `/export/Kubernetes/Immich`!)

This caused "No such file or directory" errors until the path format was corrected.

### Storage Strategy Documented

| Storage Type | Use Case | Example Apps |
|--------------|----------|--------------|
| Longhorn (block) | App data, databases, runtime state | AdGuard logs, PostgreSQL |
| NFS (file) | Bulk media, photos | Immich, *arr stack |
| ConfigMap (K8s) | Static config files | Homepage settings |

### NFS Status

- NAS (10.10.30.4) is network reachable
- NFS export /export/Kubernetes enabled on OMV
- NFSv4 mount tested and verified from cluster nodes
- Manifest ready at `manifests/storage/nfs-immich.yaml`
- PV name: `immich-nfs`, PVC name: `immich-media`

---

## January 16, 2026 — Kubernetes HA Cluster Bootstrap Complete

### Milestone: 3-Node HA Cluster Running

Successfully bootstrapped a 3-node high-availability Kubernetes cluster using kubeadm.

| Component | Version | Status |
|-----------|---------|--------|
| Kubernetes | v1.35.0 | Running |
| kube-vip | v1.0.3 | Active (VIP: 10.10.30.10) |
| Cilium | 1.18.6 | Healthy |
| etcd | 3 members | Quorum established |

### Ansible Playbooks Created

Full automation for cluster bootstrap:

| Playbook | Purpose |
|----------|---------|
| 00-preflight.yml | Pre-flight checks (cgroup v2, network, DNS) |
| 01-prerequisites.yml | System prep (swap, modules, containerd, kubeadm) |
| 02-kube-vip.yml | VIP setup with K8s 1.29+ workaround |
| 03-init-cluster.yml | kubeadm init with config generation |
| 04-cilium.yml | CNI installation with checksum verification |
| 05-join-cluster.yml | Control plane join with post-join reboot |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Post-join reboot | Enabled | Resolves Cilium init timeouts and kube-vip leader election conflicts |
| Workstation config | ~/.kube/homelab.yaml | Separate from work EKS (~/.kube/config) |
| kubectl alias | `kubectl-homelab` | Work wiki copy-paste compatibility |

### Lessons Learned

**Cascading restart issue:** Joining multiple control planes can cause cascading failures:
- Cilium init timeouts ("failed to sync configmap cache")
- kube-vip leader election conflicts
- Accumulated backoff timers on failed containers

**Solution:** Reboot each node after join to clear state and backoff timers.

### Workstation Setup

```bash
# Homelab cluster (separate from work)
kubectl-homelab get nodes

# Work EKS (unchanged)
kubectl get pods
```

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
