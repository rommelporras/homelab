# Phase 4.28: Alerting & Observability Improvements

> **Status:** Planned
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
| `logging-alerts.yaml` | LokiDown, LokiIngestionStopped, LokiHighErrorRate, **LokiStorageLow** (redundant), AlloyNotOnAllNodes, AlloyNotSendingLogs, AlloyHighMemory | LokiStorageLow to be removed |
| `ups-alerts.yaml` | UPSOnBattery, UPSLowBattery, UPSBatteryCritical, UPSBatteryWarning, UPSHighLoad, UPSExporterDown, UPSOffline, UPSBackOnline | Good |
| `kube-vip-alerts.yaml` | KubeVipInstanceDown, KubeVipAllDown, KubeVipLeaseStale, KubeVipHighRestarts | Good |
| `claude-alerts.yaml` | ClaudeCodeHighDailySpend, ClaudeCodeCriticalDailySpend, ClaudeCodeNoActivity, OTelCollectorDown | Good |
| `ollama-alerts.yaml` | OllamaDown, OllamaMemoryHigh, OllamaHighRestarts | Good |
| `karakeep-alerts.yaml` | KarakeepDown, KarakeepHighRestarts | Good |
| `adguard-dns-alert.yaml` | AdGuardDNSUnreachable | **BUG: wrong labels** — needs `release: prometheus` |
| `arr-alerts.yaml` | ArrAppDown, SonarrQueueStalled, RadarrQueueStalled, NetworkInterfaceSaturated, NetworkInterfaceCritical, JellyfinDown | **BUG: JellyfinDown has no Probe** |
| `tailscale-alerts.yaml` | TailscaleConnectorDown, TailscaleOperatorDown | Good |
| `version-checker-alerts.yaml` | ContainerImageOutdated, KubernetesVersionOutdated, VersionCheckerDown | Good |
| `uptime-kuma-probe.yaml` | (Probe only — no PrometheusRule) | **BUG: probe exists, alert missing** |

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

### New Alert Rules (14 total)

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

### Files to Create (16 total)

| File | Type | Purpose |
|------|------|---------|
| `manifests/monitoring/jellyfin-probe.yaml` | Probe | Blackbox HTTP probe for Jellyfin (fixes broken JellyfinDown alert) |
| `manifests/monitoring/ghost-probe.yaml` | Probe | Blackbox HTTP probe for Ghost prod |
| `manifests/monitoring/ghost-alerts.yaml` | PrometheusRule | GhostDown alert |
| `manifests/monitoring/invoicetron-probe.yaml` | Probe | Blackbox HTTP probe for Invoicetron prod |
| `manifests/monitoring/invoicetron-alerts.yaml` | PrometheusRule | InvoicetronDown alert |
| `manifests/monitoring/portfolio-probe.yaml` | Probe | Blackbox HTTP probe for Portfolio prod |
| `manifests/monitoring/portfolio-alerts.yaml` | PrometheusRule | PortfolioDown alert |
| `manifests/monitoring/seerr-probe.yaml` | Probe | Blackbox HTTP probe for Seerr |
| `manifests/monitoring/tdarr-probe.yaml` | Probe | Blackbox HTTP probe for Tdarr |
| `manifests/monitoring/byparr-probe.yaml` | Probe | Blackbox HTTP probe for Byparr |
| `manifests/monitoring/uptime-kuma-alerts.yaml` | PrometheusRule | UptimeKumaDown alert (uses existing probe) |
| `manifests/monitoring/longhorn-servicemonitor.yaml` | ServiceMonitor | Scrape Longhorn manager metrics (port 9500) |
| `manifests/monitoring/storage-alerts.yaml` | PrometheusRule | Longhorn volume degraded/faulted alerts |
| `manifests/monitoring/certmanager-servicemonitor.yaml` | ServiceMonitor | Scrape cert-manager metrics (port 9402) |
| `manifests/monitoring/cert-alerts.yaml` | PrometheusRule | Certificate expiry + not-ready alerts |
| `manifests/monitoring/cloudflare-alerts.yaml` | PrometheusRule | Tunnel degraded/down alerts |

### Files to Modify (3 total)

