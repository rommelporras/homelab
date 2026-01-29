# Phase 4.8.1: AdGuard DNS Alerting

> **Status:** Complete
> **Target:** v0.10.3
> **Prerequisite:** Phase 4.8 complete (AdGuard Client IP)
> **DevOps Topics:** Blackbox Exporter, synthetic monitoring, DNS probing
> **CKA Topics:** Probe CRD, PrometheusRule, AlertManager routing

> **Purpose:** Alert when AdGuard DNS becomes unreachable (prevents 3-day unnoticed outages)
>
> **Problem:** L2 lease can move to wrong node after Cilium restart, causing traffic to be dropped with `externalTrafficPolicy: Local`. This happened Jan 25-28 with no alerts.
>
> **Solution:** Deploy blackbox-exporter to probe DNS externally and alert on failure.

---

## Overview

Add synthetic DNS monitoring to detect when AdGuard is running but not receiving traffic due to L2/pod node mismatch.

### Why Not Just Monitor Pod Health?

| Check | What It Catches | What It Misses |
|-------|-----------------|----------------|
| Pod liveness probe | Pod crash, OOM | L2 lease on wrong node |
| Service endpoint count | No ready endpoints | L2 lease on wrong node |
| **External DNS probe** | All of the above + L2 mismatch | - |

### Architecture

```
Prometheus → Blackbox Exporter → DNS query to 10.10.30.53 → AdGuard
                                         │
                                         ├─ Success: probe_success=1
                                         └─ Failure: probe_success=0 → Alert
```

---

## 4.8.1.1 Deploy Blackbox Exporter (Separate Helm Chart)

**Important:** kube-prometheus-stack does NOT bundle blackbox exporter. Install it separately.

- [x] Create values file `helm/blackbox-exporter/values.yaml`

  ```yaml
  # prometheus-blackbox-exporter Helm Values
  # Custom probe modules - blackbox has NO default DNS module
  config:
    modules:
      dns_udp:
        prober: dns
        timeout: 5s
        dns:
          transport_protocol: udp
          preferred_ip_protocol: ip4
          query_name: "google.com"
          query_type: "A"
          valid_rcodes:
            - NOERROR
      http_2xx:
        prober: http
        timeout: 5s
        http:
          preferred_ip_protocol: ip4
          valid_status_codes: []
          follow_redirects: true

  resources:
    requests:
      cpu: 10m
      memory: 32Mi
    limits:
      memory: 64Mi

  serviceMonitor:
    enabled: true
    defaults:
      labels:
        release: prometheus
  ```

- [x] Install blackbox exporter
  ```bash
  helm-homelab install blackbox-exporter prometheus-community/prometheus-blackbox-exporter \
    --namespace monitoring \
    --values helm/blackbox-exporter/values.yaml
  ```

- [x] Enable Probe discovery in kube-prometheus-stack

  Add to `helm/prometheus/values.yaml` under `prometheus.prometheusSpec`:

  ```yaml
  probeSelectorNilUsesHelmValues: false
  ```

---

## 4.8.1.2 Upgrade Prometheus (if probeSelector not set)

Only needed if `probeSelectorNilUsesHelmValues: false` wasn't already in values.yaml.

- [x] Upgrade kube-prometheus-stack (use the wrapper script)
  ```bash
  ./scripts/upgrade-prometheus.sh
  ```

- [x] Verify blackbox exporter is running
  ```bash
  kubectl-homelab get pods -n monitoring | grep blackbox
  # Expected: blackbox-exporter-prometheus-blackbox-exporter-xxxxx   1/1   Running
  ```

- [x] Verify blackbox exporter service name
  ```bash
  kubectl-homelab get svc -n monitoring | grep blackbox
  # Expected: blackbox-exporter-prometheus-blackbox-exporter
  ```

---

## 4.8.1.3 Create DNS Probe

The Probe CRD tells Prometheus to scrape blackbox exporter with specific target/module.

- [x] Create `manifests/monitoring/adguard-dns-probe.yaml`
  ```yaml
  # AdGuard DNS synthetic monitoring
  # Probes the LoadBalancer IP to detect L2 lease misalignment
  apiVersion: monitoring.coreos.com/v1
  kind: Probe
  metadata:
    name: adguard-dns
    namespace: monitoring
    labels:
      app: adguard-dns-probe
  spec:
    jobName: adguard-dns  # This becomes the 'job' label in metrics
    interval: 30s
    module: dns_udp
    prober:
      # Service name: <release>-prometheus-blackbox-exporter
      url: blackbox-exporter-prometheus-blackbox-exporter.monitoring.svc:9115
    targets:
      staticConfig:
        static:
          - 10.10.30.53  # AdGuard LoadBalancer IP
        labels:
          target_name: adguard-dns
  ```

- [x] Apply the Probe
  ```bash
  kubectl-homelab apply -f manifests/monitoring/adguard-dns-probe.yaml
  ```

- [x] Verify Probe is discovered by Prometheus
  ```bash
  # Check Prometheus targets (via port-forward or Grafana)
  kubectl-homelab port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090 &
  # Open http://localhost:9090/targets and look for "probe/monitoring/adguard-dns"
  ```

- [x] Verify probe_success metric exists
  ```bash
  # Query Prometheus
  curl -s "http://localhost:9090/api/v1/query?query=probe_success" | jq '.data.result[] | select(.metric.job=="adguard-dns")'
  ```

---

## 4.8.1.4 Create Alert Rule

