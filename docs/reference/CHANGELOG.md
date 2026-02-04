# Changelog

> Project decision history and revision tracking

---

## February 5, 2026 — Phase 4.9: Invoicetron Migration

### Milestone: Stateful Application with Database Migrated to Kubernetes

Migrated Invoicetron (Next.js 16 + Bun 1.3.4 + PostgreSQL 18 + Prisma 7.2.0 + Better Auth 1.4.7) from Docker Compose on reverse-mountain VM to Kubernetes. Two environments (dev + prod) with GitLab CI/CD pipeline, Cloudflare Tunnel public access, and Cloudflare Access email OTP protection.

| Component | Version | Status |
|-----------|---------|--------|
| Invoicetron | Next.js 16.1.0 | Running (invoicetron-dev, invoicetron-prod) |
| PostgreSQL | 18-alpine | Running (StatefulSet per environment) |

### Files Added

| File | Purpose |
|------|---------|
| manifests/invoicetron/deployment.yaml | App Deployment + ClusterIP Service |
| manifests/invoicetron/postgresql.yaml | PostgreSQL StatefulSet + headless Service |
| manifests/invoicetron/rbac.yaml | ServiceAccount, Role, RoleBinding for CI/CD |
| manifests/invoicetron/secret.yaml | Placeholder (1Password imperative) |
| manifests/invoicetron/backup-cronjob.yaml | Daily pg_dump CronJob + 2Gi PVC |
| manifests/gateway/routes/invoicetron-dev.yaml | HTTPRoute for dev (internal) |
| manifests/gateway/routes/invoicetron-prod.yaml | HTTPRoute for prod (internal) |

### Files Modified

| File | Change |
|------|--------|
| manifests/cloudflare/networkpolicy.yaml | Added invoicetron-prod egress on port 3000; removed temporary DMZ rule; fixed namespace from `invoicetron` to `invoicetron-prod` |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Per-environment builds | Separate Docker images | NEXT_PUBLIC_APP_URL baked at build time |
| Database passwords | Hex-only (`openssl rand -hex 20`) | Avoid URL-special characters breaking Prisma |
| Registry auth | Deploy token + imagePullSecrets | Private GitLab project = private container registry |
| Migration strategy | K8s Job before deploy | Prisma migrations run as one-shot Job in CI/CD |
| Auth client baseURL | `window.location.origin` fallback | Login works on any URL, not just build-time URL |
| Cloudflare Access | Reused "Allow Admin" policy | Email OTP gate, same policy as Uptime Kuma |
| Backup | Daily CronJob (3 AM, 7-day retention) | ~14MB database, lightweight pg_dump |

### Architecture

```
┌───────────────────────────────────────────────────────────────┐
│            invoicetron-prod namespace                         │
├───────────────────────────────────────────────────────────────┤
│                                                               │
│  PostgreSQL 18         Invoicetron App                        │
│  StatefulSet    ◄────  Deployment (1 replica)                 │
│  (10Gi Longhorn) SQL   Next.js 16 + Bun                      │
│                                                               │
│  Daily:                On deploy:                             │
│  pg_dump CronJob       Prisma Migrate Job                    │
│  → Longhorn PVC                                              │
│                                                               │
│  Secrets: database-url, better-auth-secret (1Password)       │
│  Registry: gitlab-registry imagePullSecret (deploy token)    │
└───────────────────────────────────────────────────────────────┘
```

### CI/CD Pipeline (GitLab)

```
develop → validate → test → build:dev → deploy:dev → verify:dev
main    → validate → test → build:prod → deploy:prod → verify:prod
```

- **validate:** type-check (tsc), lint, security-audit
- **test:** unit tests (vitest on node:22-slim)
- **build:** per-environment Docker image (NEXT_PUBLIC_APP_URL as build-arg)
- **deploy:** Prisma migration Job + kubectl set image
- **verify:** curl health check

### Access

| Environment | Internal URL | Public URL |
|-------------|-------------|------------|
| Dev | invoicetron.dev.k8s.rommelporras.com | — |
| Prod | invoicetron.k8s.rommelporras.com | invoicetron.rommelporras.com (Cloudflare) |

### Cloudflare Access

| Application | Policy | Authentication |
|-------------|--------|----------------|
| Invoicetron | Allow Admin (reused) | Email OTP (2 addresses) |

### CKA Learnings

| Topic | Concept |
|-------|---------|
| StatefulSet | PostgreSQL with volumeClaimTemplates, headless Service |
| Jobs | One-shot Prisma migration Job before deployment |
| CronJobs | Daily pg_dump backup with retention |
| Init containers | wait-for-db pattern with busybox nc |
| imagePullSecrets | Private registry auth with deploy tokens |
| Security context | runAsNonRoot, drop ALL, seccompProfile |
| RollingUpdate | maxSurge: 1, maxUnavailable: 0 |
| CiliumNetworkPolicy | Per-namespace egress with exact namespace names |

### Lessons Learned

1. **Private GitLab projects need imagePullSecrets** — Container registry inherits project visibility. Deploy token with `read_registry` scope + `docker-registry` secret in each namespace.

2. **envFrom injects hyphenated keys** — K8s secret keys like `database-url` become env vars with hyphens. Prisma expects `DATABASE_URL`. Use explicit `env` with `valueFrom.secretKeyRef`, not `envFrom`.

3. **PostgreSQL 18+ mount path** — Mount at `/var/lib/postgresql` (parent), not `/var/lib/postgresql/data`. PG creates the data subdirectory itself.

4. **DATABASE_URL passwords must avoid special chars** — Passwords with `/` break Prisma URL parsing. URL-encoding (`%2F`) works for CLI but not runtime. Use hex-only passwords.

5. **PostgreSQL only reads POSTGRES_PASSWORD on first init** — Changing the secret requires `ALTER USER` inside the running pod.

6. **kubectl apply reverts CI/CD image** — Manifest has placeholder image. CI/CD sets actual image via `kubectl set image`. Applying manifest reverts it. Use `kubectl set env` for runtime changes.

7. **CiliumNetworkPolicy needs exact namespace names** — `invoicetron` ≠ `invoicetron-prod`. Caused 502 through Cloudflare Tunnel until fixed.

8. **Better Auth client baseURL** — Hardcoded `NEXT_PUBLIC_APP_URL` means login only works on that domain. Removing baseURL lets Better Auth use `window.location.origin` automatically. Server-side `ADDITIONAL_TRUSTED_ORIGINS` validates allowed origins.

9. **1Password CLI session scope** — `op read` returns empty if session expired. Always `eval $(op signin)` before creating secrets. Verify secrets after creation.

### 1Password Items

| Item | Vault | Fields |
|------|-------|--------|
| Invoicetron Dev | Kubernetes | postgres-password, better-auth-secret, database-url |
| Invoicetron Prod | Kubernetes | postgres-password, better-auth-secret, database-url |

### DMZ Rule Removed

With both Portfolio and Invoicetron running in K8s, the temporary DMZ rule (`10.10.50.10/32`) in the cloudflared NetworkPolicy has been removed. Security validation: 35 passed, 0 failed.

---

## February 4, 2026 — Cloudflare WAF: RSS Feed Access

### Fix: GitHub Actions Blog RSS Fetch (403)

Added Cloudflare WAF skip rule and disabled Bot Fight Mode to allow the GitHub Profile README blog-post workflow to fetch the Ghost RSS feed from GitHub Actions.

| Component | Change |
|-----------|--------|
| Cloudflare WAF Rule 1 | New: Skip + Super Bot Fight Mode for `/rss/` |
| Cloudflare WAF Rule 2 | Renumbered: Allow `/ghost/api/content` (was Rule 1) |
| Cloudflare WAF Rule 3 | Renumbered: Block `/ghost` paths (was Rule 2) |
| Bot Fight Mode | Disabled globally (Security → Settings) |

### Key Decision

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Bot Fight Mode | Disabled globally | Free Cloudflare tier cannot create path-specific exceptions; blocks all cloud provider IPs including GitHub Actions |

### Lesson Learned

WAF custom rule "Skip all remaining custom rules" does **not** skip Bot Fight Mode — they are separate systems. To skip bot protection for a specific path, you must also check "All Super Bot Fight Mode Rules" in the WAF skip action **and** disable the global Bot Fight Mode toggle.

---

## February 3, 2026 — Phase 4.14: Uptime Kuma Monitoring

### Milestone: Self-hosted Endpoint Monitoring with Public Status Page

Deployed Uptime Kuma v2.0.2 for HTTP(s) endpoint monitoring of personal websites, homelab services, and infrastructure. Public status page exposed via Cloudflare Tunnel with Access policies blocking admin routes. Discord notifications on the #incidents channel.

| Component | Version | Status |
|-----------|---------|--------|
| Uptime Kuma | v2.0.2 (rootless) | Running (uptime-kuma namespace) |

### Files Added

