---
tags: [homelab, kubernetes, gpu, intel, device-plugin, nfd, qsv, transcoding]
updated: 2026-07-08
---

# GPU, Intel Device Plugin, and Node Feature Discovery (operational reference)

> Lean operational reference for the Intel iGPU stack (NFD + Intel GPU device plugin) that powers Jellyfin/Tdarr QSV transcoding. Use it to verify the GPU pipeline is healthy or triage a suspected GPU-to-CPU transcode fallback. For deep QSV triage (vainfo, HuC firmware, tone mapping) see [../todo/completed/phase-4.25b-intel-qsv.md](../todo/completed/phase-4.25b-intel-qsv.md). For the "why" (device plugin vs hostPath) see [Architecture.md](Architecture.md). For app-level Jellyfin/Tdarr incidents see [../runbooks/arr-stack.md](../runbooks/arr-stack.md).

## What runs, where

All 3 nodes (k8s-cp1/2/3, M80q) have an Intel UHD 630 iGPU exposing `/dev/dri/renderD128`. The stack is fully ArgoCD-managed (Helm, project `infrastructure`) - do not `kubectl apply` or `helm upgrade` these; selfHeal reverts manual changes.

| Component | Namespace | Kind | Selector / key detail | ArgoCD app |
|-----------|-----------|------|-----------------------|------------|
| Node Feature Discovery (NFD) | `node-feature-discovery` | Deployments `node-feature-discovery-master` + `-gc`, DaemonSet `node-feature-discovery-worker` | The worker DaemonSet inspects each node and, together with the master, applies node labels. It is the labeling engine only; the actual GPU rule ships with the GPU chart (see next row). | `node-feature-discovery` |
| Intel Device Plugins Operator | `intel-device-plugins` | Deployment `inteldeviceplugins-controller-manager` | Reconciles the `GpuDevicePlugin` CR | `intel-device-plugins-operator` |
| Intel GPU device plugin | `intel-device-plugins` | DaemonSet `intel-gpu-plugin-gpudeviceplugin` | Pods labeled `app=intel-gpu-plugin`; nodeSelector `intel.feature.node.kubernetes.io/gpu=true`; advertises `gpu.intel.com/i915`. The `NodeFeatureRule` that labels GPU nodes `intel.feature.node.kubernetes.io/gpu: "true"` ships with THIS chart (`nodeFeatureRule: true` in `helm/intel-device-plugins-gpu/values.yaml`), NOT the NFD chart. | `intel-device-plugins-gpu` |
| Jellyfin (consumer) | `arr-stack` | Deployment | Requests `gpu.intel.com/i915: "1"` for QSV | `arr-stack` |
| Tdarr (consumer) | `arr-stack` | Deployment | Requests `gpu.intel.com/i915: "1"` for QSV | `arr-stack` |

Key facts:

- **`sharedDevNum: 3`** (in `helm/intel-device-plugins-gpu/values.yaml`) - each node advertises `gpu.intel.com/i915: 3`, so up to 3 pods can share one iGPU. That is why allocatable/capacity reads `3` per node, not `1`.
- **Device access is unprivileged.** The plugin auto-mounts `/dev/dri` into any pod that requests `gpu.intel.com/i915`. Jellyfin/Tdarr pods add `supplementalGroups: [44, 993]` (video, render) instead of running privileged. PSS baseline, not restricted.
- **Correct namespace is `intel-device-plugins`, NOT `kube-system`.** The plugin DaemonSet does not run in kube-system.

## Verify sequence (read-only, safe to run any time)

Run these top to bottom. `kubectl-homelab` = read-only restricted kubeconfig (`~/.kube/homelab-claude.yaml`). All of the following work read-only; none require admin.

### 1. NFD label present on all GPU nodes

```
kubectl --kubeconfig ~/.kube/homelab-claude.yaml get nodes -L intel.feature.node.kubernetes.io/gpu
```

Expect `true` in the `GPU` column for k8s-cp1, k8s-cp2, k8s-cp3. If blank, the node was not labeled - check the NFD worker DaemonSet in `node-feature-discovery` and confirm the `NodeFeatureRule` exists (it is deployed by the `intel-device-plugins-gpu` chart, not the NFD chart):

```
kubectl --kubeconfig ~/.kube/homelab-claude.yaml get pods -n node-feature-discovery
kubectl --kubeconfig ~/.kube/homelab-claude.yaml get nodefeaturerule -A
```

### 2. i915 advertised as allocatable and capacity

```
kubectl --kubeconfig ~/.kube/homelab-claude.yaml get nodes \
  -o custom-columns='NODE:.metadata.name,I915_ALLOC:.status.allocatable.gpu\.intel\.com/i915,I915_CAP:.status.capacity.gpu\.intel\.com/i915'
```

Expect `3` / `3` on every node. `0` or `<none>` means the device plugin is not advertising the resource on that node (plugin pod down, or the node lost its NFD label) - the scheduler will silently place GPU-requesting pods without a GPU or leave them Pending.

### 3. Device-plugin DaemonSet healthy

```
kubectl --kubeconfig ~/.kube/homelab-claude.yaml get pods -n intel-device-plugins -l app=intel-gpu-plugin -o wide
```

Expect 3 pods `Running` `1/1`, one per node. Also confirm the operator:

```
kubectl --kubeconfig ~/.kube/homelab-claude.yaml get daemonset -n intel-device-plugins
kubectl --kubeconfig ~/.kube/homelab-claude.yaml get pods -n intel-device-plugins
```

