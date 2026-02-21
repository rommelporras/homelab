---
tags: [homelab, kubernetes, monitoring, prometheus, grafana, alerting]
updated: 2026-02-21
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
| smartctl-exporter | v0.14.0 | monitoring |
| OTel Collector | v0.144.0 | monitoring |
| version-checker | v0.10.0 | monitoring |
| Nova CronJob | v3.11.10 | monitoring |
| tdarr-exporter | latest | arr-stack |
| qbittorrent-exporter | latest | arr-stack |
| Uptime Kuma | v2.0.2 | uptime-kuma |

## Access

| Service | URL |
|---------|-----|
| Grafana | https://grafana.k8s.rommelporras.com |
| Prometheus | https://prometheus.k8s.rommelporras.com |
| Alertmanager | https://alertmanager.k8s.rommelporras.com |
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
| discord-status | Discord #status | Warning |
| healthchecks-heartbeat | healthchecks.io ping | Watchdog (1m) |
| null | Nowhere | Silenced alerts |

### Alert Routing

| Severity | Discord | Email |
|----------|---------|-------|
| Critical | #incidents | 3 recipients |
| Warning | #status | None |
| Info | (silenced) | None |

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

**Required labels:**
- `grafana_dashboard: "1"` — auto-provisioned by Grafana sidecar
- `grafana_folder: "Homelab"` annotation — all dashboards appear in the Homelab folder (enabled via `folderAnnotation` in helm/prometheus/values.yaml)

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

## Version Tracking

Three-tool approach covering container images, Helm charts, and Kubernetes version:

| Tool | Scope | Output | Schedule |
|------|-------|--------|----------|
| version-checker | Container images + K8s version | Prometheus metrics → Grafana dashboard + alerts | Continuous (1h scrape) |
| Nova CronJob | Helm chart drift | Discord #versions embed | Weekly (Sunday 08:00 PHT) |
| Renovate Bot | Container image tags in manifests | GitHub PRs (dependency dashboard approval) | Continuous |

**version-checker** runs as a Deployment in `monitoring` with `--test-all-containers` (scans all pods). LinuxServer.io images use `match-regex` annotations for non-standard tag formats. Alerts fire after 7d outdated (containers) or 14d (K8s version).

**Nova CronJob** uses an init container to copy the Nova binary from the official image to a shared emptyDir. The main container (Alpine) installs curl+jq, runs Nova, parses JSON, builds Discord embeds, and sends via webhook. Runs as root (apk needs it).

**Renovate Bot** is a GitHub App with `dependencyDashboardApproval: true` — PRs require manual approval via the Dependency Dashboard issue. Major bumps get separate PRs; minor/patch are grouped weekly.

## Configuration Files

> All monitoring manifests are organized into subdirectories under `manifests/monitoring/`.

### Helm Values

| File | Purpose |
|------|---------|
| `helm/prometheus/values.yaml` | Alertmanager config, routes, Grafana folderAnnotation |
| `helm/blackbox-exporter/values.yaml` | Blackbox exporter modules (dns_udp, http_2xx) |
| `helm/smartctl-exporter/values.yaml` | smartctl-exporter DaemonSet (NVMe S.M.A.R.T., /dev/nvme0, 60s interval) |
| `scripts/upgrade-prometheus.sh` | Helm upgrade with 1Password secrets |
| `renovate.json` | Renovate Bot configuration (image update PRs) |

### Exporters (`manifests/monitoring/exporters/`)

| File | Purpose |
|------|---------|
| `kube-vip-monitoring.yaml` | kube-vip Headless Service + Endpoints (enables Prometheus scraping of DaemonSet pods) |
| `nut-exporter.yaml` | NUT UPS exporter Deployment + Service |

> ARR-stack exporters live in their service directory (they target `arr-stack` namespace):
> - `manifests/arr-stack/tdarr/tdarr-exporter.yaml` — Tdarr stats API → Prometheus metrics
> - `manifests/arr-stack/qbittorrent/qbittorrent-exporter.yaml` — qBittorrent WebUI API → Prometheus metrics

### OTel Collector (`manifests/monitoring/otel/`)

| File | Purpose |
|------|---------|
| `otel-collector.yaml` | OTel Collector Deployment + LoadBalancer Service (VIP 10.10.30.22) |
| `otel-collector-config.yaml` | OTel Collector pipeline config (OTLP→Prometheus + Loki) |
| `otel-collector-servicemonitor.yaml` | OTel Collector ServiceMonitor |

### Grafana Routes & Datasources (`manifests/monitoring/grafana/`)

| File | Purpose |
|------|---------|
| `grafana-httproute.yaml` | Grafana HTTPRoute (grafana.k8s.rommelporras.com) |
| `alertmanager-httproute.yaml` | Alertmanager HTTPRoute (internal) |
| `prometheus-httproute.yaml` | Prometheus HTTPRoute (internal) |
| `loki-datasource.yaml` | Loki datasource ConfigMap |

