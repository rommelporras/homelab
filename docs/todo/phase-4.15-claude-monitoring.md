# Phase 4.15: Claude Code Monitoring

> **Status:** Complete (v0.15.0)
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

### 4.15.1 Allocate LoadBalancer VIP ✅

- [x] Assign **10.10.30.22** for OTel Collector in SERVERS VLAN
- [x] Update `docs/context/Networking.md` — add to VIPs table and DNS Records
- [x] Update `VERSIONS.md` — add to LoadBalancer Services table

### 4.15.2 Create OTel Collector Manifests ✅

- [x] Create `manifests/monitoring/otel-collector-config.yaml` (ConfigMap)
- [x] Verify Loki has OTLP ingestion enabled (`allow_structured_metadata: true`)
- [x] Create `manifests/monitoring/otel-collector.yaml` (Deployment + Service)
  - Image: `otel/opentelemetry-collector-contrib:0.144.0`
  - Service: LoadBalancer at 10.10.30.22
- [x] Create `manifests/monitoring/otel-collector-servicemonitor.yaml`
- [x] Apply manifests and verify pod is running

### 4.15.3 Import Grafana Dashboard ✅

- [x] Build updated dashboard JSON (29 panels, 7 collapsible sections)
- [x] Create `manifests/monitoring/claude-dashboard-configmap.yaml`
- [x] Apply ConfigMap and verify dashboard loads in Grafana
- [x] **Dashboard improvements applied:**
  - Billing cycle tracking (`$billing_day` variable, default: 12)
  - Token Usage pie chart (replaced 4 stat panels)
  - Code Edit Decisions table
  - Divide-by-zero guards on 3 panels
  - API Latency window `[5m]` → `[1h]`
  - Collapsible sections (Overview/Trends/Token & Efficiency open by default)
  - Default time range `now-8h`

### 4.15.4 Configure Client Machines ✅

- [x] Update `~/.zshrc` on WSL desktop (pointing to 10.10.30.22)
- [x] Fixed: `machine.name=$HOST` (dynamic hostname instead of hardcoded `desktop`)
- [x] Test: metrics appear in Prometheus
- [x] Test: events appear in Loki (`{service_name="claude-code"}`)

### 4.15.5 Validate End-to-End ✅

- [x] Verify all Prometheus metric panels render with real data
- [x] Verify all Loki event panels render with real data (API latency, tool executions)
- [ ] Test from a second machine (laptop on TRUSTED_WIFI) — deferred, no second machine available
- [x] Verify Alertmanager can route Claude alerts

### 4.15.6 Optional: Cost Alerts ✅

- [x] Create `manifests/monitoring/claude-alerts.yaml` (PrometheusRule)
  - 4 alert rules loaded and inactive (correct state)

### 4.15.7 Add Insights Panels ✅

New collapsed "Insights" section at bottom of dashboard (4 panels based on untapped data).

- [x] **CLI vs User Time** — pie chart using `active_time_seconds_total{type=cli|user}`
- [x] **Tool Usage** — pie chart of `tool_name` distribution from Loki `tool_result` events
- [x] **Tool Performance** — table with per-tool call count and avg duration_ms from Loki
- [x] **Prompts per Hour** — bar chart of `user_prompt` event rate from Loki
- [x] Sync updated dashboard to homelab ConfigMap and apply

### 4.15.8 Retire Local Docker Compose Stack ✅

- [x] Verify homelab metrics and events flowing correctly
- [x] Stop local Docker Compose: `docker compose stop`
- [ ] Remove Docker volumes (deferred until confident in K8s stack)
- [x] Keep `~/personal/claude-monitoring` repo intact (open-source project)

### 4.15.9 Documentation & Release

- [ ] Update all documents listed in the Documentation Checklist below
- [ ] Add rebuild guide `docs/rebuild/v0.15.0-claude-monitoring.md`
- [ ] Move this plan to `docs/todo/completed/`
- [ ] `/commit` — commit all manifests, dashboard, and documentation changes
- [ ] `/release v0.15.0 "Claude Code Monitoring"` — tag, push, create GitHub release

### 4.15.10 Backport to Open-Source Project ✅ (done in parallel)

Dashboard and configs developed in claude-monitoring first, synced to homelab.

- [x] Dashboard JSON is source of truth in claude-monitoring, synced to homelab ConfigMap
- [x] Update docker-compose.yml (Loki service, pinned versions matching homelab)
- [x] Update README.md (billing cycle, resource attributes, LogQL fixes, sections, 8h default)
- [x] Add `docs/kubernetes.md` deployment guide (OTel image version updated)
- [x] Update CHANGELOG.md with v2.0.0 entry
- [x] Update `.env.example` (OTEL_RESOURCE_ATTRIBUTES documentation)
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
