# Phase 4.22: Cloudflare Traffic Analytics

> **Status:** Planned
> **Target:** v0.18.0
> **Prerequisite:** kube-prometheus-stack + Grafana running, Cloudflare Tunnel active (Phase 4.5)
> **Priority:** Medium (observability for public sites)
> **DevOps Topics:** Prometheus exporters, Cloudflare API, Grafana dashboards, Geomap visualization
> **CKA Topics:** Deployment, Secret, ServiceMonitor, ConfigMap

> **Purpose:** Deploy a Cloudflare metrics exporter and Grafana dashboard to monitor traffic, visitor geography, error rates, and cache performance for all public sites.
>
> **Public sites:** `blog.rommelporras.com`, `www.rommelporras.com`, `status.rommelporras.com`, `invoicetron.rommelporras.com`
>
> **Why:** GA4 tracks page views but not infrastructure metrics. This gives us request rates, status codes, cache hit rates, bandwidth, threats blocked, and visitor country breakdown — all in our existing Grafana.

---

## Architecture

```
Cloudflare GraphQL API ──poll──→ cloudflare-exporter ──scrape──→ Prometheus
    (free plan)                   (monitoring ns)                    │
                                                                    ▼
                                                                Grafana
                                                          "Cloudflare Traffic"
                                                              dashboard
```

## Technology Decision

| Approach | Effort | Data | Free Plan? | Self-hosted? |
|----------|--------|------|------------|-------------|
| **lablabs/cloudflare-exporter** | Low | Country, status, cache, bandwidth | Yes (`FREE_TIER=true`) | Yes |
| Grafana Infinity plugin | Medium | Full GraphQL flexibility | Yes | Yes |
| Grafana Cloudflare plugin | Low | Best | **No (Enterprise only)** | No |
| nginx sidecar + GeoIP | High | Individual visitor IPs, city-level | Yes | Yes |

**Decision:** `lablabs/cloudflare-exporter` for Tier 1. Can layer nginx + MaxMind GeoIP later for city-level detail.

---

## Exporter Reference

**Image:** `ghcr.io/lablabs/cloudflare_exporter:0.0.16` (latest app release, May 2024 — confirmed current, Helm chart actively maintained through Dec 2025)
**Helm chart:** `cloudflare-exporter-0.2.3` (available but raw manifests preferred for repo consistency)
**Port:** 8080 (`/metrics`)
**Startup delay:** 300s (`SCRAPE_DELAY`) — exporter waits for Cloudflare GraphQL data to stabilize before exposing metrics. Liveness probe must account for this.

### Key Environment Variables

| Variable | Value | Notes |
|----------|-------|-------|
| `CF_API_TOKEN` | From Secret | Cloudflare API token |
| `FREE_TIER` | `true` | Restricts to free plan metrics |
| `SCRAPE_DELAY` | `300` | Seconds before first scrape (default) |
| `SCRAPE_INTERVAL` | `60` | Query frequency in seconds |
| `LISTEN` | `:8080` | Bind address |
| `LOG_LEVEL` | `info` | `error`, `warn`, `info`, `debug` |

### Prometheus Metrics (Free Plan)

**Requests:**
- `cloudflare_zone_requests_total` — Total requests per zone
- `cloudflare_zone_requests_cached` — Cached requests
- `cloudflare_zone_requests_status` — By HTTP status code (labels: `zone`, `status`)
- `cloudflare_zone_requests_country` — By country (labels: `zone`, `country`, `region`)
- `cloudflare_zone_requests_content_type` — By content type
- `cloudflare_zone_requests_ssl_encrypted` — SSL-encrypted requests

**Bandwidth:**
- `cloudflare_zone_bandwidth_total` — Total bytes
- `cloudflare_zone_bandwidth_cached` — Cached bytes
- `cloudflare_zone_bandwidth_country` — By country

**Threats:**
- `cloudflare_zone_threats_total` — Total threats
- `cloudflare_zone_threats_country` — By country
- `cloudflare_zone_threats_type` — By type