### Blackbox Probes (`manifests/monitoring/probes/`)

| File | Service | Target | Interval |
|------|---------|--------|----------|
| `adguard-dns-probe.yaml` | AdGuard | DNS UDP probe (10.10.30.53:53) | 30s |
| `uptime-kuma-probe.yaml` | Uptime Kuma | HTTP (uptime-kuma.uptime-kuma.svc:3001) | 60s |
| `ollama-probe.yaml` | Ollama | HTTP (ollama.ai.svc:11434) | 60s |
| `karakeep-probe.yaml` | Karakeep | HTTP /api/health (karakeep.karakeep.svc:3000) | 60s |
| `jellyfin-probe.yaml` | Jellyfin | HTTP (jellyfin.arr-stack.svc:8096) | 60s |
| `ghost-probe.yaml` | Ghost | HTTP (ghost.ghost-prod.svc:2368) | 60s |
| `invoicetron-probe.yaml` | Invoicetron | HTTP /api/health (invoicetron.invoicetron-prod.svc:3000) | 60s |
| `portfolio-probe.yaml` | Portfolio | HTTP /health (portfolio.portfolio-prod.svc:80) | 60s |
| `seerr-probe.yaml` | Seerr | HTTP (seerr.arr-stack.svc:5055) | 60s |
| `tdarr-probe.yaml` | Tdarr | HTTP (tdarr.arr-stack.svc:8265) | 60s |
| `byparr-probe.yaml` | Byparr | HTTP (byparr.arr-stack.svc:8191) | 60s |
| `bazarr-probe.yaml` | Bazarr | HTTP (bazarr.arr-stack.svc:6767) | 60s |

All probes use the `http_2xx` module (Blackbox Exporter at `blackbox-exporter-prometheus-blackbox-exporter.monitoring.svc:9115`).

### ServiceMonitors (`manifests/monitoring/servicemonitors/`)

| File | Target | Namespace | Interval |
|------|--------|-----------|----------|
| `loki-servicemonitor.yaml` | Loki | monitoring | 60s |
| `alloy-servicemonitor.yaml` | Grafana Alloy | monitoring | 60s |
| `otel-collector-servicemonitor.yaml` | OTel Collector | monitoring | 60s |
| `version-checker-servicemonitor.yaml` | version-checker | monitoring | 1h |
| `longhorn-servicemonitor.yaml` | Longhorn manager (port 9500) | longhorn-system | 60s |
| `certmanager-servicemonitor.yaml` | cert-manager (port 9402) | cert-manager | 300s |
| `tdarr-servicemonitor.yaml` | tdarr-exporter (:9090) | arr-stack | 60s |
| `qbittorrent-servicemonitor.yaml` | qbittorrent-exporter (:8000) | arr-stack | 30s |

All ServiceMonitors have `release: prometheus` + `app.kubernetes.io/part-of: kube-prometheus-stack` labels for Prometheus Operator discovery.

### Alert Rules (`manifests/monitoring/alerts/`)

