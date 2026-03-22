# Storage Runbook

Covers: Longhorn volume health, NVMe S.M.A.R.T. monitoring

## LonghornVolumeDegraded

**Severity:** warning

Longhorn volume has reduced replicas but is still accessible. At least one replica is unhealthy, reducing redundancy. Data remains available.

### Triage Steps

1. Check volume status in Longhorn UI:
   https://longhorn.k8s.rommelporras.com

2. Check replicas (volume label is the Longhorn volume UUID):
   `kubectl-homelab -n longhorn-system get replicas -l longhornvolume=<volume>`

3. Check node health (a node issue may affect replicas):
   `kubectl-homelab get nodes`

4. If a replica is rebuilding, monitor progress in Longhorn UI

---

## LonghornVolumeReplicaFailed

**Severity:** critical

Longhorn volume is in faulted state - all replicas have failed. Data access is at risk.

### Triage Steps

1. Check volume status immediately in Longhorn UI:
   https://longhorn.k8s.rommelporras.com

2. Check which replicas failed:
   `kubectl-homelab -n longhorn-system get replicas -l longhornvolume=<volume> -o wide`

3. Check node conditions:
   `kubectl-homelab get nodes`
   `kubectl-homelab describe nodes | grep -A5 Conditions`

4. If nodes are healthy, check Longhorn manager logs:
   `kubectl-homelab -n longhorn-system logs deploy/longhorn-manager --tail=100`

5. Check disk availability on all nodes:
   `kubectl-homelab -n longhorn-system get nodes.longhorn.io -o wide`

---

## LonghornVolumeAllReplicasStopped

**Severity:** warning

All replicas stopped for a detached volume (robustness=unknown, state=detached). Cluster Janitor skips this case as a safety measure - manual intervention required.

### Triage Steps

1. Check volume: `kubectl-homelab get volumes.longhorn.io <volume> -n longhorn-system`
2. Check if PVC is still in use: `kubectl-homelab get pvc -A | grep <pvc>`
3. If orphaned: delete PVC and volume via Longhorn UI
4. If needed: `kubectl-admin delete volume <volume> -n longhorn-system`

---

## NVMeMediaErrors

**Severity:** critical

NVMe drive has unrecoverable media errors, indicating physical NAND failure. Any non-zero count is serious and requires immediate action.

### Triage Steps

1. Verify error count in Grafana (NVMe Health row -> Longhorn dashboard)

2. Check full SMART report on the affected node:
   ```
   ssh wawashi@<node>.k8s.rommelporras.com
   sudo smartctl -a /dev/nvme0
   ```

3. Run extended self-test (non-destructive, ~2 min for NVMe):
   ```
   sudo smartctl -t long /dev/nvme0
   sudo smartctl -l selftest /dev/nvme0
   ```

4. If errors confirmed, plan drive replacement. Begin Longhorn backup first:
   https://longhorn.k8s.rommelporras.com

---

## NVMeSpareWarning

**Severity:** warning

NVMe available spare NAND blocks dropped below 20%. Drive endurance is being consumed. SK Hynix drives set their own threshold at ~10% - this alert fires proactively before that point.

### Triage Steps

1. Check wear level history in Grafana (NVMe Health row -> Available Spare panel)

2. Check full SMART data on the affected node:
   ```
   ssh wawashi@<node>.k8s.rommelporras.com
   sudo smartctl -a /dev/nvme0
   ```

3. Plan drive replacement before spare reaches 0.
   SK Hynix HFS512GDE9X081N drives can be sourced as identical replacements.

---

## NVMeWearHigh

**Severity:** warning

NVMe endurance used above 80% of manufacturer's rated write endurance. SK Hynix 512GB drives are rated ~300TBW.

### Triage Steps

1. Check Total Bytes Written in Grafana (NVMe Health row -> Longhorn dashboard)

2. Verify SMART data:
   ```
   ssh wawashi@<node>.k8s.rommelporras.com
   sudo smartctl -a /dev/nvme0
   ```

3. Order replacement drive (SK Hynix HFS512GDE9X081N or equivalent M.2 NVMe).
   Drain node before replacement:
   `kubectl-homelab drain <node> --ignore-daemonsets --delete-emptydir-data`

---

## NVMeTemperatureHigh

**Severity:** warning

NVMe drive has been above 65°C for 10+ minutes. SK Hynix HFS512GDE9X081N max operating temperature is 70°C - this alert fires with a 5°C buffer. Baseline idle temperature on all nodes is ~46°C; this only fires under sustained load.

### Triage Steps

1. Check temperature trend in Grafana (NVMe Health row -> Longhorn Storage dashboard)

2. Check if Tdarr is running heavy transcode workloads - GPU encoding generates heat:
   https://tdarr.k8s.rommelporras.com

3. Verify chassis airflow on the M80q (tiny form factor, relies on fan curve):
   ```
   ssh wawashi@<node>.k8s.rommelporras.com
   sudo smartctl -a /dev/nvme0  # check all temperature readings
   ```

4. If temperature is approaching 70°C, pause Tdarr immediately and check cooling.

---

## LonghornUIDown

**Severity:** warning

Longhorn UI dashboard is unreachable. Non-critical - the Longhorn backend (manager, engine, CSI) operates independently of the UI. Volume operations, snapshots, and replication continue unaffected.

### Triage Steps

```
1. Check pod status:
   kubectl-homelab get pods -n longhorn-system -l app=longhorn-ui

2. Check logs:
   kubectl-homelab logs -n longhorn-system -l app=longhorn-ui --tail=50
```
