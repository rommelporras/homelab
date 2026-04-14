# Longhorn Hardware Runbook

Covers hardware-level incidents that surface through Longhorn: PCIe bus errors,
NVMe reseating, replica failures traced to physical issues. For volume-level
triage (degraded, faulted, stuck) see [storage.md](storage.md).

## NodePCIeBusError

**Severity:** warning

Kernel AER (Advanced Error Reporting) emitted a PCIe Bus Error. "Correctable"
events mean the PCIe layer retry succeeded with no data loss, but they signal
intermittent link instability - a reseat candidate. "Fatal" or "non-fatal"
events indicate imminent hardware failure and require immediate attention.

### Triage Steps

1. Identify severity and the exact device. From the alert labels or directly
   on the affected node:
   ```
   ssh wawashi@<node>.k8s.rommelporras.com
   sudo dmesg -T | grep -E "PCIe Bus Error|AER" | tail -20
   ```
   Look for lines like:
   ```
   nvme 0000:01:00.0: PCIe Bus Error: severity=Correctable, type=Physical Layer, (Receiver ID)
   ```
   The BDF (`0000:01:00.0` above) identifies the device; `lspci -s 0000:01:00.0`
   names it (typically the NVMe controller on these M80q nodes).

2. Read persistent sysfs counters (survive dmesg ring-buffer rotation):
   ```
   sudo cat /sys/bus/pci/devices/0000:01:00.0/aer_dev_correctable
   sudo cat /sys/bus/pci/devices/0000:01:00.0/aer_dev_fatal
   sudo cat /sys/bus/pci/devices/0000:01:00.0/aer_dev_nonfatal
   ```
   Non-zero `fatal` or `nonfatal` counters = stop here and plan drive replacement.

