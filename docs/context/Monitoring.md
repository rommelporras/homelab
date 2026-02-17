---
tags: [homelab, kubernetes, monitoring, prometheus, grafana, alerting]
updated: 2026-02-12
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
| OTel Collector | v0.144.0 | monitoring |
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

## OTel Collector (Claude Code Telemetry)

| Setting | Value |
|---------|-------|
| Image | otel/opentelemetry-collector-contrib:0.144.0 |
| VIP | 10.10.30.22 (Cilium L2 LoadBalancer) |
| Ports | 4317 (gRPC), 4318 (HTTP), 8889 (Prometheus metrics) |
| Replicas | 1 |
| Memory limit | 600Mi (memory_limiter: 512 MiB) |

Receives OTLP metrics and logs from Claude Code clients, exports metrics to Prometheus and events to Loki.

### Client Configuration

Add to `~/.zshrc` on each machine:
```bash
export CLAUDE_CODE_ENABLE_TELEMETRY=1
export OTEL_METRICS_EXPORTER=otlp
export OTEL_LOGS_EXPORTER=otlp
export OTEL_EXPORTER_OTLP_PROTOCOL=grpc
export OTEL_EXPORTER_OTLP_ENDPOINT=http://10.10.30.22:4317
export OTEL_METRIC_EXPORT_INTERVAL=5000
export OTEL_LOGS_EXPORT_INTERVAL=5000
export OTEL_RESOURCE_ATTRIBUTES="machine.name=$HOST"
```

`$HOST` resolves to the machine hostname automatically.

### Query Claude Code Data

Metrics (Prometheus):
```promql
# Daily cost
sum(increase(claude_code_cost_usage_USD_total[24h]))

# Token usage by type
sum by (type) (increase(claude_code_token_usage_tokens_total[24h]))

# Session count (one-time counters use last_over_time, not increase)
count(count by (session_id) (last_over_time(claude_code_session_count_total[24h])))

# Total commits
sum(max by (session_id) (last_over_time(claude_code_commit_count_total[24h])))
```

Events (Loki):
```logql
# All Claude Code events
{service_name="claude-code"}

# API requests with cost
{service_name="claude-code"} | event_name="api_request"
```

## Grafana Dashboard Convention

Every new service should include a Grafana dashboard ConfigMap (`manifests/monitoring/<service>-dashboard-configmap.yaml`).

**Required label:** `grafana_dashboard: "1"` (auto-provisioned by Grafana sidecar).

**Standard sections:**

| Row | Panels | Description |
|-----|--------|-------------|
| Pod Status | UP/DOWN stat per workload, uptime, restarts | Use `kube_deployment_*` for Deployments, `kube_statefulset_*` for StatefulSets |
| Network Traffic | Throughput + packet rate | Split by interface if multiple exist (e.g., VPN vs pod network) |
| Resource Usage | CPU + Memory timeseries | Include dashed request/limit lines for right-sizing |

**Panel conventions:**
- Every panel must have a `description` field (renders as info icon tooltip on hover)
- Every row header must have a `description` explaining what the section shows
- Network panels use bidirectional charts: positive = Receive, negative = Transmit
- Resource panels show dashed lines: yellow = request (guaranteed), red = limit (throttle/OOM ceiling)
- Timezone: `Asia/Manila`
- Tags: `["<service>", "homelab"]`

**Example files:** `tailscale-dashboard-configmap.yaml`, `claude-dashboard-configmap.yaml`, `kube-vip-dashboard-configmap.yaml`

## Configuration Files

| File | Purpose |
|------|---------|
| helm/prometheus/values.yaml | Alertmanager config, routes |
| scripts/upgrade-prometheus.sh | Upgrade with 1Password secrets |
| manifests/monitoring/test-alert.yaml | Test PrometheusRule |
| manifests/monitoring/adguard-dns-probe.yaml | Blackbox DNS probe for AdGuard |
| manifests/monitoring/adguard-dns-alert.yaml | Alert on DNS probe failure |
| manifests/monitoring/uptime-kuma-probe.yaml | Blackbox HTTP probe for Uptime Kuma |
| manifests/monitoring/otel-collector-config.yaml | OTel Collector pipeline config |
| manifests/monitoring/otel-collector.yaml | OTel Collector Deployment + LoadBalancer Service |
| manifests/monitoring/otel-collector-servicemonitor.yaml | OTel Collector ServiceMonitor |
| manifests/monitoring/claude-dashboard-configmap.yaml | Claude Code Grafana dashboard |
| manifests/monitoring/claude-alerts.yaml | Claude Code cost alert rules |
| manifests/monitoring/kube-vip-monitoring.yaml | kube-vip Headless Service + Endpoints + ServiceMonitor |
| manifests/monitoring/kube-vip-alerts.yaml | kube-vip PrometheusRule (4 alerts) |
| manifests/monitoring/kube-vip-dashboard-configmap.yaml | kube-vip Grafana dashboard |
| helm/blackbox-exporter/values.yaml | Blackbox exporter config (dns_udp, http_2xx modules) |
| manifests/monitoring/ollama-probe.yaml | Blackbox HTTP probe for Ollama (60s interval) |
| manifests/monitoring/ollama-alerts.yaml | Ollama PrometheusRule (Down, MemoryHigh, HighRestarts) |
| manifests/monitoring/karakeep-probe.yaml | Blackbox HTTP probe for Karakeep /api/health |
| manifests/monitoring/karakeep-alerts.yaml | Karakeep PrometheusRule (Down, HighRestarts) |
| manifests/monitoring/tailscale-alerts.yaml | Tailscale PrometheusRule (ConnectorDown, OperatorDown) |
| manifests/monitoring/tailscale-dashboard-configmap.yaml | Tailscale Grafana dashboard (pod status, VPN/pod traffic, resources) |
| manifests/monitoring/jellyfin-dashboard-configmap.yaml | Jellyfin Media Server dashboard (pod status, GPU allocation, streaming traffic, resources) |
| manifests/monitoring/arr-stack-dashboard-configmap.yaml | ARR Media Stack overview dashboard (6 services: pod status, network, resources) |

## Upgrade Prometheus Stack

```bash
# Uses 1Password for secrets
./scripts/upgrade-prometheus.sh
```

## Related

- [[Secrets]] - 1Password paths for webhooks, SMTP
- [[UPS]] - UPS monitoring with nut-exporter
- [[Versions]] - Component versions
