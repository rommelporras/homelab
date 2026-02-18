# Phase 4.28: Alerting & Observability Improvements

> **Status:** Planned
> **Target:** v0.26.0
> **Prerequisite:** None (monitoring stack running since Phase 3.9)
> **Priority:** Medium (operational safety — not urgent, cluster healthy as of Feb 2026)
> **DevOps Topics:** Observability, capacity planning, proactive alerting, ServiceMonitor
> **CKA Topics:** PrometheusRule, ServiceMonitor, PersistentVolumeClaim metrics, certificate lifecycle

> **Purpose:** Close alerting gaps for Longhorn volume health, TLS certificate expiry, and Cloudflare Tunnel connectivity. Remove redundant custom alerts already covered by kube-prometheus-stack defaults.
>
> **Why:** An audit of the cluster's 177+ alert rules revealed that kube-prometheus-stack already covers PVC capacity (`KubePersistentVolumeFillingUp`) and node disk pressure (`NodeFilesystemSpaceFillingUp`). However, three critical areas have zero alerting:
> - **Longhorn volume health** — no metrics scraped, no alerts for degraded/faulted volumes
> - **TLS certificate expiry** — no metrics scraped, cert-manager renewal failures are silent
> - **Cloudflare Tunnel** — metrics ARE scraped but no alerts exist (public access can die silently)
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
| `adguard-dns-alert.yaml` | AdGuardDNSUnreachable | Good |

### Gaps Being Addressed

| Gap | Issue | Fix |
|-----|-------|-----|
| Longhorn volume health | No ServiceMonitor — metrics not scraped at all | Add ServiceMonitor + 2 alerts |
| cert-manager certificates | No ServiceMonitor — renewal failures are silent | Add ServiceMonitor + 3 alerts |
| Cloudflare Tunnel | ServiceMonitor exists but zero alerts defined | Add 2 alerts |
| Redundant LokiStorageLow | Duplicates default `KubePersistentVolumeFillingUp` | Remove |

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

### New Alert Rules (7 total)

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

### Cleanup

| Action | File | Reason |
|--------|------|--------|
| Remove `LokiStorageLow` | `logging-alerts.yaml` | Redundant with default `KubePersistentVolumeFillingUp` |

---

## PromQL Expressions

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

### Files to Create

| File | Type | Purpose |
|------|------|---------|
| `manifests/monitoring/longhorn-servicemonitor.yaml` | ServiceMonitor | Scrape Longhorn manager metrics (port 9500) |
| `manifests/monitoring/storage-alerts.yaml` | PrometheusRule | Longhorn volume degraded/faulted alerts |
| `manifests/monitoring/certmanager-servicemonitor.yaml` | ServiceMonitor | Scrape cert-manager metrics (port 9402) |
| `manifests/monitoring/cert-alerts.yaml` | PrometheusRule | Certificate expiry + not-ready alerts |
| `manifests/monitoring/cloudflare-alerts.yaml` | PrometheusRule | Tunnel degraded/down alerts |

### Files to Modify

| File | Change |
|------|--------|
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

---

## Tasks

### 4.28.1 Add Longhorn Metrics & Alerts

- [ ] 4.28.1.1 Verify no existing ServiceMonitor for Longhorn:
  ```bash
  kubectl-homelab -n longhorn-system get servicemonitor
  ```
- [ ] 4.28.1.2 Check `longhorn-backend` service labels and port name:
  ```bash
  kubectl-homelab -n longhorn-system get svc longhorn-backend -o yaml | grep -A10 'ports\|selector\|labels'
  ```
- [ ] 4.28.1.3 Create `manifests/monitoring/longhorn-servicemonitor.yaml`
- [ ] 4.28.1.4 Apply and wait for metrics to appear:
  ```bash
  kubectl-homelab apply -f manifests/monitoring/longhorn-servicemonitor.yaml
  # Wait ~2 minutes for scrape, then verify
  ```
- [ ] 4.28.1.5 Verify Longhorn metrics in Prometheus:
  ```bash
  # Port-forward Prometheus and query
  kubectl-homelab -n monitoring port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090 &
  curl -s 'http://localhost:9090/api/v1/query?query=longhorn_volume_robustness' | python3 -m json.tool | head -20
  ```
- [ ] 4.28.1.6 Verify `longhorn_volume_robustness` actual values match expected (0=unknown, 1=healthy, 2=degraded, 3=faulted)
- [ ] 4.28.1.7 Create `manifests/monitoring/storage-alerts.yaml` with `LonghornVolumeDegraded` (warning) and `LonghornVolumeReplicaFailed` (critical)
- [ ] 4.28.1.8 Apply and verify rules appear:
  ```bash
  kubectl-homelab apply -f manifests/monitoring/storage-alerts.yaml
  ```

### 4.28.2 Add cert-manager Metrics & Alerts

- [ ] 4.28.2.1 Verify no existing ServiceMonitor for cert-manager:
  ```bash
  kubectl-homelab -n cert-manager get servicemonitor
  ```
