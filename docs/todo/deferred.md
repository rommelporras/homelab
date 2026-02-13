# Deferred Tasks

> Items intentionally postponed - will be tackled after core phases complete

---

## Immich Photo Management

**Status:** Deferred - not on current roadmap
**Priority:** Low

**Namespace Strategy:**
| Project | Namespace | Database |
|---------|-----------|----------|
| Immich | `immich` | Own PostgreSQL + Redis inside namespace |

### Immich Namespace (`immich/`)

```
immich/
  ├── postgres (StatefulSet)     ← Immich's own database
  ├── redis (Deployment)
  ├── immich-server (Deployment)
  └── immich-ml (Deployment)
```

- Options: Fresh deployment vs migration from OMV NAS (10.10.30.4)
- Dependencies: PostgreSQL, Redis, NFS (photos)
- Photos storage: NFS from OMV NAS at `/export/Kubernetes`

**When:** No target date. Will plan as a future phase when prioritized.

---

## Firmware Updates (Low Priority)

**Status:** Deferred - requires physical access (HDMI, keyboard)

| Node | BIOS | EC | Status |
|------|------|-----|--------|
| k8s-cp1 | 1.99 | 256.24 | Complete |
| k8s-cp2 | 1.90 | 256.20 | **Pending** (Boot Order Lock) |
| k8s-cp3 | 1.82 | 256.20 | **Pending** (Boot Order Lock) |

**CVEs:** All Medium/Low severity. NVMe (High) already completed.

**Steps:**
1. Connect HDMI + keyboard
2. `sudo systemctl reboot --firmware-setup`
3. Disable Boot Order Lock in BIOS
4. `sudo fwupdmgr update`

**When:** During scheduled maintenance or when physically accessing rack

---

## kubeadm Control Plane Metrics Scraping

**Status:** Deferred - silenced in Alertmanager
**Added:** Phase 3.9 (2026-01-20)
**Priority:** Low
**Effort:** Medium

**Problem:**
Prometheus cannot scrape metrics from kubeadm-managed control plane components because they bind to `127.0.0.1`:
- kube-scheduler
- kube-controller-manager
- etcd

**Note:** kube-proxy is not running on this cluster — Cilium replaces it (`kubeProxyReplacement: true`). The `KubeProxyDown` alert is silenced because the component intentionally does not exist.

**Silenced Alerts:**
- `KubeProxyDown` (expected — Cilium replaces kube-proxy)
- `etcdInsufficientMembers`
- `etcdMembersDown`
- `TargetDown` (kube-scheduler, kube-controller-manager, kube-etcd)

**Current Workaround:**
Alerts routed to `null` receiver in Alertmanager config.
See: `helm/prometheus/values.yaml` → alertmanager.config.route.routes

**To Fix (if needed):**
1. Modify kubeadm ClusterConfiguration:
   ```yaml
   controllerManager:
     extraArgs:
       bind-address: "0.0.0.0"
   scheduler:
     extraArgs:
       bind-address: "0.0.0.0"
   etcd:
     local:
       extraArgs:
         listen-metrics-urls: "http://0.0.0.0:2381"
   ```
2. Update static pod manifests on all control plane nodes
3. Create/verify ServiceMonitors for each component
4. Remove silence routes from Alertmanager config (except `KubeProxyDown` — keep silenced since Cilium replaces kube-proxy)

**Why Deferred:**
- Cluster works fine (scraping issue, not component failure)
- Low value for homelab use case
- Risk of control plane disruption
- Not required for CKA

**When:** If you need etcd/scheduler metrics for debugging or production-like setup

---

## NVMe S.M.A.R.T. Health Monitoring

**Status:** Deferred
**Priority:** Medium
**Effort:** Low-Medium

**Problem:**
All 3 nodes run Longhorn on 512GB NVMe drives with 2x replication. There is currently no visibility into drive wear. If a drive fails without warning, Longhorn has only 1 remaining replica until the drive is replaced.

**Key Metrics:**
- **TBW (Total Bytes Written)** — cumulative writes vs manufacturer endurance rating
- **Percentage Used** — NVMe wear indicator (0-100%, 100% = rated endurance reached)
- **Power On Hours** — uptime tracking
- **Temperature** — thermal throttling risk

**How to check manually:**
```bash
# SSH to any node
ssh wawashi@cp1.k8s.rommelporras.com

# Check NVMe S.M.A.R.T. data (requires smartmontools)
sudo smartctl -a /dev/nvme0n1

# Key fields to look for:
#   Percentage Used:          X%
#   Data Units Written:       X [Y TB]
#   Power On Hours:           X
#   Temperature:              X Celsius
```

**To Automate (if needed):**
1. Deploy `smartctl_exporter` as a DaemonSet (or use node-exporter smartmon text collector)
2. Create Prometheus alerts for wear thresholds (e.g., percentage_used > 80%)
3. Add Grafana dashboard panel for drive health per node

**Why Deferred:**
- Drives are new — wear is negligible in early life
- Manual `smartctl` check is sufficient for now
- Can revisit after 6-12 months of Longhorn writes

**When:** After 6+ months of operation, or before Phase 5 (Production Hardening)
