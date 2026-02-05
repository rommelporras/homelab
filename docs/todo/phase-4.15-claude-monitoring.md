# Phase 4.15: Claude Code Monitoring

> **Status:** Planned
> **Target:** v0.15.0
> **Prerequisite:** Phase 3.5-3.8 complete (kube-prometheus-stack + Loki running)
> **DevOps Topics:** OpenTelemetry, OTLP, metrics pipelines, log aggregation
> **CKA Topics:** Deployment, Service (LoadBalancer), ConfigMap, ServiceMonitor

> **Purpose:** Centralize Claude Code usage monitoring on the homelab K8s cluster so any machine on TRUSTED_WIFI or LAN VLAN can report metrics and events to a single Prometheus+Loki+Grafana instance.
>
> **Replaces:** Local Docker Compose stack at `~/personal/claude-monitoring` (OTel Collector + Prometheus + Grafana running on WSL only)
>
> **Source project:** https://github.com/rommelporras/claude-code-monitoring
>
> **Parallel work:** The open-source project v2.0.0 (Loki + events + updated dashboard) is developed alongside this phase. Configs and dashboard built here get backported to the open-source project.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│  Client Machines (any VLAN with SERVERS VLAN access)                │
│                                                                     │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐             │
│  │ WSL (desktop) │  │ Laptop       │  │ Other machine │             │
│  │ Claude Code   │  │ Claude Code  │  │ Claude Code   │             │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘             │
│         │ OTLP gRPC       │ OTLP gRPC       │ OTLP gRPC          │
│         │ (metrics+logs)  │ (metrics+logs)  │ (metrics+logs)      │
└─────────┼─────────────────┼─────────────────┼─────────────────────┘
          │                 │                 │
          ▼                 ▼                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│  K8s Cluster (SERVERS VLAN 10.10.30.0/24)                          │
│  monitoring namespace                                               │
│                                                                     │
│  ┌───────────────────────────────────────────┐                     │
│  │  OTel Collector (Deployment, 1 replica)    │                     │
│  │  - Receives: OTLP gRPC (:4317)            │                     │
│  │  - Exports:  Prometheus metrics (:8889)    │                     │
│  │  - Exports:  Logs to Loki (:3100)          │                     │
│  │  - Service:  LoadBalancer (Cilium L2)      │                     │
│  │  - VIP:      10.10.30.22                   │                     │
│  └──────────┬────────────────┬───────────────┘                     │
│             │                │                                      │
│  ServiceMonitor scrape       │ Loki push                            │
│             │                │                                      │
│             ▼                ▼                                      │
│  ┌─────────────────┐  ┌─────────────────┐                         │
│  │  Prometheus      │  │  Loki           │                         │
│  │  (existing)      │  │  (existing)     │                         │
│  │  90-day retention│  │  90-day retention│                         │
│  │  claude_code_*   │  │  Claude events  │                         │
│  └────────┬────────┘  └────────┬────────┘                         │
│           │ PromQL             │ LogQL                              │
│           ▼                    ▼                                    │
│  ┌───────────────────────────────────────────┐                     │
│  │  Grafana (existing)                        │                     │
│  │  - grafana.k8s.rommelporras.com            │                     │
│  │  - Claude Code dashboard (ConfigMap)       │                     │
│  │  - Metrics panels (Prometheus)             │                     │
│  │  - Event panels (Loki)                     │                     │
│  └───────────────────────────────────────────┘                     │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Why Migrate?

| Aspect | Local Docker Compose | Homelab K8s |
|--------|---------------------|-------------|
| Retention | Single machine only | 90 days (Prometheus + Loki) |
| Access | localhost:3030 only | grafana.k8s.rommelporras.com |
| Multi-machine | Single WSL machine | Any device on TRUSTED_WIFI/LAN |
| Events/Logs | Discarded (debug exporter) | Stored in Loki (queryable) |
| Dashboard mgmt | JSON file on disk | ConfigMap in git (auto-provisioned) |
| Alerting | None | Alertmanager (Discord + Email) |
| Resilience | Dies with WSL restart | Longhorn PVC, auto-restart |
| Unified view | Separate Grafana | Same Grafana as cluster/UPS/logs |

