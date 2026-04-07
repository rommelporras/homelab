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

## Loki PVC Resize Observation

**Status:** Resolved - expanded to 20Gi, steady-state ~43%
**Priority:** Closed
**Added:** 2026-03-19
**Resolved:** 2026-03-23

### History

- 2026-03-19: Alert fired at 86.2% on 10Gi. Reduced retention 90->60 days, expanded 10->12Gi.
- 2026-03-23: Alert fired again at 92.3% on 12Gi. Log volume increased after Phase 5.5
  (more services logging). Expanded 12->20Gi. Expected steady-state: ~8.6 GiB on 20Gi (~43%).
  Procedure: `kubectl-admin patch pvc`, delete pod for filesystem resize, `--cascade=orphan`
  StatefulSet + helm upgrade to sync volumeClaimTemplates.
- 2026-04-07: Alert fired at 91.6% on 20Gi. Root cause: audit logs (72.5%, 2.5 GiB/day) +
  GitLab Sidekiq info logs (17.7%, 630 MiB/day). Fix: tightened API server audit policy
  (dropped get/list verbs), added Alloy drop rules for audit reads + Sidekiq/version-checker
  info/debug, reduced retention 60->30 days. Post-filter ingestion ~300 MiB/day.

**When:** Closed. Audit policy + Alloy filtering addressed root cause.

---

## Invoicetron CI/CD Image Tag Alignment

**Status:** Deferred - requires CI/CD pipeline change
**Priority:** Medium
**Added:** 2026-03-23

### The problem

`manifests/invoicetron/deployment.yaml` hardcodes a prod-specific image path
(`invoicetron/prod:SHA`). CI/CD patches this per-environment via `kubectl set image`.
When the manifest is applied directly to `invoicetron-dev` (e.g. during busybox base
image updates), it pushes the prod image tag to the dev namespace. Combined with
`RollingUpdate maxUnavailable:0` and ResourceQuota, this causes `KubeDeploymentRolloutStuck`.

### Why portfolio doesn't have this issue

Portfolio uses a generic placeholder (`portfolio:latest`) that works in any namespace.
CI/CD patches the correct image regardless. Invoicetron uses environment-specific paths
(`invoicetron/dev` vs `invoicetron/prod`) baked into the manifest.

### Fix options

1. **Align with portfolio pattern** - change manifest image to a generic placeholder
   (`registry.k8s.rommelporras.com/0xwsh/invoicetron:latest`), update CI/CD to set the
   correct env-specific image on each deploy
2. **Split into per-env manifests** - `deployment-dev.yaml` and `deployment-prod.yaml`
   with correct image paths (more files but explicit)
3. **Keep current + gotcha** - CLAUDE.md gotcha warns against direct apply to dev
   (current workaround, documented but error-prone)

### Workaround (current)

CLAUDE.md gotcha added: never apply `manifests/invoicetron/deployment.yaml` directly
to invoicetron-dev. If accidentally applied, fix with:
```bash
kubectl-admin set image deployment/invoicetron \
  invoicetron=registry.k8s.rommelporras.com/0xwsh/invoicetron/dev:<current-sha> \
  -n invoicetron-dev
```

**When:** Next time Invoicetron CI/CD pipeline is modified or GitLab CI config is updated.

---

## Loki Ruler for LogQL Alerts

**Status:** Deferred — waiting for a phase that touches Loki/monitoring architecture
**Priority:** Medium
**Added:** 2026-03-15 (Phase 5.1)

Audit alert rules exist at `manifests/monitoring/alerts/audit-alerts.yaml` (LogQL-based) but
cannot fire because Loki is running in single-binary mode without the ruler component.

**What's needed:**
- Enable Loki ruler in Helm values (`loki.ruler.enabled: true`)
- Configure ruler storage (local filesystem or object storage for rule state)
- Deploy the audit-alerts.yaml rules to Loki ruler
- Verify alerts fire (trigger a `kubectl exec` and confirm `AuditPodExec` fires)

