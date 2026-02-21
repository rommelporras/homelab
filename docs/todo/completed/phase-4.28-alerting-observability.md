# Phase 4.28: Alerting & Observability Improvements

> **Status:** Complete (v0.27.0 released)
> **Target:** v0.27.0
> **Prerequisite:** None (monitoring stack running since Phase 3.9)
> **Priority:** Medium (operational safety — not urgent, cluster healthy as of Feb 2026)
> **DevOps Topics:** Observability, capacity planning, proactive alerting, ServiceMonitor, Blackbox probes
> **CKA Topics:** PrometheusRule, ServiceMonitor, Probe, PersistentVolumeClaim metrics, certificate lifecycle

> **Purpose:** Fix broken alerts, add missing coverage for public-facing services, close alerting gaps for Longhorn volume health, TLS certificate expiry, and Cloudflare Tunnel connectivity. Remove redundant custom alerts already covered by kube-prometheus-stack defaults.
>
> **Why:** A full audit of the cluster's monitoring revealed three categories of issues:
>
> **Broken alerts (silently failing):**
> - **JellyfinDown** — alert references `probe_success{job="jellyfin"}` but no Blackbox Probe exists. Alert will never fire.
> - **AdGuardDNSUnreachable** — uses wrong labels (`prometheus: prometheus, role: alert-rules` instead of `release: prometheus`). May not be discovered by Prometheus Operator.
> - **Uptime Kuma** — Blackbox probe exists and scrapes `probe_success{job="uptime-kuma"}` but no PrometheusRule acts on it. The irony: the uptime monitoring tool has no uptime monitoring.
>
> **Public services with zero monitoring:**
> - **Ghost (prod)** — public blog via Cloudflare Tunnel, no probe, no alert, no dashboard
> - **Invoicetron** — public app via Cloudflare Tunnel, no probe, no alert
> - **Portfolio** — public site via HTTPRoute, no probe, no alert
>
> **Infrastructure gaps that defaults can't cover:**
> - **Longhorn volume health** — no metrics scraped, no alerts for degraded/faulted volumes
> - **TLS certificate expiry** — no metrics scraped, cert-manager renewal failures are silent
> - **Cloudflare Tunnel** — metrics ARE scraped but no alerts exist (public access can die silently)
> - **API server restart frequency** — kube-apiserver-k8s-cp3 has 30 restarts in 34 days (~1/day). Liveness probe kills the API server when etcd is briefly unreachable, causing kube-vip to lose its VIP lease and drop connectivity for ~2 min. Discovered Feb 19 during monitoring work. `KubeAPIDown` fires only after full downtime; does not catch frequent-but-brief restart patterns.
>
> **ARR services with zero monitoring:**
> - **Seerr** — user-facing request portal, no probe or alert
> - **Tdarr** — GPU transcoding service, no probe or alert
> - **Byparr** — Prowlarr's Cloudflare bypass proxy, no probe or alert
>
> Additionally, the custom `LokiStorageLow` alert is redundant with the default `KubePersistentVolumeFillingUp` and should be removed.

---

## Alerting Audit Summary (Feb 2026)

### What's Already Covered (kube-prometheus-stack defaults)

The chart provides 177+ alerts. These categories are fully covered — **no custom alerts needed:**

| Category | Key Alerts |
|----------|------------|
| PVC capacity | `KubePersistentVolumeFillingUp` (warning + critical), `KubePersistentVolumeErrors` |
| Node disk | `NodeFilesystemSpaceFillingUp`, `NodeFilesystemAlmostOutOfSpace` |
| Node health | `NodeCPUHighUsage`, `NodeMemoryHighUtilization`, `NodeNetworkReceiveErrs` |
| Pod lifecycle | `KubePodCrashLooping`, `KubePodNotReady`, `KubeContainerWaiting` |
| Deployments | `KubeDeploymentReplicasMismatch`, `KubeDeploymentRolloutStuck` |
| StatefulSets | `KubeStatefulSetReplicasMismatch`, `KubeStatefulSetUpdateNotRolledOut` |
| Kubelet certs | `KubeletClientCertificateExpiration`, `KubeletServerCertificateExpiration` |
| API server | `KubeAPIDown`, `KubeAPIErrorBudgetBurn` |
| Prometheus | `PrometheusBadConfig`, `PrometheusNotIngestingSamples` |
| Alertmanager | `AlertmanagerFailedToSendAlerts`, `AlertmanagerDown` |

### What's Custom (our manifests/monitoring/ rules)

| File | Alerts | Status |
|------|--------|--------|
| `logging-alerts.yaml` | LokiDown, LokiIngestionStopped, LokiHighErrorRate, AlloyNotOnAllNodes, AlloyNotSendingLogs, AlloyHighMemory | **Fixed** — LokiStorageLow removed |
| `ups-alerts.yaml` | UPSOnBattery, UPSLowBattery, UPSBatteryCritical, UPSBatteryWarning, UPSHighLoad, UPSExporterDown, UPSOffline, UPSBackOnline | Good |
| `kube-vip-alerts.yaml` | KubeVipInstanceDown, KubeVipAllDown, KubeVipLeaseStale, KubeVipHighRestarts | Good |
| `claude-alerts.yaml` | ClaudeCodeHighDailySpend, ClaudeCodeCriticalDailySpend, ClaudeCodeNoActivity, OTelCollectorDown | Good |
| `ollama-alerts.yaml` | OllamaDown, OllamaMemoryHigh, OllamaHighRestarts | Good |
| `karakeep-alerts.yaml` | KarakeepDown, KarakeepHighRestarts | Good |
| `adguard-dns-alert.yaml` | AdGuardDNSUnreachable | **Fixed** — labels corrected (`release: prometheus`) |
| `arr-alerts.yaml` | ArrAppDown, SonarrQueueStalled, RadarrQueueStalled, NetworkInterfaceSaturated, NetworkInterfaceCritical, JellyfinDown, SeerrDown, TdarrDown, ByparrDown | **Fixed** — JellyfinDown probe created; SeerrDown, TdarrDown, ByparrDown added |
| `tailscale-alerts.yaml` | TailscaleConnectorDown, TailscaleOperatorDown | Good |
| `version-checker-alerts.yaml` | ContainerImageOutdated, KubernetesVersionOutdated, VersionCheckerDown | Good |
| `uptime-kuma-probe.yaml` | (Probe only — no PrometheusRule) | **Fixed** — `uptime-kuma-alerts.yaml` created |

### Gaps Being Addressed

| Gap | Issue | Fix |
|-----|-------|-----|
| **JellyfinDown broken** | Alert exists but no Blackbox Probe — will never fire | Create `jellyfin-probe.yaml` |
| **AdGuard wrong labels** | Uses `prometheus: prometheus` instead of `release: prometheus` | Fix labels in `adguard-dns-alert.yaml` |
| **Uptime Kuma no alert** | Probe exists but no PrometheusRule | Create `uptime-kuma-alerts.yaml` |
| **Ghost prod unmonitored** | Public blog with zero monitoring | Add probe + alert |
| **Invoicetron unmonitored** | Public app with zero monitoring | Add probe + alert |
| **Portfolio unmonitored** | Public site with zero monitoring | Add probe + alert |
| **Seerr unmonitored** | User-facing ARR request portal with zero monitoring | Add probe + alert in `arr-alerts.yaml` |
| **Tdarr unmonitored** | GPU transcoding service with zero monitoring | Add probe + alert in `arr-alerts.yaml` |
| **Byparr unmonitored** | Prowlarr's Cloudflare bypass with zero monitoring | Add probe + alert in `arr-alerts.yaml` |
| **Longhorn volume health** | No ServiceMonitor — metrics not scraped at all | Add ServiceMonitor + 2 alerts |
| **cert-manager certificates** | No ServiceMonitor — renewal failures are silent | Add ServiceMonitor + 3 alerts |
| **Cloudflare Tunnel** | ServiceMonitor exists but zero alerts defined | Add 2 alerts |
| **Redundant LokiStorageLow** | Duplicates default `KubePersistentVolumeFillingUp` | Remove |

---

## Cluster Storage Snapshot (Feb 2026)

Captured during planning to establish baseline.

### PVC Usage

| % Used | PVC | Capacity | Status |
|--------|-----|----------|--------|
| **73.8%** | **gitlab/gitlab-minio** | **10Gi** | Watch — may need resize to 20Gi |
| **55.8%** | **ai/ollama-models** | **10Gi** | Stable if no new models added |
| 27.8% | monitoring/prometheus | 50Gi | Fine |
| 24.5% | monitoring/loki | 10Gi | Fine |
| <20% | All others (18 PVCs) | 1-50Gi | Fine |

