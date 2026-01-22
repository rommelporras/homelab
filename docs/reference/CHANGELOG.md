# Changelog

> Project decision history and revision tracking

---

## January 22, 2026 — Phase 4.1-4.4: Stateless Workloads

### Milestone: Home Services Running on Kubernetes

Successfully deployed stateless home services to Kubernetes with full monitoring integration.

| Component | Version | Status |
|-----------|---------|--------|
| AdGuard Home | v0.107.71 | Running (PRIMARY DNS for all VLANs) |
| Homepage | v1.9.0 | Running (2 replicas, multi-tab layout) |
| Glances | v3.3.1 | Running (on OMV, apt install) |
| Metrics Server | v0.8.0 | Running (Helm chart 3.13.0) |

### Files Added

| File | Purpose |
|------|---------|
| manifests/home/adguard/ | AdGuard Home deployment (ConfigMap, Deployment, Service, HTTPRoute, PVC) |
| manifests/home/homepage/ | Homepage dashboard (Kustomize with configMapGenerator) |
| manifests/storage/longhorn/httproute.yaml | Longhorn UI exposure for Homepage widget |
| helm/metrics-server/values.yaml | Metrics server Helm values |
| docs/todo/phase-4.9-tailscale-operator.md | Future Tailscale K8s operator planning |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| DNS IP | 10.10.30.55 (LoadBalancer) | Cilium L2 announcement, separate from FW failover |
| AdGuard storage | Init container + Longhorn PVC | ConfigMap → PVC on first boot, runtime changes preserved |
| Homepage storage | ConfigMap only (stateless) | Kustomize hash suffix for automatic rollouts |
| Secrets | 1Password CLI (imperative) | Never commit secrets to git |
| Settings env vars | Init container substitution | Homepage doesn't substitute `{{HOMEPAGE_VAR_*}}` in providers section |
| Longhorn widget | HTTPRoute exposure | Widget needs direct API access to Longhorn UI |

### Architecture

```
                    ┌─────────────────────────────────────────┐
                    │         Home Namespace (home)           │
                    └─────────────────────────────────────────┘
                                      │
        ┌─────────────────────────────┼─────────────────────────────┐
        │                             │                             │
┌───────▼───────┐            ┌────────▼────────┐           ┌────────▼────────┐
│  AdGuard Home │            │    Homepage     │           │  Metrics Server │
│  v0.107.71    │            │    v1.9.0       │           │    v0.8.0       │
├───────────────┤            ├─────────────────┤           ├─────────────────┤
│ LoadBalancer  │            │ ClusterIP       │           │ ClusterIP       │
│ 10.10.30.55   │            │ → HTTPRoute     │           │ (kube-system)   │
│ DNS :53/udp   │            │                 │           │                 │
│ HTTP :3000    │            │ 2 replicas      │           │ metrics.k8s.io  │
└───────────────┘            └─────────────────┘           └─────────────────┘
        │                             │
        ▼                             ▼
  All VLAN DHCP              Grafana-style dashboard
  Primary DNS                with K8s/Longhorn widgets
```

### DNS Cutover

| VLAN | Primary DNS | Secondary DNS |
|------|-------------|---------------|
| GUEST | 10.10.30.55 | 10.10.30.54 |
| IOT | 10.10.30.55 | 10.10.30.54 |
| LAN | 10.10.30.55 | 10.10.30.54 |
| SERVERS | 10.10.30.55 | 10.10.30.54 |
| TRUSTED_WIFI | 10.10.30.55 | 10.10.30.54 |

### 1Password Items Created

| Item | Vault | Fields |
|------|-------|--------|
| Homepage | Kubernetes | proxmox-pve-user/token, proxmox-fw-user/token, opnsense-username/password, immich-key, omv-user/pass, glances-pass, adguard-user/pass, weather-key, grafana-user/pass, etc. |

### Lessons Learned

1. **Homepage env var substitution limitation:** `{{HOMEPAGE_VAR_*}}` works in `services.yaml` but NOT in `settings.yaml` `providers` section. Used init container with sed to substitute at runtime.