**Manual queries work now** — `{source="audit_log"} | json` in Grafana Explore.
The gap is only automated alerting.

**When:** Next time Loki is upgraded or monitoring architecture is revisited.

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

## NUT Client on Proxmox PVE (Dell 3090)

**Status:** Deferred - manual setup required on Proxmox host
**Priority:** Medium - ungraceful shutdown risks OMV filesystem corruption
**Added:** 2026-03-16 (Phase 5.3)

### The problem

The UPS (CyberPower CP1600EPFCLCD) protects all homelab hardware. The NUT server runs on
k8s-cp1 (USB cable connected there). The 3 k8s nodes have NUT clients with staggered
shutdown timers (10min/20min/low-battery). But the Dell 3090 running Proxmox PVE has
**no NUT client** - when the UPS battery dies, Proxmox and its VMs get killed ungracefully.

### What's at risk

The Dell 3090 (Proxmox PVE) hosts:
- **OMV (OpenMediaVault)** at 10.10.30.4 - the NAS VM with NFS storage for k8s
- Any other Proxmox VMs

Without a NUT client, during a power outage:
- k8s nodes shut down gracefully (NUT clients handle it)
- Dell PVE stays on until UPS battery dies, then hard power-off
- OMV filesystem could corrupt (ext4/btrfs journal may not flush)
- NFS exports become unavailable without clean unmount

### Setup steps

1. **Install NUT client on the Proxmox host** (not inside OMV VM):
   ```bash
   # SSH to Proxmox PVE host (Dell 3090)
   apt update && apt install nut-client
   ```

2. **Configure as NUT client** - edit `/etc/nut/nut.conf`:
   ```
   MODE=netclient
   ```

3. **Configure upsmon** - edit `/etc/nut/upsmon.conf`:
   ```
   # Connect to NUT server on k8s-cp1
   MONITOR cyberpower@10.10.30.11 1 <monitor-user> <monitor-password> secondary

   # Shutdown command - shuts down VMs first, then host
   SHUTDOWNCMD "/usr/sbin/shutdown -h +0"

   # How long on battery before triggering shutdown
   # Should be BEFORE k8s-cp1 (which shuts down on low battery)
   # k8s-cp3=10min, k8s-cp2=20min, so PVE should be ~15min
   HOSTSYNC 15
   ```

4. **NUT credentials** - use the monitor account:
   - Username: `op://Kubernetes/NUT Monitor/username`
   - Password: `op://Kubernetes/NUT Monitor/password`

5. **Configure Proxmox to shut down VMs before host**:
   - Proxmox UI > Datacenter > Options > HA Shutdown Policy
   - Or in `/etc/default/pve-ha-manager`: ensure VMs get shutdown signal before host powers off
   - OMV VM should have `onboot: 1` and `startup: order=1,up=30` in its config

6. **Test** (simulate power failure):
   ```bash
   # On k8s-cp1 (NUT server):
   upsmon -c fsd   # Force Shutdown - DO THIS ONLY WHEN READY
   ```

### Shutdown order (target)

| Order | Device | Timer | Method |
|-------|--------|-------|--------|
| 1 | k8s-cp3 | 10 min on battery | NUT client (upsmon -s) |
| 2 | Dell PVE (OMV VM first, then host) | 15 min on battery | NUT client (upsmon -s) |
| 3 | k8s-cp2 | 20 min on battery | NUT client (upsmon -s) |
| 4 | k8s-cp1 | Low battery (FSD) | NUT server (upsmon -p), sends UPS power-off |
| 5 | Topton (OPNsense) | UPS battery dies | No NUT - last device standing |

### Also consider: Topton N100 (OPNsense)