3. Check NVMe SMART to rule out drive-level issues:
   ```
   # smartctl is not installed on nodes; use the in-cluster exporter:
   kubectl-homelab exec -n monitoring \
     smartctl-exporter-prometheus-smartctl-exporter-0-<node-suffix> \
     -- wget -qO- http://localhost:9633/metrics \
     | grep -E 'smartctl_device_(media_errors|critical_warning|percentage_used|available_spare)'
   ```
   Healthy baseline: `media_errors=0`, `critical_warning=0`,
   `available_spare=100`, `percentage_used <5`. If any of these are trending
   bad, the drive itself is failing - see [storage.md NVMeMediaErrors](storage.md#nvmemediaerrors).

4. Check Grafana for correlated Longhorn events in the same window:
   https://grafana.k8s.rommelporras.com - Longhorn dashboard, volume
   robustness panel. Replica failures on the same node within minutes of
   AER events are a strong signal that the PCIe link is affecting I/O.

5. **Decision tree:**
   - Correctable only, <5 events/week, no Longhorn impact -> monitor, schedule
     a reseat at next planned maintenance
   - Correctable, repeating with Longhorn replica failures -> reseat soon
     (see "Reseating an NVMe" below)
   - Any fatal or non-fatal event -> drain node and replace drive

---

## LonghornVolumeAutoSalvaged

**Severity:** warning

Longhorn detected replica errors and triggered its `AutoSalvaged` recovery flow.
A single salvage is usually benign (Longhorn did its job); repeated salvage on
the same node within days indicates hardware or networking issues.

### Triage Steps

1. Find the volume and the replica that failed:
   ```
   kubectl-homelab get events -n longhorn-system \
     --field-selector reason=AutoSalvaged --sort-by='.lastTimestamp' | tail -5

   kubectl-homelab get volume <pvc-uuid> -n longhorn-system -o json \
     | jq '{robustness: .status.robustness, state: .status.state, node: .status.currentNodeID}'
   ```

2. Identify which replica failed and where it lived:
   ```
   kubectl-homelab get replicas.longhorn.io -n longhorn-system \
     -l longhornvolume=<pvc-uuid> -o wide
   ```
   Look for the replica with `FAILEDAT` set or missing from the list (new
   replicas have different suffixes after salvage/rebuild).

3. Cross-check kernel logs on the failing replica's host for the same timeframe:
   ```
   ssh wawashi@<node>.k8s.rommelporras.com
   sudo dmesg -T | grep -E "medium error|I/O error|PCIe|iscsi" | tail -30
   ```
   Medium errors on an `sd*` device usually trace back to Longhorn's iSCSI
   layer, not the physical NVMe. The iSCSI device on the engine's node may
   report errors when the remote replica stalls - this is a symptom, not
   necessarily the cause.

4. Check whether a rebuild was already in progress on the same node when the
   failure happened:
   ```
   kubectl-homelab logs -n longhorn-system -l app=longhorn-manager --since=30m \
     | grep -E 'rebuild|salvage|ERR'
   ```

5. **Decision tree:**
   - One salvage, clean rebuild, no recurrence -> no action. Longhorn did its job
   - Repeated salvages on the same node within days -> see NodePCIeBusError
     above and consider reseating that node's NVMe
   - Salvage happens during replica rebuilds on the same node -> review
     `concurrent-replica-rebuild-per-node-limit` (default 5) in Longhorn
     settings. Only tune if a clear pattern emerges over a 30-day window

---

## Reseating an NVMe

Lenovo M80q tiny-form-factor chassis with a single M.2 NVMe under the bottom
cover. Reseat addresses: loose socket contact, oxidation, thermal warping.
Takes ~15 min including node drain + uncordon. Do this when:

- Correctable PCIe errors are recurring (multiple events/week) AND
- SMART is still clean AND
- At least one Longhorn replica failure has correlated with the AER pattern

### Procedure

1. **Pre-flight: confirm 3 replicas healthy for every volume on the node.**
   Reseating drops one replica copy for the duration; the cluster must have
   at least 2 healthy replicas on OTHER nodes for each volume during the work.
   ```
   kubectl-homelab get volumes.longhorn.io -n longhorn-system -o json \
     | jq -r '.items[] | select(.spec.numberOfReplicas == 3) | select(.status.robustness != "healthy") | .metadata.name'
   ```
   Must return empty. If any volume is already degraded, fix that first.

2. **Take a fresh Longhorn backup** of any volume whose only replicas
   include one on the node being reseated (defense in depth - reseat should
   not lose data, but if physical intervention corrupts the M.2 seating on
   the way back in, the backup is the rollback path):
   ```
   # Longhorn UI -> Volume -> Create Backup
   # Wait for backup to reach "Completed" state before proceeding.
   ```

3. **Drain the node:**
   ```
   kubectl-admin cordon k8s-cp3
   kubectl-admin drain k8s-cp3 \
     --ignore-daemonsets --delete-emptydir-data --force
   # Expect Longhorn's instance-manager and csi-plugin DaemonSets to stay;
   # everything else reschedules. Drain takes 2-5 min.
   ```

4. **Power off the node gracefully:**
   ```
   ssh wawashi@k8s-cp3 "sudo shutdown -h now"
   # Wait ~60s for clean shutdown.
   ```

5. **Physical work:**
   - Unplug power from the M80q
   - Remove the bottom cover (one captive screw on the M80q)
   - Locate the M.2 NVMe (SK Hynix HFS512GDE9X081N on this cluster)
   - Loosen the single retaining screw, the drive pops up at ~30 degrees
   - Remove fully, inspect the gold-finger contacts for discoloration or
     debris. If dirty, gently clean with isopropyl alcohol (>90%) and a
     lint-free cloth. Allow to dry fully
   - Reinsert at ~30 degrees, push down flat, replace retaining screw
   - Replace bottom cover, reconnect power

6. **Power on and verify boot:**
   ```
   # M80q BIOS POST takes 5-7 min. Wait for:
   ping -c1 k8s-cp3
   ssh wawashi@k8s-cp3 "uptime"
   ```

7. **Uncordon and verify Longhorn recovery:**
   ```
   kubectl-admin uncordon k8s-cp3

   # Wait for Longhorn replica rebuilds to complete. With default
   # concurrent-replica-rebuild-per-node-limit=5, this takes 5-20 min
   # depending on replica sizes. Watch:
   kubectl-homelab get replicas.longhorn.io -n longhorn-system \
     --field-selector spec.nodeID=k8s-cp3 -w
   # All replicas should reach status.currentState=running.
   ```

8. **Confirm AER counters reset** (sysfs counters clear on reboot):
   ```
   ssh wawashi@k8s-cp3 \
     "sudo cat /sys/bus/pci/devices/0000:01:00.0/aer_dev_correctable"
   # Expected: 0 errors directly after boot.
   ```

9. **Monitor for 7 days.** If correctable PCIe errors return within a week,
   reseat did not fix the link - escalate to drive or mainboard replacement.

---

## When to Replace vs Reseat

| Symptom | First action |
|---|---|
| Correctable PCIe errors, no SMART issues | Reseat |
| Correctable errors return within 7 days of reseat | Replace drive |
| Correctable errors return after drive swap | Replace mainboard or move workload to another node |
| Any fatal/non-fatal PCIe error | Replace drive (do not reseat - likely NAND/controller failure) |
| Non-zero `smartctl_device_media_errors` | Replace drive - see [storage.md NVMeMediaErrors](storage.md#nvmemediaerrors) |
| Non-zero `smartctl_device_critical_warning` | Replace drive immediately (thermal, reliability, read-only, or spare-exhausted flag set) |
| `available_spare` dropping week-over-week | Replace drive before it reaches 10% (manufacturer threshold) |

---

## Incident Log

- **2026-04-14 16:38 Asia/Manila** - bazarr-config replica on k8s-cp3
  (`pvc-a1c35c01-...-r-ecb92f9a`) stopped responding, triggering Longhorn
  AutoSalvaged. k8s-cp2 went NotReady for ~95s during the I/O stall;
  karakeep + chrome were collateral damage. Longhorn rebuilt the replica
  cleanly. No direct drive-level error found on cp3, but cp3 had 4 PCIe
  correctable errors in the preceding 8 days (Apr 6, 9, 10, 11). Phase 5.9.7
  added the observability that would have caught this earlier (see CHANGELOG
  entry for v0.39.0).