| File | Change |
|------|--------|
| `manifests/monitoring/adguard-dns-alert.yaml` | Fix labels: `prometheus: prometheus` + `role: alert-rules` → `release: prometheus` + `app.kubernetes.io/part-of: kube-prometheus-stack` |
| `manifests/monitoring/arr-alerts.yaml` | Add SeerrDown, TdarrDown, ByparrDown alerts to existing groups |
| `manifests/monitoring/logging-alerts.yaml` | Remove `LokiStorageLow` rule (redundant with default `KubePersistentVolumeFillingUp`) |

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

- [ ] 4.28.1.1 Verify JellyfinDown alert exists but has no probe:
  ```bash
  # Alert should reference job="jellyfin" but this metric should be absent
  kubectl-homelab -n monitoring get probe jellyfin
  # Expected: NotFound
  ```
- [ ] 4.28.1.2 Create `manifests/monitoring/jellyfin-probe.yaml` — Blackbox HTTP probe targeting `http://jellyfin.arr-stack.svc.cluster.local:8096`
- [ ] 4.28.1.3 Apply Jellyfin probe and verify metric appears:
  ```bash
  kubectl-homelab apply -f manifests/monitoring/jellyfin-probe.yaml
  # Wait ~2 min, then check
  curl -s 'http://localhost:9090/api/v1/query?query=probe_success{job="jellyfin"}' | python3 -m json.tool
  ```
- [ ] 4.28.1.4 Fix AdGuard alert labels — edit `manifests/monitoring/adguard-dns-alert.yaml`:
  - Change `prometheus: prometheus` → `release: prometheus`
  - Change `role: alert-rules` → `app.kubernetes.io/part-of: kube-prometheus-stack`
- [ ] 4.28.1.5 Apply fixed AdGuard alert and verify it appears in Prometheus rules:
  ```bash
  kubectl-homelab apply -f manifests/monitoring/adguard-dns-alert.yaml
  ```
- [ ] 4.28.1.6 Create `manifests/monitoring/uptime-kuma-alerts.yaml` — PrometheusRule with `UptimeKumaDown` alert on `probe_success{job="uptime-kuma"} == 0` (for: 3m, severity: warning)
- [ ] 4.28.1.7 Apply Uptime Kuma alert and verify:
  ```bash
  kubectl-homelab apply -f manifests/monitoring/uptime-kuma-alerts.yaml
  ```

### 4.28.2 Add Public Service Probes & Alerts (Priority: High)

> Public-facing services reachable from the internet with zero monitoring.

- [ ] 4.28.2.1 Create `manifests/monitoring/ghost-probe.yaml` — Blackbox HTTP probe targeting `http://ghost.ghost-prod.svc.cluster.local:2368`
- [ ] 4.28.2.2 Create `manifests/monitoring/ghost-alerts.yaml` — `GhostDown` alert (warning, 5m)
- [ ] 4.28.2.3 Create `manifests/monitoring/invoicetron-probe.yaml` — Blackbox HTTP probe targeting `http://invoicetron.invoicetron-prod.svc.cluster.local:3000/api/health`
- [ ] 4.28.2.4 Create `manifests/monitoring/invoicetron-alerts.yaml` — `InvoicetronDown` alert (warning, 5m)
- [ ] 4.28.2.5 Create `manifests/monitoring/portfolio-probe.yaml` — Blackbox HTTP probe targeting `http://portfolio.portfolio-prod.svc.cluster.local:80/health`
- [ ] 4.28.2.6 Create `manifests/monitoring/portfolio-alerts.yaml` — `PortfolioDown` alert (warning, 5m)
- [ ] 4.28.2.7 Apply all 6 files and verify probes + alerts:
  ```bash
  kubectl-homelab apply -f manifests/monitoring/ghost-probe.yaml \
    -f manifests/monitoring/ghost-alerts.yaml \
    -f manifests/monitoring/invoicetron-probe.yaml \
    -f manifests/monitoring/invoicetron-alerts.yaml \
    -f manifests/monitoring/portfolio-probe.yaml \
    -f manifests/monitoring/portfolio-alerts.yaml
  ```
