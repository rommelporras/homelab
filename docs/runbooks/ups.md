# UPS Runbook

Covers: UPS power monitoring via NUT (Network UPS Tools)

---

## UPSOnBattery

**Severity:** warning

UPS has switched from line power to battery. Fires after 1 minute on battery. Utility power has likely been lost or interrupted.

### Triage Steps

1. Check if utility power is out physically - look for tripped breakers or building outage.
2. Verify UPS status on OPNsense via the NUT plugin (`Services > UPS > Status`). Confirm `OB` flag is set.
3. Check that all three k8s nodes are still reachable:
   ```
   kubectl-homelab get nodes
   ```
4. Monitor battery charge - if power does not return within a few minutes, prepare for `UPSLowBattery` or `UPSBatteryCritical`.
5. If this is a brief flicker (power returns quickly), verify all services recover cleanly.

---

## UPSLowBattery

**Severity:** critical

UPS has raised the Low Battery (`LB`) flag. Fires immediately with no `for:` delay. This is the UPS hardware signal that runtime is near-zero - NUT's auto-shutdown should already be triggering.

### Triage Steps

1. Confirm NUT's `upsmon` initiated a graceful shutdown on OPNsense. Check OPNsense system logs for `upsmon` entries.
2. Verify nodes are shutting down gracefully:
   ```
   kubectl-homelab get nodes
   ```
   Nodes will become `NotReady` as shutdown progresses - this is expected.
3. If auto-shutdown did not trigger, manually initiate shutdown on each node via SSH:
   ```
   ssh wawashi@10.10.30.11 'sudo shutdown -h now'
   ssh wawashi@10.10.30.12 'sudo shutdown -h now'
   ssh wawashi@10.10.30.13 'sudo shutdown -h now'
   ```
4. After power is restored, check battery charge before powering nodes back on.
5. Check battery health after the event - repeated deep discharges degrade battery life.

---

## UPSBatteryCritical

**Severity:** critical

Battery charge has dropped below 30% and remained there for over 1 minute. The UPS `LB` flag may or may not have fired yet. Shutdown must be in progress or initiated immediately.

### Triage Steps

1. Check current battery charge:
   - In Prometheus: `network_ups_tools_battery_charge`
   - In OPNsense NUT status page
2. Verify that NUT auto-shutdown is in progress (check `UPSLowBattery` triage steps above).
3. If nodes are still running and charge is still dropping, initiate manual shutdown now - do not wait.
4. After power restoration and nodes are back up, verify no data corruption:
   - Check Longhorn volume health: `kubectl-homelab get volumes -n longhorn-system`
   - Check etcd health: `kubectl-admin -n kube-system exec etcd-cp1 -- etcdctl endpoint health`
5. Check whether the UPS `LB` threshold is configured correctly in NUT (`LOWBATT` setting on OPNsense). It should fire before reaching 30%.

---

## UPSBatteryWarning

**Severity:** warning

Battery charge is between 30% and 50% and has been in this range for over 2 minutes. This fires during a power outage as the battery drains, or when the battery is aging and not holding a full charge.

### Triage Steps

1. Determine whether this is firing during an active outage (check `UPSOnBattery`):
   - If on battery during outage: monitor charge and prepare for `UPSBatteryCritical`.
   - If on line power with charge below 50%: battery is not charging fully - it is likely degraded.
2. For a potentially degraded battery, check battery age. Most UPS batteries last 3-5 years.
3. Check OPNsense NUT status for battery voltage and estimated runtime.
4. If the battery is aging, order a replacement. Run a capacity test (brief intentional outage) to confirm runtime before replacing.
5. If this alert fires persistently when on line power, the battery may need replacement immediately.

---

## UPSHighLoad

**Severity:** warning

UPS load has exceeded 80% for more than 5 minutes. At high load, battery runtime during an outage is significantly reduced.

### Triage Steps

1. Check current load in Prometheus: `network_ups_tools_ups_load`
2. Identify high-power devices connected to the UPS. Likely candidates: all three nodes under sustained CPU load, NAS under heavy disk activity.
3. Check node resource usage:
   ```
   kubectl-homelab top nodes
   ```
4. If a workload is causing the spike (e.g. a Tdarr transcode job or backup), consider throttling or rescheduling it.
5. If load is consistently high under normal operation, consider redistributing devices to a second UPS or upgrading to a higher-capacity unit.
6. Note the estimated runtime at current load from OPNsense NUT status - plan accordingly if a power event occurs while load is elevated.

---

## UPSExporterDown

**Severity:** critical

Prometheus cannot reach the `nut-exporter` job for 2 minutes. UPS status is no longer being monitored - a power event would go undetected.

### Triage Steps

1. Check the NUT exporter pod:
   ```
   kubectl-homelab get pods -n monitoring -l app=nut-exporter
   kubectl-homelab describe pod -n monitoring -l app=nut-exporter
   kubectl-homelab logs -n monitoring -l app=nut-exporter --tail=50
   ```
2. If the pod is crashing, check logs for connection errors to the NUT server on OPNsense.
3. Verify the NUT server is running on OPNsense (`Services > UPS` in OPNsense UI, or check if `upsd` process is up).
4. Verify network connectivity from the monitoring namespace to OPNsense's NUT port (3493):
   ```
   kubectl-admin run -it --rm nettest --image=alpine/k8s:1.35.0 --restart=Never -- nc -zv <opnsense-ip> 3493
   ```
5. Check if a CiliumNetworkPolicy is blocking egress to OPNsense from the monitoring namespace.
6. Restart the exporter pod if the NUT server is confirmed healthy:
   ```
   kubectl-admin rollout restart deployment/nut-exporter -n monitoring
   ```

---

## UPSOffline

**Severity:** critical

The UPS is reporting neither `OL` (on line) nor `OB` (on battery) for 2 minutes. This indicates a communication or hardware fault - the UPS state is unknown.

### Triage Steps

1. Check physical UPS - verify it is powered on and the USB/serial cable to OPNsense is connected.
2. Check OPNsense NUT status page (`Services > UPS > Status`). If blank or errored, `upsd` may have lost communication with the UPS driver.
3. On OPNsense, restart the NUT service to re-establish driver communication.
4. Check OPNsense system logs for `upsd` or `usbhid-ups` driver errors.
5. If the USB connection is the issue, replug the UPS USB cable on OPNsense and restart NUT.
6. This alert fires without a grace period if `UPSExporterDown` is also active - resolve exporter connectivity first, as the UPS may simply be unreachable rather than offline.

---

## UPSBackOnline

**Severity:** info

UPS has returned to line power after being on battery. This is an informational alert confirming power restoration - no action required unless services did not recover.

### Triage Steps

1. Verify all nodes returned to `Ready` state:
   ```
   kubectl-homelab get nodes
   ```
2. Check for pods stuck in `CrashLoopBackOff` or `Error` after the power event:
   ```
   kubectl-homelab get pods -A --field-selector=status.phase!=Running | grep -v Completed
   ```
3. Verify Longhorn volumes are healthy (volumes may need to re-attach after node recovery):
   ```
   kubectl-homelab get volumes -n longhorn-system
   ```
4. Check etcd cluster health if the outage was long enough to trigger node shutdowns:
   ```
   kubectl-admin -n kube-system exec etcd-cp1 -- etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key endpoint health --cluster
   ```
5. Verify the UPS battery charge is recovering - charge should climb back toward 100% over the next hour.
6. Clear any silenced or acknowledged alerts from this power event in Alertmanager.
