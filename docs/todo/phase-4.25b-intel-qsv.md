# Phase 4.25b: Intel QSV Hardware Transcoding

> **Status:** Planned
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
│                                                      │
│  Intel i5-10400T                                     │
│  └── UHD Graphics 630 (iGPU)                        │
│      └── /dev/dri/renderD128                         │
│                                                      │
│  Kernel: i915 driver + HuC firmware (enable_guc=2)   │
│  Packages: intel-media-va-driver-non-free, vainfo    │
└──────────────────────┬──────────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────────┐
│  Kubernetes                                          │
│                                                      │
│  Node Feature Discovery (DaemonSet)                  │
│  └── Labels: intel.feature.node.kubernetes.io/gpu    │
│                                                      │
│  Intel Device Plugins Operator                       │
│  └── Intel GPU Plugin (DaemonSet)                    │
│      └── Advertises: gpu.intel.com/i915              │
│      └── sharedDevNum: 3 (3 pods can share 1 iGPU)  │
│                                                      │
│  Jellyfin Pod (media namespace)                      │
│  └── resources.limits: gpu.intel.com/i915: "1"       │
│  └── supplementalGroups: [video_gid, render_gid]     │
│  └── Device plugin auto-mounts /dev/dri              │
└─────────────────────────────────────────────────────┘
```

### Codec Support (i5-10400T / UHD 630 / Comet Lake)

| Codec | HW Decode | HW Encode | Notes |
|-------|-----------|-----------|-------|
| H.264 (AVC) 8-bit | Yes | Yes | Most common format |
| HEVC (H.265) 8-bit | Yes | Yes | Low-power encode path, requires HuC firmware |
| HEVC (H.265) 10-bit | Yes | Yes | Low-power encode path, requires HuC firmware |
| VP9 8-bit/10-bit | Yes | No | Decode only on Comet Lake |
| AV1 | No | No | Requires 11th gen+ (decode), Arc/14th gen+ (encode) |
| MPEG-2 | Yes | Yes | Legacy format |

---

## Prerequisites

- [ ] Phase 4.25 complete — Jellyfin running with CPU transcoding
- [ ] Verify `/dev/dri/renderD128` exists on all nodes: `ls -la /dev/dri/`
- [ ] Verify `render` and `video` group GIDs on nodes: `getent group render video`
- [ ] cert-manager running (required by Intel Device Plugins Operator webhooks)

---

## Tasks

### 4.25b.1 Node Preparation (Ansible — All 3 Nodes)

- [ ] 4.25b.1.1 Create Ansible playbook `ansible/playbooks/08-intel-gpu.yml`:
  ```yaml
  # Install Intel media driver and verification tools
  - name: Install Intel GPU packages
    apt:
      name:
        - intel-media-va-driver-non-free   # iHD VA-API driver
        - vainfo                            # VA-API verification tool
        - intel-gpu-tools                   # intel_gpu_top monitoring
        - linux-firmware                    # i915 firmware (usually present)
      state: present

  # Enable HuC firmware for HEVC low-power encode
  - name: Configure i915 HuC firmware loading
    copy:
      dest: /etc/modprobe.d/i915.conf
      content: "options i915 enable_guc=2\n"
    notify: update-initramfs

  - name: Update initramfs
    command: update-initramfs -u
    notify: reboot
  ```
- [ ] 4.25b.1.2 Run playbook on all 3 nodes (requires reboot)
- [ ] 4.25b.1.3 Verify on each node after reboot:
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

  # Note GIDs for Jellyfin pod config
  getent group render video
  # Expect: render:x:104, video:x:44 (verify exact GIDs)
  ```

### 4.25b.2 Deploy Node Feature Discovery

- [ ] 4.25b.2.1 Install NFD Helm chart (v0.18.3 — use OCI registry, legacy Helm repo is deprecated):
  ```bash
  helm-homelab upgrade -i --create-namespace \
    -n node-feature-discovery node-feature-discovery \
    oci://registry.k8s.io/nfd/charts/node-feature-discovery \
    --version 0.18.3
  ```