- [ ] 4.28.2.8 Verify all probe metrics appear in Prometheus:
  ```bash
  for job in ghost invoicetron portfolio; do
    echo "=== $job ==="
    curl -s "http://localhost:9090/api/v1/query?query=probe_success{job=\"$job\"}" | python3 -m json.tool | head -10
  done
  ```

### 4.28.3 Add ARR Service Probes & Alerts (Priority: Medium)

> ARR stack services with user-facing UIs or critical dependencies that have zero monitoring.

- [ ] 4.28.3.1 Create `manifests/monitoring/seerr-probe.yaml` — Blackbox HTTP probe targeting `http://seerr.arr-stack.svc.cluster.local:5055`
- [ ] 4.28.3.2 Create `manifests/monitoring/tdarr-probe.yaml` — Blackbox HTTP probe targeting `http://tdarr.arr-stack.svc.cluster.local:8265`
- [ ] 4.28.3.3 Create `manifests/monitoring/byparr-probe.yaml` — Blackbox HTTP probe targeting `http://byparr.arr-stack.svc.cluster.local:8191`
- [ ] 4.28.3.4 Add `SeerrDown`, `TdarrDown`, `ByparrDown` alerts to `manifests/monitoring/arr-alerts.yaml` (all warning, 5m)
- [ ] 4.28.3.5 Apply all 4 files:
  ```bash
  kubectl-homelab apply -f manifests/monitoring/seerr-probe.yaml \
    -f manifests/monitoring/tdarr-probe.yaml \
    -f manifests/monitoring/byparr-probe.yaml \
    -f manifests/monitoring/arr-alerts.yaml
  ```
- [ ] 4.28.3.6 Verify probe metrics:
  ```bash
  for job in seerr tdarr byparr; do
    echo "=== $job ==="
    curl -s "http://localhost:9090/api/v1/query?query=probe_success{job=\"$job\"}" | python3 -m json.tool | head -10
  done
  ```

### 4.28.4 Add Longhorn Metrics & Alerts

- [ ] 4.28.4.1 Verify no existing ServiceMonitor for Longhorn:
  ```bash
  kubectl-homelab -n longhorn-system get servicemonitor
  ```
- [ ] 4.28.4.2 Check `longhorn-backend` service labels and port name:
  ```bash
  kubectl-homelab -n longhorn-system get svc longhorn-backend -o yaml | grep -A10 'ports\|selector\|labels'
  ```
- [ ] 4.28.4.3 Create `manifests/monitoring/longhorn-servicemonitor.yaml`
- [ ] 4.28.4.4 Apply and wait for metrics to appear:
  ```bash
  kubectl-homelab apply -f manifests/monitoring/longhorn-servicemonitor.yaml
  # Wait ~2 minutes for scrape, then verify
  ```
- [ ] 4.28.4.5 Verify Longhorn metrics in Prometheus:
  ```bash
  # Port-forward Prometheus and query
  kubectl-homelab -n monitoring port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090 &
  curl -s 'http://localhost:9090/api/v1/query?query=longhorn_volume_robustness' | python3 -m json.tool | head -20
  ```
- [ ] 4.28.4.6 Verify `longhorn_volume_robustness` actual values match expected (0=unknown, 1=healthy, 2=degraded, 3=faulted)
- [ ] 4.28.4.7 Create `manifests/monitoring/storage-alerts.yaml` with `LonghornVolumeDegraded` (warning) and `LonghornVolumeReplicaFailed` (critical)
- [ ] 4.28.4.8 Apply and verify rules appear:
  ```bash
  kubectl-homelab apply -f manifests/monitoring/storage-alerts.yaml
  ```

### 4.28.5 Add cert-manager Metrics & Alerts

- [ ] 4.28.5.1 Verify no existing ServiceMonitor for cert-manager:
  ```bash
  kubectl-homelab -n cert-manager get servicemonitor
  ```
- [ ] 4.28.5.2 Check cert-manager service labels and metrics port:
  ```bash
  kubectl-homelab -n cert-manager get svc cert-manager -o yaml | grep -A10 'ports\|selector\|labels'
  ```