| File | Purpose |
|------|---------|
| manifests/uptime-kuma/namespace.yaml | Namespace with PSS labels (baseline enforce, restricted audit/warn) |
| manifests/uptime-kuma/statefulset.yaml | StatefulSet with volumeClaimTemplates (Longhorn 1Gi) |
| manifests/uptime-kuma/service.yaml | Headless + ClusterIP services on port 3001 |
| manifests/uptime-kuma/httproute.yaml | Gateway API HTTPRoute for `uptime.k8s.rommelporras.com` |
| manifests/uptime-kuma/networkpolicy.yaml | CiliumNetworkPolicy (DNS, internet HTTPS, cluster-internal, home network) |
| manifests/monitoring/uptime-kuma-probe.yaml | Blackbox HTTP probe for Prometheus |
| docs/rebuild/v0.13.0-uptime-kuma.md | Full rebuild guide |

### Files Modified

| File | Change |
|------|--------|
| manifests/cloudflare/networkpolicy.yaml | Added uptime-kuma namespace egress on port 3001 |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Workload type | StatefulSet | Stable identity + persistent SQLite storage |
| Image variant | rootless (not slim-rootless) | Includes Chromium for browser-engine monitors |
| Database | SQLite | Single-instance, no external DB dependency |
| Storage | volumeClaimTemplates (1Gi) | Auto-creates PVC per pod, no separate manifest |
| Public access | Cloudflare Tunnel + block-admin | SPA-compatible; block `/dashboard`, `/manage-status-page`, `/settings` |
| Notifications | Reuse #incidents channel | Unified incident channel, no channel sprawl |
| Monitor retries | 1 for public/prod, 3 for internal/dev | Faster alerting for critical services |

### Architecture

```
uptime-kuma namespace
┌───────────────────────────────────┐
│ StatefulSet (1 replica)           │
│ - Image: 2.0.2-rootless           │
│ - SQLite on Longhorn PVC (1Gi)   │
│ - Non-root (UID 1000)            │
└───────────────┬───────────────────┘
                │
     ┌──────────┼──────────┐
     │          │          │
  Headless   ClusterIP   HTTPRoute
  Service    Service     uptime.k8s.rommelporras.com
                          │
               Cloudflare Tunnel
               status.rommelporras.com/status/homelab
```

### Access

| Environment | URL | Access |
|-------------|-----|--------|
| Admin | https://uptime.k8s.rommelporras.com | Internal (HTTPRoute) |
| Status Page | https://status.rommelporras.com/status/homelab | Public (Cloudflare Tunnel) |

### Monitors Configured

| Group | Monitors |
|-------|----------|
| Website | rommelporras.com, beta.rommelporras.com (Staging), Blog Prod, Blog Dev |
| Apps | Grafana, Homepage Dashboard, Longhorn Storage, Immich, Karakeep, MySpeed, Homepage (Proxmox) |
| Infrastructure | Proxmox PVE, Proxmox Firewall, OPNsense, OpenMediaVault, NAS Glances |
| DNS | AdGuard Primary, AdGuard Failover |

Tags: Kubernetes (Blue), Proxmox (Orange), Network (Purple), Storage (Pink), Public (Green)

### Cloudflare Access (Block Admin)

| Path | Action |
|------|--------|
| `status.rommelporras.com/dashboard` | Blocked (Everyone) |
| `status.rommelporras.com/manage-status-page` | Blocked (Everyone) |
| `status.rommelporras.com/settings` | Blocked (Everyone) |
| `status.rommelporras.com/status/homelab` | Public (no policy) |

### CKA Learnings

| Topic | Concept |
|-------|---------|
| StatefulSet | volumeClaimTemplates auto-create PVCs, headless Service for stable DNS |
| CiliumNetworkPolicy | Uses pod ports not service ports; private IP exclusion requires explicit toCIDR for home network |
| Gateway API | HTTPRoute sectionName for listener selection |
| Cloudflare Access | Block-admin simpler than allowlist for SPAs (JS/CSS/API paths) |
| Hairpin routing | Cilium Gateway returns 403 for pod-to-VIP-to-pod traffic |

### Lessons Learned

1. **StatefulSet vs Deployment for SQLite** — StatefulSet provides stable pod identity (`uptime-kuma-0`) and volumeClaimTemplates auto-create PVCs. No separate PVC manifest needed.

2. **CiliumNetworkPolicy uses pod ports, not service ports** — A service mapping port 80→3000 requires the network policy to allow port 3000 (the pod port). Service port abstraction doesn't apply at the CNI level.

3. **Private IP exclusion blocks home network** — `toCIDRSet` with `except: 10.0.0.0/8` blocks home network devices (AdGuard failover, OPNsense, NAS). Must add explicit `toCIDR` rules for specific IPs.

4. **Hairpin routing with Cilium Gateway** — Pods accessing their own service via the Gateway VIP (pod→VIP→pod) get 403. Use internal service URLs for self-monitoring or accept the limitation.

5. **Cloudflare Access: block-admin > allowlist for SPAs** — Allowlisting only `/status/homelab` blocks JS/CSS/API paths the SPA needs. Blocking only admin paths (`/dashboard`, `/manage-status-page`, `/settings`) is simpler and SPA-compatible.

6. **rootless vs slim-rootless** — The `rootless` image includes Chromium for browser-engine monitors (real browser rendering checks). `slim-rootless` saves ~200MB but loses this capability. Memory limits need bumping (256Mi→768Mi).

7. **HTTPRoute BackendNotFound timing issue** — Cilium Gateway controller may report `Service "uptime-kuma" not found` even when the service exists. Delete and re-apply the HTTPRoute to force re-reconciliation.

8. **Cloudflare Zero Trust requires payment method** — Even the free plan ($0/month, 50 seats) requires a credit card or PayPal for identity verification. Standard anti-abuse measure.

### 1Password Items

| Item | Vault | Fields |
|------|-------|--------|
| Uptime Kuma | Kubernetes | username, password, website |

---

## February 2, 2026 — Phase 4.13: Domain Migration

### Milestone: Corporate-Style Domain Hierarchy

Migrated all Kubernetes services from `*.k8s.home.rommelporras.com` to a tiered domain scheme under `*.k8s.rommelporras.com`. Introduced corporate-style environment tiers (base, dev, stg) with scoped wildcard TLS certificates.

| Component | Change |
|-----------|--------|
| Gateway | 3 HTTPS listeners (base, dev, stg) with scoped wildcards |
| TLS | 3 wildcard certs via cert-manager DNS-01 |
| API Server | New SAN `api.k8s.rommelporras.com` on all 3 nodes |
| DNS (K8s AdGuard) | New rewrites for all tiers + node hostnames |
| DNS (Failover LXC) | Matching rewrites for failover safety |

### Domain Scheme

| Tier | Wildcard | Purpose |
|------|----------|---------|
| Base | `*.k8s.rommelporras.com` | Infrastructure + production |
| Dev | `*.dev.k8s.rommelporras.com` | Development environments |
| Stg | `*.stg.k8s.rommelporras.com` | Staging environments |

### Service Migration

| Service | Old Domain | New Domain |
|---------|-----------|------------|
| Homepage | portal.k8s.home.rommelporras.com | portal.k8s.rommelporras.com |
| Grafana | grafana.k8s.home.rommelporras.com | grafana.k8s.rommelporras.com |
| GitLab | gitlab.k8s.home.rommelporras.com | gitlab.k8s.rommelporras.com |
| Registry | registry.k8s.home.rommelporras.com | registry.k8s.rommelporras.com |
| Blog Prod | blog.k8s.home.rommelporras.com | blog.k8s.rommelporras.com |
| Blog Dev | blog-dev.k8s.home.rommelporras.com | blog.dev.k8s.rommelporras.com |
| Portfolio Prod | portfolio-prod.k8s.home.rommelporras.com | portfolio.k8s.rommelporras.com |
| Portfolio Dev | portfolio-dev.k8s.home.rommelporras.com | portfolio.dev.k8s.rommelporras.com |
| Portfolio Stg | portfolio-staging.k8s.home.rommelporras.com | portfolio.stg.k8s.rommelporras.com |
| K8s API | k8s-api.home.rommelporras.com | api.k8s.rommelporras.com |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Tier convention | prod=default, non-prod=qualified | Corporate pattern: `blog.k8s` is prod, `blog.dev.k8s` is dev |
| Wildcard scope | Per-tier wildcards | `*.k8s`, `*.dev.k8s`, `*.stg.k8s` — no broad `*.rommelporras.com` |
| Legacy boundary | `*.home.rommelporras.com` untouched | Proxmox, OPNsense, OMV stay on NPM |
| Node hostnames | `cp{1,2,3}.k8s.rommelporras.com` | Hierarchical, consistent with service naming |
| API hostname | `api.k8s.rommelporras.com` | Short, follows corporate convention |

### Lessons Learned

1. **kubeadm `certs renew` does NOT add new SANs** — It only renews expiration, reusing existing SANs. To add a new SAN: delete the cert+key, then run `kubeadm init phase certs apiserver --config /path/to/config.yaml`.

2. **Local kubeadm config takes priority over ConfigMap** — If `/etc/kubernetes/kubeadm-config.yaml` exists on a node, `kubeadm init phase certs` uses it instead of the kube-system ConfigMap. Must update (or create) the local file on each node.

3. **AdGuard configmap is only an init template** — The init container copies config to PVC only on first boot (`if [ ! -f ... ]`). Runtime changes must be made via web UI. Configmap should still be updated as rebuild source of truth.