- [ ] 4.28.2.2 Check cert-manager service labels and metrics port:
  ```bash
  kubectl-homelab -n cert-manager get svc cert-manager -o yaml | grep -A10 'ports\|selector\|labels'
  ```
- [ ] 4.28.2.3 Create `manifests/monitoring/certmanager-servicemonitor.yaml`
- [ ] 4.28.2.4 Apply and wait for metrics:
  ```bash
  kubectl-homelab apply -f manifests/monitoring/certmanager-servicemonitor.yaml
  ```
- [ ] 4.28.2.5 Verify cert-manager metrics in Prometheus:
  ```bash
  curl -s 'http://localhost:9090/api/v1/query?query=certmanager_certificate_expiration_timestamp_seconds' | python3 -m json.tool | head -20
  ```
- [ ] 4.28.2.6 Verify all 3 certificates appear in metrics (wildcard-k8s-tls, wildcard-dev-k8s-tls, wildcard-stg-k8s-tls)
- [ ] 4.28.2.7 Create `manifests/monitoring/cert-alerts.yaml` with:
  - `CertificateExpiringSoon` (warning, <30d)
  - `CertificateExpiryCritical` (critical, <7d)
  - `CertificateNotReady` (critical)
- [ ] 4.28.2.8 Apply and verify:
  ```bash
  kubectl-homelab apply -f manifests/monitoring/cert-alerts.yaml
  ```

### 4.28.3 Add Cloudflare Tunnel Alerts

- [ ] 4.28.3.1 Verify cloudflared metrics are being scraped:
  ```bash
  curl -s 'http://localhost:9090/api/v1/query?query=up{job="cloudflared"}' | python3 -m json.tool | head -10
  ```
- [ ] 4.28.3.2 Create `manifests/monitoring/cloudflare-alerts.yaml` with:
  - `CloudflareTunnelDegraded` (warning, <2 healthy pods for 5m)
  - `CloudflareTunnelDown` (critical, 0 healthy pods for 2m)
- [ ] 4.28.3.3 Apply and verify:
  ```bash
  kubectl-homelab apply -f manifests/monitoring/cloudflare-alerts.yaml
  ```

### 4.28.4 Remove Redundant Alert

- [ ] 4.28.4.1 Remove `LokiStorageLow` from `manifests/monitoring/logging-alerts.yaml`
- [ ] 4.28.4.2 Verify default `KubePersistentVolumeFillingUp` covers Loki PVC:
  ```bash
  curl -s 'http://localhost:9090/api/v1/query?query=kubelet_volume_stats_available_bytes{persistentvolumeclaim="storage-loki-0"}' | python3 -m json.tool | head -10
  ```
- [ ] 4.28.4.3 Apply updated logging-alerts:
  ```bash
  kubectl-homelab apply -f manifests/monitoring/logging-alerts.yaml
  ```

### 4.28.5 End-to-End Verification

- [ ] 4.28.5.1 Verify all 7 new alerts appear in Prometheus (Status → Rules)
- [ ] 4.28.5.2 Verify `LokiStorageLow` is gone from rules list
- [ ] 4.28.5.3 Verify no false positives firing (all volumes healthy, certs valid, tunnel up)
- [ ] 4.28.5.4 Test critical alert routing — temporarily lower a threshold or use test-alert pattern to confirm Discord #incidents + email delivery
- [ ] 4.28.5.5 Verify warning alert routes to Discord #status only (no email)

### 4.28.6 Security & Commit

- [ ] 4.28.6.1 `/audit-security`
- [ ] 4.28.6.2 `/commit` (infrastructure)

### 4.28.7 Documentation & Release

> Second commit: documentation updates and audit.

- [ ] 4.28.7.1 Update `docs/todo/README.md` — add Phase 4.28 to phase index + release mapping
- [ ] 4.28.7.2 Update `README.md` (root) — note observability improvements in services list
- [ ] 4.28.7.3 Update `VERSIONS.md` — note new ServiceMonitors
- [ ] 4.28.7.4 Update `docs/reference/CHANGELOG.md` — add alerting improvements entry
- [ ] 4.28.7.5 Update `docs/context/Monitoring.md` — add all new alert files + ServiceMonitors to inventory
- [ ] 4.28.7.6 Create `docs/rebuild/v0.26.0-alerting-improvements.md`
- [ ] 4.28.7.7 `/audit-docs`
- [ ] 4.28.7.8 `/commit` (documentation)
- [ ] 4.28.7.9 `/release v0.26.0 "Alerting & Observability Improvements"`
- [ ] 4.28.7.10 Move this file to `docs/todo/completed/`

---

## Verification Checklist

