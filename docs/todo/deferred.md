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

## Phase 5.9 Vault Snapshot Cutover Cleanup

**Status:** Deferred - earliest 2026-04-21 (~6 days of CronWorkflow runs)
**Priority:** Low
**Added:** 2026-04-14, updated 2026-04-15 with real post-cutover state

### Context

Phase 5.9 migrated the daily Vault Raft snapshot from a CronJob in `vault` ns
to a CronWorkflow in `argo-workflows` ns (v0.39.0). During cutover, the legacy
NFS PV + PVC were intentionally kept alongside the new argo-workflows PV/PVC so
both could write to the same NAS directory without a gap.

**State after v0.39.0 ship (2026-04-15):**
- Legacy `vault-snapshot` CronJob + ServiceAccount — ❌ **removed** (pruned by
  ArgoCD from commit `b1342f9`)
- Legacy `vault-snapshots-nfs` PV + `vault-snapshots` PVC (vault ns) — ✅ **still
  present** (pending this cleanup)
- New `vault-snapshots-argo-nfs` PV + `vault-snapshots` PVC (argo-workflows ns)
  — ✅ **sole active write path**
- Legacy `vault-snapshot` Vault K8s auth role — ✅ **still present** (pending
  this cleanup)
- New `vault-snapshot-argo` Vault K8s auth role — ✅ **sole active role**,
  bound to `argo-workflows:vault-snapshot-workflow`

Two cleanup items remain. Both are safe once the CronWorkflow has run cleanly
for 5-7 days.

### Readiness check before running

The CronWorkflow's `ttlStrategy.secondsAfterSuccess: 86400` deletes the
Workflow object after 24h — so `kubectl get workflows` will only show the
last 0-1 run, NOT the last week. Use these three checks instead:

```bash
# 1. NAS snapshot files — ground truth, files persist for 3 days per the
#    CronWorkflow's `find -mtime +3 -delete` prune step. Expect 3-4 files
#    (today + last 3 nights) all ~80K and owned by uid 65534.
ssh wawashi@10.10.30.11 \
  'sudo mkdir -p /tmp/nfs && \
   sudo mount -t nfs4 10.10.30.4:/Kubernetes /tmp/nfs && \
   ls -lh /tmp/nfs/Backups/vault/ && \
   sudo umount /tmp/nfs'
# Pass criteria: at least 3 vault-YYYYMMDD.snap files, newest ≤26h old.

# 2. VaultSnapshotStale alert should NOT have fired since the cutover.
kubectl-admin exec -n argocd statefulset/argocd-application-controller \
  -- sh -c 'curl -s http://prometheus-kube-prometheus-prometheus.monitoring.svc:9090/api/v1/query?query=ALERTS%7Balertname%3D%22VaultSnapshotStale%22%7D' \
  | jq '.data.result'
# Pass criteria: [] (empty — alert not firing).
# Or check Alertmanager UI: https://alertmanager.k8s.rommelporras.com

# 3. Latest CronWorkflow run succeeded (if the object is still alive; see TTL note).
kubectl-homelab get workflows -n argo-workflows --sort-by=.metadata.creationTimestamp 2>/dev/null | tail -3
# Pass criteria: if any row exists, STATUS=Succeeded. If zero rows, that's
# normal (TTL expired) — fall back to checks 1 + 2.
```

### 5.9.3.10 — Remove legacy NFS PV/PVC in the vault namespace

**Pre-flight safety checks (run BEFORE editing):**

```bash
# A. New argo-workflows PV is bound and healthy (active sink):
kubectl-homelab get pv vault-snapshots-argo-nfs -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,CLAIM:.spec.claimRef.name --no-headers
# Expect: STATUS=Bound, CLAIM=vault-snapshots

# B. Legacy PV/PVC are still Bound (not orphaned, so their deletion is predictable):
kubectl-homelab get pv vault-snapshots-nfs -o jsonpath='{.status.phase}{"\n"}'
kubectl-homelab get pvc vault-snapshots -n vault -o jsonpath='{.status.phase}{"\n"}'
# Expect both: Bound

# C. No other manifest references the legacy names (catch any new consumer
# that appeared after cutover):
grep -rn 'vault-snapshots-nfs\|vault-snapshots[^-a]' manifests/ helm/ scripts/ 2>/dev/null | grep -v 'vault-snapshots-argo-nfs'
# Expect: only hits in manifests/vault/snapshot-cronjob.yaml itself.
```

If any check fails, stop and investigate.

**Remove the file entirely (not just its contents):**

```bash
git rm manifests/vault/snapshot-cronjob.yaml
# /audit-security then /commit - bundle this with 5.9.3.11's seed-script
# entry if you haven't already updated it.
git push origin main
```

ArgoCD picks up the deletion and prunes the PV + PVC. The NAS directory is
unaffected — reclaim policy is `Retain` and only the Kubernetes objects go
away. The argo-workflows PV continues mounting the same NAS path.

**Post-deletion verify:**

```bash
kubectl-homelab get pv vault-snapshots-nfs 2>&1
# Expect: NotFound
kubectl-homelab get pvc -n vault
# Expect: empty
kubectl-homelab get cronworkflow vault-snapshot -n argo-workflows
# Expect: still Active with next scheduled run. Wait for the next 02:00
# Manila run to succeed (or trigger a manual `kubectl create` from the
# template) before marking this complete.
```

### 5.9.3.11 — Delete the legacy Vault Kubernetes auth role