4. **RWO PVC + RollingUpdate = deadlock** — Grafana's Longhorn RWO volume caused a stuck rollout: new pod scheduled on different node couldn't attach the volume, old pod couldn't terminate (rolling update). Fix: scale to 0 then back to 1.

5. **Gateway API multi-listener migration pattern** — Add new listeners alongside old ones, switch HTTPRoutes to new listeners, verify, then remove old listeners in cleanup phase. Zero-downtime migration.

### CKA Learnings

| Topic | Concept |
|-------|---------|
| Gateway API | Multi-listener pattern, scoped wildcards, sectionName routing |
| cert-manager | Automatic Certificate creation from Gateway annotations, DNS-01 challenges |
| kubeadm | certSANs management, cert regeneration vs renewal, ConfigMap vs local config |
| TLS | Wildcard scope (one subdomain level only), multi-cert Gateway |

### Files Modified

| Category | Files |
|----------|-------|
| Gateway | manifests/gateway/homelab-gateway.yaml |
| HTTPRoutes (8) | gitlab, gitlab-registry, portfolio-prod, ghost-prod, longhorn, adguard, homepage, grafana |
| HTTPRoutes (3) | portfolio-dev, portfolio-staging, ghost-dev |
| Helm | gitlab/values.yaml, gitlab-runner/values.yaml, prometheus/values.yaml |
| Manifests | portfolio/deployment.yaml, ghost-dev/ghost-deployment.yaml, homepage/deployment.yaml |
| Config | homepage/config/services.yaml, homepage/config/settings.yaml |
| DNS | home/adguard/configmap.yaml |
| Scripts | scripts/sync-ghost-prod-to-dev.sh |
| Ansible | group_vars/all.yml, group_vars/control_plane.yml |

---

## January 31, 2026 — Phase 4.12: Ghost Blog Platform

### Milestone: Self-hosted Ghost CMS with Dev/Prod Environments

Deployed Ghost 6.14.0 blog platform with MySQL 8.4.8 LTS backend in two environments (ghost-dev, ghost-prod). Includes database sync scripts for prod-to-dev and prod-to-local workflows.

| Component | Version | Status |
|-----------|---------|--------|
| Ghost | 6.14.0 | Running (ghost-dev, ghost-prod) |
| MySQL | 8.4.8 LTS | Running (StatefulSet per environment) |

### Files Added