### Node NVMe (Longhorn Backend)

| Node | Used | Free |
|------|------|------|
| k8s-cp1 | 98G / 465G (21%) | 343G free |
| k8s-cp2 | 103G / 465G (22%) | 338G free |
| k8s-cp3 | 98G / 465G (21%) | 344G free |

No urgency — all nodes have ~340G free.

---

## Alert Design

### Severity & Routing

Existing Alertmanager routing handles everything — no config changes needed:

| Severity | Discord Channel | Email | Receiver |
|----------|----------------|-------|----------|
| **critical** | #incidents | Yes (3 addresses) | `discord-incidents-email` |
| **warning** | #status | No | `discord-status` |

### New Alert Rules (20 total)

#### Service Health — Blackbox Probes (7 alerts)

| Alert | Target | Probe Job | Duration | Severity | Route |
|-------|--------|-----------|----------|----------|-------|
| `GhostDown` | `ghost.ghost-prod.svc:2368` | ghost | 5m | **warning** | #status only |
| `InvoicetronDown` | `invoicetron.invoicetron-prod.svc:3000/api/health` | invoicetron | 5m | **warning** | #status only |
| `PortfolioDown` | `portfolio.portfolio-prod.svc:80/health` | portfolio | 5m | **warning** | #status only |
| `SeerrDown` | `seerr.arr-stack.svc:5055` | seerr | 5m | **warning** | #status only |
| `TdarrDown` | `tdarr.arr-stack.svc:8265` | tdarr | 5m | **warning** | #status only |
| `ByparrDown` | `byparr.arr-stack.svc:8191` | byparr | 5m | **warning** | #status only |
| `UptimeKumaDown` | (existing probe, job=`uptime-kuma`) | uptime-kuma | 3m | **warning** | #status only |

**Why warning, not critical?** These are single-service outages, not data-loss scenarios. The `CloudflareTunnelDown` alert (critical) already covers the case where ALL public access dies. Individual service failures are operational awareness, not emergencies.

#### Longhorn Storage (2 alerts)

| Alert | Threshold | Duration | Severity | Route |
|-------|-----------|----------|----------|-------|
| `LonghornVolumeDegraded` | robustness = degraded | 10m | **warning** | #status only |
| `LonghornVolumeReplicaFailed` | robustness = faulted | 5m | **critical** | #incidents + email |

**Why not PVC/node storage alerts?** Already covered by defaults:
- `KubePersistentVolumeFillingUp` handles all PVCs (warning at <15%, critical at <3%)
- `NodeFilesystemSpaceFillingUp` handles node disk (predictive — fires if filling in 24h/4h)

#### cert-manager Certificates (3 alerts)

| Alert | Threshold | Duration | Severity | Route |
|-------|-----------|----------|----------|-------|
| `CertificateExpiringSoon` | <30 days to expiry | 1h | **warning** | #status only |
| `CertificateExpiryCritical` | <7 days to expiry | 1h | **critical** | #incidents + email |
| `CertificateNotReady` | ready condition = false | 15m | **critical** | #incidents + email |