2. **Longhorn widget requires HTTPRoute:** The Homepage Longhorn info widget fetches data via HTTP from Longhorn UI. Must expose via Gateway API even for internal use.

3. **Security context for init containers:** Don't forget `allowPrivilegeEscalation: false` and `capabilities.drop: ALL` on init containers, not just main containers.

4. **Glances version matters:** OMV apt installs v3.x. Homepage widget config needs `version: 3`, not `version: 4`.

5. **ConfigMap hash suffix:** Kustomize `configMapGenerator` adds hash suffix, enabling automatic pod rollouts when config changes. Don't use `generatorOptions.disableNameSuffixHash`.

### HTTPRoutes Configured

| Service | URL |
|---------|-----|
| AdGuard | adguard.k8s.home.rommelporras.com |
| Homepage | portal.k8s.home.rommelporras.com |
| Longhorn | longhorn.k8s.home.rommelporras.com |

---

## January 20, 2026 — Phase 3.9: Alertmanager Notifications

### Milestone: Discord + Email Alerting Configured

Configured Alertmanager to send notifications via Discord and Email, with intelligent routing based on severity.

| Component | Status |
|-----------|--------|
| Discord #incidents | Webhook configured (critical alerts) |
| Discord #status | Webhook configured (warnings, info, resolved) |
| iCloud SMTP | Configured (noreply@rommelporras.com) |
| Email recipients | 3 addresses for critical alerts |

### Files Added/Modified

| File | Purpose |
|------|---------|
| helm/prometheus/values.yaml | Alertmanager config with routes and receivers |
| scripts/upgrade-prometheus.sh | Helm upgrade script with 1Password integration |
| manifests/monitoring/test-alert.yaml | Test alerts for verification |
| docs/rebuild/v0.5.0-alerting.md | Rebuild guide for alerting setup |
| docs/todo/deferred.md | Added kubeadm scraping issue |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Discord channel naming | #incidents + #status | Clear action expectation: incidents need action, status is FYI |
| Category naming | Notifications | Honest about purpose (notification inbox, not observability tool) |
| Email recipients | 3 addresses for critical | Redundancy: iCloud issues won't prevent delivery to Gmail |
| SMTP authentication | @icloud.com email | Apple requires Apple ID for SMTP auth, not custom domain |
| kubeadm alerts | Silenced (null receiver) | False positives from localhost-bound components; cluster works fine |
| Secrets management | 1Password + temp file | --set breaks array structures; temp file with cleanup is safer |

### Alert Routing

```
┌─────────────────────────────────────────────────┐
│                 Alertmanager                    │
└─────────────────────┬───────────────────────────┘
                      │
    ┌─────────────────┼─────────────────┐
    │                 │                 │
┌───▼───┐        ┌────▼────┐       ┌────▼────┐
│Silenced│        │Critical │       │Warning/ │
│kubeadm │        │         │       │  Info   │
└───┬───┘        └────┬────┘       └────┬────┘
    │                 │                 │
┌───▼───┐        ┌────▼────┐       ┌────▼────┐
│ null  │        │#incidents│       │#status  │
│       │        │+ 3 emails│       │  only   │
└───────┘        └─────────┘       └─────────┘
```

### Silenced Alerts (Deferred)

| Alert | Reason | Fix Location |
|-------|--------|--------------|
| KubeProxyDown | kube-proxy metrics not exposed | docs/todo/deferred.md |
| etcdInsufficientMembers | etcd bound to localhost | docs/todo/deferred.md |
| etcdMembersDown | etcd bound to localhost | docs/todo/deferred.md |
| TargetDown (kube-*) | Control plane bound to localhost | docs/todo/deferred.md |

### 1Password Items Created

| Item | Vault | Purpose |
|------|-------|---------|
| Discord Webhook Incidents | Kubernetes | #incidents webhook URL |
| Discord Webhook Status | Kubernetes | #status webhook URL |
| iCloud SMTP Alertmanager | Kubernetes | SMTP credentials |

### Lessons Learned

