---
tags: [homelab, kubernetes, ups, nut, power]
updated: 2026-03-13
---

# UPS

NUT (Network UPS Tools) monitoring and graceful shutdown.

## Hardware

| Setting | Value |
|---------|-------|
| Model | CyberPower CP1600EPFCLCD |
| Connection | USB to k8s-cp1 |

## NUT Architecture

```
                    ┌─────────────┐
                    │  CyberPower │
                    │     UPS     │
                    └──────┬──────┘
                           │ USB
                           ▼
┌──────────────────────────────────────────────────┐
│                   k8s-cp1                         │
│              NUT Server (upsd)                    │
│         Monitors UPS, shares data                 │
└──────────────────┬───────────────────────────────┘
                   │ Network (port 3493)
         ┌─────────┴─────────┐
         ▼                   ▼
┌─────────────────┐  ┌─────────────────┐
│    k8s-cp2      │  │    k8s-cp3      │
│  NUT Client     │  │  NUT Client     │
│   (upsmon)      │  │   (upsmon)      │
└─────────────────┘  └─────────────────┘
```

## NUT Versions

| Component | Version |
|-----------|---------|
| NUT | 2.8.1 |
| nut-exporter | 3.1.1 |

## Node Roles

| Node | Role | Config |
|------|------|--------|
| k8s-cp1 | Server + Primary | USB connected, `upsmon -p` |
| k8s-cp2 | Client + Secondary | Network, `upsmon -s` |
| k8s-cp3 | Client + Secondary | Network, `upsmon -s` |

## Staggered Shutdown Timers

| Node | Timer | Trigger | Reason |
|------|-------|---------|--------|
| k8s-cp3 | 10 min | On battery | First to shutdown (reduce load) |
| k8s-cp2 | 20 min | On battery | Second to shutdown |
| k8s-cp1 | Low Battery | FSD from UPS | Last (sends power-off to UPS) |

## Kubelet Graceful Shutdown

| Setting | Value |
|---------|-------|
| shutdownGracePeriod | 120s |
| shutdownGracePeriodCriticalPods | 30s |

Configured in `/var/lib/kubelet/config.yaml` on each node.

## NUT Credentials

| Item | 1Password Path |
|------|----------------|
| Admin | `op://Kubernetes/NUT Admin/username` |
| Admin | `op://Kubernetes/NUT Admin/password` |
| Monitor | `op://Kubernetes/NUT Monitor/username` |
| Monitor | `op://Kubernetes/NUT Monitor/password` |

## Prometheus Metrics

nut-exporter runs in the monitoring namespace, scrapes NUT server.

| Metric | Description |
|--------|-------------|
| nut_battery_charge | Battery charge % |
| nut_battery_runtime_seconds | Estimated runtime |
| nut_ups_load | UPS load % |
| nut_ups_status | UPS status (OL, OB, LB) |

## UPS Alerts

| Alert | Condition |
|-------|-----------|
| UPSOnBattery | Status = OB (on battery) |
| UPSLowBattery | Status contains LB |
| UPSHighLoad | Load > 80% |
| UPSBatteryLow | Charge < 50% |
| UPSBatteryCritical | Charge < 20% |

## Grafana Dashboard

Custom UPS dashboard auto-provisioned via ConfigMap.

Shows: Battery charge, runtime, load, status history.

## Configuration Files

| File | Location |
|------|----------|
| NUT config | /etc/nut/ on each node |
| nut-exporter | manifests/monitoring/nut-exporter.yaml |
| UPS alerts | manifests/monitoring/ups-alerts.yaml |
| Dashboard | manifests/monitoring/ups-dashboard-configmap.yaml |

## Related

- [[Monitoring]] - nut-exporter, alerts
- [[Secrets]] - NUT credentials
- [[Cluster]] - Node roles