**Pre-flight safety checks:**

```bash
# A. Legacy role is bound ONLY to the already-deleted vault-snapshot SA:
vault read auth/kubernetes/role/vault-snapshot
# Expect: bound_service_account_names=[vault-snapshot],
#         bound_service_account_namespaces=[vault]
# If more SAs are bound, investigate before deleting.

# B. The legacy SA is gone (already pruned by 5.9.3.9):
kubectl-admin get sa vault-snapshot -n vault 2>&1
# Expect: Error from server (NotFound)

# C. The new role is alive and bound to the active SA:
vault read auth/kubernetes/role/vault-snapshot-argo
# Expect: bound_service_account_names=[vault-snapshot-workflow],
#         bound_service_account_namespaces=[argo-workflows]
```

**Delete:**

```bash
vault delete auth/kubernetes/role/vault-snapshot
# Confirm:
vault list auth/kubernetes/role | grep -E '^vault-snapshot'
# Expect: only `vault-snapshot-argo` listed.
```

**Post-deletion verify the next scheduled run still works:**

Wait until the next 02:00 Manila run. Either open Argo Workflows UI and watch
it go green, or check NAS the next morning (`vault-YYYYMMDD.snap` for today's
date exists, size ~80K, uid 65534). If it fails, the argo-workflows
`vault-snapshot-workflow` SA can't auth to Vault — check the CronWorkflow
run's snapshot-step logs and confirm the `vault-snapshot-argo` Vault role
is still intact (binding or policy didn't drift).

### When

**Earliest: 2026-04-21** (first scheduled CronWorkflow run was 2026-04-15
02:00 Manila; 6 days gives a full weekday cycle without a weekend break
from the schedule).

Do both 5.9.3.10 and 5.9.3.11 in the same session — they're independent but
the work is small enough that splitting adds overhead. After 5.9.3.11
succeeds, close out this entry by moving it to a "Resolved" subsection
(like the "ARR Stack Backup CronJob Rework" entry above).

---

## k8s-cp3 NVMe Reseat

**Status:** Deferred - schedule during next planned maintenance window
**Priority:** Low (currently correctable AER only; cluster is healthy)
**Added:** 2026-04-14 (Phase 5.9.7 storage observability)

### Context

k8s-cp3's NVMe (SKHynix HFS512GDE9X081N) threw **4 PCIe correctable bus
errors** over an 8-day window ending 2026-04-11 (Apr 6, 9, 10, 11). Kernel AER
reports `severity=Correctable, type=Physical Layer, (Receiver ID)` — the PCIe
layer retried successfully, no data loss. SMART is clean:
`media_errors=0`, `critical_warning=0`, `available_spare=100%`,
`percentage_used=0%`.

Correctable events signal intermittent link instability (loose seating,
oxidation on M.2 contacts, thermal warping, dust). Reseat is the first-line
remediation before considering drive or mainboard replacement.

The 2026-04-14 karakeep outage was triggered by a Longhorn AutoSalvage of a
replica on cp3. Direct causation between the PCIe AER pattern and the replica
stall is unconfirmed (no AER events on 2026-04-14 itself), but cp3 is the
only node with a recurring AER pattern, so reseat is the low-risk next step.

**Live monitoring is now in place** (Phase 5.9.7): `NodePCIeBusError` and
`LonghornVolumeAutoSalvaged` alerts fire automatically. Before scheduling the
reseat, check Grafana / Alertmanager for any new occurrences since 2026-04-11
to confirm the pattern is ongoing (if errors have stopped entirely, reseat
becomes lower priority).

### What "reseat" means

Physically remove the M.2 NVMe module from its slot and reinsert it.
On the Lenovo M80q tiny form factor: unscrew the retaining screw at the tip
of the M.2 slot, the board pops up at ~30°, pull it straight out of the slot
connector, inspect the gold-finger contacts for visible oxidation/dust, clean
with >90% isopropyl alcohol on a lint-free cloth if needed (allow to dry
fully), push back in at ~30°, press flat, rescrew.

### Procedure

Full procedure is in [`docs/runbooks/longhorn-hardware.md`](../runbooks/longhorn-hardware.md)
under "Reseating an NVMe". Summary:

1. **Pre-flight:** Longhorn default is `numberOfReplicas: 2` on this cluster.
   For each volume that has a replica on cp3, confirm at least one healthy
   replica exists on a DIFFERENT node (cp1 or cp2) so data stays accessible
   during the reseat. Take a Longhorn snapshot of any critical volume whose
   only other replica is on a node with known issues. Check via:
   ```
   kubectl-admin get volumes.longhorn.io -n longhorn-system -o json \
     | jq -r '.items[] | select(.status.robustness != "healthy") | .metadata.name'
   ```
   Must return empty before proceeding.
2. `kubectl-admin cordon k8s-cp3 && kubectl-admin drain k8s-cp3 --ignore-daemonsets --delete-emptydir-data --force`
3. `ssh wawashi@k8s-cp3 "sudo shutdown -h now"`
4. Physical work: bottom cover (single captive screw), M.2 retaining screw,
   pull NVMe at 30°, inspect gold-finger contacts, clean with >90% IPA if
   visibly dirty (fully dry before reinsertion), reinsert at 30°, press
   flat, rescrew.
5. Power on, wait 5-7 min for M80q BIOS POST (per MEMORY.md — 300s timeout
   is too short, 600s is right).
6. `kubectl-admin uncordon k8s-cp3`
7. Watch Longhorn replica rebuilds complete (`kubectl-homelab get
   replicas.longhorn.io -n longhorn-system --field-selector
   spec.nodeID=k8s-cp3 -w`). All should reach `status.currentState=running`.
8. Confirm AER counters reset:
   `ssh wawashi@k8s-cp3 "sudo cat /sys/bus/pci/devices/0000:01:00.0/aer_dev_correctable"`
   → 0 (counters reset on reboot even without reseating; the reseat's
   benefit shows up in the 7-day follow-up window).
9. Monitor for 7 days via Alertmanager / Grafana. If any
   `NodePCIeBusError` alert fires for cp3 during that window, reseat did
   not resolve the issue — escalate to drive or mainboard replacement
   per the runbook's "When to Replace vs Reseat" table.

### Signals that should bump priority

- Any `NodePCIeBusError` alert with `severity=Non-Fatal` or `severity=Fatal`
  → reseat immediately, plan drive replacement
- `smartctl_device_media_errors > 0` or `smartctl_device_critical_warning > 0`
  → skip reseat, replace drive
- Another Longhorn `AutoSalvaged` event on a cp3 replica within 7 days
  → reseat during next available window

**When:** Next planned node reboot (kernel upgrade, Ubuntu patch, etc.), or
immediately on any non-correctable AER event.

---

## Revert Longhorn over-provisioning 150% → 100%

**Status:** Deferred - waiting for cp3 NVMe reseat (or replacement with larger drive)
**Priority:** Low (only affects scheduling math; safety still enforced by per-volume alerts)
**Added:** 2026-04-28 (post Phase 5.9.1 PVC resize batch)

### Why we bumped to 150% in the first place

Pre-ship audit (2026-04-28) found cp3's Longhorn disk at the schedulable cap:
311 GiB scheduled out of 325.7 GiB ProvisionedLimit (= (465 GiB max − 140 GiB
reserved) × 100% over-provisioning). The prometheus-db resize 60→80Gi needed
20 GiB additional schedule space and was rejected by the validator. Bumping
the global setting `storage-over-provisioning-percentage` from 100 → 150
pushed cp3's cap to 488 GiB, freeing ~177 GiB of scheduling headroom and
unblocking the resize.

### Why this is safe (in the meantime)

Over-provisioning is a *nominal* limit, not a physical one. cp3's actual disk
fill is ~63% (~290 GiB used of 465 GiB). If real usage approaches the
physical cap, per-PVC `KubePersistentVolumeFillingUp` alerts (kube-state-metrics
default, fires at 85-90% used) catch it well before disk-full. The 150% bump
relies on those alerts as the real safety net.

### Why we want to revert

100% means Longhorn refuses to allocate more nominal volume space than the
disk has free, which is a stronger guarantee than per-PVC alerts. It's the
"one system says no" form of safety. We want that back as soon as the
physical capacity supports it.

### Gating constraint

Revert is only safe when *every* disk's `StorageScheduled` already fits within
`(StorageMax − Reserved) × 100%`. Today that means cp3 needs to drop from
~331 GiB scheduled (post-resize batch) to <325 GiB. Longhorn won't unwind
existing replicas when the setting is changed — the constraint applies to
*future* scheduling, so reverting now would lock cp3 against any further
volume creation/expansion.

### Path to revert

Pick whichever ships first:

1. **Reseat or upgrade cp3 NVMe** *(recommended, see "k8s-cp3 NVMe Reseat"
   entry above)*. If reseat fixes the AER pattern in place: physical capacity
   stays at 465 GiB, no scheduling change. If you replace with a larger drive
   (1 TB or 2 TB), cap rises to 750-1500 GiB at 100% OP — comfortably above
   current scheduled.
2. **Rebalance replicas** off cp3 onto cp1/cp2. Longhorn UI → Node `k8s-cp3`
   → Disk → Disable Scheduling → Replica Eviction. Replicas rebuild on the
   other two nodes. Once cp3 scheduled drops below 325 GiB, revert is safe.
   Risk: cp1/cp2 may not have headroom to absorb the migration; verify
   first via `kubectl-admin get nodes.longhorn.io -n longhorn-system -o json
   | jq '.items[].status.diskStatus'`.
3. **Combination** of Fix 1 + opportunistic cleanup of any orphan/oversized
   replicas on cp3.

### Revert command (when ready)

```bash
# Verify all 3 nodes' scheduled space is below their 100% cap
kubectl-admin get nodes.longhorn.io -n longhorn-system -o json | \
  jq -r '.items[] | .metadata.name as $n | (.status.diskStatus // {}) | to_entries[] |
    "\($n)/\(.key)  scheduled=\(((.value.storageScheduled // 0)/1073741824)|floor)Gi  cap_at_100%=\((((.value.storageMaximum // 0) - (.value.storageReserved // 0))/1073741824)|floor)Gi"'

# If every disk's scheduled <= cap_at_100%, revert:
kubectl-admin patch setting.longhorn.io/storage-over-provisioning-percentage \
  -n longhorn-system --type=merge -p '{"value":"100"}'

# Verify
kubectl-admin get setting.longhorn.io/storage-over-provisioning-percentage \
  -n longhorn-system -o jsonpath='{.value}{"\n"}'
```

### Acceptance criteria

- All 3 Longhorn disks: `StorageScheduled ≤ (StorageMax − StorageReserved) × 100%`
- `setting.longhorn.io/storage-over-provisioning-percentage = 100`
- No `LonghornDiskCapacityCritical`-style alerts firing
- A new test PVC at the boundary size still schedules without rejection

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

## Portfolio Pipeline E2E Step (Phase 5.9.1 Stage 2 Follow-up)

**Status:** Deferred - portfolio-pipeline ships with lint/type-check/test-unit only
**Priority:** Medium (regression surface without E2E in the pipeline)
**Added:** 2026-04-19 (Phase 5.9.1 Stage 2 smoke-testing)

### Context

The original Phase 5.9.1 Stage 2 plan included a `test-e2e` step in the
portfolio-pipeline DAG using Playwright. Three issues surfaced during
smoke testing that made shipping E2E in v0.39.2 impractical without
further iteration:

1. `manifests/argo-workflows/templates/test-e2e-template.yaml` specifies
   `mcr.microsoft.com/playwright:v1.58.2-noble` as the container image
   but the parameterized `command` runs `bun install`. The Playwright
   image does not ship bun - the step errors with `bun: command not found`.
   Fix requires either installing bun inside the Playwright image at
   runtime (slow, fragile) or switching to `oven/bun:*` + `bunx
   playwright install chromium --with-deps` (simpler but needs CNP
   + image size verification).

2. `~/personal/portfolio/playwright.config.ts` `webServer` section runs
   `npx serve out -l 3000` when `process.env.CI` is set, which assumes
   `out/` exists in the workspace. The current DAG structure has
   test-e2e depend only on `clone`, not on `build`, so `out/` is never
   produced. Fix requires either running `bun run build` inline in the
   test-e2e step (couples test to build ordering) or restructuring the
   DAG so test-e2e depends on build (defeats parallelism).

3. Playwright chromium binary download (`playwright.download.prss.microsoft.com`
   or similar Microsoft CDN) needs CNP egress coverage. The broad
   HTTPS-to-world egress added in v0.39.2 covers this, so the CNP
   side is ready.

### What's needed

- Pick the Playwright-in-CI strategy: bun-based image + `bunx playwright
  install`, or pre-built Playwright + bun side-install
- Restructure portfolio-pipeline DAG so `test-e2e` has access to `out/`
  (either via `bun run build` inline or via an artifact dependency on
  the build step)
- Update `test-e2e-template.yaml` to match the chosen strategy
- Re-wire `test-e2e` into `portfolio-pipeline.yaml` DAG
- Validate end-to-end with a Workflow submission before ship

### When to revisit

After v0.39.2 is stable and GitLab-CI deploys have been retired. The
test-e2e template file stays in-tree but unwired, so the work is
additive when it happens.

## Argo Workflows Restricted PSS Hardening (Phase 5.9.1 Stage 2 Follow-up)

**Status:** Deferred - acceptable under baseline PSS; warn-only for restricted
**Priority:** Low
**Added:** 2026-04-18 (Phase 5.9.1 Stage 2 security audit)

### Context

Three CI pipeline WorkflowTemplates in `manifests/argo-workflows/templates/` trip
`warn: restricted` on the argo-workflows namespace (enforcement is `baseline`, so
pods still start — they just emit a PSS warning). The gaps below were flagged in the
`/audit-security` pass before shipping v0.39.2 and deferred because tightening them
requires more than a 2-line diff.

### What's left

**`clone-template.yaml`** — alpine/git:2.52.0 runs as root by default; git clone
itself doesn't need root, but the shared `/workspace` emptyDir is created as
`root:root 0755` so a non-root container can't write to it. Fix requires coordinating
a pod-level `fsGroup: 1000` setting across `portfolio-pipeline.yaml` and
`invoicetron-pipeline.yaml` (fsGroup is pod-scoped, not container-scoped).

**`invoicetron-pipeline.yaml` migrate step** — uses the app's own image; needs
verification that the Invoicetron Dockerfile sets `USER 1000` (or `USER node`)
before adding `runAsNonRoot: true`. If the app image runs as root, this step
would fail to start with `container has runAsNonRoot and image will run as root`.

**`deploy-image-template.yaml`** — intentionally runs as root today (writes
`/root/.ssh/id_ed25519`, runs `apk add --no-cache curl tar gzip`). Going non-root
requires either:
  - Pre-built image with kustomize + git + ssh + curl baked in (no `apk add` step)
  - Mount the SSH key at `/home/git/.ssh` and adjust `GIT_SSH_COMMAND` path
  - Run the chmod + ssh config as an initContainer under root, then drop to
    non-root for the actual git push
`seccompProfile: RuntimeDefault` is already applied (seccomp filtering is
independent of uid=0), so syscall-restriction is in place even while uid=0.

### When to revisit

Bundle with the next Argo Workflows chart bump or if the namespace PSS is
upgraded from `enforce: baseline` to `enforce: restricted` (that change is
not currently scheduled).

### Acceptance criteria

- Restricted PSS warnings on argo-workflows namespace go to zero
- All CI pipelines still succeed end-to-end (clone / build / deploy / verify)
- No regression on deploy-image step's ability to commit + push via SSH

---

## Phase 5.9.1 credential rotations (internal-only exposures)

**Status:** Rotations complete 2026-04-24 (during soak) - only overlap-token cleanup pending
**Priority:** Low (all reachable only from cluster LAN or host with WSL jsonl)
**Added:** 2026-04-24

Forensic grep of `/home/wsl/.claude/projects/-home-wsl-personal-homelab/80c9dd38-43a4-42fc-aa62-4db2ef848b04.jsonl` (pre-compact Claude Code transcript) turned up six credentials whose values or immediate hashes passed through tool output during earlier Phase 5.9.1 debugging. One (`staging-promote-token`) was rotated pre-ship because the leak was still active in this session. The rest were initially deferred as post-ship cleanup because their attack surface is internal-only, but all were rotated during the 2026-04-24 → 2026-04-27 soak window instead of waiting. What's left is only the cleanup of the **old** overlapping credentials (user-run from any host with `gh` + `glab` logged in — see `scripts/phase-5.9.1-credential-cleanup.sh`).

**Credentials to rotate:**

| Credential | Vault path | 1P reference | Exposure evidence | Scope |
|---|---|---|---|---|
| ~~`argo-workflows/gitlab-registry` password~~ | `secret/argo-workflows/gitlab-registry` | `op://Kubernetes/Argo Workflows/registry-password` | `glpat-sJlBSQ_…` appears in transcript (line ~555) | ✅ **Fully rotated 2026-04-24** — Vault v5; new group deploy token `argo-workflows-buildkit-2026-04-24` created. Pull auth probed green via skopeo. Write-path verified 2026-04-24T10:46 via `portfolio-dev-rsgw5` build (46s) + push (18s) stages Succeeded — skopeo pushed image `:881f2309` to `registry.k8s.rommelporras.com/0xwsh/portfolio` using the new token. Pending cleanup: delete old `argo-workflows-buildkit` deploy token in GitLab group settings UI. |
| ~~`argo-workflows/github-deploy-key`~~ | `secret/argo-workflows/github-deploy-key` | `op://Kubernetes/Argo Workflows/github-deploy-key` | OpenSSH private key body leaked at transcript lines 3375, 3468 | ✅ **Fully rotated 2026-04-24** — Vault v5; new deploy-key id `149522582` added; ExternalSecret synced. SSH + read probed green from in-cluster pod. Write-path verified 2026-04-24T10:46 via `portfolio-dev-rsgw5` deploy step successfully pushing CI-bot commit `0a26999 chore(ci): update portfolio/dev image to 881f2309 [skip ci]` to origin/main. Pending cleanup: `gh api -X DELETE repos/rommelporras/homelab/keys/149092650`, then `shred -u ~/tmp/ae-rotate/argo-events-deploy-key*`. |
| ~~`argo-workflows/gitlab-clone-token` + `invoicetron/deploy-token`~~ | `secret/argo-workflows/gitlab-clone-token` + `secret/invoicetron/deploy-token` | `op://Kubernetes/Invoicetron Deploy Token` (one 1P item feeds both Vault paths) | `vault kv get` x2 in transcript | ✅ **Rotated 2026-04-24** — new project-level deploy token `k8s-ci-2026-04-24` on `0xwsh/invoicetron` (scopes: `read_repository` + `read_registry`) replaces two old tokens (`k8s-image-pull` id 2, `argo-workflows-clone` id 3). 1P v7, Vault paths bumped to v3 / v13, three ExternalSecrets force-synced (`gitlab-clone-token` in argo-workflows, `gitlab-registry` in invoicetron-dev and invoicetron-prod). Clone probe returned HEAD `194ee4c`; skopeo pull probe returned dev image manifest. No write scope → no soak-verification pending. Action: delete both old project-level tokens (id 2 + id 3) in GitLab UI at https://gitlab.k8s.rommelporras.com/0xwsh/invoicetron/-/settings/repository#js-deploy-tokens |
| ~~`argo-events/invoicetron-webhook-secret`~~ | `secret/argo-events/invoicetron-webhook-secret` | `op://Kubernetes/Argo Workflows/invoicetron-webhook-secret` | JSON-dump fetch x3 in transcript | ✅ **Rotated 2026-04-24** (Vault v6; EventSource redeployed, old webhook 9 deleted, new webhook 11 auto-registered; GitLab push-event test accepted, eventID `d6799b98…`) |
| ~~`invoicetron-dev/app` `database-url` + `invoicetron-dev/db` `postgres-password`~~ | `secret/invoicetron-dev/app` + `secret/invoicetron-dev/db` | `op://Kubernetes/Invoicetron Dev/database-url` + `postgres-password` | JSON-dump fetch + `vault kv get invoicetron-prod/app` | ✅ **Rotated 2026-04-24** — DEV only. New 24-byte hex password applied via `ALTER USER invoicetron WITH PASSWORD` on invoicetron-db-0; 1P v6 (both fields); Vault `/db` v8 and `/app` v9; three ExternalSecrets force-synced (`invoicetron-db` + `invoicetron-app` in ns, `invoicetron-migrate-db-urls` in argo-workflows); app deployment restarted, new pod Ready in 12s. Verified via `pg_stat_activity` showing 2 active sessions on `invoicetron` DB with new password. |
| ~~`invoicetron-prod/app` `database-url` + `invoicetron-prod/db` `postgres-password`~~ | `secret/invoicetron-prod/*` | `op://Kubernetes/Invoicetron Prod/*` | same pattern as dev (JSON-dump / vault kv get) | ✅ **Rotated 2026-04-24** — PROD. New 24-byte hex password via `ALTER USER invoicetron WITH PASSWORD` on `invoicetron-prod/invoicetron-db-0`; 1P v4 (both fields); Vault `/db` v8 and `/app` v9; three ExternalSecrets force-synced. Prod app pod Ready in 18s post-restart. Verified: HTTP 307 on prod URL, `pg_stat_activity` reports 2 active sessions, zero auth-failure logs on Postgres. URL scheme `postgresql://` preserved (not `postgres://`). |
| ~~`ghost-dev/mysql` (both `root-password` + `user-password`)~~ | `secret/ghost-dev/mysql` | `op://Kubernetes/Ghost Dev MySQL` | `vault kv get` x5 | ✅ **Rotated 2026-04-24** — MySQL root + ghost user both rotated via `ALTER USER` on ghost-mysql-0; 1P Ghost Dev MySQL v3 (both fields); Vault v9 (both fields, single path). Ghost app deployment restarted, Ready in 39s. Verified via HTTP 200 on `https://blog.dev.k8s.rommelporras.com/` (proves `ghost` user authenticated with new password). No prod Ghost instance to rotate. |

**Why originally deferred (historical):** every consumer of these secrets lives inside the cluster and the credentials are only usable from cluster-adjacent networks (the home LAN, or a host with the WSL jsonl file). There is no internet-reachable attack surface. Deferral was chosen to avoid ship-window CI/DB downtime. In practice all 7 rotations were picked up during soak on 2026-04-24 with no incident, and the write-path for the two high-value rotations (github-deploy-key + gitlab-registry) was naturally exercised by `portfolio-dev-rsgw5` the same day.

**Pending cleanup (user-run from WSL2 dev host):**
1. `gh api -X DELETE repos/rommelporras/homelab/keys/149092650` — delete old GitHub deploy key
2. Revoke old GitLab group deploy token `argo-workflows-buildkit` at https://gitlab.k8s.rommelporras.com/groups/0xwsh/-/settings/repository#js-deploy-tokens
3. Revoke old GitLab project deploy tokens `k8s-image-pull` (id 2) and `argo-workflows-clone` (id 3) at https://gitlab.k8s.rommelporras.com/0xwsh/invoicetron/-/settings/repository#js-deploy-tokens
4. ~~`shred -u ~/tmp/ae-rotate/argo-events-deploy-key*` then `rmdir ~/tmp/ae-rotate`~~ — done 2026-04-28 (the keypair was generated on WSL2, not Aurora DX, so the cleanup ran here)

Items 1-3 staged as `scripts/phase-5.9.1-credential-cleanup.sh` (run from WSL2 after `/ship v0.39.2`).

**Rotation pattern (reusable):**
1. Generate/create the new value (openssl for tokens, `glab api` for GitLab deploy tokens, `ssh-keygen` for deploy keys, `ALTER USER ... WITH PASSWORD` for DB)
2. Update 1Password field (source of truth per CLAUDE.md)
3. `vault kv patch <path> <field>="<value>"` (run from a terminal with op + vault CLIs; never via Claude Code because `op` isn't reachable from WSL)
4. `kubectl-admin annotate externalsecret <name> -n <ns> force-sync="$(date +%s)" --overwrite` to trigger immediate ES reconcile
5. Restart the consuming pod(s) if the secret is consumed via `env.secretKeyRef` (Deployments mounting as volume re-read on next pod creation, no restart needed)
6. Run a smoke to prove the new value flows through

**Exact commands and verification steps for each credential:** see `docs/todo/phase-5.9.1-cicd-pipeline-migration.md` "Credential rotation playbook" section (the body of the playbook was left in the phase doc for Steps 2-6; only the progress summary points here).

**When to do it:** next calm weekend after v0.39.2 ships, ideally bundled as a single rotation session in Aurora DX. Note that rotating the Postgres-backed DATABASE_URLs and `ghost-dev/mysql` means coordinating the DB-level password change with the `vault kv patch` and pod restart - more involved than the token rotations.

---

## Cilium L2 Announcement Lease Auto-Rebalance

**Status:** Deferred - immediate fix applied, long-term fix pending
**Priority:** Medium (silent breakage on pod migration; not data-affecting)
**Added:** 2026-04-28

### What happened

K8s AdGuard (`10.10.30.53`) silently received zero LAN client traffic for ~6 weeks despite the
pod being healthy and resolving DNS. Root cause: the Cilium L2 announcement lease for the
service was held by `k8s-cp3` for 89 days, but the AdGuard pod had migrated to `k8s-cp2` on
2026-04-24 (pod recreation after the OOM memory bump in `15b24a3`). With
`externalTrafficPolicy: Local`, external traffic ARP-resolved `.53` to cp3's MAC, landed on
cp3, and got dropped because cp3 had no local backend pod.

The misalignment was hidden because cluster-internal `dig @10.10.30.53` from any node still
worked (Cilium's overlay forwards in-cluster traffic across nodes regardless of Local policy),
so health probes and basic smoke tests all passed.

### Scope at incident time

All four LoadBalancer-announced VIPs were stuck on cp3, but only AdGuard was symptom-visible:

| Service | LB IP | Pod node | Lease holder | Externally-broken |
|---------|-------|----------|--------------|-------------------|
| Gateway (Envoy) | `10.10.30.20` | every node (DaemonSet) | cp3 | No - Envoy on all nodes |
| GitLab SSH | `10.10.30.21` | cp1 | cp3 | Yes (likely) - undetected |
| AdGuard DNS | `10.10.30.53` | cp2 | cp3 | Yes - this incident |
| OTel Collector | `10.10.30.22` | cp1 | cp3 | Cluster policy, not exposed externally |

### Immediate fix (2026-04-28)

Deleted cilium-agent pod on cp3 (`kubectl-admin delete pod cilium-bfs46 -n kube-system`),
forcing all four leases to expire and re-elect. Cilium 1.19.2 has local-backend preference
for `externalTrafficPolicy: Local` services, so re-election landed the leases on the correct
nodes deterministically (AdGuard -> cp2, GitLab SSH -> cp1, etc.). Verified via fresh ARP
probe + PowerShell `Resolve-DnsName -Server 10.10.30.53` from a non-cluster client.

No git changes; no manifest edits. Pure runtime fix.

### Why this will recur

Cilium's L2 announcement leader election only re-runs when the lease expires (cilium-agent
restart, network partition). It does NOT re-run when service endpoints change (e.g. pod
migrates to a different node). So any of these triggers will silently re-break a service:

- Pod evicted by node pressure / drain / cordon
- Resource limit bump (manifests/.../deployment.yaml change) -> pod recreation
- Helm upgrade of a chart that recreates pods
- Longhorn volume failover migrating a stateful pod

### Long-term fix options (pick one)

**Option A: per-service `CiliumL2AnnouncementPolicy` with `serviceSelector`** *(recommended,
easiest to manage)*

Replace the single catch-all policy in `manifests/cilium/l2-announcement.yaml` with one
policy per LoadBalancer service. Each policy would scope `serviceSelector.matchLabels` to a
single service. This narrows leader election to the service's own endpoints (Cilium re-evaluates
node eligibility against backends per-policy), which makes the local-backend preference more
reliable and makes the system's behavior easier to reason about.

Pros:
- Fully declarative - lives in git, no runtime watchdogs
- Failure mode is per-service, not cluster-wide
- Easy to debug (`kubectl get ciliuml2announcementpolicy -A` shows scope at a glance)
- One YAML file change; trivial to revert

Cons:
- Adds ~4 small policy resources where there is currently 1
- Need to verify per-service `serviceSelector` actually triggers re-election on endpoint change (test by deleting the AdGuard pod and watching the lease)

**Option B: cluster-janitor task that detects and re-elects mismatches**

Extend `cluster-janitor` (the existing CronJob that already cleans Failed pods + stopped
Longhorn replicas) with a fourth task: for each `cilium-l2announce-*` lease, compare
`spec.holderIdentity` to the node hosting any ready endpoint of the corresponding service.
If mismatch, delete the cilium-agent pod on the lease holder.

Pros:
- Fits the existing janitor pattern; no new infrastructure
- Catches the issue automatically without human intervention
- Discord notification surfaces it in `#janitor` so it doesn't silently auto-fix without anyone knowing

Cons:
- Reactive, not preventive (10-minute detection window)
- Adds a moving part that itself can break
- Brief disruption every time a pod migrates and the janitor reacts

**Option C: upstream Cilium fix**

File an issue/PR upstream: leader election should re-evaluate on endpoint change for
`externalTrafficPolicy: Local` services, not just on lease expiry. Arguably the correct
behavior given the documented local-backend preference.

Pros: fixes the root cause for everyone.
Cons: out of our hands; long lead time; we still need a workaround in the meantime.

### Recommendation

**Option A.** It is purely declarative, lives in git, the failure mode is per-service, and
once tested it self-manages without ongoing operator attention. Pair with Option C (file
the upstream issue) as a longer-term cleanup so that the per-service policies eventually
become unnecessary.

### When to revisit

After v0.39.2 stabilizes. Plausible bundle: a small phase covering (1) split policies,
(2) test with a deliberate pod move, (3) add a Prometheus alert that fires when any
`cilium-l2announce-*` lease holder differs from the pod node for a Local-policy service.

### Acceptance criteria

- One `CiliumL2AnnouncementPolicy` per LoadBalancer service, each with explicit `serviceSelector`
- Verified that deleting the AdGuard pod (or any other Local-policy service's pod) results in
  the lease re-electing to the new pod's node within 60s
- Alert fires in Prometheus when lease/pod-node mismatch persists >5 min
- `docs/context/Networking.md` updated to describe the new pattern

---

## Phase 5.9.1 v0.39.2 post-ship verification

**Status:** Pending - check ~2 weeks after ship
**Priority:** Low
**Added:** 2026-04-28
**Earliest revisit:** 2026-05-12

The 4-day soak (2026-04-24 -> 2026-04-28) had only **one** real CI workflow run
(`portfolio-dev-rsgw5` on 2026-04-24, exercising the rotated github-deploy-key +
gitlab-registry credentials). No further pushes to `develop` or `main` on either
project occurred in the rest of the window. That one run is sufficient ship
evidence, but write-path proof from the **other** project (invoicetron) and from
`main`-branch flows on both projects has not been re-exercised since the rotation.

### What to check

1. `git log --author='ci-bot@k8s.rommelporras.com' --since='2026-04-28'` shows
   ≥1 commit per project (portfolio + invoicetron) and at least one to a `main`
   overlay (i.e. `manifests/<project>/overlays/{prod,staging}/kustomization.yaml`).
2. `kubectl-admin get workflows -n argo-workflows --sort-by=.metadata.creationTimestamp`
   shows post-ship runs in `Succeeded` for both `portfolio-{dev,staging,prod}` and
   `invoicetron-{dev,prod}` templates (TTL is 1d on success / 7d on failure, so
   only recent ones will be visible - check ArgoCD app sync history or the
   per-project deployment image tag for indirect evidence of older runs).
3. Per-project `argo_workflows_count{phase="Succeeded"}` rate over 2w in
   Prometheus - flatline = no real CI activity.

### What to do if no real runs occurred

- Push an empty commit to each project's `develop` and `main` to force CI:
  `git commit --allow-empty -m "chore(ci): post-ship soak verification"` then push.
- For portfolio `main` specifically, recall that direct push is blocked
  (`push_access_levels: "No one"`) - use the MR flow per phase doc Notes #55.
- Watch the workflows finish, confirm CI-bot commits land on homelab `main`,
  ArgoCD picks them up, target deployments roll.

### What to do if runs occurred and any failed

- Open the failed workflow log via `argocd-application-controller` exec or the
  Argo Workflows UI at `argo-workflows.k8s.rommelporras.com`.
- Common post-ship regressions to watch for: registry token expired silently,
  GitHub deploy key revoked, sensor pod selector changed by a chart upgrade,
  Vault auth role drift after rotation.

### Acceptance criteria

- ≥1 successful workflow per project per environment in the 2w window, OR
- An induced run (empty commit) confirms the pipeline still works end-to-end
- No silent regression in CI-bot commit cadence vs. pre-ship baseline

---

## PVC resize batch (post-soak audit 2026-04-28)

**Status:** Identified - prometheus-db urgent (93%), gitlab-minio next (92%)
**Priority:** High for prometheus-db / gitlab-minio; Medium for arr-data
**Added:** 2026-04-28

The soak audit surfaced three PVCs over the `KubePersistentVolumeFillingUp`
warning threshold. Per the existing CLAUDE.md gotcha, StatefulSet
`volumeClaimTemplates` are immutable, so each resize is a multi-step
operation (patch live PVC -> Longhorn online expansion -> delete pod for
`resize2fs` on remount -> `--cascade=orphan` + helm upgrade to sync the
template). Procedure documented in CLAUDE.md "StatefulSet PVC expansion".

### Targets

| PVC | Namespace | Current | Used | Suggested | Owner workload |
|---|---|---|---|---|---|
| `prometheus-prometheus-kube-prometheus-prometheus-db-...-0` | monitoring | 60Gi | 56Gi (93%) | **80Gi** | StatefulSet `prometheus-prometheus-kube-prometheus-prometheus` (kube-prometheus-stack) |
| `gitlab-minio` | gitlab | 20Gi | 18.5Gi (92%) | **40Gi** | StatefulSet `gitlab-minio` (note: MinIO is dead per CLAUDE.md - replace with Garage S3 instead of resizing if convenient; otherwise resize as a stopgap) |
| `arr-data` (RWX, 2 mounters reporting same %) | arr-stack | 2Ti | 1.76Ti (88%) | **3Ti** | shared by ARR media workloads (Sonarr/Radarr/Bazarr/etc.) - safe to grow during normal hours, no DB |

### Why prometheus-db is urgent

At ~3 GiB/day current ingestion, 93% on 60Gi -> 95% (alert escalation) in
~2 days. Retention is already at 30d post-Phase 5.5 audit-policy/Alloy-filter
work, so the next cheap lever is capacity, not retention. Bumping to 80Gi
gives ~7 days of additional runway plus headroom for compaction churn.

### Why gitlab-minio is urgent

MinIO is the GitLab artifact + container registry backing store. Hitting
100% means GitLab CI breaks (failed artifact uploads) and `argo-workflows`
build/push steps fail at the registry layer. The CLAUDE.md "MinIO is dead"
note suggests the long-term fix is migrating GitLab artifact storage to
Garage S3, but that's a larger task. Stopgap resize keeps things alive
until the migration phase.

### Why arr-data can wait

2Ti -> 88% means ~240 GiB free. Media ingestion rate is hours/day, not
GiB/day. ~30-90d runway depending on download volume. Resize before it
hits 95%, but no immediate fire.

### Sequence (for each PVC)

1. Take a Longhorn snapshot of the source volume via Longhorn UI.
2. `kubectl-admin patch pvc <name> -n <ns> --type=merge -p '{"spec":{"resources":{"requests":{"storage":"<new-size>"}}}}'`
3. Wait for Longhorn to expand the block device online (watch `kubectl-admin get pvc -n <ns> <name>` -> `.status.capacity.storage`).
4. `kubectl-admin delete pod -n <ns> <pod-of-statefulset>` to trigger `resize2fs` on the next mount.
5. Update the helm chart values that drive `volumeClaimTemplates.spec.resources.requests.storage` to the new size.
6. `kubectl-admin delete statefulset <name> -n <ns> --cascade=orphan` then commit + ArgoCD sync to recreate the StatefulSet with the new template (no pod disruption since `--cascade=orphan` leaves pods running).
7. Verify the new StatefulSet's `volumeClaimTemplates` matches the live PVC capacity.

### Acceptance criteria

- All three PVCs ≤ 70% utilization post-resize
- No `KubePersistentVolumeFillingUp` firing
- Helm chart values match live PVC sizes (no drift)

### When to do it

prometheus-db + gitlab-minio: before or immediately after `/ship v0.39.2`
to clear the active firing warning. arr-data: next maintenance window.
