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

**When:** Closed. If alert fires again, consider Alloy drop rules to reduce log volume.

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
