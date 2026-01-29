# Phase 4.8.1: AdGuard DNS Alerting

> **Status:** Planned
> **Target:** v0.10.3
> **Prerequisite:** Phase 4.8 complete (AdGuard Client IP)
> **DevOps Topics:** Blackbox Exporter, synthetic monitoring, DNS probing
> **CKA Topics:** ServiceMonitor, ProbeMonitor, AlertManager rules

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

---

## 4.8.1.1 Deploy Blackbox Exporter

- [ ] Add blackbox-exporter to kube-prometheus-stack values
  ```yaml
  # helm/kube-prometheus-stack/values.yaml
  blackboxExporter:
    enabled: true
  ```

- [ ] Upgrade Helm release
  ```bash
  helm-homelab upgrade prometheus prometheus-community/kube-prometheus-stack \
    -n monitoring -f helm/kube-prometheus-stack/values.yaml
  ```

---

## 4.8.1.2 Create DNS Probe

- [ ] Create Probe resource for AdGuard DNS
  ```yaml
  # manifests/monitoring/adguard-dns-probe.yaml
  apiVersion: monitoring.coreos.com/v1
  kind: Probe
  metadata:
    name: adguard-dns
    namespace: monitoring
  spec:
    interval: 30s
    module: dns_udp
    prober:
      url: prometheus-blackbox-exporter.monitoring.svc:9115
    targets:
      staticConfig:
        static:
          - 10.10.30.53  # AdGuard LoadBalancer IP
  ```

---

## 4.8.1.3 Create Alert Rule

- [ ] Create PrometheusRule for DNS failure
  ```yaml
  # manifests/monitoring/adguard-dns-alert.yaml
  apiVersion: monitoring.coreos.com/v1
  kind: PrometheusRule
  metadata:
    name: adguard-dns-alerts
    namespace: monitoring
    labels:
      prometheus: prometheus
      role: alert-rules
  spec:
    groups:
    - name: adguard-dns
      rules:
      - alert: AdGuardDNSUnreachable
        expr: probe_success{job="probe/monitoring/adguard-dns"} == 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "AdGuard DNS is unreachable"
          description: "External DNS probe to 10.10.30.53 has failed for 2 minutes. Check L2 lease alignment with pod node."
          runbook: |
            1. Check pod node: kubectl-homelab get pods -n home -l app=adguard-home -o wide
            2. Check L2 lease: kubectl-homelab get leases -n kube-system | grep adguard
            3. If mismatch, delete lease to force re-election
  ```

---

## 4.8.1.4 Verify Alerting

- [ ] Simulate failure by temporarily moving pod to different node
- [ ] Verify alert fires in Alertmanager
- [ ] Verify Discord notification received
- [ ] Restore pod to correct node

---

## Verification Checklist

- [ ] Blackbox exporter running in monitoring namespace
- [ ] DNS probe showing in Prometheus targets
- [ ] `probe_success` metric available for AdGuard DNS
- [ ] Alert rule loaded in Prometheus
- [ ] Test alert fires and notifies Discord

---

## Files to Create

```
manifests/monitoring/
├── adguard-dns-probe.yaml
└── adguard-dns-alert.yaml
```

---

## References

- [Blackbox Exporter](https://github.com/prometheus/blackbox_exporter)
- [Prometheus Probe CRD](https://prometheus-operator.dev/docs/operator/api/#monitoring.coreos.com/v1.Probe)
- Phase 4.8: AdGuard Client IP (root cause of the monitoring need)

---

## Final: Commit and Release

- [ ] Commit changes
  ```bash
  /commit
  ```

- [ ] Release v0.10.3
  ```bash
  /release v0.10.3
  ```

- [ ] Move this file to completed folder
  ```bash
  mv docs/todo/phase-4.8.1-adguard-dns-alerting.md docs/todo/completed/
  ```
