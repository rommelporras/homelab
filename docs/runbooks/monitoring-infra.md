# Monitoring & CSI infrastructure - when the watchers themselves fail

> The components in this runbook are the SOURCE of your alerting and storage provisioning. When they fail, the failure is SILENT - the alerts that would tell you something is wrong depend on the very thing that broke. Use this when a service is broken but no alert fired, when `kubectl top` returns nothing, or when brand-new/rescheduled pods hang in `ContainerCreating` cluster-wide. Cross-linked from [00-EMERGENCY.md §6 (Storage stuck)](00-EMERGENCY.md#6-storage--volume-stuck) and [§11 (alert storm)](00-EMERGENCY.md#11-everything-is-broken-alert-storm). Related: [storage.md](storage.md), [longhorn-hardware.md](longhorn-hardware.md), [ups.md](ups.md), [../context/Monitoring.md](../context/Monitoring.md).

---

## 0. First, prove each watcher is actually alive

These four are all ArgoCD-managed (apps: `blackbox-exporter`, `smartctl-exporter`, `metrics-server`, `longhorn`). None of them page you loudly when they die, so the first move is always the same read-only sweep. Everything here is safe.

```bash
# Whole-cluster deploy + daemonset overview (spot the 0/1 or 0/3)
kubectl-homelab get deploy,ds -A

# The specific ones this runbook covers:
kubectl-homelab get deploy blackbox-exporter-prometheus-blackbox-exporter -n monitoring
kubectl-homelab get ds   smartctl-exporter-prometheus-smartctl-exporter-0 -n monitoring
kubectl-homelab get deploy metrics-server -n kube-system
kubectl-homelab get deploy csi-attacher csi-provisioner csi-resizer csi-snapshotter -n longhorn-system
```

Known-good replica counts (verified live 2026-07-08):

| Component | Namespace | Kind / name | Healthy |
|-----------|-----------|-------------|---------|
| Blackbox exporter | `monitoring` | deploy `blackbox-exporter-prometheus-blackbox-exporter` | `1/1` |
| Smartctl exporter | `monitoring` | ds `smartctl-exporter-prometheus-smartctl-exporter-0` | `3/3` (one per node) |
| Metrics server | `kube-system` | deploy `metrics-server` | `1/1` |
| CSI control plane | `longhorn-system` | deploy `csi-attacher` / `-provisioner` / `-resizer` / `-snapshotter` | `2/2` each |

> Restart note (applies to every section below): all four are ArgoCD-managed, so do NOT `kubectl apply` or `helm upgrade` them - selfHeal reverts manual manifest edits. To restart a workload without touching its spec, roll it: `kubectl-admin rollout restart deploy/<name> -n <ns>` (or `daemonset/<name>`). That is not a spec change, so ArgoCD leaves it alone. `rollout restart` needs `kubectl-admin` (the restricted kubeconfig cannot write).

---

## 1. BlackboxExporterDown - the foundation of all "ServiceDown" probes

**What it is:** the single Blackbox exporter deployment in `monitoring` is the prober behind EVERY `Probe` object in the cluster (26 of them, verified: adguard-dns, vault, ghost, jellyfin, all the arr apps, argocd, garage, etc.). Every `Probe` names this exporter's service as its `prober.url` (`blackbox-exporter-prometheus-blackbox-exporter.monitoring.svc:9115`). Prometheus does not probe those targets itself - it tells Blackbox to, then scrapes the result as `probe_success{job="<jobName>"}`. Alerts like `AdGuardDNSDown`, `GhostDown`, `VaultDown`, `JellyfinDown` all evaluate `probe_success == 0`.

**Why this is the scary one:** if Blackbox is down, `probe_success` stops being produced for every probed target. A metric that is absent does not evaluate to `0`, so **none of the `probe_success == 0` alerts fire**. You go completely blind on service-down detection and it looks quiet. AdGuard could be dead and you would not get `AdGuardDNSDown`.

> **KNOWN GAP - there is no alert that watches Blackbox itself.** There is no `up{job=...} == 0` rule for the Blackbox exporter, and (verified 2026-07-08) there is **no ServiceMonitor scraping the exporter's own `/metrics` either** - despite `serviceMonitor.enabled: true` in `helm/blackbox-exporter/values.yaml`, no `blackbox` ServiceMonitor object exists in any namespace. (The 26 `Probe` objects still work - each points Prometheus at the exporter's `:9115/probe` endpoint directly - so `probe_success` is produced; what is missing is a self-scrape of the exporter's own `up{}`.) Net effect: nothing tells you Blackbox died. You only discover it by noticing that ALL synthetic probes went silent at once, or by this manual check. Closing it (add a ServiceMonitor + `up == 0` alert, or a probe-freshness alert on `absent(probe_success)`) is worth doing when you next touch monitoring.

### Detection

```bash
# 1. Replica count - want 1/1
kubectl-homelab get deploy blackbox-exporter-prometheus-blackbox-exporter -n monitoring

# 2. The tell-tale: are ANY synthetic probes still reporting?
#    In Grafana Explore / Prometheus (https://grafana.k8s.rommelporras.com), run:
#      count(probe_success)
#    Normal is ~26. If it drops to 0 or is absent, the prober is down, not 26 services.
```

### Manual verify (does the prober actually answer?)

The exporter container listens on `:9115`. Ask it to probe something you know is up (Google over HTTP) and read the raw result. `exec` requires `kubectl-admin` (the restricted kubeconfig is blocked from exec):

```bash
# From the blackbox pod itself (http_2xx is a real module in helm/blackbox-exporter/values.yaml):
kubectl-admin exec -n monitoring deploy/blackbox-exporter-prometheus-blackbox-exporter -- \
  wget -qO- 'http://localhost:9115/probe?target=https://www.google.com&module=http_2xx' \
  | grep '^probe_success'
# probe_success 1  -> the prober works; the problem is elsewhere (a target, or Prometheus scrape)
# no output / connection refused -> the prober is broken
```

### Fix

```bash
kubectl-admin rollout restart deploy/blackbox-exporter-prometheus-blackbox-exporter -n monitoring
kubectl-homelab get pods -n monitoring | grep blackbox     # wait for 1/1 Running
```

Then re-run `count(probe_success)` and confirm it climbs back toward ~26. If the pod itself won't start, treat it like any pod: `kubectl-admin logs -n monitoring deploy/blackbox-exporter-prometheus-blackbox-exporter` and see [00-EMERGENCY.md §5 (A pod won't start)](00-EMERGENCY.md#5-a-pod-wont-start).

---

## 2. SmartctlExporterDown - the only eyes on your NVMe drives

**What it is:** a DaemonSet (`smartctl-exporter-prometheus-smartctl-exporter-0`, one pod per node, container port `9633`) that reads NVMe SMART data off each M80q's drive and exposes `smartctl_device_*` metrics. Every NVMe health alert - `NVMeMediaErrors`, `NVMeSpareWarning`, `NVMeWearHigh`, `NVMeTemperatureHigh` (all in `manifests/monitoring/alerts/storage-alerts.yaml`) - is built on those metrics.

**Why it matters:** if this DaemonSet is down, `smartctl_device_*` stops flowing, the NVMe alerts can't fire, and **a drive that is actively dying (media errors, exhausted spare blocks, thermal throttle) becomes invisible.** Given the cp3 NVMe history in this cluster, that is exactly the failure mode you least want to be blind to.

> **RESOLVED cross-doc note (verified 2026-07-08):** `smartctl` **IS installed on
> the nodes** at `/usr/sbin/smartctl` (`ssh wawashi@10.10.30.11 'which smartctl'`
> returns it). So:
> - [storage.md](storage.md#nvmemediaerrors)'s `ssh wawashi@<node>` + `sudo smartctl
>   -a /dev/nvme0` triage is **correct** and works as a fallback when the exporter is down.
> - [longhorn-hardware.md](longhorn-hardware.md) line 41's "smartctl is not installed
>   on nodes" claim is **WRONG and should be fixed** (it is not in this file - flag it).
> Bottom line: if `smartctl-exporter` is down you still have the node CLI as a
> fallback for SMART data. (longhorn-hardware.md's own exporter command uses
> `kubectl-homelab exec`, which is RBAC-blocked - it needs `kubectl-admin exec`.)

> **KNOWN GAP:** as with Blackbox, there is currently no `SmartctlExporterDown` / `up{job=...} == 0` alert (verified 2026-07-08 - no such rule in `manifests/monitoring/alerts/`). Note the exporter DOES have a ServiceMonitor (`smartctl-exporter-prometheus-smartctl-exporter`), so the `up{}` series exists and an alert *could* be written - it just isn't yet. For now nothing pages you when the exporter dies; you find it here or by noticing `smartctl_device_*` panels on the Longhorn dashboard going flat.

### Detection

```bash
# Want 3/3 DESIRED=CURRENT=READY (one per node)
kubectl-homelab get ds smartctl-exporter-prometheus-smartctl-exporter-0 -n monitoring
kubectl-homelab get pods -n monitoring -o wide | grep smartctl   # confirm one per cp1/cp2/cp3

# In Prometheus/Grafana - is SMART data still arriving?
#   count(smartctl_device_smart_status)   # expect a small non-zero number, one per drive
```

### Manual verify (read SMART straight off a node's exporter pod)

`exec` requires `kubectl-admin`. Pick the pod on the node you care about (get names from the `get pods -o wide` above):

```bash
kubectl-admin exec -n monitoring smartctl-exporter-prometheus-smartctl-exporter-0-<suffix> -- \
  wget -qO- http://localhost:9633/metrics \
  | grep -E 'smartctl_device_(media_errors|critical_warning|percentage_used|available_spare)'
# Healthy baseline: media_errors=0, critical_warning=0, available_spare=100, percentage_used<5
```

If that returns data, the exporter is fine and any missing NVMe alert is a Prometheus scrape/rule issue, not a dead exporter.

### Fix

```bash
kubectl-admin rollout restart daemonset/smartctl-exporter-prometheus-smartctl-exporter-0 -n monitoring
kubectl-homelab get pods -n monitoring -o wide | grep smartctl   # wait for all 3 Running
```

If only ONE pod is down, the problem is that node (drive access, node NotReady) - check [00-EMERGENCY.md §8 (node down)](00-EMERGENCY.md#8-a-node-is-down-or-notready). If a drive itself is failing, escalate to [longhorn-hardware.md](longhorn-hardware.md) and [storage.md#nvmemediaerrors](storage.md#nvmemediaerrors).

---

## 3. MetricsServerDown - `kubectl top` dies, scheduler goes half-blind

**What it is:** `metrics-server` in `kube-system` serves the `metrics.k8s.io` API. It backs `kubectl top`, HPA scaling decisions, and resource-aware scheduling. Not a Prometheus exporter - it is a Kubernetes aggregated API service.

**Why it matters:** if it's down, `kubectl top nodes/pods` returns an error, any HPA stops scaling on CPU/memory, and the scheduler loses live utilization signal. It rarely takes anything down hard, but during an incident you lose a key "where is the load?" tool exactly when you need it.

### Detection

```bash
# 1. Replica count - want 1/1
kubectl-homelab get deploy metrics-server -n kube-system

# 2. The definitive signal: is the aggregated API Available?  (needs kubectl-admin -
#    the restricted kubeconfig is Forbidden from 'get apiservices')
kubectl-admin get apiservice v1beta1.metrics.k8s.io
# Healthy: AVAILABLE = True
```

### Manual verify

```bash
# If this works, metrics-server is serving:
kubectl-admin top nodes
# Error "metrics not available" / "the server could not find the requested resource"
#   -> metrics-server is down or the APIService is not Available.
```

### Fix

```bash
kubectl-admin rollout restart deploy/metrics-server -n kube-system
kubectl-homelab get pods -n kube-system | grep metrics-server     # wait for 1/1 Running
kubectl-admin get apiservice v1beta1.metrics.k8s.io               # AVAILABLE back to True
```

If it comes up but the APIService stays `False`, that is an aggregation-layer problem (metrics-server not reachable from the apiserver, or TLS) - check `kubectl-admin logs -n kube-system deploy/metrics-server`. ArgoCD-managed (`metrics-server` app); do not edit its manifests directly.

---

## 4. CSIControlPlaneDown - no PVC can bind/attach/resize, cluster-wide

**What it is:** four Longhorn CSI sidecar deployments in `longhorn-system`, 2 replicas each (verified): `csi-attacher`, `csi-provisioner`, `csi-resizer`, `csi-snapshotter`. They are the storage CONTROL plane - they translate Kubernetes PVC/attach/resize intents into Longhorn actions.

> **This is distinct from the node-level `longhorn-csi-plugin` DaemonSet** (3/3, one per node) that [00-EMERGENCY.md §6](00-EMERGENCY.md#6-storage--volume-stuck) points at for per-node mount failures. §6 is about "this pod on this node can't mount its volume." THIS section is about the cluster-wide provisioning brain: if these deployments are down, the failure is not scoped to one node.

**Why it matters (and why it looks like a mystery):** if the CSI control plane is down, **no PVC can be provisioned, attached, or resized anywhere.** Every new pod, and every pod that gets rescheduled (node drain, eviction, OOM restart, Helm bump), hangs in `ContainerCreating` with `FailedAttachVolume` / `waiting for a volume to be created` - across all namespaces at once. It looks like "everything's broken" but it's one root cause.

> **THIS IS THE ROOT-CAUSE POINTER FOR THE "NEVER DELETE A PVC" RULE.** When a pod is stuck `ContainerCreating` on a volume, the panic instinct is to delete the PVC. **Do not.** Deleting a PVC destroys the Longhorn volume and every replica permanently. If the cause is a dead CSI control plane, the PVC and the data are completely fine - only the attach/provision machinery is down. Restore the CSI deployments and the stuck pods resolve on their own. See the rule in [00-EMERGENCY.md §6](00-EMERGENCY.md#6-storage--volume-stuck) and CLAUDE.md.

### Detection

```bash
# All four should be 2/2:
kubectl-homelab get deploy csi-attacher csi-provisioner csi-resizer csi-snapshotter -n longhorn-system

# Corroborate: pods stuck ContainerCreating across MANY namespaces = cluster-wide, points here
kubectl-homelab get pods -A --field-selector=status.phase=Pending -o wide
kubectl-homelab get pods -A | grep -E 'ContainerCreating'
```

If a stuck pod's events say `FailedAttachVolume` / `Multi-Attach` on ONE node only, that is more likely the node-level plugin or a stale iSCSI session - go to [00-EMERGENCY.md §6](00-EMERGENCY.md#6-storage--volume-stuck) and [storage.md#staleiscsisession](storage.md#staleiscsisession) instead. Cluster-wide `waiting for a volume to be created` / attach failures across many namespaces = this section.

### Manual verify

```bash
# Are all four control-plane deployments actually serving (2/2, pods Running)?
kubectl-homelab get pods -n longhorn-system -o wide | grep -E 'csi-attacher|csi-provisioner|csi-resizer|csi-snapshotter'

# The node-level plugin is a SEPARATE thing - confirm it too so you know which layer broke:
kubectl-homelab get ds longhorn-csi-plugin -n longhorn-system     # want 3/3
```

### Fix

```bash
# Restart whichever of the four is not 2/2. Repeat per broken deployment.
kubectl-admin rollout restart deploy/csi-attacher      -n longhorn-system
kubectl-admin rollout restart deploy/csi-provisioner   -n longhorn-system
kubectl-admin rollout restart deploy/csi-resizer       -n longhorn-system
kubectl-admin rollout restart deploy/csi-snapshotter   -n longhorn-system

kubectl-homelab get deploy -n longhorn-system | grep csi-          # back to 2/2 each
```

These are managed by the `longhorn` ArgoCD app (Helm chart, `longhorn-system` ns) - do NOT `helm upgrade` or `kubectl apply` them. Once they're 2/2, the stuck `ContainerCreating` pods should attach within a minute or two on their own; do not force-delete their PVCs. If the pods still hang after the control plane is healthy, drop to the node-level triage in [00-EMERGENCY.md §6](00-EMERGENCY.md#6-storage--volume-stuck).

---

## 5. Already covered elsewhere - don't duplicate

- **UPS / NUT exporter** - `nut-exporter` in `monitoring` already HAS a real alert (`UPSExporterDown`, `up{job="nut-exporter"} == 0`) with its own runbook. If UPS metrics go dark, go to [ups.md#UPSExporterDown](ups.md#UPSExporterDown), not here.

---

## Quick command index

| Symptom | Check | Fix (needs kubectl-admin) |
|---------|-------|---------------------------|
| No `*Down` service alerts firing, probes silent | `count(probe_success)` in Prometheus; `get deploy blackbox-exporter-prometheus-blackbox-exporter -n monitoring` | `rollout restart deploy/blackbox-exporter-prometheus-blackbox-exporter -n monitoring` |
| No NVMe SMART alerts / drive health blind | `get ds smartctl-exporter-prometheus-smartctl-exporter-0 -n monitoring`; `count(smartctl_device_smart_status)` | `rollout restart daemonset/smartctl-exporter-prometheus-smartctl-exporter-0 -n monitoring` |
| `kubectl top` fails, HPAs not scaling | `get apiservice v1beta1.metrics.k8s.io` (admin) = True? | `rollout restart deploy/metrics-server -n kube-system` |
| Pods `ContainerCreating` cluster-wide, PVCs won't bind/attach | `get deploy csi-* -n longhorn-system` all 2/2? | `rollout restart deploy/csi-<attacher\|provisioner\|resizer\|snapshotter> -n longhorn-system` |

All four are ArgoCD-managed - restart only via `rollout restart`, never `kubectl apply` / `helm upgrade`.

