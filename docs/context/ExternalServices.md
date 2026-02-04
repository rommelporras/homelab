---
tags: [homelab, kubernetes, external-services, cloudflare, analytics, smtp]
updated: 2026-02-03
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
| status.rommelporras.com | uptime-kuma/uptime-kuma |
| invoicetron.rommelporras.com | invoicetron (DMZ VM) |

### WAF Custom Rules

Protect Ghost admin panel and allow public endpoints. Rules evaluate in strict order (Security → WAF → Custom Rules).

| # | Rule Name | Expression | Action |
|---|-----------|-----------|--------|
| 1 | Blog - Allow RSS Feed | `http.host eq "blog.rommelporras.com" and http.request.uri.path eq "/rss/"` | Skip all remaining custom rules + Super Bot Fight Mode |
| 2 | Ghost - Allow Content API | `http.host eq "blog.rommelporras.com" and starts_with(http.request.uri.path, "/ghost/api/content")` | Skip all remaining custom rules |
| 3 | Ghost - Block Admin | `http.host eq "blog.rommelporras.com" and starts_with(http.request.uri.path, "/ghost")` | Block |

Rule 1 skips both custom rules and Super Bot Fight Mode. Bot Fight Mode is disabled globally (Security → Settings) because the free tier cannot create path-specific exceptions — it blocks all cloud provider IPs including GitHub Actions.

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