Expect DaemonSet `intel-gpu-plugin-gpudeviceplugin` DESIRED=CURRENT=READY=3 and `inteldeviceplugins-controller-manager-*` Running.

### 4. Consumer pods actually hold a GPU slot

```
kubectl --kubeconfig ~/.kube/homelab-claude.yaml get pods -n arr-stack -l app=jellyfin -o wide
kubectl --kubeconfig ~/.kube/homelab-claude.yaml get pods -n arr-stack -l app=tdarr -o wide

kubectl --kubeconfig ~/.kube/homelab-claude.yaml get deployment jellyfin -n arr-stack \
  -o jsonpath='{.spec.template.spec.containers[*].resources}{"\n"}'
kubectl --kubeconfig ~/.kube/homelab-claude.yaml get deployment tdarr -n arr-stack \
  -o jsonpath='{.spec.template.spec.containers[*].resources}{"\n"}'
```

Expect both request and limit `gpu.intel.com/i915: "1"`. (Deployment sources: `manifests/arr-stack/jellyfin/deployment.yaml`, `manifests/arr-stack/tdarr/deployment.yaml`.)

### 5. `/dev/dri` present inside the running container

`exec` is RBAC-blocked on the restricted kubeconfig - use **kubectl-admin** for this one:

```
POD=$(kubectl --kubeconfig ~/.kube/homelab.yaml get pod -n arr-stack -l app=jellyfin -o jsonpath='{.items[0].metadata.name}')
kubectl --kubeconfig ~/.kube/homelab.yaml exec -n arr-stack "$POD" -- ls -la /dev/dri
```

Expect `card0` and `renderD128`. Missing = the pod scheduled without a real GPU device (plugin not advertising, or scheduled onto a node with no allocatable i915). Diagnose with steps 2-3 above; do not add hostPath mounts.

## GAP: no alert on the GPU pipeline

**There is currently no Prometheus alert on the device plugin, NFD labels, or `gpu.intel.com/i915` allocatable.** Verified against `manifests/monitoring/alerts/` - no rule references `i915`, `gpu.intel`, `GpuDevicePlugin`, NFD, or the device-plugin DaemonSet.

`TdarrDown` and `JellyfinDown` (in `manifests/monitoring/alerts/arr-alerts.yaml`) only check HTTP reachability:

```
- alert: TdarrDown
  expr: probe_success{job="tdarr"} == 0
- alert: JellyfinDown
  expr: probe_success{job="jellyfin"} == 0
```

Consequence: if the device plugin stops advertising i915 (crash, lost NFD label, node reboot race), the pods stay HTTP-reachable and transcode falls back to CPU. Jellyfin/Tdarr keep serving, `probe_success` stays `1`, and **nothing fires** - the only symptom is slow/stuttering playback and pegged CPU.

**Recommendation (not yet implemented):** add an alert on i915 allocatable dropping below expected, and/or on the device-plugin DaemonSet not fully ready. Candidate expressions to validate against live metric names before committing:

- `sum(kube_node_status_allocatable{resource="gpu_intel_com_i915"}) < 9` (3 nodes x 3 shared = 9 expected)
- `kube_daemonset_status_number_ready{daemonset="intel-gpu-plugin-gpudeviceplugin", namespace="intel-device-plugins"} < 3`

> Confirm the exact metric name and label form (`gpu_intel_com_i915` vs `gpu.intel.com/i915`) in Prometheus before writing the rule - kube-state-metrics sanitizes resource names and this has not been verified live. New alerts go in `manifests/monitoring/alerts/` per repo convention (ArgoCD-synced).

## Common failure modes

| Symptom | Likely cause | First check |
|---------|--------------|-------------|
| GPU node missing `true` label | NFD worker down / NodeFeatureRule not applied | Verify step 1, then NFD pods in `node-feature-discovery` |
| i915 allocatable `0` / `<none>` on a node | Plugin pod down, or node lost NFD label | Verify steps 2-3 |
| Consumer pod Pending | No free i915 slot (all 3 shares in use) or no allocatable on any schedulable node | `kubectl --kubeconfig ~/.kube/homelab-claude.yaml describe pod -n arr-stack <pod>` for the FailedScheduling event |
| Playback stutters, CPU pegged, apps still up | Silent GPU-to-CPU fallback (the unmonitored gap) | Verify step 5; if `/dev/dri` missing, work back through steps 2-3 |
| `HuC authenticated` missing / HDR looks blocky | Firmware / tone-mapping (out of scope here) | See [../todo/completed/phase-4.25b-intel-qsv.md](../todo/completed/phase-4.25b-intel-qsv.md) |

Node-level GPU driver/firmware checks (`vainfo`, `dmesg | grep -i huc`) run on the node itself via SSH: `ssh wawashi@10.10.30.11` (cp1), `.12` (cp2), `.13` (cp3). The exact commands and expected output are documented in the phase-4.25b doc - do not reproduce here.

## Related

- [Architecture.md](Architecture.md) - why Intel Device Plugin over hostPath, `sharedDevNum` rationale
- [../todo/completed/phase-4.25b-intel-qsv.md](../todo/completed/phase-4.25b-intel-qsv.md) - deep QSV triage: vainfo, HuC firmware, tone mapping, codec support
- [../runbooks/arr-stack.md](../runbooks/arr-stack.md) - Jellyfin/Tdarr app-level incidents (TdarrDown, JellyfinDown runbooks)
- [../runbooks/00-EMERGENCY.md](../runbooks/00-EMERGENCY.md) - cluster-wide outage entry point
- [Monitoring.md](Monitoring.md) - Prometheus/Grafana/alert conventions (where a GPU alert would live)