- [ ] 4.28.5.3 Create `manifests/monitoring/certmanager-servicemonitor.yaml`
- [ ] 4.28.5.4 Apply and wait for metrics:
  ```bash
  kubectl-homelab apply -f manifests/monitoring/certmanager-servicemonitor.yaml
  ```
- [ ] 4.28.5.5 Verify cert-manager metrics in Prometheus:
  ```bash
  curl -s 'http://localhost:9090/api/v1/query?query=certmanager_certificate_expiration_timestamp_seconds' | python3 -m json.tool | head -20
  ```
- [ ] 4.28.5.6 Verify all 3 certificates appear in metrics (wildcard-k8s-tls, wildcard-dev-k8s-tls, wildcard-stg-k8s-tls)
- [ ] 4.28.5.7 Create `manifests/monitoring/cert-alerts.yaml` with:
  - `CertificateExpiringSoon` (warning, <30d)
  - `CertificateExpiryCritical` (critical, <7d)
  - `CertificateNotReady` (critical)
- [ ] 4.28.5.8 Apply and verify:
  ```bash
  kubectl-homelab apply -f manifests/monitoring/cert-alerts.yaml
  ```

### 4.28.6 Add Cloudflare Tunnel Alerts

- [ ] 4.28.6.1 Verify cloudflared metrics are being scraped:
  ```bash
  curl -s 'http://localhost:9090/api/v1/query?query=up{job="cloudflared"}' | python3 -m json.tool | head -10
  ```
- [ ] 4.28.6.2 Create `manifests/monitoring/cloudflare-alerts.yaml` with:
  - `CloudflareTunnelDegraded` (warning, <2 healthy pods for 5m)
  - `CloudflareTunnelDown` (critical, 0 healthy pods for 2m)
- [ ] 4.28.6.3 Apply and verify:
  ```bash
  kubectl-homelab apply -f manifests/monitoring/cloudflare-alerts.yaml
  ```

### 4.28.7 Remove Redundant Alert

- [ ] 4.28.7.1 Remove `LokiStorageLow` from `manifests/monitoring/logging-alerts.yaml`
- [ ] 4.28.7.2 Verify default `KubePersistentVolumeFillingUp` covers Loki PVC:
  ```bash
  curl -s 'http://localhost:9090/api/v1/query?query=kubelet_volume_stats_available_bytes{persistentvolumeclaim="storage-loki-0"}' | python3 -m json.tool | head -10
  ```
- [ ] 4.28.7.3 Apply updated logging-alerts:
  ```bash
  kubectl-homelab apply -f manifests/monitoring/logging-alerts.yaml
  ```

### 4.28.8 End-to-End Verification

- [ ] 4.28.8.1 Verify all 14 new alerts + 3 fixed alerts appear in Prometheus (Status → Rules)
- [ ] 4.28.8.2 Verify `LokiStorageLow` is gone from rules list
- [ ] 4.28.8.3 Verify no false positives firing (all volumes healthy, certs valid, tunnel up, all services running)
- [ ] 4.28.8.4 Test critical alert routing — temporarily lower a threshold or use test-alert pattern to confirm Discord #incidents + email delivery
- [ ] 4.28.8.5 Verify warning alert routes to Discord #status only (no email)

### 4.28.9 Security & Commit

- [ ] 4.28.9.1 `/audit-security`
- [ ] 4.28.9.2 `/commit` (infrastructure)

### 4.28.10 ARR Stack Dashboard Improvements

> From Phase 4.26 learnings — manual `kubectl logs` was needed to debug indexer issues, download failures, and quality profile rejections. These operational insights should be visible in Grafana.

- [ ] 4.28.10.1 Add Loki log panels to ARR Stack dashboard:
  - Radarr/Sonarr grab/reject logs (which indexer, quality score, rejection reason)
  - Prowlarr indexer search activity (queries per indexer, failure rate)
  - Byparr Cloudflare solve success/failure rate
- [ ] 4.28.10.2 Add qBittorrent download panels:
  - Active downloads (count, speed, ETA)
  - Download history by indexer source (1337x vs YTS vs Bitsearch)
  - Failed/stalled downloads
