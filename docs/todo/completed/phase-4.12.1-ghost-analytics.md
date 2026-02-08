# Phase 4.12.1: Ghost Web Analytics (Tinybird)

> **Status:** Complete
> **Target:** v0.17.0
> **Prerequisite:** Phase 4.12 (Ghost Blog) + Phase 4.5 (Cloudflare Tunnel)
> **CKA Topics:** Deployment, Service, Security context, CiliumNetworkPolicy cross-namespace egress

---

## Overview

Integrated Ghost's native web analytics powered by Tinybird. Deployed the TrafficAnalytics proxy (Fastify/Node.js) that enriches page hit data (user agent, referrer, privacy-preserving signatures) before forwarding to Tinybird's event ingestion API.

**Architecture:**
```
Browser (ghost-stats.js) ──POST──→ blog-api.rommelporras.com
                                        │
                                  Cloudflare Tunnel
                                        │
                                  TrafficAnalytics proxy
                                  (ghost/traffic-analytics:1.0.72)
                                        │
                                  Tinybird Events API
                                  (us-east-1 AWS)
```

Ghost admin reads analytics data directly from Tinybird's stats endpoint via `tinybird__stats__endpoint`.

---

## Tasks

### 4.12.1.1 Tinybird Account Setup

- [x] 4.12.1.1.1 Create Tinybird account (us-east-1 AWS region, free tier)
- [x] 4.12.1.1.2 Install Tinybird CLI and deploy Ghost template (`tb push`)
- [x] 4.12.1.1.3 Create 1Password item "Ghost Tinybird" in Kubernetes vault
- [x] 4.12.1.1.4 Create K8s secret `ghost-tinybird` in ghost-prod namespace

### 4.12.1.2 TrafficAnalytics Deployment

- [x] 4.12.1.2.1 Create `manifests/ghost-prod/analytics-deployment.yaml`
- [x] 4.12.1.2.2 Create `manifests/ghost-prod/analytics-service.yaml`
- [x] 4.12.1.2.3 Debug CrashLoopBackOff (OOM — container needs ~145MB, limit was 128Mi)
- [x] 4.12.1.2.4 Fix memory limits: requests=128Mi, limits=256Mi

### 4.12.1.3 Ghost Configuration

- [x] 4.12.1.3.1 Add Tinybird env vars to ghost-deployment.yaml using `__` nested config convention
- [x] 4.12.1.3.2 Verify "Web analytics" toggle enabled in Ghost admin
- [x] 4.12.1.3.3 Debug 404 on `/.ghost/analytics/` — Ghost does NOT proxy analytics (Caddy does in Docker Compose)

### 4.12.1.4 Public Endpoint

- [x] 4.12.1.4.1 Create Cloudflare Tunnel hostname `blog-api.rommelporras.com` → TrafficAnalytics service
- [x] 4.12.1.4.2 Add CNAME `blog-api` → tunnel UUID in Cloudflare DNS
- [x] 4.12.1.4.3 Fix CiliumNetworkPolicy — add port 3000 to ghost-prod egress rule
- [x] 4.12.1.4.4 Purge AdGuard DNS cache for local resolution
- [x] 4.12.1.4.5 Verify end-to-end: browser → TrafficAnalytics → Tinybird → Ghost admin

### 4.12.1.5 Documentation & Release

- [x] 4.12.1.5.1 Security audit (`/audit-security`) — PASS (0 critical on staged files)
- [x] 4.12.1.5.2 Commit infrastructure changes
- [x] 4.12.1.5.3 Update documentation (context, rebuild, README, VERSIONS, CHANGELOG)
- [x] 4.12.1.5.4 `/audit-docs`
- [x] 4.12.1.5.5 Commit documentation changes
- [x] 4.12.1.5.6 `/release v0.17.0 "Ghost Web Analytics (Tinybird)"`
- [x] 4.12.1.5.7 Move this file to `docs/todo/completed/`

---

## Files Added

| File | Purpose |
|------|---------|
| manifests/ghost-prod/analytics-deployment.yaml | TrafficAnalytics proxy (Fastify/Node.js) |
| manifests/ghost-prod/analytics-service.yaml | ClusterIP Service for Ghost → TrafficAnalytics communication |

## Files Modified

| File | Change |
|------|--------|
| manifests/ghost-prod/ghost-deployment.yaml | Added Tinybird env vars (analytics__url, tinybird__*) |
| manifests/cloudflare/networkpolicy.yaml | Added port 3000 (TrafficAnalytics) to ghost-prod egress rule |

---

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Analytics provider | Tinybird (Ghost native) | Built-in Ghost admin dashboard, cookie-free, privacy-preserving |
| Tinybird region | US-East-1 (AWS) | No Asia-Pacific regions available; server pushes to Tinybird, not browser |
| Proxy image | ghost/traffic-analytics:1.0.72 | Official Ghost proxy, enriches page hits before forwarding to Tinybird |
| Memory limits | 128Mi/256Mi | Container uses ~145MB at idle; 128Mi limit causes OOM with zero logs |
| Public hostname | blog-api.rommelporras.com | Ad-blocker-friendly (avoids "analytics", "tracking", "stats" keywords) |
| TLS subdomain | Single-level (`blog-api`) | Cloudflare free SSL only covers `*.rommelporras.com`, not `*.blog.rommelporras.com` |
| Ghost config convention | Double-underscore (`__`) | `tinybird__workspaceId` maps to `config.tinybird.workspaceId`; flat env vars don't map |