| File | Alerts | Phase |
|------|--------|-------|
| `test-alert.yaml` | AlwaysFiring (manual testing only) | v0.5.0 |
| `logging-alerts.yaml` | LokiDown, LokiIngestionStopped, LokiHighErrorRate, AlloyNotOnAllNodes, AlloyNotSendingLogs, AlloyHighMemory | v0.5.0 |
| `ups-alerts.yaml` | UPSOnBattery, UPSLowBattery, UPSBatteryCritical, UPSBatteryWarning, UPSHighLoad, UPSExporterDown, UPSOffline, UPSBackOnline | v0.4.0 |
| `adguard-dns-alert.yaml` | AdGuardDNSUnreachable (DNS probe failure) | v0.9.0 |
| `claude-alerts.yaml` | ClaudeCodeHighDailySpend, ClaudeCodeCriticalDailySpend, ClaudeCodeNoActivity, OTelCollectorDown | v0.15.0 |
| `kube-vip-alerts.yaml` | KubeVipInstanceDown, KubeVipAllDown, KubeVipLeaseStale, KubeVipHighRestarts | v0.19.0 |
| `ollama-alerts.yaml` | OllamaDown, OllamaMemoryHigh, OllamaHighRestarts | v0.20.0 |
| `karakeep-alerts.yaml` | KarakeepDown, KarakeepHighRestarts | v0.21.0 |
| `tailscale-alerts.yaml` | TailscaleConnectorDown, TailscaleOperatorDown | v0.22.0 |
| `arr-alerts.yaml` | ArrAppDown, SonarrQueueStalled, RadarrQueueStalled, NetworkInterfaceSaturated, NetworkInterfaceCritical, JellyfinDown, SeerrDown, TdarrDown, ByparrDown, ArrQueueWarning, ArrQueueError, BazarrDown, JellyfinHighMemory, TdarrTranscodeErrors, TdarrTranscodeErrorsBurst, TdarrHealthCheckErrors, TdarrHealthCheckErrorsBurst, QBittorrentStalledDownloads | v0.25.0–v0.27.0 |
| `version-checker-alerts.yaml` | ContainerImageOutdated, KubernetesVersionOutdated, VersionCheckerDown | v0.26.0 |
| `uptime-kuma-alerts.yaml` | UptimeKumaDown (3m, warning) | v0.27.0 |
| `ghost-alerts.yaml` | GhostDown (5m, warning) | v0.27.0 |
| `invoicetron-alerts.yaml` | InvoicetronDown (5m, warning) | v0.27.0 |
| `portfolio-alerts.yaml` | PortfolioDown (5m, warning) | v0.27.0 |
| `storage-alerts.yaml` | LonghornVolumeDegraded (warning), LonghornVolumeReplicaFailed (critical), NVMeMediaErrors (critical), NVMeSpareWarning (warning), NVMeWearHigh (warning), NVMeTemperatureHigh (warning) | v0.27.0 |
| `cert-alerts.yaml` | CertificateExpiringSoon (30d, warning), CertificateExpiryCritical (7d, critical), CertificateNotReady (critical) | v0.27.0 |
| `cloudflare-alerts.yaml` | CloudflareTunnelDegraded (warning), CloudflareTunnelDown (critical) | v0.27.0 |
| `apiserver-alerts.yaml` | KubeApiserverFrequentRestarts (>5 restarts/24h, warning) | v0.27.0 |
| `service-health-alerts.yaml` | ServiceHighResponseTime (>5s for 5m, warning) | v0.27.0 |
| `cpu-throttling-alerts.yaml` | CPUThrottlingHigh (>50%, arr-stack excluded, info) | v0.27.0 |
| `node-alerts.yaml` | NodeMemoryMajorPagesFaults (>2000/s + <15% mem available, warning) | v0.27.0 |

**Severity routing:**
- `critical` → Discord #incidents + Email (3 recipients)
- `warning` → Discord #status only
- `info` → null (silenced — visible in Alertmanager UI only)

### Grafana Dashboards (`manifests/monitoring/dashboards/`)

All dashboards are auto-provisioned via Grafana sidecar. All have `grafana_folder: "Homelab"` annotation.

| File | Dashboard | Key Panels |
|------|-----------|------------|
| `ups-dashboard-configmap.yaml` | UPS Monitoring | Battery status, load, runtime, events |
| `claude-dashboard-configmap.yaml` | Claude Code | Daily cost, token usage, session count, commits |
| `kube-vip-dashboard-configmap.yaml` | kube-vip HA | Instances up/down, leader election, restarts, network |
| `tailscale-dashboard-configmap.yaml` | Tailscale VPN | Pod status, VPN/pod traffic, resource usage |
| `jellyfin-dashboard-configmap.yaml` | Jellyfin | Pod status, GPU utilization, streaming traffic, resources |
| `network-dashboard-configmap.yaml` | Network Traffic | Per-node NIC throughput (cp1/cp2/cp3), saturation analysis |
| `arr-stack-dashboard-configmap.yaml` | ARR Media Stack | 8 rows: Pod Status (core + companions), Tdarr Library Stats, qBittorrent Activity, Network, Resources, Restarts, Recent Activity (Loki logs) |
| `scraparr-dashboard-configmap.yaml` | Scraparr ARR Metrics | Library sizes, queue health, indexer stats, disk usage |
| `longhorn-dashboard-configmap.yaml` | Longhorn Storage | NVMe S.M.A.R.T. (6 stat panels), TBW history, write rate, disk usage, volume I/O |
| `version-checker-dashboard-configmap.yaml` | Version Checker | Outdated containers, K8s version drift |
| `service-health-dashboard-configmap.yaml` | Service Health | 12-service UP/DOWN grid, uptime history, response times |

### Version Checker (`manifests/monitoring/version-checker/`)

| File | Purpose |
|------|---------|
| `version-checker-deployment.yaml` | version-checker Deployment + Service |
| `version-checker-rbac.yaml` | RBAC (ClusterRole, ClusterRoleBinding — pods + apps read) |
| `version-check-cronjob.yaml` | Nova CronJob (weekly Helm drift → Discord #versions) |
| `version-check-script.yaml` | Nova CronJob script ConfigMap |
| `version-check-rbac.yaml` | Nova CronJob RBAC (secrets read for Helm) |

## Upgrade Prometheus Stack

```bash
# Uses 1Password for secrets
./scripts/upgrade-prometheus.sh
```

## Related

- [[Secrets]] - 1Password paths for webhooks, SMTP
- [[UPS]] - UPS monitoring with nut-exporter
- [[Versions]] - Component versions