**Visitors:**
- `cloudflare_zone_pageviews_total` — Page views
- `cloudflare_zone_uniques_total` — Unique visitors

**Tunnel (bonus — since we use Cloudflare Tunnel):**
- `cloudflare_tunnel_health_status` — 0=unhealthy, 1=healthy, 2=degraded, 3=inactive
- `cloudflare_tunnel_connector_active_connections` — Active connections per connector

**Not available on free plan:** Per-path analytics, colocation metrics, origin latency (p50/p95/p99).

---

## Prerequisites

- [ ] Cloudflare API Token with these permissions:
  - Account > Account Analytics > Read
  - Account > Cloudflare Tunnel > Read (for tunnel metrics)
  - Zone > Analytics > Read
  - Zone Resources: All zones
- [ ] Zone ID from Cloudflare dashboard (Settings > General > Zone ID)

---

## Tasks

### 4.22.1 Cloudflare API Setup

- [ ] 4.22.1.1 Create Cloudflare API Token at `dash.cloudflare.com/profile/api-tokens`:
  - Permission: Account > Account Analytics > Read
  - Permission: Account > Cloudflare Tunnel > Read
  - Permission: Zone > Analytics > Read
  - Zone Resources: Include > All zones
- [ ] 4.22.1.2 Get Zone ID from Cloudflare dashboard
- [ ] 4.22.1.3 Store in 1Password: `op://Kubernetes/Cloudflare Exporter/api-token`

### 4.22.2 Create Manifests

- [ ] 4.22.2.1 Create `manifests/monitoring/cloudflare-exporter.yaml` — Deployment + Service + ServiceMonitor (single file, same pattern as other exporters)
  - Image: `ghcr.io/lablabs/cloudflare_exporter:0.0.16`
  - Env: `CF_API_TOKEN` from Secret, `FREE_TIER=true`, `LOG_LEVEL=info`
  - Secret created imperatively from 1Password (same pattern as cloudflared-token)
- [ ] 4.22.2.2 Security context:
  - `runAsNonRoot: true`, `runAsUser: 65534`, `runAsGroup: 65534`
  - `readOnlyRootFilesystem: true`
  - `automountServiceAccountToken: false`
  - `capabilities.drop: [ALL]`
  - `seccompProfile.type: RuntimeDefault`
- [ ] 4.22.2.3 Resource limits: `cpu: 25m/100m`, `memory: 64Mi/128Mi`
- [ ] 4.22.2.4 Probes — must account for 300s startup delay:
  - Liveness: `httpGet /metrics :8080`, `initialDelaySeconds: 320`
  - Readiness: `httpGet /metrics :8080`, `initialDelaySeconds: 310`
- [ ] 4.22.2.5 ServiceMonitor: `interval: 120s` (exporter refreshes every 60s, no point scraping faster)

### 4.22.3 Deploy & Verify

- [ ] 4.22.3.1 Create K8s Secret from 1Password:
  ```bash
  kubectl-homelab create secret generic cloudflare-exporter-token \
    --from-literal=CF_API_TOKEN="$(op read 'op://Kubernetes/Cloudflare Exporter/api-token')" \
    -n monitoring
  ```
- [ ] 4.22.3.2 Apply manifests and verify pod running (takes ~5 min to become ready due to SCRAPE_DELAY)
- [ ] 4.22.3.3 Verify Prometheus scraping: `up{job="cloudflare-exporter"} == 1`
- [ ] 4.22.3.4 Verify metrics exist: `cloudflare_zone_requests_total`

### 4.22.4 Build Grafana Dashboard