---

## What is the OTel Collector?

Claude Code emits metrics and events via OTLP (OpenTelemetry Protocol). Prometheus and Loki don't natively speak OTLP. The OTel Collector is the bridge:

```
                                    ┌──→ Prometheus metrics (:8889)
Claude Code ──OTLP gRPC──→ OTel Collector
                                    └──→ Loki logs (push to :3100)
```

It receives OTLP on port 4317, processes data (batching, memory limits), and:
- Exposes metrics in Prometheus-compatible format on port 8889
- Pushes structured events to Loki's native OTLP endpoint (`/otlp`)

This is the same component running as `claude-otel-collector` in the Docker Compose stack, but with Loki export added.

---

## Networking Decision: LoadBalancer vs NodePort

**LoadBalancer (Cilium L2 Announcement)** — Recommended

| Consideration | LoadBalancer | NodePort |
|---------------|-------------|----------|
| Client config | Single stable VIP | Must know node IPs + random port |
| DNS | Can add `otel.k8s.rommelporras.com` | N/A |
| Port | Standard 4317 | 30000-32767 range |
| Consistency | Same pattern as AdGuard (.53), GitLab SSH (.21) | Different pattern |
| Failover | Cilium handles VIP migration | Client must retry another node |

**Decision:** Cilium L2 LoadBalancer at **10.10.30.22** (next free in IP pool after .21).

---

## Security: Why HTTP (not HTTPS)?

The OTLP gRPC connection carries telemetry counters (cost, tokens, session IDs) — not credentials or PII. All machines are on trusted VLANs with firewall-controlled access to SERVERS VLAN. Adding TLS to gRPC would require cert-manager issuing internal certs, distributing CA certs to every machine, and maintaining cert rotation — significant complexity for minimal benefit on a private LAN. Internal cluster telemetry pipelines (Alloy→Loki, node-exporter→Prometheus) also use plain HTTP.

---

## Metrics Reference