- [x] Create `manifests/monitoring/adguard-dns-alert.yaml`
  ```yaml
  # Alert when AdGuard DNS probe fails
  # Catches L2 lease misalignment that pod health checks miss
  apiVersion: monitoring.coreos.com/v1
  kind: PrometheusRule
  metadata:
    name: adguard-dns-alerts
    namespace: monitoring
    labels:
      # Required for Prometheus to discover this rule
      prometheus: prometheus
      role: alert-rules
  spec:
    groups:
    - name: adguard-dns
      rules:
      - alert: AdGuardDNSUnreachable
        # job label comes from Probe's jobName field
        expr: probe_success{job="adguard-dns"} == 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "AdGuard DNS is unreachable"
          description: "External DNS probe to 10.10.30.53 has failed for 2+ minutes. Likely L2 lease on wrong node."
          runbook: |
            1. Check pod node:
               kubectl-homelab get pods -n home -l app=adguard-home -o wide

            2. Check L2 lease holder:
               kubectl-homelab get leases -n kube-system cilium-l2announce-home-adguard-dns -o jsonpath='{.spec.holderIdentity}'

            3. If pod node != lease holder, delete lease to force re-election:
               kubectl-homelab delete lease -n kube-system cilium-l2announce-home-adguard-dns

            4. Verify DNS resolution restored:
               dig @10.10.30.53 google.com
  ```

- [x] Apply the alert rule
  ```bash
  kubectl-homelab apply -f manifests/monitoring/adguard-dns-alert.yaml
  ```

- [x] Verify rule is loaded in Prometheus
  ```bash
  # Check Prometheus rules page
  # http://localhost:9090/rules - look for "adguard-dns" group
  ```

---

## 4.8.1.5 Test Alert Pipeline

Simulate a failure to verify the full alert pipeline works.

### Option A: Delete the L2 lease (safe, real failure mode)

- [x] Note current state
  ```bash
  # Pod location
  kubectl-homelab get pods -n home -l app=adguard-home -o wide

  # Current lease holder
  kubectl-homelab get leases -n kube-system cilium-l2announce-home-adguard-dns -o jsonpath='{.spec.holderIdentity}'
  ```

- [x] Delete the lease to trigger re-election
  ```bash
  kubectl-homelab delete lease -n kube-system cilium-l2announce-home-adguard-dns
  ```

- [x] Watch for alert (may take 2+ minutes for `for: 2m`)
  ```bash
  # Check Alertmanager
  kubectl-homelab port-forward -n monitoring svc/prometheus-kube-prometheus-alertmanager 9093:9093 &
  # Open http://localhost:9093/#/alerts
  ```

- [x] Verify Discord notification received

- [x] Cilium should auto-recreate lease on correct node within seconds

### Option B: Block DNS port temporarily (more disruptive)

```bash
# On the node running AdGuard, block UDP 53 (requires root on node)
# NOT RECOMMENDED for homelab - use Option A instead
```

---

## Verification Checklist

- [x] Blackbox exporter pod running: `kubectl-homelab get pods -n monitoring | grep blackbox`
- [x] Blackbox exporter has dns_udp module: `kubectl-homelab get cm -n monitoring blackbox-exporter-prometheus-blackbox-exporter -o yaml | grep dns_udp`
- [x] Probe resource exists: `kubectl-homelab get probe -n monitoring adguard-dns`
- [x] Probe appears in Prometheus targets: http://localhost:9090/targets
- [x] `probe_success{job="adguard-dns"}` metric exists in Prometheus
- [x] PrometheusRule loaded: http://localhost:9090/rules
- [x] Test alert fires correctly (tested with probe to 10.10.30.99)
- [x] Discord notification received for test alert

---

## Files Changed/Created

```
helm/prometheus/values.yaml              # Add probeSelectorNilUsesHelmValues
helm/blackbox-exporter/values.yaml       # NEW: Blackbox exporter config with dns_udp module
manifests/monitoring/
├── adguard-dns-probe.yaml               # Probe CRD
└── adguard-dns-alert.yaml               # PrometheusRule
scripts/upgrade-prometheus.sh            # Fixed Healthchecks field name
VERSIONS.md                              # Added blackbox-exporter chart
```

---

## Troubleshooting

### Probe not appearing in Prometheus targets

1. Check `probeSelectorNilUsesHelmValues: false` is set
2. Verify Prometheus was restarted after helm upgrade
3. Check Probe resource exists: `kubectl-homelab get probe -A`

### probe_success always 0

1. Test blackbox exporter directly:
   ```bash
   kubectl-homelab exec -n monitoring deployment/blackbox-exporter-prometheus-blackbox-exporter -- \
     wget -qO- "http://localhost:9115/probe?target=10.10.30.53&module=dns_udp" | grep probe_success
   ```
2. Check dns_udp module is configured correctly
3. Verify AdGuard is actually responding: `dig @10.10.30.53 google.com`

### Alert not firing

1. Check expression in Prometheus: query `probe_success{job="adguard-dns"}`
2. Verify PrometheusRule labels match Prometheus selector
3. Check Alertmanager is receiving alerts: http://localhost:9093

---

## References

- [Blackbox Exporter Configuration](https://github.com/prometheus/blackbox_exporter/blob/master/CONFIGURATION.md)
- [Prometheus Probe CRD](https://prometheus-operator.dev/docs/operator/api/#monitoring.coreos.com/v1.Probe)
- [kube-prometheus-stack blackbox values](https://github.com/prometheus-community/helm-charts/blob/main/charts/kube-prometheus-stack/values.yaml)
- Phase 4.8: AdGuard Client IP (root cause of the monitoring need)

---

## Final: Commit and Release

- [x] Commit changes (913a039)

- [ ] Release v0.10.3 (user will do manually)

- [x] Move this file to completed folder