The Topton runs OPNsense (firewall/router). It has no NUT client either. Options:
- Install NUT client on the OPNsense VM (available as a plugin)
- Or let it die last - the firewall should stay up as long as possible for network
- If you add NUT to OPNsense, set timer to 25min (after k8s-cp2, before k8s-cp1)

### Phase 5.3 Cilium discovery (resolved)

During Phase 5.3, the nut-exporter policy used `toCIDR` for the NUT server IP, which
silently failed because Cilium assigns cluster nodes a `remote-node` identity (not a
CIDR/world identity). Fixed by using `toEntities: [remote-node]` on port 3493. Same
fix applied to kube-vip metrics (port 2112). Both now working.

**Cilium identity cheat sheet:**

| Destination | Use this, not toCIDR |
|-------------|---------------------|
| Other cluster nodes | `toEntities: [remote-node]` |
| Local node | `toEntities: [host]` |
| Pods | `toEndpoints` or `toEntities: [cluster]` |
| External IPs (NAS, LAN) | `toCIDR` (this one is correct) |

---

## Phase 5.6 VAP Deny Mode

**Status:** Deferred - waiting 1 week of clean Warn-mode operation
**Priority:** Medium
**Added:** 2026-03-26 (Phase 5.6)

Phase 5.6.3.6: Switch the ValidatingAdmissionPolicy `image-registry-restriction` from
Warn mode to Deny mode. The VAP was deployed in Warn mode on 2026-03-26. After 1 week
of clean operation (no false positives in `kubectl-homelab get events -A | grep ValidatingAdmissionPolicy`),
switch `validationActions: [Warn]` to `validationActions: [Deny]` in
`manifests/kube-system/image-registry-policy.yaml`.

**Target date:** 2026-04-02

---

## ArgoCD Upgrade to v3.4.0 (K8s 1.35 Official Support)

**Status:** Deferred - waiting for v3.4.0 GA release
**Priority:** Medium
**Added:** 2026-03-27 (Phase 5.7)