| File | Purpose |
|------|---------|
| manifests/ghost-dev/namespace.yaml | Dev namespace with PSA labels |
| manifests/ghost-dev/secret.yaml | Placeholder (1Password imperative) |
| manifests/ghost-dev/mysql-statefulset.yaml | MySQL StatefulSet with Longhorn 10Gi |
| manifests/ghost-dev/mysql-service.yaml | Headless Service for MySQL DNS |
| manifests/ghost-dev/ghost-pvc.yaml | Ghost content PVC (Longhorn 5Gi) |
| manifests/ghost-dev/ghost-deployment.yaml | Ghost Deployment with init container |
| manifests/ghost-dev/ghost-service.yaml | ClusterIP Service for Ghost |
| manifests/ghost-dev/httproute.yaml | Gateway API route (internal) |
| manifests/ghost-prod/* | Same structure for production |
| scripts/sync-ghost-prod-to-dev.sh | Database + content sync utility |
| scripts/sync-ghost-prod-to-local.sh | Prod database to local docker-compose |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Ghost version | 6.14.0 (Debian) | glibc compatibility, Sharp image library |
| MySQL version | 8.4.8 LTS | 5yr premier support, 8.0.x EOL April 2026 |
| Character set | utf8mb4 | Full unicode/emoji support in blog posts |
| Deployment strategy | Recreate | RWO PVC cannot be mounted by two pods |
| Gateway parentRefs | namespace: default | Corrected from plan (was kube-system) |
| MySQL security | No container restrictions | Entrypoint requires root (chown, gosu) |
| Ghost security | runAsNonRoot, uid 1000 | Full hardening with drop ALL capabilities |
| Mail config | Reused iCloud SMTP | Same app-specific password as Alertmanager |

### Access

| Environment | Internal URL | Public URL |
|-------------|-------------|------------|
| Dev | blog-dev.k8s.home.rommelporras.com | — |
| Prod | blog.k8s.home.rommelporras.com | blog.rommelporras.com (Cloudflare) |

### Public Access & Security (February 1)

Configured Cloudflare Tunnel for public access and WAF custom rules to protect the Ghost admin panel.

| Component | Change |
|-----------|--------|
| Cloudflare Tunnel | Added `blog.rommelporras.com` → `http://ghost.ghost-prod.svc.cluster.local:2368` |
| CiliumNetworkPolicy | Added ghost-prod:2368 egress rule for cloudflared |
| Cloudflare WAF Rule 1 | Skip: Allow `/rss/` (public RSS feed for GitHub Actions blog-post workflow) |
| Cloudflare WAF Rule 2 | Skip: Allow `/ghost/api/content` (public Content API for search) |
| Cloudflare WAF Rule 3 | Block: All other `/ghost` paths (admin panel, Admin API) |

### Files Modified

| File | Change |
|------|--------|
| manifests/cloudflare/networkpolicy.yaml | Added ghost-prod namespace egress on port 2368 |

### Key Decisions (Public Access)

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Tunnel protocol | HTTP (not HTTPS) | Ghost serves plain HTTP on 2368; cloudflared sends X-Forwarded-Proto: https |
| Admin protection | WAF custom rules | Cloudflare Access has known path precedence bugs; WAF evaluates in strict order |
| RSS feed | Skip rule (allow) + skip Super Bot Fight Mode | Cloudflare Bot Management blocks GitHub Actions IPs; `/rss/` is public read-only |
| Bot Fight Mode | Disabled globally | Free tier cannot create path-specific exceptions; blocks all cloud provider IPs |
| Content API | Skip rule (allow) | Sodo Search widget calls /ghost/api/content/ from browser; blocking breaks search |
| Admin API | Block rule | /ghost/api/admin/ is write-capable; original plan would have bypassed it |

### Lessons Learned (Public Access)

1. **Ghost 301-redirects HTTP when url is HTTPS** — Ghost checks `X-Forwarded-Proto` header. Cloudflare Tunnel with HTTP type sends this header automatically. Using HTTPS type causes cloudflared to attempt TLS to Ghost (which doesn't support it).

2. **CiliumNetworkPolicy blocks cross-namespace by default** — The cloudflared egress policy blocks all private IPs and whitelists per-namespace. New tunnel backends require an explicit egress rule.

3. **Cloudflare Access path precedence is unreliable** — "Most specific path wins" has [known bugs](https://community.cloudflare.com/t/policy-inheritance-not-prioritizing-most-specific-path/820213). WAF custom rules with Skip + Block pattern is deterministic.

4. **Ghost Content API vs Admin API** — Only `/ghost/api/content/` needs public access (read-only, API key auth). `/ghost/api/admin/` is write-capable (JWT auth) and should be blocked publicly.

### CKA Learnings

| Topic | Concept |
|-------|---------|
| StatefulSet | volumeClaimTemplates, headless Service, stable network identity |
| Pod Security Admission | 3 modes (enforce/audit/warn), baseline vs restricted |
| Init containers | wait-for pattern with busybox nc |
| Security context | runAsNonRoot, capabilities drop/add, seccompProfile |
| Gateway API | HTTPRoute parentRefs, cross-namespace routing |
| Secrets | Imperative creation from 1Password, placeholder pattern |
| CiliumNetworkPolicy | Per-namespace egress whitelisting for cross-namespace traffic |

---

## January 30, 2026 — Phase 4.8.1: AdGuard DNS Alerting

### Milestone: Synthetic DNS Monitoring for L2 Lease Misalignment

Deployed blackbox exporter with DNS probe to detect when AdGuard is running but unreachable due to Cilium L2 lease misalignment. This directly addresses the 3-day unnoticed outage (Jan 25-28) identified in Phase 4.8.

| Component | Version | Status |
|-----------|---------|--------|
| blackbox-exporter | v0.28.0 | Running (monitoring namespace) |
| Probe CRD (adguard-dns) | — | Scraping every 30s |
| PrometheusRule (AdGuardDNSUnreachable) | — | Loaded, severity: critical |

### Files Added/Modified

| File | Purpose |
|------|---------|
| helm/blackbox-exporter/values.yaml | Blackbox exporter config with dns_udp module |
| helm/prometheus/values.yaml | Added probeSelectorNilUsesHelmValues: false |
| manifests/monitoring/adguard-dns-probe.yaml | Probe CRD targeting 10.10.30.53 |
| manifests/monitoring/adguard-dns-alert.yaml | PrometheusRule with runbook |
| scripts/upgrade-prometheus.sh | Fixed Healthchecks Ping URL field name |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Blackbox exporter deployment | Separate Helm chart | kube-prometheus-stack does NOT bundle it |
| Probe target | LoadBalancer IP (10.10.30.53) | Tests full path including L2 lease alignment |
| DNS query domain | google.com | Universal, always resolvable |
| Alert threshold | 2 minutes | Avoids flapping while catching real outages |
| Alert severity | Critical | DNS is foundational; failure affects all VLANs |

### Architecture

```
Prometheus → Blackbox Exporter → DNS query to 10.10.30.53 → AdGuard
                                         │
                                         ├─ Success: probe_success=1
                                         └─ Failure: probe_success=0 → Alert
```

### CKA Learnings

| Topic | Concept |
|-------|---------|
| Probe CRD | Custom resource for blackbox exporter targets |
| PrometheusRule | Custom alert rules with PromQL expressions |
| Synthetic monitoring | Testing from outside the system under test |
| jobName field | Controls the `job` label in Prometheus metrics |

### Lessons Learned

1. **kube-prometheus-stack does NOT include blackbox exporter** — Despite the `prometheusBlackboxExporter` key existing in chart values, it requires a separate Helm chart installation.

2. **probeSelectorNilUsesHelmValues must be set** — Without `probeSelectorNilUsesHelmValues: false`, Prometheus ignores Probe CRDs. Silently fails with no error.

3. **Blackbox exporter has NO default DNS module** — Must explicitly configure `dns_udp` with `query_name` (required field). Without it, probe errors with no useful message.

4. **Service name follows `<release>-prometheus-blackbox-exporter` pattern** — Not `<release>-kube-prometheus-blackbox-exporter` as initially assumed.

5. **1Password field names must be exact** — `credential` vs `url` vs `password` — always verify with `op item get <name> --format json | jq '.fields[]'`.

### Alert Runbook

```
1. Check pod node:
   kubectl-homelab get pods -n home -l app=adguard-home -o wide

2. Check L2 lease holder:
   kubectl-homelab get leases -n kube-system cilium-l2announce-home-adguard-dns -o jsonpath='{.spec.holderIdentity}'

3. If pod node != lease holder, delete lease:
   kubectl-homelab delete lease -n kube-system cilium-l2announce-home-adguard-dns

4. Verify DNS restored:
   dig @10.10.30.53 google.com
```

### Alert Pipeline Verified

| Test | Result |
|------|--------|
| Test probe (non-existent IP) | probe_success=0 |
| Alert pending after 15s | ✓ |
| Alert firing after 1m | ✓ |
| Discord #status notification | ✓ Received |
| Cleanup + resolved notification | ✓ Received |

---

## January 29, 2026 — Phase 4.8: AdGuard Client IP Preservation

### Milestone: Fixed Client IP Visibility in AdGuard Logs

Resolved issue where AdGuard showed node IPs instead of real client IPs. Root cause was `externalTrafficPolicy: Cluster` combined with Cilium L2 lease on wrong node.

| Component | Change |
|-----------|--------|
| AdGuard DNS Service | externalTrafficPolicy: Cluster → Local |
| AdGuard Deployment | nodeSelector pinned to k8s-cp2 |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Traffic policy | Local | Preserves client IP (no SNAT) |
| Pod placement | Node pinning | Simpler than DaemonSet, keeps UI config |
| L2 alignment | Manual lease delete | Force re-election to pod node |

### CKA Learnings

| Topic | Concept |
|-------|---------|
| externalTrafficPolicy | Cluster (SNAT, any node) vs Local (preserve IP, pod node only) |
| Cilium L2 Announcement | Leader election via Kubernetes Leases |
| Health Check Node Port | Auto-created for Local policy services |

### Lessons Learned

1. **L2 lease must match pod node for Local policy** - Traffic dropped if mismatch occurs.

2. **Cilium agent restart can move L2 lease** - Caused 3-day outage (Jan 25-28) with no alerts.

3. **CoreDNS IPs in AdGuard are expected** - Pods query CoreDNS which forwards to AdGuard.

4. **General L2 policies can conflict with specific ones** - Delete conflicting policies before creating service-specific ones.

---

## January 28, 2026 — Phase 4.7: Portfolio CI/CD Migration

### Milestone: First App Deployed via GitLab CI/CD

Migrated portfolio website from PVE VM Docker Compose to Kubernetes with full GitLab CI/CD pipeline. Three environments (dev, staging, prod) with GitFlow branching strategy.

| Component | Status |
|-----------|--------|
| Portfolio (Next.js) | Running (3 environments) |
| GitLab CI/CD | 4-stage pipeline (validate, test, build, deploy) |
| Container Registry | Public project for anonymous pulls |

### Files Added

| File | Purpose |
|------|---------|
| manifests/portfolio/deployment.yaml | Deployment + Service (2 replicas) |
| manifests/portfolio/rbac.yaml | ServiceAccount for CI/CD deploys |
| manifests/gateway/routes/portfolio-*.yaml | HTTPRoutes for 3 environments |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Environments | dev/staging/prod | Corporate pattern learning |
| Branching | GitFlow | develop → dev (auto), staging (manual), main → prod (auto) |
| Registry auth | Public project | Simpler than imagePullSecrets for personal portfolio |
| URL pattern | Flat subdomains | portfolio-dev vs portfolio.dev for wildcard TLS |

### Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    GitLab CI/CD Pipeline                        │
├─────────────────────────────────────────────────────────────────┤
│  develop branch ──► validate ──► test ──► build ──► deploy:dev  │
│                                                    ──► deploy:staging (manual)
│  main branch ────► validate ──► test ──► build ──► deploy:prod  │
└─────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────┐
│  portfolio-dev        portfolio-staging      portfolio-prod     │
│  (internal only)      beta.rommelporras.com  www.rommelporras.com│
└─────────────────────────────────────────────────────────────────┘
```

### Cloudflare Tunnel Routes

| Subdomain | Target |
|-----------|--------|
| beta.rommelporras.com | portfolio.portfolio-staging.svc:80 |
| www.rommelporras.com | portfolio.portfolio-prod.svc:80 |

### Lessons Learned

1. **RBAC needs list/watch for rollout status** - `kubectl rollout status` requires list and watch verbs on deployments and replicasets.

2. **kubectl context order matters** - `set-context` must come before `use-context` in CI/CD scripts.

3. **Wildcard TLS only covers one level** - `*.k8s.home...` doesn't cover `portfolio.dev.k8s.home...`. Use flat subdomains like `portfolio-dev.k8s.home...`.

4. **CiliumNetworkPolicy for tunnel egress** - Cloudflared egress policy must explicitly allow each namespace it needs to reach.

5. **Docker-in-Docker needs wait loop** - Add `until docker info; do sleep 2; done` before docker commands in CI.

---

## January 25, 2026 — Phase 4.6: GitLab CE

### Milestone: Self-hosted DevOps Platform

Deployed GitLab CE v18.8.2 with GitLab Runner for CI/CD pipelines, Container Registry, and SSH access.

| Component | Version | Status |
|-----------|---------|--------|
| GitLab CE | v18.8.2 | Running |
| GitLab Runner | v18.8.0 | Running (Kubernetes executor) |
| PostgreSQL | 16.6 | Running (bundled) |
| Container Registry | v4.x | Running |

### Files Added

| File | Purpose |
|------|---------|
| helm/gitlab/values.yaml | GitLab Helm configuration |
| helm/gitlab-runner/values.yaml | Runner with Kubernetes executor |
| manifests/gateway/routes/gitlab.yaml | HTTPRoute for web UI |
| manifests/gateway/routes/gitlab-registry.yaml | HTTPRoute for container registry |
| manifests/gitlab/gitlab-shell-lb.yaml | LoadBalancer for SSH (10.10.30.21) |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Edition | Community Edition (CE) | Free, sufficient for homelab |
| Storage | Bundled PostgreSQL/Redis | Learning/PoC, not production |
| SSH Access | Dedicated LoadBalancer IP (.21) | Separate from Gateway, avoids port conflicts |
| SMTP | Shared iCloud SMTP | Reuses existing Alertmanager credentials |
| Secrets | SET_VIA_HELM pattern | Matches Alertmanager, no email in public repo |

### Architecture

```
                         Internet
                             │
          ┌──────────────────┴──────────────────┐
          ▼                                     ▼
┌───────────────────┐                ┌───────────────────┐
│  Gateway API      │                │  LoadBalancer     │
│  10.10.30.20:443  │                │  10.10.30.21:22   │
│  (HTTPS)          │                │  (SSH)            │
└─────────┬─────────┘                └─────────┬─────────┘
          │                                    │
    ┌─────┴─────┐                              │
    ▼           ▼                              ▼
┌───────┐  ┌──────────┐                ┌─────────────┐
│GitLab │  │ Registry │                │ gitlab-shell│
│  Web  │  │  :5000   │                │   :2222     │
│ :8181 │  └──────────┘                └─────────────┘
└───────┘
```

### 1Password Items

| Item | Vault | Fields |
|------|-------|--------|
| GitLab | Kubernetes | username, password, postgresql-password |
| GitLab Runner | Kubernetes | runner-token |
| iCloud SMTP | Kubernetes | username, password (renamed from "iCloud SMTP Alertmanager") |

### Access

| Type | URL |
|------|-----|
| Web UI | https://gitlab.k8s.home.rommelporras.com |
| Registry | https://registry.k8s.home.rommelporras.com |
| SSH | ssh://git@ssh.gitlab.k8s.home.rommelporras.com (10.10.30.21) |

### Lessons Learned

1. **gitlab-shell listens on 2222, not 22** - Container runs as non-root, uses high port internally. LoadBalancer maps 22→2222.

2. **Cilium L2 sharing requires annotation** - To share IP with Gateway, both services need `lro.io/sharing-key`. Used separate IP instead for simplicity.

3. **PostgreSQL secret needs two keys** - Chart expects both `postgresql-password` and `postgresql-postgres-password` in the secret.

4. **SET_VIA_HELM pattern** - Placeholders in values.yaml with `--set` injection at install time keeps credentials out of git.

---

## January 24, 2026 — Phase 4.5: Cloudflare Tunnel

### Milestone: HA Cloudflare Tunnel on Kubernetes

Migrated cloudflared from DMZ LXC to Kubernetes for high availability. Tunnel now survives node failures and Proxmox reboots.

| Component | Version | Status |
|-----------|---------|--------|
| cloudflared | 2026.1.1 | Running (2 replicas, HA) |

### Files Added

| File | Purpose |
|------|---------|
| manifests/cloudflare/deployment.yaml | 2-replica deployment with anti-affinity |
| manifests/cloudflare/networkpolicy.yaml | CiliumNetworkPolicy egress rules |
| manifests/cloudflare/pdb.yaml | PodDisruptionBudget (minAvailable: 1) |
| manifests/cloudflare/service.yaml | ClusterIP for Prometheus metrics |
| manifests/cloudflare/servicemonitor.yaml | Prometheus scraping |
| manifests/cloudflare/secret.yaml | Documentation placeholder for imperative secret |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Replicas | 2 with required anti-affinity | HA across nodes, survives single node failure |
| Security | CiliumNetworkPolicy | Block NAS/internal, allow only Cloudflare Edge + public services |
| DMZ access | Temporary 10.10.50.10/32 rule | Transition period until portfolio/invoicetron migrate to K8s |
| Secrets | 1Password → imperative kubectl | GitOps-friendly, future ESO migration path |
| Namespace PSS | restricted | Matches official cloudflared security recommendations |

### Architecture

```
                    Cloudflare Edge
         (mnl01, hkg11, sin02, sin11, etc.)
                         │
                    8 QUIC connections
                         │
         ┌───────────────┴───────────────┐
         ▼                               ▼
┌─────────────────┐             ┌─────────────────┐
│  cloudflared    │             │  cloudflared    │
│  k8s-cp1        │             │  k8s-cp2        │
│  4 connections  │             │  4 connections  │
└────────┬────────┘             └────────┬────────┘
         │                               │
         └───────────────┬───────────────┘
                         ▼
               ┌─────────────────┐
               │ reverse-mountain│
               │  10.10.50.10    │
               │ (DMZ - temporary)│
               └─────────────────┘
```

### CiliumNetworkPolicy Rules

| Rule | Target | Ports | Purpose |
|------|--------|-------|---------|
| DNS | kube-dns | 53/UDP | Service discovery |
| Cloudflare | 0.0.0.0/0 except RFC1918 | 443, 7844 | Tunnel traffic |
| Portfolio (K8s) | portfolio namespace | 80 | Future K8s service |
| Invoicetron (K8s) | invoicetron namespace | 3000 | Future K8s service |
| DMZ (temporary) | 10.10.50.10/32 | 3000, 3001 | Current Proxmox VM |

### Security Validation

Verified via test pod with `app=cloudflared` label:

| Test | Target | Result |
|------|--------|--------|
| NAS | 10.10.30.4:5000 | BLOCKED |
| Router | 10.10.30.1:80 | BLOCKED |
| Grafana | monitoring namespace | BLOCKED |
| Cloudflare Edge | 104.16.132.229:443 | ALLOWED |
| DMZ VM | 10.10.50.10:3000,3001 | ALLOWED |

### Lessons Learned

1. **CiliumNetworkPolicy blocks private IPs by design** - `toCIDRSet` with `except` for 10.0.0.0/8 blocks DMZ too. Added specific /32 rule for transition period.

2. **Pod Security Standards enforcement** - Test pods in `restricted` namespace need full securityContext (runAsNonRoot, capabilities.drop, seccompProfile).

3. **Loki log retention is 90 days** - Logs auto-delete after 2160h. Old tunnel errors will naturally expire.

4. **OPNsense allows SERVERS→DMZ** - But Cilium blocks it at K8s layer. Network segmentation works at multiple levels.

### 1Password Items

| Item | Vault | Field | Purpose |
|------|-------|-------|---------|
| Cloudflare Tunnel | Kubernetes | token | cloudflared tunnel authentication |

### Public Services (via Tunnel)

| Service | URL | Backend |
|---------|-----|---------|
| Portfolio | https://www.rommelporras.com | 10.10.50.10:3001 (temporary) |
| Invoicetron | https://invoicetron.rommelporras.com | 10.10.50.10:3000 (temporary) |

---

## January 22, 2026 — Phase 4.1-4.4: Stateless Workloads

### Milestone: Home Services Running on Kubernetes

Successfully deployed stateless home services to Kubernetes with full monitoring integration.

| Component | Version | Status |
|-----------|---------|--------|
| AdGuard Home | v0.107.71 | Running (PRIMARY DNS for all VLANs) |
| Homepage | v1.9.0 | Running (2 replicas, multi-tab layout) |
| Glances | v3.3.1 | Running (on OMV, apt install) |
| Metrics Server | v0.8.0 | Running (Helm chart 3.13.0) |

### Files Added

| File | Purpose |
|------|---------|
| manifests/home/adguard/ | AdGuard Home deployment (ConfigMap, Deployment, Service, HTTPRoute, PVC) |
| manifests/home/homepage/ | Homepage dashboard (Kustomize with configMapGenerator) |
| manifests/storage/longhorn/httproute.yaml | Longhorn UI exposure for Homepage widget |
| helm/metrics-server/values.yaml | Metrics server Helm values |
| docs/todo/phase-4.9-tailscale-operator.md | Future Tailscale K8s operator planning |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| DNS IP | 10.10.30.55 (LoadBalancer) | Cilium L2 announcement, separate from FW failover |
| AdGuard storage | Init container + Longhorn PVC | ConfigMap → PVC on first boot, runtime changes preserved |
| Homepage storage | ConfigMap only (stateless) | Kustomize hash suffix for automatic rollouts |
| Secrets | 1Password CLI (imperative) | Never commit secrets to git |
| Settings env vars | Init container substitution | Homepage doesn't substitute `{{HOMEPAGE_VAR_*}}` in providers section |
| Longhorn widget | HTTPRoute exposure | Widget needs direct API access to Longhorn UI |

### Architecture

```
                    ┌─────────────────────────────────────────┐
                    │         Home Namespace (home)           │
                    └─────────────────────────────────────────┘
                                      │
        ┌─────────────────────────────┼─────────────────────────────┐
        │                             │                             │
┌───────▼───────┐            ┌────────▼────────┐           ┌────────▼────────┐
│  AdGuard Home │            │    Homepage     │           │  Metrics Server │
│  v0.107.71    │            │    v1.9.0       │           │    v0.8.0       │
├───────────────┤            ├─────────────────┤           ├─────────────────┤
│ LoadBalancer  │            │ ClusterIP       │           │ ClusterIP       │
│ 10.10.30.55   │            │ → HTTPRoute     │           │ (kube-system)   │
│ DNS :53/udp   │            │                 │           │                 │
│ HTTP :3000    │            │ 2 replicas      │           │ metrics.k8s.io  │
└───────────────┘            └─────────────────┘           └─────────────────┘
        │                             │
        ▼                             ▼
  All VLAN DHCP              Grafana-style dashboard
  Primary DNS                with K8s/Longhorn widgets
```

### DNS Cutover

| VLAN | Primary DNS | Secondary DNS |
|------|-------------|---------------|
| GUEST | 10.10.30.55 | 10.10.30.54 |
| IOT | 10.10.30.55 | 10.10.30.54 |
| LAN | 10.10.30.55 | 10.10.30.54 |
| SERVERS | 10.10.30.55 | 10.10.30.54 |
| TRUSTED_WIFI | 10.10.30.55 | 10.10.30.54 |

### 1Password Items Created

| Item | Vault | Fields |
|------|-------|--------|
| Homepage | Kubernetes | proxmox-pve-user/token, proxmox-fw-user/token, opnsense-username/password, immich-key, omv-user/pass, glances-pass, adguard-user/pass, weather-key, grafana-user/pass, etc. |

### Lessons Learned

1. **Homepage env var substitution limitation:** `{{HOMEPAGE_VAR_*}}` works in `services.yaml` but NOT in `settings.yaml` `providers` section. Used init container with sed to substitute at runtime.

2. **Longhorn widget requires HTTPRoute:** The Homepage Longhorn info widget fetches data via HTTP from Longhorn UI. Must expose via Gateway API even for internal use.

3. **Security context for init containers:** Don't forget `allowPrivilegeEscalation: false` and `capabilities.drop: ALL` on init containers, not just main containers.

4. **Glances version matters:** OMV apt installs v3.x. Homepage widget config needs `version: 3`, not `version: 4`.

5. **ConfigMap hash suffix:** Kustomize `configMapGenerator` adds hash suffix, enabling automatic pod rollouts when config changes. Don't use `generatorOptions.disableNameSuffixHash`.

### HTTPRoutes Configured

| Service | URL |
|---------|-----|
| AdGuard | adguard.k8s.home.rommelporras.com |
| Homepage | portal.k8s.home.rommelporras.com |
| Longhorn | longhorn.k8s.home.rommelporras.com |

---

## January 20, 2026 — Phase 3.9: Alertmanager Notifications

### Milestone: Discord + Email Alerting Configured

Configured Alertmanager to send notifications via Discord and Email, with intelligent routing based on severity.

| Component | Status |
|-----------|--------|
| Discord #incidents | Webhook configured (critical alerts) |
| Discord #status | Webhook configured (warnings, info, resolved) |
| iCloud SMTP | Configured (noreply@rommelporras.com) |
| Email recipients | 3 addresses for critical alerts |

### Files Added/Modified

| File | Purpose |
|------|---------|
| helm/prometheus/values.yaml | Alertmanager config with routes and receivers |
| scripts/upgrade-prometheus.sh | Helm upgrade script with 1Password integration |
| manifests/monitoring/test-alert.yaml | Test alerts for verification |
| docs/rebuild/v0.5.0-alerting.md | Rebuild guide for alerting setup |
| docs/todo/deferred.md | Added kubeadm scraping issue |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Discord channel naming | #incidents + #status | Clear action expectation: incidents need action, status is FYI |
| Category naming | Notifications | Honest about purpose (notification inbox, not observability tool) |
| Email recipients | 3 addresses for critical | Redundancy: iCloud issues won't prevent delivery to Gmail |
| SMTP authentication | @icloud.com email | Apple requires Apple ID for SMTP auth, not custom domain |
| kubeadm alerts | Silenced (null receiver) | False positives from localhost-bound components; cluster works fine |
| Secrets management | 1Password + temp file | --set breaks array structures; temp file with cleanup is safer |

### Alert Routing

```
┌─────────────────────────────────────────────────┐
│                 Alertmanager                    │
└─────────────────────┬───────────────────────────┘
                      │
    ┌─────────────────┼─────────────────┐
    │                 │                 │
┌───▼───┐        ┌────▼────┐       ┌────▼────┐
│Silenced│        │Critical │       │Warning/ │
│kubeadm │        │         │       │  Info   │
└───┬───┘        └────┬────┘       └────┬────┘
    │                 │                 │
┌───▼───┐        ┌────▼────┐       ┌────▼────┐
│ null  │        │#incidents│       │#status  │
│       │        │+ 3 emails│       │  only   │
└───────┘        └─────────┘       └─────────┘
```

### Silenced Alerts (Deferred)

| Alert | Reason | Fix Location |
|-------|--------|--------------|
| KubeProxyDown | kube-proxy metrics not exposed | docs/todo/deferred.md |
| etcdInsufficientMembers | etcd bound to localhost | docs/todo/deferred.md |
| etcdMembersDown | etcd bound to localhost | docs/todo/deferred.md |
| TargetDown (kube-*) | Control plane bound to localhost | docs/todo/deferred.md |

### 1Password Items Created

| Item | Vault | Purpose |
|------|-------|---------|
| Discord Webhook Incidents | Kubernetes | #incidents webhook URL |
| Discord Webhook Status | Kubernetes | #status webhook URL |
| iCloud SMTP | Kubernetes | SMTP credentials |

### Lessons Learned

1. **Helm --set breaks arrays** - Using `--set 'receivers[0].webhook_url=...'` overwrites the entire array structure. Use multiple `--values` files instead.
2. **iCloud SMTP auth** - Must use @icloud.com email for authentication, not custom domain. From address can be custom domain.
3. **Port 587 = STARTTLS** - Not SSL. Common misconfiguration in email clients.
4. **kubeadm metrics** - Control plane components bind to localhost by default. Fixing requires modifying static pod manifests (risky, low value for homelab).

---

## January 20, 2026 — Documentation: Rebuild Guides

### Milestone: Split Rebuild Documentation by Release Tag

Created comprehensive step-by-step rebuild guides split by release tag for better organization and versioning.

| Document | Release | Phases |
|----------|---------|--------|
| [docs/rebuild/README.md](../rebuild/README.md) | Index | Overview, prerequisites, versions |
| [docs/rebuild/v0.1.0-foundation.md](../rebuild/v0.1.0-foundation.md) | v0.1.0 | Phase 1: Ubuntu, SSH |
| [docs/rebuild/v0.2.0-bootstrap.md](../rebuild/v0.2.0-bootstrap.md) | v0.2.0 | Phase 2: kubeadm, Cilium |
| [docs/rebuild/v0.3.0-storage.md](../rebuild/v0.3.0-storage.md) | v0.3.0 | Phase 3.1-3.4: Longhorn |
| [docs/rebuild/v0.4.0-observability.md](../rebuild/v0.4.0-observability.md) | v0.4.0 | Phase 3.5-3.8: Gateway, Monitoring, Logging, UPS |

### Benefits

- Each release is self-contained and versioned
- Can rebuild to a specific milestone
- Easier to maintain and update individual phases
- Aligns with git tags for reproducibility

---

## January 20, 2026 — Phase 3.8: UPS Monitoring (NUT)

### Milestone: NUT + Prometheus UPS Monitoring Running

Successfully installed Network UPS Tools (NUT) for graceful cluster shutdown during power outages, with Prometheus/Grafana integration for historical metrics and alerting.

| Component | Version | Status |
|-----------|---------|--------|
| NUT (Network UPS Tools) | 2.8.1 | Running (server on cp1, clients on cp2/cp3) |
| nut-exporter (DRuggeri) | 3.1.1 | Running (Deployment in monitoring namespace) |
| CyberPower UPS | CP1600EPFCLCD | Connected (USB to k8s-cp1) |

### Files Added

| File | Purpose |
|------|---------|
| manifests/monitoring/nut-exporter.yaml | Deployment, Service, ServiceMonitor for UPS metrics |
| manifests/monitoring/ups-alerts.yaml | PrometheusRule with 8 UPS alerts |
| manifests/monitoring/dashboards/ups-monitoring.json | Custom UPS dashboard (improved from Grafana.com #19308) |
| manifests/monitoring/ups-dashboard-configmap.yaml | ConfigMap for Grafana auto-provisioning |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| NUT server location | k8s-cp1 (bare metal) | Must run outside K8s to shutdown the node itself |
| Staggered shutdown | Time-based (10/20 min) | NUT upssched timers are native and reliable; percentage-based requires custom polling scripts |
| Exporter | DRuggeri/nut_exporter | Actively maintained (Dec 2025), better documentation, TLS support |
| Dashboard | Custom (repo-stored) | Grafana.com #19308 had issues; custom dashboard with ConfigMap auto-provisioning |
| Metric prefix | network_ups_tools_* | DRuggeri exporter uses this prefix (not nut_*) |
| UPS label | ServiceMonitor relabeling | Exporter doesn't add `ups` label; added via relabeling for dashboard compatibility |

### Architecture

```
CyberPower UPS ──USB──► k8s-cp1 (NUT Server + Master)
                              │
                    TCP 3493 (nutserver)
                              │
              ┌───────────────┼───────────────┐
              ▼               ▼               ▼
          k8s-cp2         k8s-cp3        K8s Cluster
        (upssched)      (upssched)     ┌─────────────────┐
       20min→shutdown  10min→shutdown  │  nut-exporter   │
                                       │  (Deployment)   │
                                       └────────┬────────┘
                                                │ :9995
                                       ┌────────▼────────┐
                                       │   Prometheus    │
                                       │ (ServiceMonitor)│
                                       └────────┬────────┘
                                                │
                                       ┌────────▼────────┐
                                       │    Grafana      │
                                       │  (Dashboard)    │
                                       └────────┬────────┘
                                                │
                                       ┌────────▼────────┐
                                       │  Alertmanager   │
                                       │(PrometheusRule) │
                                       └─────────────────┘
```

### Staggered Shutdown Strategy

| Node | Trigger | Timer | Reason |
|------|---------|-------|--------|
| k8s-cp3 | ONBATT event | 10 minutes | First to shutdown, reduce load early |
| k8s-cp2 | ONBATT event | 20 minutes | Second to shutdown, maintain quorum longer |
| k8s-cp1 | Low Battery (LB) | Native NUT | Last node, sends UPS power-off command |

With ~70 minute runtime at 9% load, these timers provide ample safety margin.

### Kubelet Graceful Shutdown

Configured on all nodes to evict pods gracefully before power-off:

```yaml
shutdownGracePeriod: 120s           # Total time for pod eviction
shutdownGracePeriodCriticalPods: 30s # Reserved for critical pods
```

### Alerts Configured

| Alert | Severity | Trigger |
|-------|----------|---------|
| UPSOnBattery | warning | On battery for 1m |
| UPSLowBattery | critical | LB flag set (immediate) |
| UPSBatteryCritical | critical | Battery < 30% for 1m |
| UPSBatteryWarning | warning | Battery 30-50% for 2m |
| UPSHighLoad | warning | Load > 80% for 5m |
| UPSExporterDown | critical | Exporter unreachable for 2m |
| UPSOffline | critical | Neither OL nor OB status for 2m |
| UPSBackOnline | info | Returns to line power |

### Lessons Learned

**USB permissions require udev rules:** The NUT driver couldn't access the USB device due to permissions. Created `/etc/udev/rules.d/90-nut-ups.rules` to grant the `nut` group access to CyberPower USB devices.

**DRuggeri Helm chart doesn't exist:** Despite documentation suggesting otherwise, there's no working Helm repository. Created manual manifests instead (Deployment, Service, ServiceMonitor).

**Metric names differ from documentation:** DRuggeri exporter uses `network_ups_tools_*` prefix, not `nut_*`. The status metric uses `{flag="OB"}` syntax, not `{status="OB"}`. Had to query the actual exporter to discover correct metric names.

**1Password CLI session scope:** The `op` CLI session is terminal-specific. Running `eval $(op signin)` in one terminal doesn't affect others. Each terminal needs its own session.

**Exporter doesn't add `ups` label:** The DRuggeri exporter doesn't include an `ups` label for single-UPS setups. Dashboard queries with `{ups="$ups"}` returned no data. Fixed with ServiceMonitor relabeling to inject `ups=cyberpower` label.

**Grafana.com dashboard had issues:** Dashboard #19308 showed "No Data" for several panels due to missing `--nut.vars_enable` metrics (battery.runtime, output.voltage). Created custom dashboard stored in repo with ConfigMap auto-provisioning.

**Grafana thresholdsStyle modes:** Setting `thresholdsStyle.mode: "line"` draws horizontal threshold lines on graphs; `"area"` fills background with threshold colors. Both can clutter graphs if overused.

### Access

- UPS Dashboard: https://grafana.k8s.home.rommelporras.com/d/ups-monitoring
- NUT Server: 10.10.30.11:3493
- nut-exporter (internal): nut-exporter.monitoring.svc.cluster.local:9995

### Sample PromQL Queries

```promql
network_ups_tools_battery_charge                        # Battery percentage
network_ups_tools_ups_load                              # Current load %
network_ups_tools_ups_status{flag="OL"}                 # Online status (1=true)
network_ups_tools_ups_status{flag="OB"}                 # On battery status
network_ups_tools_battery_runtime_seconds               # Estimated runtime
```

---

## January 19, 2026 — Phase 3.7: Logging Stack

### Milestone: Loki + Alloy Running

Successfully installed centralized logging with Loki for storage and Alloy for log collection.

| Component | Version | Status |
|-----------|---------|--------|
| Loki | v3.6.3 | Running (SingleBinary, 10Gi PVC) |
| Alloy | v1.12.2 | Running (DaemonSet, 3 pods) |

### Files Added

| File | Purpose |
|------|---------|
| helm/loki/values.yaml | Loki SingleBinary mode, 90-day retention, Longhorn storage |
| helm/alloy/values.yaml | Alloy DaemonSet with K8s API log collection + K8s events |
| manifests/monitoring/loki-datasource.yaml | Grafana datasource ConfigMap for Loki |
| manifests/monitoring/loki-servicemonitor.yaml | Prometheus scraping for Loki metrics |
| manifests/monitoring/alloy-servicemonitor.yaml | Prometheus scraping for Alloy metrics |
| manifests/monitoring/logging-alerts.yaml | PrometheusRule with Loki/Alloy alerts |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Loki mode | SingleBinary | Cluster generates ~4MB/day logs, far below 20GB/day threshold |
| Storage backend | Filesystem (Longhorn PVC) | SimpleScalable/Distributed require S3, overkill for homelab |
| Retention | 90 days | Storage analysis showed ~360-810MB needed, 10Gi provides headroom |
| Log collection | loki.source.kubernetes | Uses K8s API, no volume mounts or privileged containers needed |
| Alloy controller | DaemonSet | One pod per node ensures all logs collected |
| OCI registry | Loki only | Alloy doesn't support OCI yet, uses traditional Helm repo |
| K8s events | Single collector | Only k8s-cp1's Alloy forwards events to avoid triplicates |
| Observability | ServiceMonitors + Alerts | Monitor the monitors - Prometheus scrapes Loki/Alloy |
| Alloy memory | 256Mi limit | Increased from 128Mi to handle events collection safely |

### Lessons Learned

**Loki OCI available but undocumented:** Official docs still show `helm repo add grafana`, but Loki chart is available via OCI at `oci://ghcr.io/grafana/helm-charts/loki`. Alloy is not available via OCI (403 denied).

**lokiCanary is top-level setting:** The Loki chart has `lokiCanary.enabled` at the top level, NOT under `monitoring.lokiCanary`. This caused unwanted canary pods until fixed.

**loki.source.kubernetes vs loki.source.file:** The newer `loki.source.kubernetes` component tails logs via K8s API instead of mounting `/var/log/pods`. Benefits: no volume mounts, no privileged containers, works with restrictive Pod Security Standards.

**Grafana sidecar auto-discovery:** Creating a ConfigMap with label `grafana_datasource: "1"` automatically adds the datasource to Grafana. No manual configuration needed.

### Architecture

```
Pod stdout ──────► Alloy (DaemonSet) ──► Loki (SingleBinary) ──► Longhorn PVC
K8s Events ──────►        │                      │
                          │                      ▼
                          │                  Grafana
                          │                      ▲
                          ▼                      │
                    Prometheus ◄── ServiceMonitors (loki, alloy)
                          │
                          ▼
                    Alertmanager ◄── PrometheusRule (logging-alerts)
```

### Alerts Configured

| Alert | Severity | Trigger |
|-------|----------|---------|
| LokiDown | critical | Loki unreachable for 5m |
| LokiIngestionStopped | warning | No logs received for 15m |
| LokiHighErrorRate | warning | Error rate > 10% for 10m |
| LokiStorageLow | warning | PVC < 20% free for 30m |
| AlloyNotOnAllNodes | warning | Alloy pods < node count for 10m |
| AlloyNotSendingLogs | warning | No logs sent for 15m |
| AlloyHighMemory | warning | Memory > 80% limit for 10m |

### Access

- Grafana Explore: https://grafana.k8s.home.rommelporras.com/explore
- Loki (internal): loki.monitoring.svc.cluster.local:3100

### Sample LogQL Queries

```logql
{namespace="monitoring"}                    # All monitoring logs
{namespace="kube-system", container="etcd"} # etcd logs
{cluster="homelab"} |= "error"              # Search for errors
{source="kubernetes_events"}                # All K8s events
{source="kubernetes_events"} |= "Warning"   # Warning events only
```

---

## January 18, 2026 — Phase 3.6: Monitoring Stack

### Milestone: kube-prometheus-stack Running

Successfully installed complete monitoring stack with Prometheus, Grafana, Alertmanager, and node-exporter.

| Component | Version | Status |
|-----------|---------|--------|
| kube-prometheus-stack | v81.0.0 | Running |
| Prometheus | v0.88.0 | Running (50Gi PVC) |
| Grafana | latest | Running (10Gi PVC) |
| Alertmanager | latest | Running (5Gi PVC) |
| node-exporter | latest | Running (DaemonSet, 3 pods) |

### Files Added

| File | Purpose |
|------|---------|
| helm/prometheus/values.yaml | Helm values with 90-day retention, Longhorn storage |
| manifests/monitoring/grafana-httproute.yaml | Gateway API route for HTTPS access |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Pod Security | privileged | node-exporter needs hostNetwork, hostPID, hostPath |
| OCI registry | Yes | Recommended by upstream, no helm repo add needed |
| Retention | 90 days | Balance between history and storage usage |
| Storage | Longhorn | Consistent with cluster storage strategy |

### Lessons Learned

**Pod Security Standards block node-exporter:** The `baseline` PSS level rejects pods with hostNetwork/hostPID/hostPath. node-exporter requires these for host-level metrics collection.

**Solution:** Use `privileged` PSS for monitoring namespace: `kubectl label namespace monitoring pod-security.kubernetes.io/enforce=privileged`

**DaemonSet backoff requires restart:** After fixing PSS, the DaemonSet controller was in backoff. Required `kubectl rollout restart daemonset` to retry pod creation.

### Access

- Grafana: https://grafana.k8s.home.rommelporras.com
- Prometheus (internal): prometheus-kube-prometheus-prometheus:9090
- Alertmanager (internal): prometheus-kube-prometheus-alertmanager:9093

---

## January 17, 2026 — Phase 3: Storage Infrastructure

### Milestone: Longhorn Distributed Storage Running

Successfully installed Longhorn for persistent storage across all 3 nodes.

| Component | Version | Status |
|-----------|---------|--------|
| Longhorn | v1.10.1 | Running |
| StorageClass | longhorn (default) | Active |
| Replicas | 2 per volume | Configured |

### Ansible Playbooks Added

| Playbook | Purpose |
|----------|---------|
| 06-storage-prereqs.yml | Create /var/lib/longhorn, verify iscsid, install nfs-common |
| 07-remove-taints.yml | Remove control-plane taints for homelab workloads |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Replica count | 2 | With 3 nodes, survives 1 node failure. 3 replicas would waste storage. |
| Storage path | /var/lib/longhorn | Standard location, ~432GB available per node |
| Taint removal | All nodes | Homelab has no dedicated workers, workloads must run on control plane |
| Helm values file | helm/longhorn/values.yaml | GitOps-friendly, version controlled |

### Lessons Learned

**Control-plane taints block workloads:** By default, kubeadm taints control plane nodes with `NoSchedule`. In a homelab cluster with no dedicated workers, this prevents Longhorn (and all other workloads) from scheduling.

**Solution:** Remove taints with `kubectl taint nodes --all node-role.kubernetes.io/control-plane:NoSchedule-`

**Helm needs KUBECONFIG:** When using a non-default kubeconfig (like homelab.yaml), Helm requires the correct kubeconfig. Created `helm-homelab` alias in ~/.zshrc alongside `kubectl-homelab`.

**NFSv4 pseudo-root path format:** When OMV exports `/export` with `fsid=0`, it becomes the NFSv4 pseudo-root. Mount paths must be relative to this root:
- Filesystem path: `/export/Kubernetes/Immich`
- NFSv4 mount path: `/Kubernetes/Immich` (not `/export/Kubernetes/Immich`!)

This caused "No such file or directory" errors until the path format was corrected.

### Storage Strategy Documented

| Storage Type | Use Case | Example Apps |
|--------------|----------|--------------|
| Longhorn (block) | App data, databases, runtime state | AdGuard logs, PostgreSQL |
| NFS (file) | Bulk media, photos | Immich, *arr stack |
| ConfigMap (K8s) | Static config files | Homepage settings |

### NFS Status

- NAS (10.10.30.4) is network reachable
- NFS export /export/Kubernetes enabled on OMV
- NFSv4 mount tested and verified from cluster nodes
- Manifest ready at `manifests/storage/nfs-immich.yaml`
- PV name: `immich-nfs`, PVC name: `immich-media`

---

## January 16, 2026 — Kubernetes HA Cluster Bootstrap Complete

### Milestone: 3-Node HA Cluster Running

Successfully bootstrapped a 3-node high-availability Kubernetes cluster using kubeadm.

| Component | Version | Status |
|-----------|---------|--------|
| Kubernetes | v1.35.0 | Running |
| kube-vip | v1.0.3 | Active (VIP: 10.10.30.10) |
| Cilium | 1.18.6 | Healthy |
| etcd | 3 members | Quorum established |

### Ansible Playbooks Created

Full automation for cluster bootstrap:

| Playbook | Purpose |
|----------|---------|
| 00-preflight.yml | Pre-flight checks (cgroup v2, network, DNS) |
| 01-prerequisites.yml | System prep (swap, modules, containerd, kubeadm) |
| 02-kube-vip.yml | VIP setup with K8s 1.29+ workaround |
| 03-init-cluster.yml | kubeadm init with config generation |
| 04-cilium.yml | CNI installation with checksum verification |
| 05-join-cluster.yml | Control plane join with post-join reboot |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Post-join reboot | Enabled | Resolves Cilium init timeouts and kube-vip leader election conflicts |
| Workstation config | ~/.kube/homelab.yaml | Separate from work EKS (~/.kube/config) |
| kubectl alias | `kubectl-homelab` | Work wiki copy-paste compatibility |

### Lessons Learned

**Cascading restart issue:** Joining multiple control planes can cause cascading failures:
- Cilium init timeouts ("failed to sync configmap cache")
- kube-vip leader election conflicts
- Accumulated backoff timers on failed containers

**Solution:** Reboot each node after join to clear state and backoff timers.

### Workstation Setup

```bash
# Homelab cluster (separate from work)
kubectl-homelab get nodes

# Work EKS (unchanged)
kubectl get pods
```

---

## January 11, 2026 — Node Preparation & Project Setup

### Ubuntu Pro Attached

All 3 nodes attached to Ubuntu Pro (free personal subscription, 5 machine limit).

| Service | Status | Benefit |
|---------|--------|---------|
| ESM Apps | Enabled | Extended security for universe packages |
| ESM Infra | Enabled | Extended security for main packages |
| Livepatch | Enabled | Kernel patches without reboot |

### Firmware Updates

| Node | NVMe | BIOS | EC | Notes |
|------|------|------|-----|-------|
| cp1 | 41730C20 | 1.99 | 256.24 | All updates applied |
| cp2 | 41730C20 | 1.90 | 256.20 | Boot Order Lock blocking BIOS/EC |
| cp3 | 41730C20 | 1.82 | 256.20 | Boot Order Lock blocking BIOS/EC |

**NVMe update (High urgency):** Applied to all nodes.
**BIOS/EC updates (Low urgency):** Deferred for cp2/cp3 - requires physical access to disable Boot Order Lock in BIOS. Tracked in TODO.md.

### Claude Code Configuration

Created `.claude/` directory structure:

| Component | Purpose |
|-----------|---------|
| commands/commit.md | Conventional commits with `infra:` type |
| commands/release.md | Semantic versioning and GitHub releases |
| commands/validate.md | YAML and K8s manifest validation |
| commands/cluster-status.md | Cluster health checks |
| agents/kubernetes-expert | K8s troubleshooting and best practices |
| skills/kubeadm-patterns | Bootstrap issues and upgrade patterns |
| hooks/protect-sensitive.sh | Block edits to secrets/credentials |

### GitHub Repository

Recreated repository with clean commit history and proper conventional commit messages.

**Description:** From Proxmox VMs/LXCs to GitOps-driven Kubernetes. Proxmox now handles NAS and OPNsense only. Production workloads run on 3-node HA bare-metal K8s. Lenovo M80q nodes, kubeadm, Cilium, kube-vip, Longhorn. Real HA for real workloads. CKA-ready.

### Rules Added to CLAUDE.md

- No AI attribution in commits
- No automatic git commits/pushes (require explicit request or /commit, /release)

---

## January 11, 2026 — Ubuntu Installation Complete

### Milestone: Phase 1 Complete

All 3 nodes running Ubuntu 24.04.3 LTS with SSH access configured.

### Hardware Verification

**Actual hardware is M80q, not M70q Gen 1** as originally thought.

| Spec | Documented | Actual |
|------|------------|--------|
| Model | M70q Gen 1 | **M80q** |
| Product ID | — | 11DN0054PC |
| CPU | i5-10400T | i5-10400T |
| NIC | I219-V | **I219-LM** |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Hostnames | k8s-cp1/2/3 | Industry standard k8s prefix |
| Username | wawashi | Consistent across all nodes |
| IP Scheme | .11/.12/.13 | Node number matches last octet |
| VIP | 10.10.30.10 | "Base" cluster address |
| Filesystem | ext4 | Most stable for containers |
| LVM | Full disk | Manually expanded from 100GB default |

### Issues Resolved

| Issue | Cause | Solution |
|-------|-------|----------|
| DHCP not working in installer | Gateway/DNS not persisting | Use OPNsense DHCP reservations |
| Nodes can't reach gateway | VLAN 30 not in trunk list | Add VLAN to Native AND Trunk |
| LVM only 100GB | Ubuntu installer bug | Edit ubuntu-lv size to max |
| Interface name | Docs said enp0s31f6 | Actual is eno1 (Intel I219-LM) |

### Documentation Refactor

Consolidated documentation to reduce redundancy:

**Files Consolidated:**
- HARDWARE_SPECS.md → Merged into CLUSTER_STATUS.md
- SWITCH_CONFIG.md → Merged into NETWORK_INTEGRATION.md
- PRE_INSTALLATION_CHECKLIST.md → Lessons in CHANGELOG.md
- KUBEADM.md → Split into KUBEADM_BOOTSTRAP.md (project-specific)

**Key Principle:** CLUSTER_STATUS.md is the single source of truth for all node/hardware values.

---

## January 10, 2026 — Switch Configuration

### VLAN Configuration

Configured LIANGUO LG-SG5T1 managed switch.

### Critical Learning

**VLAN must be in Trunk VLAN list even if set as Native VLAN** on this switch model.

---

## January 4, 2026 — Pre-Installation Decisions

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Network Speed | 1GbE initially | Identify bottlenecks first |
| VIP Strategy | kube-vip (ARP) | No OPNsense changes needed |
| Switch Type | Managed | VLAN support required |
| Ubuntu Install | Full disk + LVM | Simple, Longhorn uses directory |

---

## January 3, 2026 — Hardware Purchase

### Hardware Purchased

| Item | Qty | Specs |
|------|-----|-------|
| Lenovo M80q | 3 | i5-10400T, 16GB, 512GB NVMe |
| LIANGUO LG-SG5T1 | 1 | 5x 2.5GbE + 1x 10G SFP+ |

### Decision: M80q over M70q Gen 3

| Factor | M70q Gen 3 | M80q (purchased) |
|--------|------------|------------------|
| CPU Gen | 12th (hybrid) | 10th (uniform) |
| RAM | DDR5 | DDR4 |
| Price | Higher | **Lower** |
| Complexity | P+E cores | Simple |

10th gen uniform cores simpler for Kubernetes scheduling.

---

## December 31, 2025 — Network Adapter Correction

### Correction Applied

| Previous | Corrected |
|----------|-----------|
| Intel i226-V | **Intel i225-V rev 3** |

**Reason:** i226-V has ASPM + NVMe conflicts causing stability issues.

---

## December 2025 — Initial Planning

### Project Goals Defined

1. Learn Kubernetes via hands-on homelab
2. Master AWS EKS monitoring for work
3. Pass CKA certification by September 2026

### Key Requirements

- High availability (3-node minimum for etcd quorum)
- Stateful workload support (Longhorn)
- CKA exam alignment (kubeadm, not k3s)