1. **Helm --set breaks arrays** - Using `--set 'receivers[0].webhook_url=...'` overwrites the entire array structure. Use multiple `--values` files instead.
2. **iCloud SMTP auth** - Must use @icloud.com email for authentication, not custom domain. From address can be custom domain.
3. **Port 587 = STARTTLS** - Not SSL. Common misconfiguration in email clients.
4. **kubeadm metrics** - Control plane components bind to localhost by default. Fixing requires modifying static pod manifests (risky, low value for homelab).

---

## January 20, 2026 — Documentation: Rebuild Guides

### Milestone: Split Rebuild Documentation by Release Tag

Created comprehensive step-by-step rebuild guides split by release tag for better organization and versioning.

| Document | Release | Phases |
|----------|---------|--------|
| [docs/rebuild/README.md](../rebuild/README.md) | Index | Overview, prerequisites, versions |
| [docs/rebuild/v0.1.0-foundation.md](../rebuild/v0.1.0-foundation.md) | v0.1.0 | Phase 1: Ubuntu, SSH |
| [docs/rebuild/v0.2.0-bootstrap.md](../rebuild/v0.2.0-bootstrap.md) | v0.2.0 | Phase 2: kubeadm, Cilium |
| [docs/rebuild/v0.3.0-storage.md](../rebuild/v0.3.0-storage.md) | v0.3.0 | Phase 3.1-3.4: Longhorn |
| [docs/rebuild/v0.4.0-observability.md](../rebuild/v0.4.0-observability.md) | v0.4.0 | Phase 3.5-3.8: Gateway, Monitoring, Logging, UPS |

### Benefits

- Each release is self-contained and versioned
- Can rebuild to a specific milestone
- Easier to maintain and update individual phases
- Aligns with git tags for reproducibility

---

## January 20, 2026 — Phase 3.8: UPS Monitoring (NUT)

### Milestone: NUT + Prometheus UPS Monitoring Running

Successfully installed Network UPS Tools (NUT) for graceful cluster shutdown during power outages, with Prometheus/Grafana integration for historical metrics and alerting.

| Component | Version | Status |
|-----------|---------|--------|
| NUT (Network UPS Tools) | 2.8.1 | Running (server on cp1, clients on cp2/cp3) |
| nut-exporter (DRuggeri) | 3.1.1 | Running (Deployment in monitoring namespace) |
| CyberPower UPS | CP1600EPFCLCD | Connected (USB to k8s-cp1) |

### Files Added

