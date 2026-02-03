---
tags: [homelab, kubernetes, monitoring, prometheus, grafana, alerting]
updated: 2026-02-03
---

# Monitoring

Observability stack: Prometheus, Grafana, Loki, Alertmanager.

## Components

| Component | Version | Namespace |
|-----------|---------|-----------|
| kube-prometheus-stack | 81.0.0 | monitoring |
| Prometheus | v0.88.0 | monitoring |
| Grafana | — | monitoring |
| Alertmanager | v0.30.1 | monitoring |
| Loki | v3.6.3 | monitoring |
| Alloy | v1.12.2 | monitoring |
| node-exporter | — | monitoring |
| nut-exporter | 3.1.1 | monitoring |
| blackbox-exporter | v0.28.0 | monitoring |
| Uptime Kuma | v2.0.2 | uptime-kuma |

## Access

| Service | URL |
|---------|-----|
| Grafana | https://grafana.k8s.rommelporras.com |
| Prometheus | ClusterIP (port-forward: 9090) |
| Alertmanager | ClusterIP (port-forward: 9093) |
| Uptime Kuma | https://uptime.k8s.rommelporras.com |
| Uptime Kuma (public) | https://status.rommelporras.com/status/homelab |

## Grafana

| Setting | Value |
|---------|-------|
| Admin user | admin |
| Password | 1Password: `op://Kubernetes/Grafana/password` |
| Datasources | Prometheus, Loki (auto-provisioned) |

## Loki

| Setting | Value |
|---------|-------|
| Mode | SingleBinary |
| Retention | 90 days |
| Storage | Longhorn PVC |

Query logs:
```bash
# Pods
{namespace="monitoring", pod=~"prometheus.*"}

# K8s events
{source="kubernetes_events"}
```

## Alloy (Log Collector)

| Setting | Value |
|---------|-------|
| Mode | DaemonSet |
| Memory limit | 256Mi |
| Collects | Pod logs, K8s events |

## Alertmanager

### Receivers

| Receiver | Destination | When |
|----------|-------------|------|
| discord-incidents-email | Discord #incidents + Email | Critical |
| discord-status | Discord #status | Warning, Info |
| healthchecks-heartbeat | healthchecks.io ping | Watchdog (1m) |
| null | Nowhere | Silenced alerts |

### Alert Routing

| Severity | Discord | Email |
|----------|---------|-------|
| Critical | #incidents | 3 recipients |
| Warning | #status | None |
| Info | #status | None |

### Email Recipients (Critical)

- critical@rommelporras.com
- r3mmel023@gmail.com
- rommelcporras@gmail.com

### Silenced Alerts

These kubeadm false positives are routed to `null`:

| Alert | Reason |
|-------|--------|
| KubeProxyDown | kube-proxy removed (Cilium eBPF) |
| etcdInsufficientMembers | etcd metrics not scraped |
| etcdMembersDown | etcd metrics not scraped |
| TargetDown (kube-scheduler) | Bound to localhost |
| TargetDown (kube-controller-manager) | Bound to localhost |
| TargetDown (kube-etcd) | Bound to localhost |

See `docs/todo/deferred.md` for future fix instructions.

## Configuration Files

| File | Purpose |
|------|---------|
| helm/prometheus/values.yaml | Alertmanager config, routes |
| scripts/upgrade-prometheus.sh | Upgrade with 1Password secrets |
| manifests/monitoring/test-alert.yaml | Test PrometheusRule |
| manifests/monitoring/adguard-dns-probe.yaml | Blackbox DNS probe for AdGuard |
| manifests/monitoring/adguard-dns-alert.yaml | Alert on DNS probe failure |
| manifests/monitoring/uptime-kuma-probe.yaml | Blackbox HTTP probe for Uptime Kuma |
| helm/blackbox-exporter/values.yaml | Blackbox exporter config (dns_udp module) |

## Upgrade Prometheus Stack

```bash
# Uses 1Password for secrets
./scripts/upgrade-prometheus.sh
```

## Related

- [[Secrets]] - 1Password paths for webhooks, SMTP
- [[UPS]] - UPS monitoring with nut-exporter
- [[Versions]] - Component versions