Claude Code emits these metrics via OTLP (documented at https://code.claude.com/docs/en/monitoring-usage):

| Metric | Type | Key Labels | Notes |
|--------|------|------------|-------|
| `claude_code_cost_usage_USD` | Counter | model | Cost per API request |
| `claude_code_token_usage_tokens` | Counter | model, type | type: input/output/cacheRead/cacheCreation |
| `claude_code_active_time_seconds` | Counter | — | Active time (not idle) |
| `claude_code_session_count` | Counter | — | Session start events |
| `claude_code_commit_count` | Counter | — | Git commits by Claude |
| `claude_code_pull_request_count` | Counter | — | PRs created |
| `claude_code_lines_of_code_count` | Counter | type | type: added/removed |
| `claude_code_code_edit_tool_decision` | Counter | tool, decision, language | Accept/reject of edits |

**Standard attributes on all metrics:** `session.id`, `user.account_uuid`, `organization.id`, `terminal.type`

**Important:** All metrics are per-session counters. When a session ends, the time series becomes stale. Always use `increase()` or `rate()` for aggregations, never raw `sum()`.

**Note:** Metric names above are the OTLP names with dots converted to underscores. The exact Prometheus-format names (with `_total` suffix for counters and unit suffixes like `_USD`, `_tokens`, `_seconds`) should be verified after deployment by querying: `curl -s "http://localhost:9090/api/v1/label/__name__/values" | jq '.data[] | select(startswith("claude_code"))'`

## Events Reference

Claude Code emits these events via `OTEL_LOGS_EXPORTER=otlp` (stored in Loki):

| Event | Key Fields | Use Case |
|-------|------------|----------|
| `claude_code.api_request` | model, cost_usd, duration_ms, token counts | API latency (p95/p99), per-request cost |
| `claude_code.api_error` | error, status_code, attempt | Error tracking, retry analysis |
| `claude_code.tool_result` | tool_name, success, duration_ms, decision | Tool performance analysis |
| `claude_code.tool_decision` | tool_name, decision, source | Compliance audit trail |
| `claude_code.user_prompt` | prompt_length | Session activity (content redacted by default) |

---

## Tasks

### 4.15.1 Allocate LoadBalancer VIP

- [ ] Assign **10.10.30.22** for OTel Collector in SERVERS VLAN
  - Current allocations: .10 (API VIP), .11-.13 (nodes), .20 (Gateway), .21 (GitLab SSH), .53 (AdGuard DNS)
  - Next free in Cilium IP pool (10.10.30.20-99): **.22**
- [ ] Update `docs/context/Networking.md` — add to VIPs table and DNS Records
- [ ] Update `VERSIONS.md` — add to LoadBalancer Services table

### 4.15.2 Create OTel Collector Manifests

Depends on 4.15.1 (need VIP for Service annotation).

- [ ] Create `manifests/monitoring/otel-collector-config.yaml` (ConfigMap)
  - Receivers: OTLP gRPC (:4317) + HTTP (:4318)
  - Processors: memory_limiter (512 MiB), batch (1024, 1s)
  - Exporters: prometheus (:8889), otlphttp/loki (http://loki.monitoring.svc.cluster.local:3100/otlp)
  - Pipelines: metrics → prometheus, logs → otlphttp/loki
  - Uses Loki native OTLP ingestion (not deprecated `loki` exporter)
  - No debug exporter (production)
- [ ] Verify Loki has OTLP ingestion enabled (`allow_structured_metadata: true`)
  - Default in Loki 3.0+ (our Loki is v3.6.3), but verify with: `kubectl-homelab -n monitoring exec deploy/loki -- cat /etc/loki/local-config.yaml | grep structured_metadata`
  - If not enabled, add `allow_structured_metadata: true` to `limits_config` in `helm/loki/values.yaml` and upgrade
- [ ] Create `manifests/monitoring/otel-collector.yaml` (Deployment + Service)
  - Deployment: 1 replica, `otel/opentelemetry-collector-contrib` (pinned version)
  - Ports: 4317 (gRPC), 4318 (HTTP), 8889 (Prometheus metrics)
  - Resources: requests 100m/128Mi, limits 500m/600Mi (must exceed memory_limiter's 512 MiB)
  - Service: type LoadBalancer, `lbipam.cilium.io/ips: "10.10.30.22"`
- [ ] Create `manifests/monitoring/otel-collector-servicemonitor.yaml`
  - Port: 8889, path: /metrics, interval: 15s
  - Namespace: monitoring
- [ ] Apply manifests and verify pod is running

### 4.15.3 Import Grafana Dashboard

- [ ] Build updated dashboard JSON with:
  - **Metrics panels** (Prometheus): cost, tokens, sessions (native session.count), PRs (native pull_request.count), active time, commits, lines, code edit decisions by language
  - **Event panels** (Loki): API latency (p95/p99), tool performance table, API error rate, recent tool executions log
  - **Layout**: 7 collapsible sections (Overview, Productivity, Sessions, Trends, Cost Analysis, Performance, Token & Efficiency)
  - Datasource UIDs: `prometheus` for metrics, `loki` for events
- [ ] Create `manifests/monitoring/claude-dashboard-configmap.yaml`
  - Label: `grafana_dashboard: "1"` (same pattern as UPS dashboard)
- [ ] Apply ConfigMap and verify dashboard loads in Grafana

### 4.15.4 Configure Client Machines

- [ ] Update `~/.zshrc` on WSL desktop:
  ```bash
  export CLAUDE_CODE_ENABLE_TELEMETRY=1
  export OTEL_METRICS_EXPORTER=otlp
  export OTEL_LOGS_EXPORTER=otlp
  export OTEL_EXPORTER_OTLP_PROTOCOL=grpc
  export OTEL_EXPORTER_OTLP_ENDPOINT=http://10.10.30.22:4317
  export OTEL_METRIC_EXPORT_INTERVAL=60000
  export OTEL_LOGS_EXPORT_INTERVAL=5000
  export OTEL_RESOURCE_ATTRIBUTES="machine.name=desktop"
  ```
  - For other machines, set `machine.name` to identify the source (e.g., `laptop`, `work-mac`)
- [ ] Document client setup in `docs/context/Monitoring.md` for other machines
- [ ] Test: run Claude Code session, verify metrics appear in Prometheus
- [ ] Test: verify events appear in Loki (`{service_name="claude-code"}`)

### 4.15.5 Validate End-to-End

- [ ] Verify all Prometheus metric panels render with real data
- [ ] Verify all Loki event panels render with real data
- [ ] Test from a second machine (laptop on TRUSTED_WIFI) if available
- [ ] Verify Alertmanager can route Claude alerts (test with low threshold)

### 4.15.6 Optional: Cost Alerts

- [ ] Create PrometheusRule for Claude Code cost alerts
  - Warning: daily spend exceeds threshold (e.g., $10/day)
  - Routes to Discord #status via existing Alertmanager config
- [ ] Create `manifests/monitoring/claude-alerts.yaml`

### 4.15.7 Retire Local Docker Compose Stack

- [ ] Verify homelab metrics and events flowing correctly for 24+ hours
- [ ] Stop local Docker Compose: `cd ~/personal/claude-monitoring && docker compose down`
- [ ] Remove Docker volumes: `docker volume rm claude_prometheus_data claude_grafana_data`
- [ ] Keep `~/personal/claude-monitoring` repo intact (open-source project, will receive v2.0.0 backport)

### 4.15.8 Documentation & Release

- [ ] Update all documents listed in the Documentation Checklist below
- [ ] Add rebuild guide `docs/rebuild/v0.15.0-claude-monitoring.md`
- [ ] Move this plan to `docs/todo/completed/`
- [ ] `/commit` — commit all manifests, dashboard, and documentation changes
- [ ] `/release v0.15.0 "Claude Code Monitoring"` — tag, push, create GitHub release

### 4.15.9 Backport to Open-Source Project

After homelab release, update `~/personal/claude-monitoring` for v2.0.0:

- [ ] Copy OTel Collector config (adapted for Docker Compose networking)
- [ ] Copy updated dashboard JSON (update datasource UIDs for Docker Compose)
- [ ] Update docker-compose.yml (add Loki service, pin image versions)
- [ ] Update README.md (architecture, metrics, events, K8s guide, upgrade notes)
- [ ] Add `docs/kubernetes.md` deployment guide (based on this phase's manifests)
- [ ] Update CHANGELOG.md with v2.0.0 entry
- [ ] `/commit` — commit all v2.0.0 changes
- [ ] `/release v2.0.0 "Loki Events & Dashboard Upgrade"` — tag, push, create GitHub release

---

## Documentation Checklist

Every document that needs updating for this phase, with specific changes:

### Must Update (blocking for release)

| Document | Changes |
|----------|---------|
| `docs/context/Monitoring.md` | Add OTel Collector section (version, namespace, VIP, purpose). Add "Claude Code Telemetry" subsection with client env vars. Add configuration files table entries for new manifests. Add Loki query example for Claude events. |
| `docs/context/Networking.md` | Add `OTel Collector | 10.10.30.22 | otel.k8s.rommelporras.com | Cilium L2` to VIPs table. Add DNS record if created. |
| `VERSIONS.md` | Add OTel Collector to "Helm Charts" or new "Monitoring Components" row. Add `OTel Collector | 10.10.30.22 | 4317/TCP | monitoring` to LoadBalancer Services table. Add entry to Version History table. |
| `docs/rebuild/v0.15.0-claude-monitoring.md` | New file — step-by-step rebuild guide for the OTel Collector deployment, dashboard import, and client configuration. |

### Should Update (important but non-blocking)

| Document | Changes |
|----------|---------|
| `docs/context/Architecture.md` | Add OTel Collector to component list if architecture decisions are tracked there. Note: external telemetry ingestion pattern. |
| `docs/todo/README.md` | Update phase summary table with 4.15 entry and status. |
| `README.md` (homelab root) | No change needed — CLAUDE.md references are sufficient. |

### Move After Release

| Document | Action |
|----------|--------|
| `docs/todo/phase-4.15-claude-monitoring.md` | Move to `docs/todo/completed/` |
| Update Status line | Change from "Planned" to "Complete (v0.15.0)" |

---

## Files to Create

| File | Type | Purpose |
|------|------|---------|
| `manifests/monitoring/otel-collector-config.yaml` | ConfigMap | OTel Collector pipeline config (OTLP → Prometheus + Loki) |
| `manifests/monitoring/otel-collector.yaml` | Deployment + Service | OTel Collector workload + LoadBalancer at 10.10.30.22 |
| `manifests/monitoring/otel-collector-servicemonitor.yaml` | ServiceMonitor | Prometheus scrape target for OTel Collector metrics |
| `manifests/monitoring/claude-dashboard-configmap.yaml` | ConfigMap | Grafana dashboard JSON (metrics + events panels) |
| `manifests/monitoring/claude-alerts.yaml` | PrometheusRule | Cost alerts (optional) |
| `docs/rebuild/v0.15.0-claude-monitoring.md` | Documentation | Rebuild guide |

## Files to Modify

| File | Change |
|------|--------|
| `docs/context/Monitoring.md` | Add OTel Collector section, Claude telemetry client config |
| `docs/context/Networking.md` | Add OTel VIP (10.10.30.22) to VIPs table |
| `VERSIONS.md` | Add OTel Collector entry, LoadBalancer Services, Version History |
| `docs/todo/README.md` | Add Phase 4.15 to summary table |

---

## Reference: OTel Collector Config (target for K8s)

```yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

processors:
  memory_limiter:
    check_interval: 1s
    limit_mib: 512
  batch:
    send_batch_size: 1024
    timeout: 1s

exporters:
  prometheus:
    endpoint: "0.0.0.0:8889"
    enable_open_metrics: true
  otlphttp/loki:
    endpoint: "http://loki.monitoring.svc.cluster.local:3100/otlp"

service:
  pipelines:
    metrics:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [prometheus]
    logs:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [otlphttp/loki]
```

Key differences from Docker Compose version:
- No debug exporter (production)
- Uses `otlphttp/loki` (Loki native OTLP ingestion) instead of deprecated `loki` exporter
- Loki endpoint uses K8s service DNS (`loki.monitoring.svc.cluster.local`)
- No `send_timestamps: true` (Prometheus handles timestamps)

---

## Quality Checklist

- [ ] OTel Collector pod running and healthy in monitoring namespace
- [ ] LoadBalancer VIP 10.10.30.22 assigned and reachable from TRUSTED_WIFI/LAN
- [ ] Prometheus scraping OTel Collector (check Targets page at grafana.k8s.rommelporras.com)
- [ ] `claude_code_cost_usage_USD_total` metric visible in Prometheus
- [ ] `claude_code_session_count_total` metric visible (native, not derived)
- [ ] Events appearing in Loki: `{service_name="claude-code"}`
- [ ] Grafana dashboard — all metrics panels rendering with real data
- [ ] Grafana dashboard — all event panels rendering with real data (API latency, tool performance)
- [ ] Multiple machines can send metrics simultaneously (if second machine available)
- [ ] Local Docker Compose stack stopped and volumes removed
- [ ] All documents in Documentation Checklist updated
- [ ] Phase plan moved to `docs/todo/completed/`