- [ ] 4.28.10.3 Add Radarr/Sonarr quality panels:
  - Custom format score distribution (how many releases are YTS fallback vs proper BluRay)
  - Upgrade queue (movies/shows waiting for better quality)
  - Import list activity (new additions per list per day)
- [ ] 4.28.10.4 Add Tdarr transcoding panels:
  - Transcode queue size and progress
  - Space saved by transcoding (original vs transcoded size)
  - QSV GPU utilization during transcode window

### 4.28.11 Documentation & Release

> Second commit: documentation updates and audit.

- [ ] 4.28.11.1 Update `docs/todo/README.md` — add Phase 4.28 to phase index + release mapping
- [ ] 4.28.11.2 Update `README.md` (root) — note observability improvements in services list
- [ ] 4.28.11.3 Update `VERSIONS.md` — note new ServiceMonitors
- [ ] 4.28.11.4 Update `docs/reference/CHANGELOG.md` — add alerting improvements entry
- [ ] 4.28.11.5 Update `docs/context/Monitoring.md` — add all new alert files, probes, and ServiceMonitors to inventory
- [ ] 4.28.11.6 Create `docs/rebuild/v0.27.0-alerting-improvements.md`
- [ ] 4.28.11.7 `/audit-docs`
- [ ] 4.28.11.8 `/commit` (documentation)
- [ ] 4.28.11.9 `/release v0.27.0 "Alerting & Observability Improvements"`
- [ ] 4.28.11.10 Move this file to `docs/todo/completed/`

---

## Verification Checklist

### Bug Fixes
- [ ] `JellyfinDown` alert now fires correctly (Blackbox probe providing metrics)
- [ ] `AdGuardDNSUnreachable` alert has correct labels (`release: prometheus`)
- [ ] `UptimeKumaDown` alert active on existing probe

### New Probes (7 probes)
- [ ] `probe_success{job="jellyfin"}` metric present
- [ ] `probe_success{job="ghost"}` metric present
- [ ] `probe_success{job="invoicetron"}` metric present
- [ ] `probe_success{job="portfolio"}` metric present
- [ ] `probe_success{job="seerr"}` metric present
- [ ] `probe_success{job="tdarr"}` metric present
- [ ] `probe_success{job="byparr"}` metric present

### New Alerts (14 alerts)
- [ ] `GhostDown` rule active (warning)
- [ ] `InvoicetronDown` rule active (warning)
- [ ] `PortfolioDown` rule active (warning)
- [ ] `SeerrDown` rule active (warning)
- [ ] `TdarrDown` rule active (warning)
- [ ] `ByparrDown` rule active (warning)
- [ ] `UptimeKumaDown` rule active (warning)
- [ ] `LonghornVolumeDegraded` rule active (warning)
- [ ] `LonghornVolumeReplicaFailed` rule active (critical)
- [ ] `CertificateExpiringSoon` rule active (warning)
- [ ] `CertificateExpiryCritical` rule active (critical)
- [ ] `CertificateNotReady` rule active (critical)
- [ ] `CloudflareTunnelDegraded` rule active (warning)
- [ ] `CloudflareTunnelDown` rule active (critical)

### ServiceMonitors
- [ ] Longhorn ServiceMonitor created and metrics visible in Prometheus
- [ ] cert-manager ServiceMonitor created and certificate expiry metrics visible

### Cleanup
- [ ] `LokiStorageLow` removed from logging-alerts.yaml

### Routing
- [ ] Critical alerts route to Discord #incidents + email (3 recipients)
- [ ] Warning alerts route to Discord #status only (no email)
- [ ] No false positives firing

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

# Remove new ServiceMonitors
kubectl-homelab delete servicemonitor longhorn -n longhorn-system
kubectl-homelab delete servicemonitor cert-manager -n cert-manager

# Restore modified files
git checkout -- manifests/monitoring/logging-alerts.yaml
git checkout -- manifests/monitoring/adguard-dns-alert.yaml
git checkout -- manifests/monitoring/arr-alerts.yaml
kubectl-homelab apply -f manifests/monitoring/logging-alerts.yaml
kubectl-homelab apply -f manifests/monitoring/adguard-dns-alert.yaml
kubectl-homelab apply -f manifests/monitoring/arr-alerts.yaml
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
