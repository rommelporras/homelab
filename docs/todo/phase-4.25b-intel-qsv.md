# Phase 4.25b: Intel QSV Hardware Transcoding

> **Status:** In Progress
> **Target:** v0.24.0
> **Prerequisite:** Phase 4.25 (Jellyfin deployed and working with CPU transcoding)
> **Priority:** Medium (enables mobile streaming on weak connections)
> **DevOps Topics:** Device plugins, node-level driver config, GPU resource scheduling
> **CKA Topics:** DaemonSet, Device Plugin API, Node Feature Discovery, resource limits, supplementalGroups

> **Purpose:** Enable Intel Quick Sync Video (QSV) hardware transcoding on all 3 cluster nodes so Jellyfin can transcode media on-the-fly for mobile/low-bandwidth streaming without heavy CPU usage.
>
> **Why:** When traveling on mobile data or weak WiFi, Jellyfin needs to transcode 4K/1080p media down to a lower bitrate in real-time. The Intel i5-10400T iGPU (UHD 630) handles this efficiently — near-zero CPU impact, low power draw. Without QSV, transcoding pegs the CPU and limits concurrent streams to ~1-2.

---

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  Each K8s Node (k8s-cp1, cp2, cp3)                  │
│                                                     │
│  Intel i5-10400T                                    │
│  └── UHD Graphics 630 (iGPU)                        │
│      └── /dev/dri/renderD128                        │
│                                                     │
│  Kernel: i915 driver + HuC firmware (enable_guc=2)  │
│  Packages: intel-media-va-driver-non-free, vainfo   │
└──────────────────────┬──────────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────────┐
│  Kubernetes                                         │
│                                                     │
│  Node Feature Discovery (DaemonSet)                 │
│  └── Labels: intel.feature.node.kubernetes.io/gpu   │
│                                                     │
│  Intel Device Plugins Operator                      │
│  └── Intel GPU Plugin (DaemonSet)                   │
│      └── Advertises: gpu.intel.com/i915             │
│      └── sharedDevNum: 3 (3 pods can share 1 iGPU)  │
│                                                     │
│  Jellyfin Pod (arr-stack namespace)                 │
│  └── resources.limits: gpu.intel.com/i915: "1"      │
│  └── supplementalGroups: [video_gid, render_gid]    │
│  └── Device plugin auto-mounts /dev/dri             │
└─────────────────────────────────────────────────────┘
```

### Codec Support (i5-10400T / UHD 630 / Comet Lake)

| Codec | HW Decode | HW Encode | Notes |
|-------|-----------|-----------|-------|
| H.264 (AVC) 8-bit | Yes | Yes | Most common format |
| H.264 (AVC) 10-bit | No | No | Not supported by ANY GPU (Intel/NVIDIA/AMD) — software decode only |
| HEVC (H.265) 8-bit | Yes | Yes | Low-power encode path, requires HuC firmware |
| HEVC (H.265) 10-bit | Yes | Yes | Low-power encode path, requires HuC firmware |
| VP9 8-bit/10-bit | Yes | No | Decode only on Comet Lake |
| AV1 | No | No | Requires 11th gen+ (decode), Arc/14th gen+ (encode) |
| MPEG-2 | Yes | Yes | Legacy format |

---

## Prerequisites

- [x] Phase 4.25 complete — Jellyfin running with CPU transcoding
- [x] Verify `/dev/dri/renderD128` exists on all nodes: `ls -la /dev/dri/`
- [x] Verify `render` and `video` group GIDs on nodes: `getent group render video` — **render:993, video:44**
- [x] cert-manager running (required by Intel Device Plugins Operator webhooks)

---

## Tasks

### 4.25b.1 Node Preparation (Ansible — All 3 Nodes)

- [x] 4.25b.1.1 Create Ansible playbook `ansible/playbooks/08-intel-gpu.yml`:
  ```yaml
  # Install Intel media driver and verification tools
  - name: Install Intel GPU packages
    apt:
      name:
        - intel-media-va-driver-non-free   # iHD VA-API driver
        - vainfo                            # VA-API verification tool
        - intel-gpu-tools                   # intel_gpu_top monitoring
      state: present

  # Enable HuC firmware for HEVC low-power encode
  # enable_guc=2 = HuC load only (correct for Comet Lake)
  # NEVER use enable_guc=1 or 3 on Gen 9/10 — GuC submission is unsupported and causes crashes
  # Note: enable_guc=2 taints the kernel (cosmetic, no functional impact)
  - name: Configure i915 HuC firmware loading
    copy:
      dest: /etc/modprobe.d/i915.conf
      content: "options i915 enable_guc=2\n"
    notify: update-initramfs

  - name: Update initramfs
    command: update-initramfs -u
    notify: reboot
  ```
- [x] 4.25b.1.2 Run playbook on all 3 nodes (requires reboot) — rolling reboot with `serial: 1`, all 3 passed
- [x] 4.25b.1.3 Verify on each node after reboot — all gates passed (iHD 24.1.0, HuC authenticated, kubelet active):
  ```bash
  # i915 driver loaded
  lsmod | grep i915

  # DRI devices exist
  ls -la /dev/dri/
  # Expect: card0, renderD128

  # VA-API works with iHD driver
  vainfo --display drm --device /dev/dri/renderD128
  # Look for: "Driver version: Intel iHD driver"

  # HuC firmware loaded
  sudo dmesg | grep -i huc
  # Expect: "HuC authenticated"
  # If "HuC: load failed" — firmware binary missing from /lib/firmware/i915/
  # Fix: apt install linux-firmware && update-initramfs -u && reboot
  # If still missing, Ubuntu's initramfs may not include i915 firmware by default
  # Create /etc/initramfs-tools/hooks/i915_add_firmware to force inclusion

  # Note GIDs for Jellyfin pod config
  getent group render video
  # Confirmed: render:x:993, video:x:44
  ```

### 4.25b.2 Deploy Node Feature Discovery

- [x] 4.25b.2.1 Install NFD Helm chart (v0.18.3 — use OCI registry, legacy Helm repo is deprecated)
- [x] 4.25b.2.2 Apply Intel NFD feature rules (pinned to v0.34.1)
- [x] 4.25b.2.3 Verify GPU labels on all nodes — all 3 labeled `intel.feature.node.kubernetes.io/gpu: true`
  ```bash
  kubectl-homelab get nodes -o json | jq '.items[].metadata.labels | with_entries(select(.key | startswith("intel.feature")))'
  # Expect: "intel.feature.node.kubernetes.io/gpu": "true"
  ```

### 4.25b.3 Deploy Intel Device Plugins Operator + GPU Plugin

- [x] 4.25b.3.1 Create `helm/intel-gpu-plugin/values.yaml`:
  ```yaml
  name: gpudeviceplugin
  sharedDevNum: 3          # Allow 3 pods to share each iGPU
  logLevel: 2
  enableMonitoring: true
  allocationPolicy: "none"
  nodeFeatureRule: true

  nodeSelector:
    intel.feature.node.kubernetes.io/gpu: 'true'
  ```
- [x] 4.25b.3.2 Install Intel Device Plugins Operator (v0.34.1 — requires cert-manager)
  > **Note:** Required `fs.inotify.max_user_instances=512` on all nodes ([Issue #2075](https://github.com/intel/intel-device-plugins-for-kubernetes/issues/2075)). Applied via `/etc/sysctl.d/99-inotify.conf`.
- [x] 4.25b.3.3 Install Intel GPU Plugin (v0.34.1)
- [x] 4.25b.3.4 Verify GPU resources advertised — all 3 nodes show `gpu.intel.com/i915: 3`
  ```bash
  kubectl-homelab get node k8s-cp1 -o json | jq '.status.allocatable | with_entries(select(.key | startswith("gpu")))'
  # Expect: "gpu.intel.com/i915": "3"
  ```

### 4.25b.4 Update Jellyfin Deployment for QSV

- [x] 4.25b.4.1 Update `manifests/arr-stack/jellyfin/deployment.yaml`:
  - Add GPU resource request/limit:
    ```yaml
    resources:
      requests:
        cpu: "500m"
        memory: "512Mi"
        gpu.intel.com/i915: "1"
      limits:
        cpu: "4"
        memory: "4Gi"
        gpu.intel.com/i915: "1"
    ```
  - Add supplemental groups to pod security context (verified GIDs from all 3 nodes):
    ```yaml
    securityContext:
      supplementalGroups:
        - 44    # video
        - 993   # render
    ```
  - Add disk-backed emptyDir for transcode cache (NOT tmpfs — see Known Issues):
    ```yaml
    volumes:
      - name: transcode
        emptyDir: {}
    volumeMounts:
      - name: transcode
        mountPath: /config/transcodes
    ```
  - Increase memory limit to 4Gi (transcoding is memory-hungry, ~300-500Mi idle + ~200-500Mi per stream)
  - Note: Do NOT set `privileged: true` — device plugin handles /dev/dri access
  - Note: Stays PSS baseline compatible
- [x] 4.25b.4.2 Apply updated deployment and verify pod starts with GPU — confirmed `gpu.intel.com/i915: 1`:
  ```bash
  kubectl-homelab apply -f manifests/arr-stack/jellyfin/deployment.yaml
  kubectl-homelab -n arr-stack describe pod -l app=jellyfin | grep gpu.intel.com
  # Expect: gpu.intel.com/i915: 1
  ```

### 4.25b.4b Grafana Dashboard for Jellyfin & GPU

- [x] 4.25b.4b.1 Create `manifests/monitoring/jellyfin-dashboard-configmap.yaml`:
  - **Pod Status row:** Merged UP/DOWN + node placement (cp1/cp2/cp3) via `label_replace` + `kube_pod_info`, Uptime, Container Restarts, Transcode I/O (disk write rate via `container_fs_writes_bytes_total`)
  - **GPU Allocation row:** `gpu.intel.com/i915` allocated vs available per node (from kube-state-metrics), cluster-wide available/in-use stat panels
  - **Network Traffic row:** Jellyfin streaming throughput (left) + Tailscale tunnel traffic on `tailscale0` interface (right) — shows remote vs local streaming
  - **Resource Usage row:** CPU + Memory with dashed request/limit lines (idle ~300-500Mi, per stream +200-500Mi)
- [x] 4.25b.4b.2 Apply dashboard ConfigMaps (Jellyfin + ARR Stack)
- [x] 4.25b.4b.3 Verify both dashboards load in Grafana — confirmed via API (11 panels each, refresh 10s, 12h range)

> **Note:** Actual GPU engine utilization (Video/Render/Blitter %) requires `intel-gpu-exporter` or similar. Out of scope for this phase — use `sudo intel_gpu_top` on nodes for manual checks. Can be added in Phase 4.28 (Observability Improvements).

### 4.25b.5 Configure Jellyfin QSV in UI

- [x] 4.25b.5.1 Navigate to Administration Dashboard > Playback > Transcoding
- [x] 4.25b.5.2 Set Hardware acceleration to **Intel Quick Sync Video (QSV)**
- [x] 4.25b.5.3 Set QSV Device to `/dev/dri/renderD128`
- [x] 4.25b.5.4 Enable hardware encoding + low-power H.264/HEVC encoders
- [x] 4.25b.5.5 Check hardware decoding codecs: H.264, HEVC, MPEG-2, VP9, HEVC 10bit, VP9 10bit
- [x] 4.25b.5.6 Enable tone mapping (for HDR content)
- [x] 4.25b.5.7 Enable VPP tone mapping (preferred over OpenCL — uses fixed-function hardware)
- [x] 4.25b.5.8 Allow encoding in HEVC format

> **Tone Mapping Warning:** Jellyfin 10.11.x has a known bug (Issue [#15576](https://github.com/jellyfin/jellyfin/issues/15576)) where OpenCL-based tone mapping produces blocky/pixelated output with QSV. VPP tone mapping is unaffected and takes priority when both are enabled. If HDR content looks bad, verify VPP is being used (check pod logs for `tonemap_vaapi` vs `tonemap_opencl`).

### 4.25b.6 Verify Transcoding

- [x] 4.25b.6.1 Play a video in browser that forces transcode — tested with 3mbps bitrate limit
- [x] 4.25b.6.2 Verify pod logs confirm QSV codec selection — confirmed `hevc_qsv -low_power 1` with `driver=iHD`
- [x] 4.25b.6.3 Verify hardware scaling — confirmed `scale_vaapi=w=960:h=540` (1080p → 540p on GPU)
- [x] 4.25b.6.4 Test from phone (Jellyfin Android 2.6.3) — Direct Play at native quality, smooth playback
- [ ] 4.25b.6.5 Verify on the node — GPU is active during transcode (manual):
  ```bash
  # Find which node Jellyfin is running on
  kubectl-homelab -n arr-stack get pod -l app=jellyfin -o jsonpath='{.items[0].spec.nodeName}'
  # Then SSH to that node
  ssh wawashi@<node>.k8s.rommelporras.com
  sudo intel_gpu_top
  # Video engine should show activity
  ```

### 4.25b.7 Documentation & Release

- [x] 4.25b.7.1 Update `VERSIONS.md` — add NFD, Intel GPU Plugin versions
- [x] 4.25b.7.2 Update `docs/reference/CHANGELOG.md` — add QSV decision, codec support matrix
- [x] 4.25b.7.3 Update `docs/context/Cluster.md` — add Intel GPU info per node
- [x] 4.25b.7.4 Update `docs/context/Architecture.md` — add device plugin stack
- [x] 4.25b.7.5 Create `docs/rebuild/v0.24.0-intel-qsv.md`
- [x] 4.25b.7.6 Update `docs/todo/README.md` and `docs/rebuild/README.md`
- [ ] 4.25b.7.7 `/audit-docs`
- [ ] 4.25b.7.8 `/commit`
- [ ] 4.25b.7.9 `/release v0.24.0 "Intel QSV Hardware Transcoding"`
- [ ] 4.25b.7.10 Move this file to `docs/todo/completed/`

---

## Resource Budget (New Components Only)

| Component | Namespace | CPU Request | CPU Limit | Memory Request | Memory Limit |
|-----------|-----------|-------------|-----------|----------------|--------------|
| NFD | node-feature-discovery | ~50m | ~200m | ~64Mi | ~256Mi |
| Intel Operator | intel-device-plugins | ~50m | ~200m | ~64Mi | ~256Mi |
| GPU Plugin (per node) | intel-device-plugins | ~10m | ~50m | ~32Mi | ~64Mi |
| Jellyfin delta | arr-stack | +0 | +0 | +0 | +2Gi (4Gi total) |

Minimal footprint. The GPU plugin DaemonSet is very lightweight.

---

## Files to Create

| File | Type | Purpose |
|------|------|---------|
| `ansible/playbooks/08-intel-gpu.yml` | Ansible Playbook | Install Intel GPU drivers + HuC firmware on all nodes |
| `helm/intel-gpu-plugin/values.yaml` | Helm Values | Intel GPU Plugin configuration (v0.34.1) |
| `manifests/monitoring/jellyfin-dashboard-configmap.yaml` | ConfigMap | Grafana dashboard for Jellyfin + GPU allocation |
| `manifests/monitoring/arr-stack-dashboard-configmap.yaml` | ConfigMap | Grafana dashboard for all 6 ARR services overview |

### Pinned Versions

| Component | Version | Notes |
|-----------|---------|-------|
| Node Feature Discovery | 0.18.3 | Helm chart via OCI registry |
| Intel Device Plugins Operator | 0.34.1 | Requires cert-manager |
| Intel GPU Plugin | 0.34.1 | `sharedDevNum: 3` |
| intel-media-va-driver-non-free | 24.1.0 (Ubuntu 24.04 multiverse) | iHD VA-API driver |

## Files to Modify

| File | Change |
|------|--------|
| `manifests/arr-stack/jellyfin/deployment.yaml` | Add GPU resource, supplementalGroups, transcode emptyDir, bump memory limit |

---

## Verification Checklist

- [x] `vainfo` shows iHD driver on all 3 nodes — iHD 24.1.0
- [x] `dmesg | grep huc` shows "HuC authenticated" on all 3 nodes — kbl_huc_4.0.0.bin
- [x] NFD labels all nodes with `intel.feature.node.kubernetes.io/gpu: true`
- [x] `gpu.intel.com/i915: 3` in node allocatable resources — all 3 nodes
- [x] Jellyfin pod shows `gpu.intel.com/i915: 1` in describe output
- [x] Pod logs show `hevc_qsv` codec selection with `-low_power 1` (HuC-enabled encode)
- [x] ARR Stack overview dashboard applied to Grafana (merged Pod Status + node placement)
- [x] Jellyfin dashboard improved: merged UP/DOWN+node, Transcode I/O stat, Tailscale tunnel traffic panel
- [x] Verify dashboards load in Grafana — both confirmed via Grafana API (11 panels each, 10s refresh)
- [ ] Verify `intel_gpu_top` shows Video engine activity during transcode (manual)
- [ ] VPP tone mapping works on HDR content (no blocky/pixelated output)
- [x] Mobile phone playback smooth on low bandwidth — Jellyfin Android 2.6.3 Direct Play + 720kbps QSV transcode verified


---

## Rollback

```bash
# Remove GPU from Jellyfin (revert deployment to CPU-only)
kubectl-homelab apply -f manifests/arr-stack/jellyfin/deployment.yaml  # (reverted version)