**Starting point:** Import community dashboard [#13133](https://grafana.com/grafana/dashboards/13133) (official lablabs dashboard), then customize. Alternative: [#17156](https://grafana.com/grafana/dashboards/17156-cloudflare-zone-analytics/).

**Template variable:** `zone = label_values(cloudflare_zone_requests_total, zone)` (multi-select dropdown)

Target panel layout:

| Row | Panel | Type | Width | PromQL |
|-----|-------|------|-------|--------|
| Overview | Total Requests (24h) | Stat | w=6 | `sum(increase(cloudflare_zone_requests_total{zone=~"$zone"}[24h]))` |
| Overview | Unique Visitors (24h) | Stat | w=6 | `sum(increase(cloudflare_zone_uniques_total{zone=~"$zone"}[24h]))` |
| Overview | Cache Hit Rate | Gauge | w=6 | `sum(increase(...cached[24h])) / sum(increase(...total[24h])) * 100` |
| Overview | Threats Blocked | Stat | w=6 | `sum(increase(cloudflare_zone_threats_total{zone=~"$zone"}[24h]))` |
| Traffic | Requests by Site | Timeseries | w=24 | `sum by (zone) (increase(...total[$__rate_interval]))` |
| Geography | Visitors by Country | Geomap | w=14 | `sum by (country) (increase(...country[$__range]))` (Instant, Lookup mode) |
| Geography | Top Countries | Table | w=10 | `topk(15, sum by (country) (increase(...country[24h])))` |
| Status | HTTP Status Codes | Bar chart | w=12 | `sum by (status) (increase(...status[$__rate_interval]))` |
| Status | Error Rate by Site | Timeseries | w=12 | `sum(increase(...status{status=~"5.."}[1h])) / sum(increase(...total[1h])) * 100` |
| Bandwidth | Bandwidth by Site | Timeseries | w=12 | `sum by (zone) (increase(...bandwidth_total[$__rate_interval]))` |
| Bandwidth | Cached vs Uncached | Timeseries | w=12 | Stacked: cached vs (total - cached) |
| Threats | Threats Over Time | Timeseries | w=12 | `sum by (zone) (increase(...threats_total[$__rate_interval]))` |
| Threats | Threats by Type | Pie | w=12 | `sum by (type) (increase(...threats_type[24h]))` |
| Tunnel | Tunnel Status | Stat | w=8 | `cloudflare_tunnel_health_status` (value map: 0=red, 1=green, 2=yellow) |
| Tunnel | Active Connections | Timeseries | w=8 | `cloudflare_tunnel_connector_active_connections` |
| Tunnel | Connector Info | Table | w=8 | `cloudflare_tunnel_connector_info` (version, arch, origin_ip) |

**Geomap note:** `cloudflare_zone_requests_country` uses ISO 3166-1 alpha-2 codes (`US`, `PH`, `GB`). Grafana's built-in Countries gazetteer supports these natively — Lookup mode with the `country` label maps automatically.

- [ ] 4.22.4.1 Import dashboard #13133 as starting point
- [ ] 4.22.4.2 Customize with panels above (add Geomap, Tunnel section)
- [ ] 4.22.4.3 Create `manifests/monitoring/cloudflare-dashboard-configmap.yaml` (sidecar label `grafana_dashboard: "1"`)
- [ ] 4.22.4.4 Verify dashboard renders with real traffic data
- [ ] 4.22.4.5 Tune Geomap panel — verify country codes map correctly

### 4.22.5 Alert Rules

- [ ] 4.22.5.1 Create `manifests/monitoring/cloudflare-alerts.yaml` (PrometheusRule):

| Alert | Expression | Severity | Notes |
|-------|-----------|----------|-------|
| `CloudflareTrafficSpike` | requests(1h) > 5x 7-day avg | warning | Unusual traffic surge |
| `CloudflareZeroTraffic` | requests(1h) == 0 | warning | Site may be unreachable |
| `CloudflareHighErrorRate` | 5xx/total > 10% for 15m | critical | Origin errors |
| `CloudflareHigh4xxRate` | 4xx/total > 30% for 15m | warning | Bot scanning or misconfig |
| `CloudflareThreatSpike` | threats(1h) > 50 | warning | Attack activity |
| `CloudflareLowCacheRate` | cached/total < 30% for 24h | info | Review cache rules |
| `CloudflareExporterDown` | `up{job="cloudflare-exporter"} == 0` | critical | Exporter unreachable |
| `CloudflareTunnelUnhealthy` | `health_status == 0` for 5m | critical | Public sites unreachable |
| `CloudflareTunnelDegraded` | `health_status == 2` for 10m | warning | Tunnel degraded |

### 4.22.6 Optional: CF-IPCountry Headers

- [ ] 4.22.6.1 Enable "Add visitor location headers" in Cloudflare Managed Transforms
  - This adds `CF-Connecting-IP` and `CF-IPCountry` to all requests hitting origin
  - Useful for future Tier 2 (nginx sidecar + GeoIP enrichment via Alloy)

### 4.22.7 Documentation & Release

> Second commit: documentation updates and audit.

- [ ] 4.22.7.1 Update `docs/todo/README.md` — add Phase 4.22 to phase index + namespace table
- [ ] 4.22.7.2 Update `README.md` (root) — add Cloudflare analytics to services/monitoring list
- [ ] 4.22.7.3 Update `VERSIONS.md` — add Cloudflare exporter version
- [ ] 4.22.7.4 Update `docs/reference/CHANGELOG.md` — add exporter + dashboard decision entry
- [ ] 4.22.7.5 Update `docs/context/Monitoring.md` — add Cloudflare exporter section
- [ ] 4.22.7.6 Update `docs/context/ExternalServices.md` — document API token scope
- [ ] 4.22.7.7 Update `docs/context/Secrets.md` — add Cloudflare Exporter 1Password item
- [ ] 4.22.7.8 Create `docs/rebuild/v0.18.0-cloudflare-analytics.md`
- [ ] 4.22.7.9 `/audit-docs`
- [ ] 4.22.7.10 `/commit`
- [ ] 4.22.7.11 `/release v0.18.0 "Cloudflare Traffic Analytics"`
- [ ] 4.22.7.12 Move this file to `docs/todo/completed/`

---

## Future: Tier 2 (City-Level GeoIP)

If country-level from the exporter isn't enough, the upgrade path is:

1. Add nginx sidecar to Ghost prod that logs `CF-Connecting-IP` + `CF-IPCountry`
2. Register for MaxMind GeoLite2 (free, ~70MB database)
3. Mount GeoLite2-City.mmdb into Alloy DaemonSet
4. Add `stage.geoip` to Alloy pipeline for Ghost logs
5. Import NGINX Logs & Geo Map dashboard (Grafana #12268)
6. Build Geomap panels with city-level visitor locations

This is Phase 4.22+ work if needed — the exporter covers 80% of the use case.

---

## Files to Create

| File | Type | Purpose |
|------|------|---------|
| `manifests/monitoring/cloudflare-exporter.yaml` | Deployment + Service + ServiceMonitor | Exporter (single file, same pattern as other exporters) |
| `manifests/monitoring/cloudflare-dashboard-configmap.yaml` | ConfigMap | Grafana dashboard JSON |
| `manifests/monitoring/cloudflare-alerts.yaml` | PrometheusRule | 9 alert rules (traffic, errors, threats, tunnel, exporter) |

---

## Verification Checklist

- [ ] Exporter pod running in `monitoring` namespace
- [ ] Prometheus scraping exporter (`up == 1`)
- [ ] `cloudflare_zone_requests_total` metric has data
- [ ] Grafana dashboard renders with real traffic data
- [ ] Geomap panel shows visitor countries
- [ ] Alert rules loaded in Alertmanager (inactive = correct initial state)

---

## Rollback

```bash
kubectl-homelab delete -f manifests/monitoring/cloudflare-exporter.yaml
kubectl-homelab delete -f manifests/monitoring/cloudflare-dashboard-configmap.yaml
kubectl-homelab delete -f manifests/monitoring/cloudflare-alerts.yaml
```