- [ ] Longhorn ServiceMonitor created and metrics visible in Prometheus
- [ ] cert-manager ServiceMonitor created and certificate expiry metrics visible
- [ ] `LonghornVolumeDegraded` rule active (warning)
- [ ] `LonghornVolumeReplicaFailed` rule active (critical)
- [ ] `CertificateExpiringSoon` rule active (warning)
- [ ] `CertificateExpiryCritical` rule active (critical)
- [ ] `CertificateNotReady` rule active (critical)
- [ ] `CloudflareTunnelDegraded` rule active (warning)
- [ ] `CloudflareTunnelDown` rule active (critical)
- [ ] `LokiStorageLow` removed from logging-alerts.yaml
- [ ] Critical alerts route to Discord #incidents + email (3 recipients)
- [ ] Warning alerts route to Discord #status only (no email)
- [ ] No false positives firing

---

## Rollback

```bash
# Remove new alerts
kubectl-homelab delete prometheusrule storage-alerts -n monitoring
kubectl-homelab delete prometheusrule cert-alerts -n monitoring
kubectl-homelab delete prometheusrule cloudflare-alerts -n monitoring

# Remove new ServiceMonitors
kubectl-homelab delete servicemonitor longhorn -n longhorn-system
kubectl-homelab delete servicemonitor cert-manager -n cert-manager

# Restore LokiStorageLow
git checkout -- manifests/monitoring/logging-alerts.yaml
kubectl-homelab apply -f manifests/monitoring/logging-alerts.yaml
```

---

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Drop PVCSpaceLow alert | Default `KubePersistentVolumeFillingUp` already covers this | Avoids redundant alerting — kube-prometheus-stack has 2-tier PVC alerts |
| Drop LonghornNodeStorageLow alert | Default `NodeFilesystemSpaceFillingUp` already covers this | Predictive alerts (24h/4h fill rate) are better than static threshold |
| Remove LokiStorageLow | Redundant | Default `KubePersistentVolumeFillingUp` covers all PVCs including Loki |
| Longhorn robustness alerts only | Degraded + faulted | The gap defaults can't cover — only Longhorn knows replica health |
| cert-manager 30d/7d thresholds | Let's Encrypt = 90d cycle, renews at 30d | 30d warning = first sign of renewal failure, 7d = urgent |
| Cloudflare 2m down threshold | Tunnel failure = all public access dies | 2m is aggressive but appropriate — public-facing service |
| 60s scrape for Longhorn | Volume health changes slowly | Saves Prometheus resources vs 15s default |
| 300s scrape for cert-manager | Certificate expiry changes daily | 5-minute interval is more than sufficient |

---

## 4.28.8 ARR Stack Dashboard Improvements (from Phase 4.26 learnings)

> During Phase 4.26 deployment, manual `kubectl logs` was needed to debug indexer issues, download failures, and quality profile rejections. These operational insights should be visible in Grafana.

- [ ] 4.28.8.1 Add Loki log panels to ARR Stack dashboard:
  - Radarr/Sonarr grab/reject logs (which indexer, quality score, rejection reason)
  - Prowlarr indexer search activity (queries per indexer, failure rate)
  - Byparr Cloudflare solve success/failure rate
- [ ] 4.28.8.2 Add qBittorrent download panels:
  - Active downloads (count, speed, ETA)
  - Download history by indexer source (1337x vs YTS vs Bitsearch)
  - Failed/stalled downloads
- [ ] 4.28.8.3 Add Radarr/Sonarr quality panels:
  - Custom format score distribution (how many releases are YTS fallback vs proper BluRay)
  - Upgrade queue (movies/shows waiting for better quality)
  - Import list activity (new additions per list per day)
- [ ] 4.28.8.4 Add Tdarr transcoding panels:
  - Transcode queue size and progress
  - Space saved by transcoding (original vs transcoded size)
  - QSV GPU utilization during transcode window

---

## Not In Scope (Phase 5 or Later)

| Gap | Phase | Rationale |
|-----|-------|-----------|
| GitLab service + database health alerts | Phase 5 | Application-level monitoring, lower priority |
| Ghost / Invoicetron health alerts | Phase 5 | Application-level, already have Blackbox probes |
| Gateway API / HTTPRoute health | Phase 5 | No Prometheus metrics available — needs Blackbox probes for each route |
| Backup job success monitoring | Phase 5 | No automated backups exist yet |
| NFS storage alerting | Phase 4.25 | Relevant when ARR Stack uses NFS for media |
| GitLab Minio PVC resize (73.8% used) | Track separately | Operational task, not an alerting change |

---

## CKA Learnings

| Topic | Concept |
|-------|---------|
| ServiceMonitor | Custom Prometheus scrape targets for non-default services (Longhorn, cert-manager) |
| PrometheusRule | Custom alerting rules with PromQL expressions and severity-based routing |
| Certificate lifecycle | cert-manager metrics for monitoring Let's Encrypt renewal health |
| Longhorn internals | Volume robustness model (healthy → degraded → faulted) |
| Alertmanager routing | Leveraging existing severity-based routing without config changes |
| Default rule awareness | Understanding kube-prometheus-stack defaults to avoid redundant custom alerts |