| File | Purpose |
|------|---------|
| manifests/monitoring/nut-exporter.yaml | Deployment, Service, ServiceMonitor for UPS metrics |
| manifests/monitoring/ups-alerts.yaml | PrometheusRule with 8 UPS alerts |
| manifests/monitoring/dashboards/ups-monitoring.json | Custom UPS dashboard (improved from Grafana.com #19308) |
| manifests/monitoring/ups-dashboard-configmap.yaml | ConfigMap for Grafana auto-provisioning |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| NUT server location | k8s-cp1 (bare metal) | Must run outside K8s to shutdown the node itself |
| Staggered shutdown | Time-based (10/20 min) | NUT upssched timers are native and reliable; percentage-based requires custom polling scripts |
| Exporter | DRuggeri/nut_exporter | Actively maintained (Dec 2025), better documentation, TLS support |
| Dashboard | Custom (repo-stored) | Grafana.com #19308 had issues; custom dashboard with ConfigMap auto-provisioning |
| Metric prefix | network_ups_tools_* | DRuggeri exporter uses this prefix (not nut_*) |
| UPS label | ServiceMonitor relabeling | Exporter doesn't add `ups` label; added via relabeling for dashboard compatibility |

### Architecture

```
CyberPower UPS ──USB──► k8s-cp1 (NUT Server + Master)
                              │
                    TCP 3493 (nutserver)
                              │
              ┌───────────────┼───────────────┐
              ▼               ▼               ▼
          k8s-cp2         k8s-cp3        K8s Cluster
        (upssched)      (upssched)     ┌─────────────────┐
       20min→shutdown  10min→shutdown  │  nut-exporter   │
                                       │  (Deployment)   │
                                       └────────┬────────┘
                                                │ :9995
                                       ┌────────▼────────┐
                                       │   Prometheus    │
                                       │ (ServiceMonitor)│
                                       └────────┬────────┘
                                                │
                                       ┌────────▼────────┐
                                       │    Grafana      │
                                       │  (Dashboard)    │
                                       └────────┬────────┘
                                                │
                                       ┌────────▼────────┐
                                       │  Alertmanager   │
                                       │(PrometheusRule) │
                                       └─────────────────┘
```

### Staggered Shutdown Strategy

| Node | Trigger | Timer | Reason |
|------|---------|-------|--------|
| k8s-cp3 | ONBATT event | 10 minutes | First to shutdown, reduce load early |
| k8s-cp2 | ONBATT event | 20 minutes | Second to shutdown, maintain quorum longer |
| k8s-cp1 | Low Battery (LB) | Native NUT | Last node, sends UPS power-off command |

With ~70 minute runtime at 9% load, these timers provide ample safety margin.

### Kubelet Graceful Shutdown

Configured on all nodes to evict pods gracefully before power-off:

```yaml
shutdownGracePeriod: 120s           # Total time for pod eviction
shutdownGracePeriodCriticalPods: 30s # Reserved for critical pods
```

### Alerts Configured

| Alert | Severity | Trigger |
|-------|----------|---------|
| UPSOnBattery | warning | On battery for 1m |
| UPSLowBattery | critical | LB flag set (immediate) |
| UPSBatteryCritical | critical | Battery < 30% for 1m |
| UPSBatteryWarning | warning | Battery 30-50% for 2m |
| UPSHighLoad | warning | Load > 80% for 5m |
| UPSExporterDown | critical | Exporter unreachable for 2m |
| UPSOffline | critical | Neither OL nor OB status for 2m |
| UPSBackOnline | info | Returns to line power |

### Lessons Learned

**USB permissions require udev rules:** The NUT driver couldn't access the USB device due to permissions. Created `/etc/udev/rules.d/90-nut-ups.rules` to grant the `nut` group access to CyberPower USB devices.

**DRuggeri Helm chart doesn't exist:** Despite documentation suggesting otherwise, there's no working Helm repository. Created manual manifests instead (Deployment, Service, ServiceMonitor).

**Metric names differ from documentation:** DRuggeri exporter uses `network_ups_tools_*` prefix, not `nut_*`. The status metric uses `{flag="OB"}` syntax, not `{status="OB"}`. Had to query the actual exporter to discover correct metric names.

**1Password CLI session scope:** The `op` CLI session is terminal-specific. Running `eval $(op signin)` in one terminal doesn't affect others. Each terminal needs its own session.

**Exporter doesn't add `ups` label:** The DRuggeri exporter doesn't include an `ups` label for single-UPS setups. Dashboard queries with `{ups="$ups"}` returned no data. Fixed with ServiceMonitor relabeling to inject `ups=cyberpower` label.

**Grafana.com dashboard had issues:** Dashboard #19308 showed "No Data" for several panels due to missing `--nut.vars_enable` metrics (battery.runtime, output.voltage). Created custom dashboard stored in repo with ConfigMap auto-provisioning.

**Grafana thresholdsStyle modes:** Setting `thresholdsStyle.mode: "line"` draws horizontal threshold lines on graphs; `"area"` fills background with threshold colors. Both can clutter graphs if overused.

### Access

- UPS Dashboard: https://grafana.k8s.home.rommelporras.com/d/ups-monitoring
- NUT Server: 10.10.30.11:3493
- nut-exporter (internal): nut-exporter.monitoring.svc.cluster.local:9995

### Sample PromQL Queries

```promql
network_ups_tools_battery_charge                        # Battery percentage
network_ups_tools_ups_load                              # Current load %
network_ups_tools_ups_status{flag="OL"}                 # Online status (1=true)
network_ups_tools_ups_status{flag="OB"}                 # On battery status
network_ups_tools_battery_runtime_seconds               # Estimated runtime
```

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
