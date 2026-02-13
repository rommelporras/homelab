---
tags: [homelab, kubernetes, external-services, cloudflare, analytics, tinybird, smtp, tailscale]
updated: 2026-02-13
---

# External Services

Third-party services configured outside the cluster but integrated with workloads.

For 1Password paths and secret references, see [[Secrets]].

## Google Analytics (GA4)

Single GA4 property with multiple data streams — all traffic in one dashboard.

| Stream | Domain | Measurement ID | Method |
|--------|--------|---------------|--------|
| My Portfolio | rommelporras.com | G-VZKWF8Y4PZ | Direct gtag.js (in site HTML) |
| Status Page | status.rommelporras.com | G-3CW788LJCE | Uptime Kuma → Settings → Status Pages → Google Analytics Tag ID |
| Blog | blog.rommelporras.com | G-3JPQSZ3DVM | Via GTM container (see below) |

**Console:** [analytics.google.com](https://analytics.google.com) (rommelcporras@gmail.com)

## Google Tag Manager (GTM)

Manages tracking tags for the blog. Add new tags (Google Ads, LinkedIn, etc.) in the GTM dashboard — no Ghost changes needed.

| Setting | Value |
|---------|-------|
| Account | rommelporras.com |
| Container | Blog |
| Container ID | GTM-KJRK79WT |
| Installed on | Ghost prod → Settings → Code injection → Site Header |

**Tags configured:**

| Tag | Type | Trigger | ID |
|-----|------|---------|-----|
| GA4 - Blog | Google Tag | All Pages | G-3JPQSZ3DVM |

**Console:** [tagmanager.google.com](https://tagmanager.google.com) (rommelcporras@gmail.com)

## Cloudflare

### Tunnel

Exposes public services from the cluster without opening firewall ports.

| Setting | Value |
|---------|-------|
| Dashboard | Cloudflare Zero Trust → Networks → Tunnels |
| Replicas | 2 pods (anti-affinity across nodes) |
| Image | cloudflare/cloudflared |
| Secret | `op://Kubernetes/Cloudflare Tunnel/token` |

**Public hostnames:**

| Hostname | Backend |
|----------|---------|
| www.rommelporras.com | portfolio-prod/portfolio |
| blog.rommelporras.com | ghost-prod/ghost |
| blog-api.rommelporras.com | ghost-prod/ghost-analytics |
| status.rommelporras.com | uptime-kuma/uptime-kuma |
| invoicetron.rommelporras.com | invoicetron-prod/invoicetron |

### WAF Custom Rules

Protect Ghost admin panel and allow public endpoints. Rules evaluate in strict order (Security → WAF → Custom Rules).

| # | Rule Name | Expression | Action |
|---|-----------|-----------|--------|
| 1 | Blog - Allow RSS Feed | `http.host eq "blog.rommelporras.com" and http.request.uri.path eq "/rss/"` | Skip all remaining custom rules + Super Bot Fight Mode |
| 2 | Ghost - Allow Content API | `http.host eq "blog.rommelporras.com" and starts_with(http.request.uri.path, "/ghost/api/content")` | Skip all remaining custom rules |
| 3 | Ghost - Block Admin | `http.host eq "blog.rommelporras.com" and starts_with(http.request.uri.path, "/ghost")` | Block |

Rule 1 skips both custom rules and Super Bot Fight Mode. Bot Fight Mode is disabled globally (Security → Settings) because the free tier cannot create path-specific exceptions — it blocks all cloud provider IPs including GitHub Actions.

### Cloudflare Access

Protects public-facing applications with access policies.

| Application | Domain | Policy | Method |
|-------------|--------|--------|--------|
| Uptime Kuma | status.rommelporras.com | Block Admin (blocks /dashboard, /manage-status-page, /settings) | Block Everyone |
| Invoicetron | invoicetron.rommelporras.com | Allow Admin | Email OTP |

**Note:** Ghost blog uses WAF custom rules (not Cloudflare Access) for admin protection.
See WAF Custom Rules section above.

**Allow Admin policy:**
- Action: Allow
- Include: Emails (cloudflare@rommelporras.com, rommelcporras@gmail.com)
- Session duration: 24 hours

### DNS API Token

Used by cert-manager for DNS-01 challenge (Let's Encrypt wildcard certs).

| Setting | Value |
|---------|-------|
| Secret | `op://Kubernetes/Cloudflare DNS API Token/credential` |
| Used by | cert-manager ClusterIssuer (letsencrypt-prod) |

## Let's Encrypt

| Setting | Value |
|---------|-------|
| Environment | Production |
| ACME server | https://acme-v02.api.letsencrypt.org/directory |
| Challenge | DNS-01 via Cloudflare |
| ClusterIssuer | letsencrypt-prod |

**Certificates:**

| Secret | Domain | Renewal |
|--------|--------|---------|
| wildcard-k8s-tls | *.k8s.rommelporras.com | 90 days (auto) |
| wildcard-dev-k8s-tls | *.dev.k8s.rommelporras.com | 90 days (auto) |
| wildcard-stg-k8s-tls | *.stg.k8s.rommelporras.com | 90 days (auto) |

## Healthchecks.io

Dead man's switch — Alertmanager sends periodic pings to validate the alerting pipeline is healthy.

| Setting | Value |
|---------|-------|
| Secret | `op://Kubernetes/Healthchecks Ping URL/password` |
| Sender | Alertmanager Watchdog receiver |
| Interval | 1 minute |
| Console | [healthchecks.io](https://healthchecks.io) |

## Discord

Two webhook channels for alert routing.

| Channel | Purpose | Secret |
|---------|---------|--------|
| #incidents | Critical alerts | `op://Kubernetes/Discord Webhook Incidents/credential` |
| #status | Info/Warning updates | `op://Kubernetes/Discord Webhook Status/credential` |

## iCloud SMTP

Apple iCloud SMTP for email notifications. Requires an app-specific password generated at [appleid.apple.com](https://appleid.apple.com).

| Setting | Value |
|---------|-------|
| Server | smtp.mail.me.com |
| Port | 587 (STARTTLS) |
| Auth | App-specific password |
| Secret | `op://Kubernetes/iCloud SMTP/{username,password}` |

**Used by:** Alertmanager, GitLab, Ghost (dev + prod)

**Alert recipients:** critical@rommelporras.com, r3mmel023@gmail.com, rommelcporras@gmail.com

## Tinybird (Ghost Web Analytics)

Cookie-free, privacy-preserving web analytics for the Ghost blog. Ghost's native integration sends page hits through a TrafficAnalytics proxy to Tinybird's event ingestion API.

| Setting | Value |
|---------|-------|
| Region | US-East-1 (AWS) |
| Plan | Free tier |
| Workspace | Ghost analytics |
| Secret | `op://Kubernetes/Ghost Tinybird/{workspace-id,admin-token,tracker-token,api-url}` |
| Console | [tinybird.co](https://www.tinybird.co) |

**Architecture:**
- `ghost-stats.min.js` (injected by Ghost) POSTs page hits from browser to `blog-api.rommelporras.com`
- TrafficAnalytics proxy (`ghost/traffic-analytics:1.0.72`) enriches data (user agent, referrer, privacy signatures)
- Proxy forwards to Tinybird Events API (`https://api.us-east.aws.tinybird.co/v0/events`)
- Ghost admin dashboard reads stats from Tinybird's stats endpoint

**Note:** No Asia-Pacific Tinybird regions available. US-East is closest to Philippines. Server pushes to Tinybird (not the client browser), so region only affects server-side latency.

## Tailscale

Remote access via WireGuard mesh VPN. Admin console manages ACLs, devices, and DNS.

| Setting | Value |
|---------|-------|
| Tailnet | `capybara-interval.ts.net` |
| Console | [login.tailscale.com](https://login.tailscale.com) |
| Plan | Free (personal) |
| Secret | `op://Kubernetes/Tailscale K8s Operator/{client-id,client-secret,api-token}` |

**ACL Policy (JSON editor):**

| Tag | Applied To | Purpose |
|-----|-----------|---------|
| `tag:k8s-operator` | Operator pod | Manages proxy pods and CRDs |
| `tag:k8s` | Connector + proxy pods | Subnet routing, default proxy tag |

**autoApprovers** in ACL policy auto-approve `10.10.30.0/24` routes for `tag:k8s` devices (no manual approval in admin console).

**OAuth Client (Trust Credentials):**

| Setting | Value |
|---------|-------|
| Location | Settings → Trust credentials |
| Scopes | Devices Core (R&W), Auth Keys (R&W), Services (Write) |
| Tag | `tag:k8s-operator` |

**DNS Configuration:**

| Setting | Value |
|---------|-------|
| MagicDNS | Enabled |
| Global Nameserver | `10.10.30.53` (K8s AdGuard, reachable via subnet route) |
| Override DNS | ON |

All tailnet devices use K8s AdGuard for DNS. AdGuard resolves `*.k8s.rommelporras.com` → `10.10.30.20` (Cilium Gateway), so all existing HTTPRoutes work from any Tailscale device with zero per-service configuration.

**Devices:**

| Device | Tailscale IP | Type |
|--------|-------------|------|
| `tailscale-operator` | 100.69.243.39 | Operator (tag:k8s-operator) |
| `homelab-subnet` | 100.109.196.53 | Connector / subnet router (tag:k8s) |

**Note:** API token (for Homepage widget) expires 2026-05-14. Renewal alert set for 2026-04-30.

For in-cluster technical details (connector spec, traffic flow, DERP relay), see [[Networking]].

## Domain

| Setting | Value |
|---------|-------|
| Primary domain | rommelporras.com |
| K8s zone | *.k8s.rommelporras.com |
| Dev zone | *.dev.k8s.rommelporras.com |
| Staging zone | *.stg.k8s.rommelporras.com |
| Legacy zone | *.home.rommelporras.com (Proxmox, non-K8s) |
| Internal DNS | AdGuard (10.10.30.53) with failover (10.10.30.54) |

## GitHub

| Repository | Visibility | Purpose |
|-----------|------------|---------|
| [rommelporras/homelab](https://github.com/rommelporras/homelab) | Public (MIT) | Cluster manifests, docs, Ansible |
| [rommelporras/rommelporras](https://github.com/rommelporras/rommelporras) | Public | GitHub Profile README |

### Profile README Workflows

The profile repo has two GitHub Actions that run daily at midnight UTC:

| Workflow | Action | Dependency |
|----------|--------|------------|
| `snake.yml` | Generates contribution snake SVG → `output` branch | None |
| `blog-posts.yml` | Fetches Ghost RSS → updates README | Cloudflare WAF Rule 1 (skip `/rss/`) + Bot Fight Mode OFF |