- [ ] 4.25b.2.2 Apply Intel NFD feature rules (pin to release version, not `main`):
  ```bash
  kubectl-homelab apply -f https://raw.githubusercontent.com/intel/intel-device-plugins-for-kubernetes/v0.34.1/deployments/nfd/overlays/node-feature-rules/node-feature-rules.yaml
  ```
- [ ] 4.25b.2.3 Verify GPU labels on all nodes:
  ```bash
  kubectl-homelab get nodes -o json | jq '.items[].metadata.labels | with_entries(select(.key | startswith("intel.feature")))'
  # Expect: "intel.feature.node.kubernetes.io/gpu": "true"
  ```

### 4.25b.3 Deploy Intel Device Plugins Operator + GPU Plugin

- [ ] 4.25b.3.1 Create `helm/intel-gpu-plugin/values.yaml`:
  ```yaml
  name: gpudeviceplugin
  sharedDevNum: 3          # Allow 3 pods to share each iGPU
  logLevel: 2
  resourceManager: false
  enableMonitoring: true
  allocationPolicy: "none"
  nodeFeatureRule: true

  nodeSelector:
    intel.feature.node.kubernetes.io/gpu: 'true'
  ```
- [ ] 4.25b.3.2 Install Intel Device Plugins Operator (v0.34.1 — requires cert-manager):
  ```bash
  helm-homelab repo add intel https://intel.github.io/helm-charts/
  helm-homelab repo update
  helm-homelab upgrade -i --create-namespace \
    -n intel-device-plugins intel-device-plugins-operator \
    intel/intel-device-plugins-operator --version 0.34.1
  ```
- [ ] 4.25b.3.3 Install Intel GPU Plugin (v0.34.1):
  ```bash
  helm-homelab upgrade -i \
    -n intel-device-plugins intel-device-plugins-gpu \
    -f helm/intel-gpu-plugin/values.yaml \
    intel/intel-device-plugins-gpu --version 0.34.1
  ```
- [ ] 4.25b.3.4 Verify GPU resources advertised:
  ```bash
  kubectl-homelab get node k8s-cp1 -o json | jq '.status.allocatable | with_entries(select(.key | startswith("gpu")))'
  # Expect: "gpu.intel.com/i915": "3"
  ```

### 4.25b.4 Update Jellyfin Deployment for QSV

- [ ] 4.25b.4.1 Update `manifests/media/jellyfin/deployment.yaml`:
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
  - Add supplemental groups to pod security context (verify actual GIDs from step 4.25b.1.3):
    ```yaml
    securityContext:
      supplementalGroups:
        - 44    # video (verify: getent group video)
        - 104   # render (verify: getent group render)
    ```
  - Add emptyDir for transcode cache:
    ```yaml
    volumes:
      - name: transcode
        emptyDir: {}
    volumeMounts:
      - name: transcode
        mountPath: /config/transcodes
    ```
  - Increase memory limit to 4Gi (transcoding is memory-hungry)
  - Note: Do NOT set `privileged: true` — device plugin handles /dev/dri access
  - Note: Stays PSS baseline compatible
- [ ] 4.25b.4.2 Apply updated deployment and verify pod starts with GPU:
  ```bash
  kubectl-homelab apply -f manifests/media/jellyfin/deployment.yaml
  kubectl-homelab -n media describe pod -l app=jellyfin | grep gpu.intel.com
  # Expect: gpu.intel.com/i915: 1
  ```

### 4.25b.5 Configure Jellyfin QSV in UI