---

## CKA Learnings

| Topic | Concept |
|-------|---------|
| OOM debugging | Container that OOMs before writing stdout produces zero `kubectl logs` output |
| Security context | TrafficAnalytics fully hardened: runAsNonRoot, drop ALL, seccompProfile RuntimeDefault |
| CiliumNetworkPolicy | Cross-namespace egress requires explicit port additions when adding new services |
| Nested config env vars | Ghost uses `__` double-underscore convention for nested configuration |
| Cloudflare Tunnel | Each backend service needs its own public hostname when the app doesn't proxy internally |

---

## Lessons Learned

1. **Zero logs = OOM kill** — When a container uses more memory than its limit before writing any stdout, `kubectl logs` returns nothing. Diagnose by running the image locally with `docker stats` to check actual memory usage.

2. **Ghost `__` nested config convention** — Ghost maps env vars like `tinybird__workspaceId` to `config.tinybird.workspaceId`. Flat env vars like `TINYBIRD_WORKSPACE_ID` do NOT map to nested config. The `web_analytics_configured` calculated field checks `_isValidTinybirdConfig()` which requires these nested values.

3. **Ghost does NOT proxy `/.ghost/analytics/`** — In Docker Compose, Caddy handles routing `/.ghost/analytics/*` to TrafficAnalytics. In Kubernetes, there's no reverse proxy layer, so a separate Cloudflare Tunnel hostname is required for browser-facing POST requests.

4. **Cloudflare free SSL subdomain limit** — Universal SSL only covers one-level subdomains (`*.rommelporras.com`). Two-level subdomains like `analytics.blog.rommelporras.com` fail TLS handshake. Use single-level names instead.

5. **Ad-blocker-friendly naming** — Browser ad blockers filter requests to subdomains containing "analytics", "tracking", "stats", etc. Chose `blog-api` as a stealth name that ad blockers don't flag.

6. **CiliumNetworkPolicy port updates** — Adding a new service (TrafficAnalytics on port 3000) to an existing namespace (ghost-prod) requires updating the cloudflared egress rules. Without this, Cloudflare Tunnel returns 502.

7. **Tinybird regions** — No Asia-Pacific regions available (only US-East, EU). Data location doesn't affect end users since the server pushes to Tinybird, not the client browser.

---

## 1Password Items

| Item | Vault | Fields |
|------|-------|--------|
| Ghost Tinybird | Kubernetes | workspace-id, admin-token, tracker-token, api-url |

---

## Architecture Detail

### Ghost Env Vars for Tinybird

```yaml
# Ghost reads analytics config from these nested paths:
analytics__url: "http://ghost-analytics:3000"         # Internal proxy URL
analytics__enabled: "true"                              # Enable analytics feature
tinybird__tracker__endpoint: "https://blog-api.rommelporras.com/api/v1/page_hit"  # Browser-facing POST URL
tinybird__tracker__datasource: "analytics_events"       # Tinybird datasource name
tinybird__workspaceId: (from secret)                    # Required for config validation
tinybird__adminToken: (from secret)                     # Required for config validation (JWT mode)
tinybird__stats__endpoint: (from secret)                # Ghost admin reads stats from here
tinybird__stats__endpointBrowser: (from secret)         # Browser-side stats endpoint
```

### Data Flow

```
1. Visitor loads blog.rommelporras.com
2. Ghost injects ghost-stats.min.js (client-side)
3. ghost-stats.js POSTs page hit to blog-api.rommelporras.com/api/v1/page_hit
4. Cloudflare Tunnel routes to TrafficAnalytics pod (ghost-prod:3000)
5. TrafficAnalytics enriches data (user agent parsing, referrer, privacy signatures)
6. TrafficAnalytics forwards to Tinybird Events API (us-east-1 AWS)
7. Ghost admin queries Tinybird stats endpoint for dashboard display
```

---

## Verification Checklist

- [x] TrafficAnalytics pod running: `kubectl-homelab get pods -n ghost-prod -l app=ghost-analytics`
- [x] Ghost "Web analytics" toggle enabled in admin
- [x] `blog-api.rommelporras.com` resolves and returns 200
- [x] Analytics logs show real page hits (not just health checks)
- [x] Ghost admin shows unique visitor count
- [x] Security audit: PASS (0 critical)

---

## Rollback

```bash
# Remove TrafficAnalytics
kubectl-homelab delete -f manifests/ghost-prod/analytics-deployment.yaml
kubectl-homelab delete -f manifests/ghost-prod/analytics-service.yaml

# Remove Tinybird env vars from ghost-deployment.yaml (revert to pre-analytics version)
# Remove blog-api.rommelporras.com from Cloudflare Tunnel public hostnames
# Remove port 3000 from cloudflare/networkpolicy.yaml ghost-prod rule
# Delete ghost-tinybird secret: kubectl-homelab delete secret ghost-tinybird -n ghost-prod
```