# Remove GPU plugin + operator
helm-homelab uninstall -n intel-device-plugins intel-device-plugins-gpu
helm-homelab uninstall -n intel-device-plugins intel-device-plugins-operator
kubectl-homelab delete namespace intel-device-plugins

# Remove NFD
helm-homelab uninstall -n node-feature-discovery node-feature-discovery
kubectl-homelab delete namespace node-feature-discovery

# Remove dashboards
kubectl-homelab -n monitoring delete configmap jellyfin-dashboard arr-stack-dashboard

# Node packages and i915.conf can stay — they don't affect anything without the K8s components
```

---

## Known Issues & Risks

### Jellyfin 10.11.x QSV Tone Mapping Bug

Jellyfin 10.11.x changed the HDR tone mapping pipeline from `tonemap_vaapi` (working) to `tonemap_opencl` (broken on many Intel GPUs). Issue [#15576](https://github.com/jellyfin/jellyfin/issues/15576), closed as "Not Planned". **Mitigation:** Enable VPP tone mapping in Jellyfin settings — it uses Intel's fixed-function hardware path (not OpenCL) and takes priority when both options are enabled.

### Intel MediaSDK Deprecation (Long-term Risk)

Intel is deprecating MediaSDK for Gen 10 and older GPUs in favor of OneVPL (Gen 11+). Current `jellyfin-ffmpeg` bundles both runtimes, so QSV works today on our Comet Lake UHD 630. Future Jellyfin versions may drop MediaSDK support, requiring a switch to VA-API acceleration mode. **Not a blocker now, but worth tracking.**

### Transcode Cache: Why Disk-Backed emptyDir (Not tmpfs)

Memory-backed tmpfs emptyDir has serious risks in Kubernetes:
- OOM kills if cache grows beyond pod memory limit ([K8s Issue #128339](https://github.com/kubernetes/kubernetes/issues/128339))
- Stale tmpfs pages not released after OOMKill, causing permanent restart loops
- Can crash entire nodes if filled too fast ([K8s Issue #119611](https://github.com/kubernetes/kubernetes/issues/119611))

Disk-backed emptyDir is nearly as fast due to Linux page cache and has no OOM risk. Our 512GB NVMe drives have abundant ephemeral storage. Jellyfin auto-cleans the transcode directory via a scheduled task.

### enable_guc=2 Kernel Taint

Setting `enable_guc=2` on Comet Lake taints the kernel (cosmetic, visible in `dmesg`). This has no functional impact. If `dmesg` shows "Incompatible option enable_guc=2 — HuC is not supported!", the firmware binary may be missing from the initramfs. See step 4.25b.1.3 for troubleshooting.

### DRA (Dynamic Resource Allocation) — Future Alternative

Intel has `intel-resource-drivers-for-kubernetes` using DRA (Kubernetes 1.32+, enabled by default in 1.34+). This is the next-gen replacement for device plugins with better GPU sharing. Still too new for a homelab — stick with the device plugin approach for now.

---

## Technology Decisions

| Decision | Choice | Why |
|----------|--------|-----|
| HW transcoding method | Intel QSV (via VA-API) | Best quality-per-watt for media, built into existing CPUs |
| Device access | Intel Device Plugin (not manual hostPath) | PSS compatible, no privileged containers, proper resource scheduling |
| Node labeling | Node Feature Discovery | Auto-detects GPU presence, standard K8s ecosystem tool |
| Shared GPU count | sharedDevNum: 3 | Allows Jellyfin + future apps to share iGPU without contention |
| Jellyfin image | `jellyfin/jellyfin` (official) | Bundles `jellyfin-ffmpeg` with iHD driver built-in |
| HuC firmware | enable_guc=2 | Required for HEVC low-power encode path on Comet Lake |
| Transcode cache | Disk-backed emptyDir (not tmpfs) | Avoids OOM/node crash risk, nearly as fast due to page cache |
| Tone mapping | VPP (not OpenCL) | OpenCL broken in Jellyfin 10.11.x, VPP uses fixed-function HW |