- [ ] 4.25b.5.1 Navigate to Administration Dashboard > Playback > Transcoding
- [ ] 4.25b.5.2 Set Hardware acceleration to **Intel Quick Sync Video (QSV)**
- [ ] 4.25b.5.3 Set QSV Device to `/dev/dri/renderD128`
- [ ] 4.25b.5.4 Enable hardware encoding checkbox
- [ ] 4.25b.5.5 Check hardware decoding codecs:
  - [x] H.264
  - [x] HEVC
  - [x] MPEG-2
  - [x] VP9
  - [ ] AV1 (leave unchecked — not supported on Comet Lake)
- [ ] 4.25b.5.6 Enable tone mapping (for HDR content)
- [ ] 4.25b.5.7 Enable VPP tone mapping
- [ ] 4.25b.5.8 Allow encoding in HEVC format

### 4.25b.6 Verify Transcoding

- [ ] 4.25b.6.1 Play a video in browser that forces transcode (HEVC file in a browser that doesn't support HEVC, or set bitrate limit low)
- [ ] 4.25b.6.2 Verify Jellyfin dashboard shows **(HW)** next to codec in playback info
- [ ] 4.25b.6.3 Verify on the node — GPU is active during transcode:
  ```bash
  ssh wawashi@cp1.k8s.rommelporras.com
  sudo intel_gpu_top
  # Video engine should show activity
  ```
- [ ] 4.25b.6.4 Test from phone on mobile data — confirm smooth playback at reduced bitrate

### 4.25b.7 Documentation & Release

- [ ] 4.25b.7.1 Update `VERSIONS.md` — add NFD, Intel GPU Plugin versions
- [ ] 4.25b.7.2 Update `docs/reference/CHANGELOG.md` — add QSV decision, codec support matrix
- [ ] 4.25b.7.3 Update `docs/context/Cluster.md` — add Intel GPU info per node
- [ ] 4.25b.7.4 Update `docs/context/Architecture.md` — add device plugin stack
- [ ] 4.25b.7.5 Create `docs/rebuild/v0.24.0-intel-qsv.md`
- [ ] 4.25b.7.6 Update `docs/todo/README.md` — add Phase 4.25b
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
| Jellyfin delta | media | +0 | +0 | +0 | +2Gi (4Gi total) |

Minimal footprint. The GPU plugin DaemonSet is very lightweight.

---

## Files to Create

| File | Type | Purpose |
|------|------|---------|
| `ansible/playbooks/08-intel-gpu.yml` | Ansible Playbook | Install Intel GPU drivers + HuC firmware on all nodes |
| `helm/intel-gpu-plugin/values.yaml` | Helm Values | Intel GPU Plugin configuration (v0.34.1) |

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
| `manifests/media/jellyfin/deployment.yaml` | Add GPU resource, supplementalGroups, transcode emptyDir, bump memory limit |

---

## Verification Checklist

- [ ] `vainfo` shows iHD driver on all 3 nodes
- [ ] `dmesg | grep huc` shows "HuC authenticated" on all 3 nodes
- [ ] NFD labels all nodes with `intel.feature.node.kubernetes.io/gpu: true`
- [ ] `gpu.intel.com/i915: 3` in node allocatable resources
- [ ] Jellyfin pod shows `gpu.intel.com/i915: 1` in describe output
- [ ] Transcode shows **(HW)** in Jellyfin playback dashboard
- [ ] `intel_gpu_top` shows Video engine activity during transcode
- [ ] Mobile phone playback smooth on low bandwidth

---

## Rollback

```bash
# Remove GPU from Jellyfin (revert deployment to CPU-only)
kubectl-homelab apply -f manifests/media/jellyfin/deployment.yaml  # (reverted version)

# Remove GPU plugin + operator
helm-homelab uninstall -n intel-device-plugins intel-device-plugins-gpu
helm-homelab uninstall -n intel-device-plugins intel-device-plugins-operator
kubectl-homelab delete namespace intel-device-plugins

# Remove NFD
helm-homelab uninstall -n node-feature-discovery node-feature-discovery
kubectl-homelab delete namespace node-feature-discovery

# Node packages and i915.conf can stay — they don't affect anything without the K8s components
```

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