**Certificates monitored:** `wildcard-k8s-tls`, `wildcard-dev-k8s-tls`, `wildcard-stg-k8s-tls` (Let's Encrypt, 90-day cycle, auto-renewed by cert-manager).

#### Cloudflare Tunnel (2 alerts)

| Alert | Threshold | Duration | Severity | Route |
|-------|-----------|----------|----------|-------|
| `CloudflareTunnelDegraded` | <2 healthy pods | 5m | **warning** | #status only |
| `CloudflareTunnelDown` | 0 healthy pods | 2m | **critical** | #incidents + email |

**Current setup:** 2-replica deployment with pod anti-affinity. ServiceMonitor already exists (job=`cloudflared`).

#### API Server Restart Frequency (1 alert)

| Alert | Threshold | Duration | Severity | Route |
|-------|-----------|----------|----------|-------|
| `KubeApiserverFrequentRestarts` | >5 restarts in 24h on any node | 0m | **warning** | #status only |

**Why:** `KubeAPIDown` fires only after full downtime; does not catch frequent-but-brief restart patterns that drop the kube-vip VIP for ~2 minutes each time. Discovered Feb 19: cp3 had 30 restarts in 34 days (~1/day average). Each restart causes kube-vip to lose its lease renewal and drop connectivity.

### Bug Fixes (3 existing alerts)

| Fix | File | Change |
|-----|------|--------|
| Create Jellyfin Blackbox Probe | `jellyfin-probe.yaml` (new) | Provides `probe_success{job="jellyfin"}` that existing `JellyfinDown` alert depends on |
| Fix AdGuard alert labels | `adguard-dns-alert.yaml` (modify) | Change `prometheus: prometheus` + `role: alert-rules` → `release: prometheus` + `app.kubernetes.io/part-of: kube-prometheus-stack` |
| Add Uptime Kuma alert | `uptime-kuma-alerts.yaml` (new) | PrometheusRule acting on existing `probe_success{job="uptime-kuma"}` |

### Cleanup

| Action | File | Reason |
|--------|------|--------|
| Remove `LokiStorageLow` | `logging-alerts.yaml` | Redundant with default `KubePersistentVolumeFillingUp` |

---

## PromQL Expressions

### Service Health Probes

```promql
# All probe-based alerts follow the same pattern:
probe_success{job="<service>"} == 0
# Each Blackbox Probe creates this metric automatically
# for: 3-5m prevents alerting on transient pod restarts
```

### Longhorn

```promql
# LonghornVolumeDegraded — reduced replicas but still functional
longhorn_volume_robustness == 2
# Robustness values: 0=unknown, 1=healthy, 2=degraded, 3=faulted
# Verify actual values during implementation (Longhorn docs vs metric)

# LonghornVolumeReplicaFailed — no healthy replicas, data at risk
longhorn_volume_robustness == 3
```

### cert-manager

```promql
# CertificateExpiringSoon — less than 30 days to expiry
(certmanager_certificate_expiration_timestamp_seconds - time()) < 30 * 24 * 3600
# Only fires for certificates managed by cert-manager

# CertificateExpiryCritical — less than 7 days to expiry
(certmanager_certificate_expiration_timestamp_seconds - time()) < 7 * 24 * 3600

# CertificateNotReady — certificate not in Ready state
certmanager_certificate_ready_status{condition="True"} != 1
# Alternative if metric structure differs:
# certmanager_certificate_ready_status{condition="False"} == 1
```

### Cloudflare Tunnel

```promql
# CloudflareTunnelDegraded — not all replicas healthy (but at least 1)
sum(up{job="cloudflared"}) < 2

# CloudflareTunnelDown — no healthy replicas
sum(up{job="cloudflared"}) == 0
# Also catches: absent(up{job="cloudflared"})
```

---

## Changes

### Files Created (29 total)

| File | Type | Purpose | Status |
|------|------|---------|--------|
| `manifests/monitoring/probes/jellyfin-probe.yaml` | Probe | Blackbox HTTP probe for Jellyfin (fixes broken JellyfinDown alert) | ✅ |
| `manifests/monitoring/probes/ghost-probe.yaml` | Probe | Blackbox HTTP probe for Ghost prod | ✅ |
| `manifests/monitoring/alerts/ghost-alerts.yaml` | PrometheusRule | GhostDown alert | ✅ |
| `manifests/monitoring/probes/invoicetron-probe.yaml` | Probe | Blackbox HTTP probe for Invoicetron prod | ✅ |
| `manifests/monitoring/alerts/invoicetron-alerts.yaml` | PrometheusRule | InvoicetronDown alert | ✅ |
| `manifests/monitoring/probes/portfolio-probe.yaml` | Probe | Blackbox HTTP probe for Portfolio prod | ✅ |
| `manifests/monitoring/alerts/portfolio-alerts.yaml` | PrometheusRule | PortfolioDown alert | ✅ |
| `manifests/monitoring/probes/seerr-probe.yaml` | Probe | Blackbox HTTP probe for Seerr | ✅ |
| `manifests/monitoring/probes/tdarr-probe.yaml` | Probe | Blackbox HTTP probe for Tdarr | ✅ |
| `manifests/monitoring/probes/byparr-probe.yaml` | Probe | Blackbox HTTP probe for Byparr | ✅ |
| `manifests/monitoring/alerts/uptime-kuma-alerts.yaml` | PrometheusRule | UptimeKumaDown alert (uses existing probe) | ✅ |
| `manifests/monitoring/servicemonitors/longhorn-servicemonitor.yaml` | ServiceMonitor | Scrape Longhorn manager metrics (port 9500) | ✅ |
| `manifests/monitoring/alerts/storage-alerts.yaml` | PrometheusRule | Longhorn volume degraded/faulted alerts + NVMe SMART alerts (NVMeMediaErrors, NVMeSpareWarning, NVMeWearHigh) | ✅ |
| `manifests/monitoring/servicemonitors/certmanager-servicemonitor.yaml` | ServiceMonitor | Scrape cert-manager metrics (port 9402) | ✅ |
| `manifests/monitoring/alerts/cert-alerts.yaml` | PrometheusRule | Certificate expiry + not-ready alerts | ✅ |
| `manifests/monitoring/alerts/cloudflare-alerts.yaml` | PrometheusRule | Tunnel degraded/down alerts | ✅ |
| `manifests/monitoring/dashboards/service-health-dashboard-configmap.yaml` | ConfigMap | Grafana Service Health dashboard (12 UP/DOWN stat panels, uptime history, response time) | ✅ |
| `manifests/monitoring/alerts/apiserver-alerts.yaml` | PrometheusRule | KubeApiserverFrequentRestarts alert (>5 restarts/24h) | ✅ |
| `helm/smartctl-exporter/values.yaml` | Helm values | smartctl-exporter DaemonSet on all 3 nodes, pinned to /dev/nvme0, ServiceMonitor enabled | ✅ |
| `manifests/arr-stack/tdarr/tdarr-exporter.yaml` | Deployment | tdarr-exporter Deployment + Service (scrapes Tdarr stats API, exposes Prometheus metrics on :9090) | ✅ |
| `manifests/arr-stack/qbittorrent/qbittorrent-exporter.yaml` | Deployment | qbittorrent-exporter Deployment + Service (scrapes qBittorrent WebUI API, exposes Prometheus metrics on :8000) | ✅ |
| `manifests/monitoring/servicemonitors/tdarr-servicemonitor.yaml` | ServiceMonitor | Scrape tdarr-exporter metrics (60s interval) | ✅ |
| `manifests/monitoring/servicemonitors/qbittorrent-servicemonitor.yaml` | ServiceMonitor | Scrape qbittorrent-exporter metrics (30s interval) | ✅ |
| `manifests/arr-stack/stall-resolver/configmap.yaml` | ConfigMap | ARR stall resolver script (blocklist dead release, switch to Any quality, re-search) | ✅ |
| `manifests/arr-stack/stall-resolver/cronjob.yaml` | CronJob | Runs every 30 min, resolves stalled Sonarr/Radarr downloads automatically | ✅ |
| `manifests/monitoring/grafana/prometheus-httproute.yaml` | HTTPRoute | Expose Prometheus UI at prometheus.k8s.rommelporras.com | ✅ |
| `manifests/monitoring/grafana/alertmanager-httproute.yaml` | HTTPRoute | Expose Alertmanager UI at alertmanager.k8s.rommelporras.com | ✅ |
| `manifests/monitoring/probes/bazarr-probe.yaml` | Probe | Blackbox HTTP probe for Bazarr subtitle downloader (port 6767), job=`bazarr`, interval=60s | ✅ |
| `manifests/monitoring/alerts/service-health-alerts.yaml` | PrometheusRule | `ServiceHighResponseTime` alert (>5s for 5m on public-facing services: ghost, invoicetron, portfolio, jellyfin, seerr, karakeep) | ✅ |

### Files Modified (20 total)

| File | Change | Status |
|------|--------|--------|
| `manifests/monitoring/alerts/adguard-dns-alert.yaml` | Fixed labels: `prometheus: prometheus` + `role: alert-rules` → `release: prometheus` + `app.kubernetes.io/part-of: kube-prometheus-stack` | ✅ |
| `manifests/monitoring/alerts/arr-alerts.yaml` | Added SeerrDown, TdarrDown, ByparrDown alerts | ✅ |
| `manifests/monitoring/alerts/logging-alerts.yaml` | Removed `LokiStorageLow` rule (redundant with default `KubePersistentVolumeFillingUp`) | ✅ |
| `helm/prometheus/values.yaml` | Enable Grafana sidecar folderAnnotation for auto-provisioned dashboard folders | ✅ |
| `manifests/monitoring/dashboards/arr-stack-dashboard-configmap.yaml` | Added Byparr companion pod status panel; fixed Container Restarts; Homelab folder annotation; added Tdarr Library Stats + qBittorrent Download Activity rows (3rd row); added Recent Activity Loki log panels; fixed Configarr textMode (`value_and_name` → `value`); reordered rows to push Network/Resource Usage/Restarts/Activity down | ✅ |
| `manifests/monitoring/dashboards/longhorn-dashboard-configmap.yaml` | Full NVMe Health section (SMART status, temp, wear, spare, TBW history + write rate); NVMe dashboard redesign (table → stat panels, consolidated layout, Drive Reference section) | ✅ |
| `manifests/monitoring/dashboards/network-dashboard-configmap.yaml` | Per-node queries (cp1/cp2/cp3), stale series dedup, layout restructure, per-node color overrides, multi-series tooltip + right-side legend | ✅ |
| `manifests/monitoring/dashboards/scraparr-dashboard-configmap.yaml` | Wider service health panels, fixed Prowlarr indexers query, restructured disk usage panels | ✅ |
| `manifests/monitoring/dashboards/kube-vip-dashboard-configmap.yaml` | Complete rewrite: remove non-existent Lease Transitions panel, fix all metrics/thresholds/descriptions, switch Container Restarts to raw lifetime counter, add `hostNetwork: true` awareness note, standardize layout | ✅ |
| `manifests/monitoring/dashboards/jellyfin-dashboard-configmap.yaml` | Standardize metadata, JSON formatting, Homelab folder annotation | ✅ |
| `manifests/monitoring/dashboards/tailscale-dashboard-configmap.yaml` | Standardize metadata, JSON formatting, Homelab folder annotation | ✅ |
| `manifests/monitoring/dashboards/claude-dashboard-configmap.yaml` | Simplify tags, Homelab folder annotation | ✅ |
| `manifests/monitoring/dashboards/ups-dashboard-configmap.yaml` | Add tags, Homelab folder annotation | ✅ |
| `manifests/monitoring/dashboards/version-checker-dashboard-configmap.yaml` | Add tags, Homelab folder annotation | ✅ |
| `manifests/monitoring/dashboards/service-health-dashboard-configmap.yaml` | Improvements to existing dashboard | ✅ |
| `manifests/monitoring/alerts/arr-alerts.yaml` (2nd pass) | Added ArrQueueWarning (warning, 60m stall) and ArrQueueError (critical, 15m) alongside stall resolver | ✅ |
| `manifests/home/homepage/` | Added Prometheus targets count and Alertmanager firing count widgets | ✅ |
| `/etc/kubernetes/manifests/` (all 3 nodes) | Fixed etcd/kube-scheduler/kube-controller-manager bind addresses to 0.0.0.0 so Prometheus can scrape | ✅ |
| `manifests/monitoring/alerts/claude-alerts.yaml` | Fixed `ClaudeCodeNoActivity` timezone bug: `hour()>=17 and hour()<=18` → `hour()>=9 and hour()<=11` (was firing at 1-2am Manila instead of 5-7pm) | ✅ |
| `manifests/monitoring/alerts/arr-alerts.yaml` (3rd pass) | Added JellyfinHighMemory (warning, 3.5Gi, for:10m), BazarrDown (warning, for:5m), TdarrTranscodeErrors/Burst (warning+critical), TdarrHealthCheckErrors/Burst (warning+critical), QBittorrentStalledDownloads (warning, for:45m) | ✅ |

---

## ServiceMonitor Details

### Longhorn (NEW — currently not scraped)

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: longhorn
  namespace: longhorn-system
  labels:
    release: prometheus
spec:
  selector:
    matchLabels:
      app: longhorn-manager
  endpoints:
    - port: manager
      interval: 60s
      path: /metrics
```

- **Service:** `longhorn-backend` in `longhorn-system` (port 9500)
- **Scrape interval:** 60s (volume health doesn't change rapidly)
- **Label:** `release: prometheus` required for Prometheus Operator discovery

### cert-manager (NEW — currently not scraped)

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: cert-manager
  namespace: cert-manager
  labels:
    release: prometheus
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: cert-manager
  endpoints:
    - port: tcp-prometheus-servicemonitor
      interval: 300s
      path: /metrics
```

- **Service:** `cert-manager` in `cert-manager` namespace (port 9402, port name `tcp-prometheus-servicemonitor`)
- **Scrape interval:** 300s (certificate expiry changes slowly — 5 minutes is plenty)
- **Key metric:** `certmanager_certificate_expiration_timestamp_seconds`

### Cloudflare Tunnel (EXISTING — already scraped)

- ServiceMonitor `cloudflared` already exists in `cloudflare` namespace
- Job label: `cloudflared`
- Scrape interval: 30s
- No changes needed — just add alert rules

## Blackbox Probe Details

All probes follow the established pattern from `karakeep-probe.yaml` and `ollama-probe.yaml`:

| Probe | Target URL | Job Name | Interval | Module |
|-------|-----------|----------|----------|--------|
| Jellyfin | `http://jellyfin.arr-stack.svc.cluster.local:8096` | jellyfin | 60s | http_2xx |
| Ghost | `http://ghost.ghost-prod.svc.cluster.local:2368` | ghost | 60s | http_2xx |
| Invoicetron | `http://invoicetron.invoicetron-prod.svc.cluster.local:3000/api/health` | invoicetron | 60s | http_2xx |
| Portfolio | `http://portfolio.portfolio-prod.svc.cluster.local:80/health` | portfolio | 60s | http_2xx |
| Seerr | `http://seerr.arr-stack.svc.cluster.local:5055` | seerr | 60s | http_2xx |
| Tdarr | `http://tdarr.arr-stack.svc.cluster.local:8265` | tdarr | 60s | http_2xx |
| Byparr | `http://byparr.arr-stack.svc.cluster.local:8191` | byparr | 60s | http_2xx |

All probes use the internal Blackbox Exporter at `blackbox-exporter-prometheus-blackbox-exporter.monitoring.svc:9115` with `http_2xx` module. Internal ClusterIP targets — no external exposure needed.

**Note:** Ghost returns 301 redirect on `/` to `/ghost/` — verify `http_2xx` module follows redirects (Blackbox Exporter follows redirects by default). If not, target `/ghost/` instead.

---

## Tasks

### 4.28.1 Fix Broken Alerts (Priority: Highest)

> These exist today and are silently failing. Fix them first before adding anything new.

- [x] 4.28.1.1 Verify JellyfinDown alert exists but has no probe:
  ```bash
  # Alert should reference job="jellyfin" but this metric should be absent
  kubectl-homelab -n monitoring get probe jellyfin
  # Expected: NotFound
  ```
- [x] 4.28.1.2 Create `manifests/monitoring/probes/jellyfin-probe.yaml` — Blackbox HTTP probe targeting `http://jellyfin.arr-stack.svc.cluster.local:8096`
- [x] 4.28.1.3 Apply Jellyfin probe and verify metric appears (probe_success{job="jellyfin"} visible in Service Health dashboard)
- [x] 4.28.1.4 Fix AdGuard alert labels — `release: prometheus` confirmed in adguard-dns-alert.yaml
- [x] 4.28.1.5 Apply fixed AdGuard alert and verify it appears in Prometheus rules
- [x] 4.28.1.6 Create `manifests/monitoring/alerts/uptime-kuma-alerts.yaml` — PrometheusRule with `UptimeKumaDown` alert on `probe_success{job="uptime-kuma"} == 0` (for: 3m, severity: warning)
- [x] 4.28.1.7 Apply Uptime Kuma alert and verify

### 4.28.2 Add Public Service Probes & Alerts (Priority: High)

> Public-facing services reachable from the internet with zero monitoring.

- [x] 4.28.2.1 Create `manifests/monitoring/probes/ghost-probe.yaml` — Blackbox HTTP probe targeting `http://ghost.ghost-prod.svc.cluster.local:2368`
- [x] 4.28.2.2 Create `manifests/monitoring/alerts/ghost-alerts.yaml` — `GhostDown` alert (warning, 5m)
- [x] 4.28.2.3 Create `manifests/monitoring/probes/invoicetron-probe.yaml` — Blackbox HTTP probe targeting `http://invoicetron.invoicetron-prod.svc.cluster.local:3000/api/health`
- [x] 4.28.2.4 Create `manifests/monitoring/alerts/invoicetron-alerts.yaml` — `InvoicetronDown` alert (warning, 5m)
- [x] 4.28.2.5 Create `manifests/monitoring/probes/portfolio-probe.yaml` — Blackbox HTTP probe targeting `http://portfolio.portfolio-prod.svc.cluster.local:80/health`
- [x] 4.28.2.6 Create `manifests/monitoring/alerts/portfolio-alerts.yaml` — `PortfolioDown` alert (warning, 5m)
- [x] 4.28.2.7 Apply all 6 files
- [x] 4.28.2.8 Verify all probe metrics — all showing UP in Service Health Grafana dashboard

### 4.28.3 Add ARR Service Probes & Alerts (Priority: Medium)

> ARR stack services with user-facing UIs or critical dependencies that have zero monitoring.

- [x] 4.28.3.1 Create `manifests/monitoring/probes/seerr-probe.yaml` — Blackbox HTTP probe targeting `http://seerr.arr-stack.svc.cluster.local:5055`
- [x] 4.28.3.2 Create `manifests/monitoring/probes/tdarr-probe.yaml` — Blackbox HTTP probe targeting `http://tdarr.arr-stack.svc.cluster.local:8265`
- [x] 4.28.3.3 Create `manifests/monitoring/probes/byparr-probe.yaml` — Blackbox HTTP probe targeting `http://byparr.arr-stack.svc.cluster.local:8191`
- [x] 4.28.3.4 Add `SeerrDown`, `TdarrDown`, `ByparrDown` alerts to `manifests/monitoring/alerts/arr-alerts.yaml` (all warning, 5m)
- [x] 4.28.3.5 Apply all 4 files
- [x] 4.28.3.6 Verify probe metrics — all showing UP in Service Health Grafana dashboard

### 4.28.4 Add Longhorn Metrics & Alerts

- [x] 4.28.4.1 Verify no existing ServiceMonitor for Longhorn
- [x] 4.28.4.2 Check `longhorn-backend` service labels and port name
- [x] 4.28.4.3 Create `manifests/monitoring/servicemonitors/longhorn-servicemonitor.yaml`
- [x] 4.28.4.4 Apply and wait for metrics to appear
- [x] 4.28.4.5 Verify Longhorn metrics in Prometheus (`longhorn_volume_robustness`) — 32 volumes returned, scraping confirmed
- [x] 4.28.4.6 Verify `longhorn_volume_robustness` actual values — all 31 healthy volumes show 1=healthy; detached `invoicetron-backups` shows 0=unknown (expected, not mounted). Values confirmed: 0=unknown, 1=healthy, 2=degraded, 3=faulted.
- [x] 4.28.4.7 Create `manifests/monitoring/alerts/storage-alerts.yaml` with `LonghornVolumeDegraded` (warning) and `LonghornVolumeReplicaFailed` (critical)
- [x] 4.28.4.8 Apply and verify rules appear

### 4.28.5 Add cert-manager Metrics & Alerts

- [x] 4.28.5.1 Verify no existing ServiceMonitor for cert-manager
- [x] 4.28.5.2 Check cert-manager service labels and metrics port
- [x] 4.28.5.3 Create `manifests/monitoring/servicemonitors/certmanager-servicemonitor.yaml`
- [x] 4.28.5.4 Apply and wait for metrics
- [x] 4.28.5.5 Verify cert-manager metrics in Prometheus (`certmanager_certificate_expiration_timestamp_seconds`) — 4 results returned, scraping confirmed
- [x] 4.28.5.6 Verify all 3 certificates appear — wildcard-k8s-tls (73d), wildcard-dev-k8s-tls (73d), wildcard-stg-k8s-tls (73d). Bonus: inteldeviceplugins-serving-cert (86d) also visible.
- [x] 4.28.5.7 Create `manifests/monitoring/alerts/cert-alerts.yaml` with `CertificateExpiringSoon`, `CertificateExpiryCritical`, `CertificateNotReady`
- [x] 4.28.5.8 Apply and verify

### 4.28.6 Add Cloudflare Tunnel Alerts

- [x] 4.28.6.1 Verify cloudflared metrics are being scraped — 2 targets up=1 each, scraping confirmed
- [x] 4.28.6.2 Create `manifests/monitoring/alerts/cloudflare-alerts.yaml` with `CloudflareTunnelDegraded` and `CloudflareTunnelDown`
- [x] 4.28.6.3 Apply and verify

### 4.28.7 Remove Redundant Alert

- [x] 4.28.7.1 Remove `LokiStorageLow` from `manifests/monitoring/alerts/logging-alerts.yaml` (confirmed absent)
- [x] 4.28.7.2 Verify default `KubePersistentVolumeFillingUp` covers Loki PVC (confirmed: `KubePersistentVolumeFillingUp` is loaded in Prometheus and applies to all PVCs in all namespaces)
- [x] 4.28.7.3 Apply updated logging-alerts

### 4.28.8 Add API Server Restart Alert (NEW — discovered Feb 19, 2026)

> kube-apiserver-k8s-cp3 has 30 restarts in 34 days. The existing `KubeAPIDown` alert only fires when the API server is completely unreachable — it does not catch frequent brief restarts that drop the VIP for 2 minutes each time.

- [x] 4.28.8.1 Create `manifests/monitoring/alerts/apiserver-alerts.yaml`:
  ```yaml
  # KubeApiserverFrequentRestarts — >5 restarts in any 24h window on any node
  expr: increase(kube_pod_container_status_restarts_total{namespace="kube-system", container="kube-apiserver"}[24h]) > 5
  severity: warning
  ```
- [x] 4.28.8.2 Apply and verify rule appears in Prometheus — `prometheusrule.monitoring.coreos.com/apiserver-alerts created`, confirmed `health: ok` in rules API
- [x] 4.28.8.3 Current 24h increase: cp1=2, cp2=1, cp3=2 — alert correctly NOT firing. Threshold of >5 only fires during incident-level clustering. Alert designed to catch bursts, not background rate.

### 4.28.9 End-to-End Verification

- [x] 4.28.9.1 Verify all 15 new alerts + 3 fixed alerts appear in Prometheus (Status → Rules) — 201 total alert rules loaded, all 15 Phase 4.28 alerts confirmed `health: ok`
- [x] 4.28.9.2 Verify `LokiStorageLow` is gone from rules list — confirmed absent
- [x] 4.28.9.3 Verify Longhorn metrics scraping (`longhorn_volume_robustness`) — 32 volumes scraped, all robustness=1 (healthy). One volume (`invoicetron-backups`) shows robustness=0 (unknown) which is **expected** for detached/unmounted volumes — our alerts only fire at 2 (degraded) or 3 (faulted).
- [x] 4.28.9.4 Verify cert-manager metrics scraping — 4 certificates visible: `wildcard-k8s-tls` (73d), `wildcard-dev-k8s-tls` (73d), `wildcard-stg-k8s-tls` (73d), `inteldeviceplugins-serving-cert` (86d). All >30d, no alerts firing.
- [x] 4.28.9.5 Verify cloudflared metrics scraping — both pods up=1, no tunnel alerts firing
- [x] 4.28.9.6 Verify no false positives from Phase 4.28 alerts — none of our 15 new alerts are firing or pending. Pre-existing unrelated alerts: CPUThrottlingHigh (byparr/prowlarr — resource limits), KubeDeploymentReplicasMismatch (byparr — transient, pod now 1/1), ContainerImageOutdated (version-checker, expected), KubernetesVersionOutdated (version-checker, expected).
- [x] 4.28.9.7 Alert routing config verified in Alertmanager — `severity: critical` → `discord-incidents-email`, `severity: warning` → `discord-status`. Live Discord delivery requires triggering a real alert (manual test — not done).
- [x] 4.28.9.8 Warning routing confirmed in Alertmanager config — all Phase 4.28 service alerts are `severity: warning` → `discord-status` (no email). `LonghornVolumeReplicaFailed`, `CertificateExpiryCritical`, `CertificateNotReady`, `CloudflareTunnelDown` are `severity: critical` → `discord-incidents-email`.

### 4.28.10 Security & Commit

- [x] 4.28.10.1 `/audit-security` — PASS (0 critical; pre-existing: AdGuard bcrypt hash, missing network policies in some namespaces — both acceptable)
- [x] 4.28.10.2 `/commit` (infrastructure) — committed across multiple sessions (commits ec591c7 through bd3250b)

### 4.28.11 Dashboard Improvements

> Service Health dashboard, ARR Stack, and full dashboard audit across all 11 ConfigMaps.

- [x] 4.28.11.0 Create Service Health Grafana dashboard (`dashboards/service-health-dashboard-configmap.yaml`) — 11 UP/DOWN stat panels for all Blackbox probe services, Uptime History time series, Response Time time series. All queries use `max()` to prevent stale TSDB series from creating duplicate panels.
- [x] 4.28.11.1 ARR Stack dashboard: add Byparr companion pod status panel
- [x] 4.28.11.2 ARR Stack dashboard: fix Container Restarts to use `increase($__rate_interval)` instead of raw cumulative counter
- [x] 4.28.11.6 Enable Grafana "Homelab" folder organization — enable `folderAnnotation` in Prometheus Helm values, add `grafana_folder: "Homelab"` annotation to all 11 dashboard ConfigMaps
- [x] 4.28.11.7 Add NVMe SMART monitoring — `smartctl-exporter` DaemonSet via Helm (`helm/smartctl-exporter/values.yaml`), pinned to `/dev/nvme0`, ServiceMonitor enabled with 5 Helm-provided rules + 3 custom alerts (NVMeMediaErrors critical, NVMeSpareWarning/NVMeWearHigh warning)
- [x] 4.28.11.8 Longhorn dashboard NVMe Health section — SMART Status stat panel, Temperature, Available Spare, Wear % Used, TBW, Power-On Time all in one row; TBW History + Write Rate timeseries; Drive Reference section (model/serial/firmware); replaced Drive Info table panel (no tables in any dashboard)
- [x] 4.28.11.9 Network dashboard overhaul — per-node queries (cp1/cp2/cp3 via `label_replace`), stale series dedup via `sum by ()` + explicit `refId`, full layout restructure, per-node color overrides (cp1=green, cp2=blue, cp3=orange), multi-series tooltip + right-side table legend
- [x] 4.28.11.10 Scraparr dashboard improvements — widen service health panels (w=4→w=6), fix Prowlarr indexers query (add `sum by` across `type` label), restructure disk usage (Library Size + Media Storage Free)
- [x] 4.28.11.11 Standardize all 11 dashboard ConfigMaps — `refresh: 30s`, `timezone: Asia/Manila`, tags, panel/row descriptions, `noValue`, `colorMode: "background"` on all stat panels
- [x] 4.28.11.12 kube-vip dashboard complete rewrite — removed non-existent Lease Transitions panel, fixed Instances Up thresholds, switched Container Restarts to raw lifetime counter (step-function shows exact restart timestamps), added `hostNetwork: true` awareness note in descriptions, all metrics verified against live Prometheus data
- [x] 4.28.11.3 Add Loki log panels to ARR Stack dashboard — "Recent Activity" row with Warnings & Errors panel + ARR App Activity log panel (Loki queries on arr-stack namespace logs)
- [x] 4.28.11.4 Add qBittorrent download panels — qBittorrent Download Activity row (active torrents, download/upload speed, ratio stats) via qbittorrent-exporter metrics (requires tdarr-exporter + qbittorrent-exporter Deployments deployed in 329e623)
- [x] 4.28.11.5 Add Tdarr transcoding panels — Tdarr Library Stats row (total files, transcoded count, health check status, space saved, error counts) via tdarr-exporter metrics; repositioned to 3rd row in ARR dashboard (bd3250b)

### 4.28.12 Documentation & Release

> Second commit: documentation updates and audit.

- [x] 4.28.12.0 Update `docs/reference/CHANGELOG.md` — Phase 4.28 in-progress entry added (Feb 19, 2026); fully updated Feb 20, 2026 with Tdarr debugging session, worker tuning, Phase 4.29 planning, and Phase 4.28 marked Complete
- [x] 4.28.12.1 Update `docs/todo/README.md` — v0.27.0 row updated to 🔄 In Progress (Phase 4.28 was already in both tables)
- [x] 4.28.12.2 Update `README.md` (root) — Observability section expanded (smartctl-exporter, 11 probes, Longhorn/cert-manager ServiceMonitors, tdarr/qbit exporters, Service Health dashboard); Next Steps updated to Phase 4.29; release count updated to 27
- [x] 4.28.12.3 Update `VERSIONS.md` — added smartctl-exporter to Helm Charts table; added tdarr-exporter/qbittorrent-exporter to Home Services; updated status note and date to Feb 21
- [x] 4.28.12.4 Update `docs/context/Monitoring.md` — full rewrite of Configuration Files (new subdirectory structure: alerts/, probes/, servicemonitors/, dashboards/, exporters/, grafana/, otel/, version-checker/); added smartctl-exporter/tdarr-exporter/qbittorrent-exporter to Components table; added grafana_folder annotation note; updated date
- [x] 4.28.12.5 Create `docs/rebuild/v0.27.0-alerting-improvements.md` — 14-step rebuild guide covering all Phase 4.28 changes; updated rebuild/README.md with v0.27.0 entry, new monitoring subdirectory structure in Key Files, and new component versions
- [x] 4.28.12.6 `/audit-docs`
- [x] 4.28.12.7 `/commit` (documentation)
- [ ] 4.28.12.8 `/release v0.27.0 "Alerting & Observability Improvements"`
- [ ] 4.28.12.9 Move this file to `docs/todo/completed/`

### 4.28.13 Dashboard-Driven Alert Improvements (Pre-Release)

> Systematic audit of all 11 Grafana dashboards against existing alert rules revealed 5 gaps.
> Each dashboard was checked: what metrics it visualizes vs. what alert rules exist for those metrics.
> All 5 items are small, self-contained changes suitable for pre-release completion.

#### What Each Dashboard Showed

| Dashboard | Coverage Status | Gap Found |
|-----------|-----------------|-----------|
| Claude Code | High spend, no activity, OTel down | **Bug:** `ClaudeCodeNoActivity` fires at 1-2am Manila (17-18 UTC = UTC+8 01-02). Should fire at 5-7pm Manila (09-11 UTC). |
| Jellyfin | JellyfinDown probe | **Missing:** Memory alert. Dashboard shows 4Gi limit with memory panel — no alert when approaching OOM. |
| Service Health | UP/DOWN per probe | **Missing:** Response time alert. Dashboard tracks `probe_duration_seconds` but no alert fires for slow responses. |
| UPS | Fully covered | All power scenarios covered (on battery, low battery, high load, offline). Input voltage sag triggers OB flag which already fires `UPSOnBattery`. |
| Tailscale | Connector + Operator down | Connector has no memory limit (noted in panel description). Minor risk. No action. |
| Version Checker | Fully covered | ContainerImageOutdated + VersionCheckerDown cover everything. |
| Longhorn | Volume degraded/faulted + 5 NVMe SMART alerts | **Missing:** Temperature alert. Dashboard has a prominent Temperature stat panel with per-node values — no alert if temp exceeds 65°C. SK Hynix HFS512GDE9X081N max operating = 70°C. |
| Scraparr / ARR Stack | ARR queue + service health | **Missing:** Bazarr (subtitle downloader, port 6767) has zero monitoring. Users notice missing subtitles reactively. |
| Network | NIC saturation at 80%+95% | Fully covered. |
| kube-vip | All VIP failure modes | Fully covered. |

#### Findings

**1. Bug: `ClaudeCodeNoActivity` fires at wrong time**

The alert fires at 5-6pm UTC which is 1-2am Manila (UTC+8). The intent is end-of-business-day detection.

```yaml
# Current (WRONG) — fires at 1-2am Manila time
hour() >= 17 and hour() <= 18

# Fixed — fires at 5-7pm Manila time (9-11am UTC)
hour() >= 9 and hour() <= 11
```

File: `manifests/monitoring/alerts/claude-alerts.yaml`

**2. Missing: `JellyfinHighMemory`**

Dashboard shows memory usage vs 4Gi limit. During QSV transcoding, memory spikes ~500Mi per stream. With 2-3 concurrent streams, approaching 4Gi is realistic. No alert exists.

```promql
# Warning — approaching OOM kill threshold (87% of 4Gi)
container_memory_working_set_bytes{namespace="arr-stack", pod=~"jellyfin.*", container="jellyfin"}
> 3758096384  # 3.5Gi = 3.5 * 1024^3
```

Severity: **warning**, for: 10m, Route: #status only

Add to: `manifests/monitoring/alerts/arr-alerts.yaml` (new `jellyfin-health` group)

**3. Missing: `NVMeTemperatureHigh`**

Dashboard has a Temperature stat panel (one per node) showing current NVMe temperature. No alert fires if it exceeds safe operating range. SK Hynix drives have 70°C max; 65°C threshold gives a buffer.

```promql
# Metric name from smartctl-exporter — verify in live Prometheus first:
#   smartctl_device_temperature_celsius (most common from prometheus-community chart)
# Labels: device="nvme0n1", model_name=..., node=...
smartctl_device_temperature_celsius > 65
```

Severity: **warning**, for: 10m, Route: #status only

Add to: `manifests/monitoring/alerts/storage-alerts.yaml` (new `nvme-temperature` rule in `nvme-smart` group)

**4. Missing: `ServiceHighResponseTime`**

Dashboard has a "Response Time" row tracking `probe_duration_seconds` for all 11 probes with 1s (orange) / 3s (red) thresholds visible in the chart — but no alert rule acts on this metric.

A service can be technically UP (probe_success=1) but responding in 5+ seconds, indicating database issues, memory pressure, or cold-start degradation. Alert only for public-facing services (not internal tools like Tdarr/Byparr where slow response is normal).

```promql
# Only alert for public/user-facing services — internal tools often have slow initial response
probe_duration_seconds{job=~"ghost|invoicetron|portfolio|jellyfin|seerr|karakeep"} > 5
```

Severity: **warning**, for: 5m, Route: #status only

Add to: new `manifests/monitoring/alerts/service-health-alerts.yaml` file

**5. Missing: Bazarr probe + alert**

Bazarr is the subtitle downloader in the ARR stack. It runs at port 6767. The ARR Stack dashboard shows all companion pods but Bazarr is completely unmonitored — no Blackbox probe, no PrometheusRule. When Bazarr goes down, Jellyfin stops getting auto-subtitles. Users notice reactively when watching content.

Target: `http://bazarr.arr-stack.svc.cluster.local:6767`

Files needed:
- `manifests/monitoring/probes/bazarr-probe.yaml` — Blackbox HTTP probe, job=`bazarr`, interval=60s
- Add `BazarrDown` alert to `manifests/monitoring/alerts/arr-alerts.yaml` (severity: warning, for: 5m)
- Add `bazarr` panel to Service Health dashboard

#### Tasks

- [x] 4.28.13.1 Fix `ClaudeCodeNoActivity` timezone bug — change `hour() >= 17 and hour() <= 18` to `hour() >= 9 and hour() <= 11` in `manifests/monitoring/alerts/claude-alerts.yaml`. Apply and verify the rule reloads (`health: ok`).

- [x] 4.28.13.2 Add `JellyfinHighMemory` rule to `manifests/monitoring/alerts/arr-alerts.yaml` — added to `jellyfin` group (not a separate group — consistent with JellyfinDown being in the same group). Apply and verify (`health: ok`).

- [x] 4.28.13.3 Add `NVMeTemperatureHigh` rule to `manifests/monitoring/alerts/storage-alerts.yaml` — metric confirmed as `smartctl_device_temperature{temperature_type="current"}` (not `_celsius`). Current values: 46°C on all 3 nodes. Alert at >65°C for 10m. Apply and verify (`health: ok`, not firing).

- [x] 4.28.13.4 Create `manifests/monitoring/alerts/service-health-alerts.yaml` — new PrometheusRule with `ServiceHighResponseTime` alert. Apply and verify (`health: ok`, not firing — all probes responding <1s).

- [x] 4.28.13.5 Create `manifests/monitoring/probes/bazarr-probe.yaml` — Blackbox HTTP probe targeting `http://bazarr.arr-stack.svc.cluster.local:6767`, job=`bazarr`, interval=60s. Apply and verify `probe_success{job="bazarr"} = 1` (UP).

- [x] 4.28.13.6 Add `BazarrDown` alert to `manifests/monitoring/alerts/arr-alerts.yaml` — added to `arr-companions` group. Apply and verify (`health: ok`).

- [x] 4.28.13.7 Add Bazarr panel to Service Health dashboard — stat panel at y=9, x=18, w=6, h=4 (fills empty slot in row 3). Also added bazarr to Uptime History and Response Time time series panels. Apply and reload Grafana.

- [x] 4.28.13.8 `/audit-security` then `/commit` (infra) — commit all 4.28.13 + 4.28.14 changes together.

- [x] 4.28.13.9 Update `docs/rebuild/v0.27.0-alerting-improvements.md` — add Step 18 covering 4.28.13 + 4.28.14 changes. Then `/audit-docs` and `/commit` (docs).

#### PromQL Reference

```promql
# JellyfinHighMemory — 3.5Gi = 3758096384 bytes
container_memory_working_set_bytes{namespace="arr-stack", pod=~"jellyfin.*", container="jellyfin"} > 3758096384

# NVMeTemperatureHigh — verify metric name first; likely one of:
smartctl_device_temperature_celsius > 65
# or
smartctl_nvme_temperature_celsius > 65

# ServiceHighResponseTime — public-facing services only
probe_duration_seconds{job=~"ghost|invoicetron|portfolio|jellyfin|seerr|karakeep"} > 5
```

#### Coverage Impact

After 4.28.13:
- Total custom alert rules: ~25 (up from 20)
- Bazarr joins the 11 monitored services in Service Health dashboard → 12 probes
- All dashboard-visible metrics now have corresponding alert rules where appropriate

---

### 4.28.14 Tdarr & qBittorrent Operational Alerts (Pre-Release)

> Tdarr and qBittorrent metrics are already scraped (exporters deployed in 4.28.11). These alerts add operational awareness: transcode failures, health check errors, and stalled downloads.

#### Design: Why `increase()` Instead of Raw Counter

Both Tdarr metrics are **cumulative counters** — they only go up, never down. The cluster already has:
- 73 health check errors (Tdarr has processed 73 files with minor issues over its lifetime)
- Some transcode errors from historical runs

Using `metric > 0` would fire **immediately and permanently** — auto-resolve would never trigger because counters never reset to 0. The fix is `increase(metric[1h])` which measures *new errors in the last hour*, not historical total. When errors stop occurring, `increase()[1h]` drops to 0 → alert auto-resolves ~1h later.

#### Auto-Resolve Behavior

Auto-resolve is **already built into Alertmanager** — no extra config required:
- When PromQL expr returns 0 results: alert transitions from FIRING → RESOLVED
- Alertmanager sends resolved notification automatically
- Discord #status title uses: `{{ if eq .Status "firing" }}⚠️{{ else }}✅{{ end }}` — already in config
- Email `send_resolved: true` on `discord-incidents-email` receiver — already in config

When you manually fix a Tdarr plugin issue or the stall-resolver CronJob clears stuck downloads, the corresponding alert self-resolves with a ✅ Discord notification. No manual intervention needed.

#### Discord Routing Design

| Alert | Severity | Channel | Email | Rationale |
|-------|----------|---------|-------|-----------|
| `TdarrTranscodeErrors` | warning | #status | No | New encode failures — needs attention but not urgent |
| `TdarrHealthCheckErrors` | warning | #status | No | Spike in health check errors — file/NFS issue |
| `TdarrTranscodeErrorsBurst` | critical | #incidents | Yes | 15+ encode errors/hr → systematic plugin failure, node may be hung |
| `TdarrHealthCheckErrorsBurst` | critical | #incidents | Yes | 50+ health check errors/hr → NFS corruption or storage failure |
| `QBittorrentStalledDownloads` | warning | #status | No | Stuck downloads, check seeder availability or port forwarding |

#### Alert Definitions

**Tdarr warning — new transcode errors in last hour:**
```promql
increase(tdarr_library_transcodes{library_id="all_libraries", status="error"}[1h]) > 2
```
`for: 15m` — sustained new errors, not a one-time blip. Threshold >2 avoids false positives from occasional plugin failures.

**Tdarr warning — new health check errors in last hour:**
```promql
increase(tdarr_library_health_checks{library_id="all_libraries", status="error"}[1h]) > 5
```
`for: 15m` — threshold >5 filters noise from normal file variance. The existing 73 errors are historical (counter was already at 73 when exporter was deployed); `increase()` only sees new accumulation.

**Tdarr critical — burst of transcode errors (plugin or node failure):**
```promql
increase(tdarr_library_transcodes{library_id="all_libraries", status="error"}[1h]) > 15
```
`for: 0m` — immediate alert. 15+ encode failures in 1 hour indicates a broken plugin affecting all files (e.g. Boosh-QSV NaN bug from Tdarr debugging session).

**Tdarr critical — burst of health check errors (NFS/storage issue):**
```promql
increase(tdarr_library_health_checks{library_id="all_libraries", status="error"}[1h]) > 50
```
`for: 0m` — immediate alert. 50+ health check errors in 1 hour may indicate NFS mount failure or storage corruption affecting all files.

**qBittorrent stalled downloads:**
```promql
sum(qbittorrent_torrents_count{status="stalledDL"}) > 0
```
`for: 45m` — long `for:` duration avoids false positives (peers naturally take time to connect; stall-resolver CronJob runs every 30 min). After 45min of stalledDL status, human review is warranted. Auto-resolves when stall-resolver or user clears the stuck torrents.

#### File Changes

All Tdarr alerts go in `manifests/monitoring/alerts/arr-alerts.yaml` as new groups.
qBittorrent alert goes in the same file (consistent with existing ARR patterns).

New groups to add:
```yaml
- name: tdarr-health
  rules:
    - alert: TdarrTranscodeErrors
      ...
    - alert: TdarrTranscodeErrorsBurst
      ...
    - alert: TdarrHealthCheckErrors
      ...
    - alert: TdarrHealthCheckErrorsBurst
      ...

- name: qbittorrent
  rules:
    - alert: QBittorrentStalledDownloads
      ...
```

#### Tasks

- [x] 4.28.14.1 Add `tdarr-health` group to `manifests/monitoring/alerts/arr-alerts.yaml` with all 4 Tdarr alerts. All 4 load with `health: ok`. Not firing at rest (increase()[1h] has no data — no new errors in the last hour, which is expected after a quiet period).

- [x] 4.28.14.2 Add `qbittorrent` group to `manifests/monitoring/alerts/arr-alerts.yaml` with `QBittorrentStalledDownloads`. Loads `health: ok`. `sum(qbittorrent_torrents_count{status="stalledDL"}) = 0` — no false positive.

- [x] 4.28.14.3 Routing verified via PrometheusRule labels: TdarrTranscodeErrorsBurst + TdarrHealthCheckErrorsBurst have `severity: critical` → #incidents + email. TdarrTranscodeErrors + TdarrHealthCheckErrors + QBittorrentStalledDownloads have `severity: warning` → #status.

- [x] 4.28.14.4 `/audit-security` then `/commit` (infra) — combined with 4.28.13.8.

- [x] 4.28.14.5 Update `docs/rebuild/v0.27.0-alerting-improvements.md` — combined with 4.28.13.9.

#### PromQL Reference

```promql
# Verify current values before deploying (expect ~0 increase at rest):
# increase(tdarr_library_transcodes{library_id="all_libraries", status="error"}[1h])
# increase(tdarr_library_health_checks{library_id="all_libraries", status="error"}[1h])
# sum(qbittorrent_torrents_count{status="stalledDL"})

# TdarrTranscodeErrors (warning, for: 15m) → #status
increase(tdarr_library_transcodes{library_id="all_libraries", status="error"}[1h]) > 2

# TdarrTranscodeErrorsBurst (critical, for: 0m) → #incidents + email
increase(tdarr_library_transcodes{library_id="all_libraries", status="error"}[1h]) > 15

# TdarrHealthCheckErrors (warning, for: 15m) → #status
increase(tdarr_library_health_checks{library_id="all_libraries", status="error"}[1h]) > 5

# TdarrHealthCheckErrorsBurst (critical, for: 0m) → #incidents + email
increase(tdarr_library_health_checks{library_id="all_libraries", status="error"}[1h]) > 50

# QBittorrentStalledDownloads (warning, for: 45m) → #status
sum(qbittorrent_torrents_count{status="stalledDL"}) > 0
```

---

## Verification Checklist

### Bug Fixes
- [x] `JellyfinDown` alert now fires correctly (Blackbox probe providing metrics)
- [x] `AdGuardDNSUnreachable` alert has correct labels (`release: prometheus`)
- [x] `UptimeKumaDown` alert active on existing probe

### New Probes (8 probes)
- [x] `probe_success{job="jellyfin"}` metric present — confirmed UP in Service Health dashboard
- [x] `probe_success{job="ghost"}` metric present — confirmed UP in Service Health dashboard
- [x] `probe_success{job="invoicetron"}` metric present — confirmed UP in Service Health dashboard
- [x] `probe_success{job="portfolio"}` metric present — confirmed UP in Service Health dashboard
- [x] `probe_success{job="seerr"}` metric present — confirmed UP in Service Health dashboard
- [x] `probe_success{job="tdarr"}` metric present — confirmed UP in Service Health dashboard
- [x] `probe_success{job="byparr"}` metric present — confirmed UP in Service Health dashboard
- [x] `probe_success{job="bazarr"}` metric present — confirmed UP (added in 4.28.13.5)

### New Alerts (24 alerts)
- [x] `GhostDown` rule active (warning)
- [x] `InvoicetronDown` rule active (warning)
- [x] `PortfolioDown` rule active (warning)
- [x] `SeerrDown` rule active (warning)
- [x] `TdarrDown` rule active (warning)
- [x] `ByparrDown` rule active (warning)
- [x] `UptimeKumaDown` rule active (warning)
- [x] `LonghornVolumeDegraded` rule active (warning)
- [x] `LonghornVolumeReplicaFailed` rule active (critical)
- [x] `CertificateExpiringSoon` rule active (warning)
- [x] `CertificateExpiryCritical` rule active (critical)
- [x] `CertificateNotReady` rule active (critical)
- [x] `CloudflareTunnelDegraded` rule active (warning)
- [x] `CloudflareTunnelDown` rule active (critical)
- [x] `KubeApiserverFrequentRestarts` rule active (warning) — confirmed `health: ok`, currently NOT firing (cp1=2, cp2=1, cp3=2 restarts in 24h, all below threshold of >5)
- [x] `JellyfinHighMemory` rule active (warning) — added 4.28.13.2; `health: ok`, not firing at rest
- [x] `BazarrDown` rule active (warning) — added 4.28.13.6; `health: ok`, Bazarr probe UP
- [x] `NVMeTemperatureHigh` rule active (warning) — added 4.28.13.3; `health: ok`, ~46°C on all nodes (threshold 65°C)
- [x] `ServiceHighResponseTime` rule active (warning) — added 4.28.13.4; `health: ok`, all probes <1s (threshold 5s)
- [x] `TdarrTranscodeErrors` rule active (warning) — added 4.28.14.1; `health: ok`, not firing
- [x] `TdarrTranscodeErrorsBurst` rule active (critical) — added 4.28.14.1; `health: ok`, not firing
- [x] `TdarrHealthCheckErrors` rule active (warning) — added 4.28.14.1; `health: ok`, not firing
- [x] `TdarrHealthCheckErrorsBurst` rule active (critical) — added 4.28.14.1; `health: ok`, not firing
- [x] `QBittorrentStalledDownloads` rule active (warning) — added 4.28.14.2; `health: ok`, stalledDL=0

### ServiceMonitors
- [x] Longhorn ServiceMonitor created and applied
- [x] cert-manager ServiceMonitor created and applied
- [x] Longhorn metrics visible in Prometheus (`longhorn_volume_robustness`) — 32 volumes, all healthy
- [x] cert-manager certificate expiry metrics visible — 4 certs (3 wildcard + Intel GPU plugin cert), all >30d

### Cleanup
- [x] `LokiStorageLow` removed from logging-alerts.yaml

### Routing
- [x] Critical alerts route to Discord #incidents + email — confirmed in Alertmanager config (`severity: critical` → `discord-incidents-email`)
- [x] Warning alerts route to Discord #status only — confirmed in Alertmanager config (`severity: warning` → `discord-status`)
- [x] No false positives from Phase 4.28 alerts — verified, none of our 15 new alerts are firing or pending

---

## Rollback

```bash
# Remove new probes
kubectl-homelab -n monitoring delete probe jellyfin ghost invoicetron portfolio seerr tdarr byparr

# Remove new alerts
kubectl-homelab delete prometheusrule storage-alerts -n monitoring
kubectl-homelab delete prometheusrule cert-alerts -n monitoring
kubectl-homelab delete prometheusrule cloudflare-alerts -n monitoring
kubectl-homelab delete prometheusrule ghost-alerts -n monitoring
kubectl-homelab delete prometheusrule invoicetron-alerts -n monitoring
kubectl-homelab delete prometheusrule portfolio-alerts -n monitoring
kubectl-homelab delete prometheusrule uptime-kuma-alerts -n monitoring
kubectl-homelab delete prometheusrule apiserver-alerts -n monitoring  # if 4.28.8 was applied

# Remove new ServiceMonitors
kubectl-homelab delete servicemonitor longhorn -n longhorn-system
kubectl-homelab delete servicemonitor cert-manager -n cert-manager

# Restore modified files
git checkout -- manifests/monitoring/alerts/logging-alerts.yaml
git checkout -- manifests/monitoring/alerts/adguard-dns-alert.yaml
git checkout -- manifests/monitoring/alerts/arr-alerts.yaml
kubectl-homelab apply -f manifests/monitoring/alerts/logging-alerts.yaml
kubectl-homelab apply -f manifests/monitoring/alerts/adguard-dns-alert.yaml
kubectl-homelab apply -f manifests/monitoring/alerts/arr-alerts.yaml

# Restore ARR stack dashboard to pre-phase state
git checkout -- manifests/monitoring/dashboards/arr-stack-dashboard-configmap.yaml
kubectl-homelab apply -f manifests/monitoring/dashboards/arr-stack-dashboard-configmap.yaml
```

---

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Fix broken alerts before adding new ones | Priority 1 | Existing alerts should work before expanding coverage |
| Add public service probes | Ghost, Invoicetron, Portfolio | Internet-facing services must have uptime monitoring |
| Service health alerts as warning, not critical | `GhostDown` etc. = warning | Individual service outages are operational, not emergencies. `CloudflareTunnelDown` (critical) covers total public access loss. |
| Add ARR companion probes | Seerr, Tdarr, Byparr | User-facing UIs and critical dependencies with zero coverage |
| Seerr/Tdarr/Byparr alerts in arr-alerts.yaml | Group with existing ARR alerts | Consistent with existing `ArrAppDown`, `JellyfinDown` pattern |
| Individual alert files for non-ARR services | ghost-alerts.yaml, invoicetron-alerts.yaml, etc. | Consistent with existing per-service pattern (karakeep-alerts.yaml, ollama-alerts.yaml) |
| Drop PVCSpaceLow alert | Default `KubePersistentVolumeFillingUp` already covers this | Avoids redundant alerting — kube-prometheus-stack has 2-tier PVC alerts |
| Drop LonghornNodeStorageLow alert | Default `NodeFilesystemSpaceFillingUp` already covers this | Predictive alerts (24h/4h fill rate) are better than static threshold |
| Remove LokiStorageLow | Redundant | Default `KubePersistentVolumeFillingUp` covers all PVCs including Loki |
| Longhorn robustness alerts only | Degraded + faulted | The gap defaults can't cover — only Longhorn knows replica health |
| cert-manager 30d/7d thresholds | Let's Encrypt = 90d cycle, renews at 30d | 30d warning = first sign of renewal failure, 7d = urgent |
| Cloudflare 2m down threshold | Tunnel failure = all public access dies | 2m is aggressive but appropriate — public-facing service |
| 60s scrape for Longhorn | Volume health changes slowly | Saves Prometheus resources vs 15s default |
| 300s scrape for cert-manager | Certificate expiry changes daily | 5-minute interval is more than sufficient |
| ARR dashboard improvements in same phase | Observability = dashboards too | Phase title is "Alerting & Observability" — Loki log panels are operational observability |

---

## Not In Scope (Phase 5 or Later)

| Gap | Phase | Rationale |
|-----|-------|-----------|
| GitLab service + database health alerts | Phase 5 | Application-level monitoring, lower priority |
| Gateway API / HTTPRoute health | Phase 5 | No Prometheus metrics available — needs Blackbox probes for each route |
| Backup job success monitoring | Phase 5 | No automated backups exist yet |
| NFS storage alerting | Phase 5 | NFS doesn't expose Prometheus metrics — would need custom exporter |
| GitLab Minio PVC resize (73.8% used) | Track separately | Operational task, not an alerting change |

---

## CKA Learnings

| Topic | Concept |
|-------|---------|
| ServiceMonitor | Custom Prometheus scrape targets for non-default services (Longhorn, cert-manager) |
| Probe | Blackbox Exporter integration via Prometheus Operator Probe CRD |
| PrometheusRule | Custom alerting rules with PromQL expressions and severity-based routing |
| PrometheusRule label selectors | Rules must have correct labels (`release: prometheus`) for discovery — wrong labels = silent failure |
| Certificate lifecycle | cert-manager metrics for monitoring Let's Encrypt renewal health |
| Longhorn internals | Volume robustness model (healthy → degraded → faulted) |
| Alertmanager routing | Leveraging existing severity-based routing without config changes |
| Default rule awareness | Understanding kube-prometheus-stack defaults to avoid redundant custom alerts |
| Monitoring audit discipline | Regularly verify alerts actually fire — broken probes/selectors are a common silent failure mode |