ArgoCD v3.3.5 installed on K8s 1.35 cluster. v3.3.x officially tests K8s 1.31-1.34 only.
v3.4.0 adds official K8s 1.35 support (Go client upgrade, argoproj/argo-cd#25767).

v3.4.0 RC timeline: rc1 (2026-03-16), rc2 (2026-03-19), rc3 (2026-03-25).
Historical pattern: ~49 days from rc1 to GA, so estimated GA ~May 4, 2026.

**Check:** `helm-homelab search repo argo/argo-cd --versions | head -5`
**Upgrade:** `helm-homelab upgrade argocd argo/argo-cd --namespace argocd --version <new-chart-version> --values helm/argocd/values.yaml`
Review migration notes at: https://argo-cd.readthedocs.io/en/stable/operator-manual/upgrading/3.3-3.4/

**Target date:** 2026-05-04 (check weekly from 2026-04-14)

---

## Aurora Off-Site Backup (Google Drive)

**Status:** Deferred - waiting for Aurora NFS + rclone setup
**Priority:** Medium
**Added:** 2026-03-19 (Phase 5.4 brainstorming)

### Context

The off-site backup script (`scripts/backup/homelab-backup.sh`) is initially WSL2-only.
Aurora DX (Fedora Atomic Kinoite, 500GB NVMe) can directly NFS-mount the OMV NAS and
would use Google Drive as the cloud target instead of OneDrive.

### What's needed

- Set up NFS access on Aurora (mount `10.10.30.4:/Kubernetes/Backups`)
- Install rclone via `brew install rclone` or distrobox
- Configure rclone Google Drive remote (`rclone config` with OAuth)
- Add `pull` NFS-direct mode to `homelab-backup.sh` (no SSH hop needed)
- Add `rclone sync` step after `encrypt` for Google Drive upload
- Create Aurora-specific `scripts/backup/config` with local paths

### Alternative

Manual: run `pull` + `encrypt` on Aurora, then drag restic repo folder into Google Drive
via Nautilus/GNOME Files. No rclone needed but not automated.

**When:** After Aurora machine is set up with NFS access and a Google Drive plan is decided.

---

## ARR Stack Backup CronJob Rework (Per-PVC Jobs)

**Status:** Resolved - replaced with per-app CronJobs using podAffinity
**Priority:** Closed
**Added:** 2026-04-01 (Phase 5.8 post-migration)
**Resolved:** 2026-04-02 (Phase 5.8 session 3)

### The problem

The ARR stack backup CronJobs (`arr-backup-cp1/cp2/cp3`) group multiple PVCs per node into a single Job. Each Job mounts 3-4 Longhorn RWO PVCs and backs them all up in one run. This assumes the apps stay on specific nodes:

| CronJob | PVCs mounted | Assumed node |
|---------|-------------|-------------|
| arr-backup-cp1 | prowlarr, qbittorrent, radarr, seerr | k8s-cp1 |
| arr-backup-cp2 | sonarr, tdarr, recommendarr | k8s-cp2 |
| arr-backup-cp3 | bazarr, jellyfin | k8s-cp3 |

The CronJobs use `podAffinity` to schedule on the same node as the first app in their list. But RWO PVCs can only attach to one node. If any app in the group reschedules to a different node (e.g., after a pod delete, node drain, or eviction), its PVC follows it - and the backup Job can't mount it anymore because the Job lands on the original node via affinity but the PVC is now on a different node.

This happened during Phase 5.8: deleting crash-looping radarr caused it to reschedule from cp1 to cp2. The cp1 backup Job then hung indefinitely trying to mount radarr's PVC on cp1 while it was attached to cp2.

### Why it causes ArgoCD Degraded

ArgoCD v3 appTree health checks CronJob health by comparing `lastScheduleTime` vs `lastSuccessfulTime`. When the backup Job fails (can't mount PVC), the CronJob's `lastScheduleTime` advances but `lastSuccessfulTime` stays stale. ArgoCD sees this as Degraded.

### Fix: one Job per PVC

Replace the 3 node-grouped CronJobs with individual CronJobs per app:

```
arr-backup-prowlarr   (podAffinity: app=prowlarr,  mounts: prowlarr-config)
arr-backup-sonarr     (podAffinity: app=sonarr,     mounts: sonarr-config)
arr-backup-radarr     (podAffinity: app=radarr,     mounts: radarr-config)
...
```

Each CronJob mounts exactly one PVC and uses podAffinity to co-locate with that specific app. No cross-PVC dependencies. If an app moves nodes, its backup Job follows it automatically.

Trade-off: more CronJob objects (9 instead of 3) and more NFS mounts during the backup window. But each Job is independent and self-healing.

### Resolution

Replaced 3 node-grouped CronJobs (`arr-backup-cp1/cp2/cp3`) with 9 per-app CronJobs in
`manifests/arr-stack/backup/` (one file per app). Each CronJob uses `podAffinity` to co-locate with
its app pod (instead of `nodeSelector`). If an app moves nodes, its backup follows automatically.

**When:** Closed.

---

## Restic k8s-media Repository (Immich Photos)

**Status:** Deferred - no Immich data exists yet
**Priority:** Low
**Added:** 2026-03-19 (Phase 5.4 brainstorming)

### Context

Phase 5.4 originally planned two restic repos: `k8s-configs` (backup data) and `k8s-media`
(Immich photos). Since Immich is not deployed and `/Kubernetes/Immich/` is empty (8KB),
the media repo is deferred.

### What's needed when Immich is deployed

- Create second restic repo with separate password (add to 1Password + Vault)
- Different retention: `--keep-last 3` + tagged on-demand snapshots
- Separate prune schedule (300GB+ repo prune is slow, shouldn't block config backups)
- Add `media` subcommand to `homelab-backup.sh`

**When:** After Immich is deployed and has data worth backing up.
