---
tags: [homelab, kubernetes, secrets, 1password]
updated: 2026-02-18
---

# Secrets

All secrets are stored in 1Password. Never hardcode credentials.

## Security Boundary

**1Password is never accessed by automation.** All `op read` commands are run manually from a separate trusted terminal — never from Claude Code, CI/CD pipelines, or any automated process.

**Why:** The 1Password personal account has access to all vaults (Kubernetes, Private, etc.). There is no way to scope CLI access to a single vault on an Individual plan. Running `op` from automation risks exposing personal credentials.

**Workflow:**
1. Run `eval $(op signin)` in a separate terminal
2. Copy-paste the `kubectl-homelab create secret` commands from the secret.yaml documentation files
3. The commands use `$(op read 'op://...')` to inject values at runtime
4. Secrets are created directly in the cluster — never written to disk or git

**GitOps exception:** Secrets are the one intentional imperative step. All other resources (Deployments, Services, ConfigMaps, etc.) are declarative and managed via git.

## Secret File Convention

All `manifests/**/secret.yaml` files are **documentation placeholders** committed to git. They contain:
- Commented `kubectl create secret` commands with `op://` references
- Empty Secret manifests with `managed-by: "imperative-kubectl"` annotation
- No real credential values

These files serve as the "recipe" for recreating secrets during a cluster rebuild.

## 1Password Vault

**Vault:** `Kubernetes`

Do NOT modify items in the `Proxmox` vault (legacy infrastructure).

## Item Reference

| Item | Fields | Used By |
|------|--------|---------|
| Grafana | `password` | kube-prometheus-stack |
| Cloudflare DNS API Token | `credential` | cert-manager (Let's Encrypt) |
| Discord Webhook Incidents | `credential` | Alertmanager |
| Discord Webhook Status | `credential` | Alertmanager |
| iCloud SMTP | `username`, `password`, `server`, `port` | Alertmanager, GitLab |
| GitLab | `username`, `password`, `postgresql-password` | GitLab CE |
| GitLab Runner | `runner-token` | GitLab Runner |
| Healthchecks Ping URL | `password` | Alertmanager Watchdog (dead man's switch) |
| NUT Admin | `username`, `password` | NUT server |
| NUT Monitor | `username`, `password` | NUT clients, nut-exporter |
| Homepage | Multiple (see below) | Homepage dashboard widgets |
| Ghost Dev MySQL | `root-password`, `user-password` | ghost-dev MySQL StatefulSet |
| Ghost Prod MySQL | `root-password`, `user-password` | ghost-prod MySQL StatefulSet |
| Ghost Dev Admin API | `key` | GitLab CI/CD (dev theme deploy) |
| Ghost Prod Admin API | `key` | GitLab CI/CD (prod theme deploy) |
| Uptime Kuma | `username`, `password` | Uptime Kuma admin login |
| Invoicetron Dev | `postgres-password`, `better-auth-secret`, `database-url` | invoicetron-dev namespace |
| Invoicetron Prod | `postgres-password`, `better-auth-secret`, `database-url` | invoicetron-prod namespace |
| Invoicetron Deploy Token | `username`, `password` | gitlab-registry imagePullSecret (both namespaces) |
| Ghost Tinybird | `workspace-id`, `admin-token`, `tracker-token`, `api-url` | Ghost web analytics (TrafficAnalytics proxy) |
| Firefox Browser | `username`, `password` | Firefox KasmVNC basic auth (browser namespace) |
| Karakeep | `nextauth-secret`, `meili-master-key`, `api-key` | Karakeep auth + Meilisearch + Homepage widget |
| Tailscale K8s Operator | `client-id`, `client-secret`, `api-token` | Tailscale OAuth + Homepage widget (api-token expires 2026-05-14) |
| Portfolio | `kube-api-url`, `kube-token-development`, `kube-token-staging`, `kube-token-production` | GitLab CI/CD (portfolio deploy to K8s) |
| ARR Stack | `username`, `password`, `prowlarr-api-key`, `sonarr-api-key`, `radarr-api-key`, `bazarr-api-key`, `jellyfin-api-key`, `tdarr-api-key`, `discord-webhook-url` | All ARR apps (shared login), Homepage widgets, arr-api-keys Secret, Discord notifications |
| Opensubtitles | `username`, `user[password_confirmation]` | Bazarr subtitle provider (OpenSubtitles.com) |
| iCloud SMTP | (reused) | Ghost mail (ghost-dev, ghost-prod) |

## 1Password Paths

```bash
# Grafana
op://Kubernetes/Grafana/password

# Cloudflare (cert-manager)
op://Kubernetes/Cloudflare DNS API Token/credential

# Discord webhooks
op://Kubernetes/Discord Webhook Incidents/credential
op://Kubernetes/Discord Webhook Status/credential

# SMTP (Alertmanager, GitLab)
op://Kubernetes/iCloud SMTP/username
op://Kubernetes/iCloud SMTP/password

# GitLab
op://Kubernetes/GitLab/username
op://Kubernetes/GitLab/password
op://Kubernetes/GitLab/postgresql-password

# GitLab Runner
op://Kubernetes/GitLab Runner/runner-token

# Healthchecks (dead man's switch)
op://Kubernetes/Healthchecks Ping URL/password

# NUT
op://Kubernetes/NUT Admin/username
op://Kubernetes/NUT Admin/password
op://Kubernetes/NUT Monitor/username
op://Kubernetes/NUT Monitor/password

# Ghost MySQL (dev)
op://Kubernetes/Ghost Dev MySQL/root-password
op://Kubernetes/Ghost Dev MySQL/user-password

# Ghost MySQL (prod)
op://Kubernetes/Ghost Prod MySQL/root-password
op://Kubernetes/Ghost Prod MySQL/user-password

# Ghost Admin API (GitLab CI/CD theme deployment)
op://Kubernetes/Ghost Dev Admin API/key
op://Kubernetes/Ghost Prod Admin API/key

# Ghost Tinybird (web analytics)
op://Kubernetes/Ghost Tinybird/workspace-id
op://Kubernetes/Ghost Tinybird/admin-token
op://Kubernetes/Ghost Tinybird/tracker-token
op://Kubernetes/Ghost Tinybird/api-url

# Ghost Mail (reuses iCloud SMTP - see above)

# Uptime Kuma
op://Kubernetes/Uptime Kuma/username
op://Kubernetes/Uptime Kuma/password

# Invoicetron Dev
op://Kubernetes/Invoicetron Dev/postgres-password
op://Kubernetes/Invoicetron Dev/better-auth-secret
op://Kubernetes/Invoicetron Dev/database-url

# Invoicetron Prod
op://Kubernetes/Invoicetron Prod/postgres-password
op://Kubernetes/Invoicetron Prod/better-auth-secret
op://Kubernetes/Invoicetron Prod/database-url

# Invoicetron Deploy Token (private registry imagePullSecret)
op://Kubernetes/Invoicetron Deploy Token/username
op://Kubernetes/Invoicetron Deploy Token/password

# Firefox Browser (KasmVNC auth)
op://Kubernetes/Firefox Browser/username
op://Kubernetes/Firefox Browser/password

# Karakeep (auth + search + API)
op://Kubernetes/Karakeep/nextauth-secret
op://Kubernetes/Karakeep/meili-master-key
op://Kubernetes/Karakeep/api-key

# Tailscale K8s Operator (OAuth + Homepage widget)
op://Kubernetes/Tailscale K8s Operator/client-id
op://Kubernetes/Tailscale K8s Operator/client-secret
op://Kubernetes/Tailscale K8s Operator/api-token

# Portfolio (GitLab CI/CD deploy tokens)
op://Kubernetes/Portfolio/kube-api-url
op://Kubernetes/Portfolio/kube-token-development
op://Kubernetes/Portfolio/kube-token-staging
op://Kubernetes/Portfolio/kube-token-production

# ARR Stack (shared credentials for all ARR apps)
op://Kubernetes/ARR Stack/username
op://Kubernetes/ARR Stack/password
op://Kubernetes/ARR Stack/prowlarr-api-key
op://Kubernetes/ARR Stack/sonarr-api-key
op://Kubernetes/ARR Stack/radarr-api-key
op://Kubernetes/ARR Stack/bazarr-api-key
op://Kubernetes/ARR Stack/jellyfin-api-key
op://Kubernetes/ARR Stack/tdarr-api-key
op://Kubernetes/ARR Stack/discord-webhook-url

# Opensubtitles (Bazarr subtitle provider)
op://Kubernetes/Opensubtitles/username
op://Kubernetes/Opensubtitles/user[password_confirmation]

# Homepage (widget credentials)
op://Kubernetes/Homepage/proxmox-pve-user
op://Kubernetes/Homepage/proxmox-pve-token
op://Kubernetes/Homepage/proxmox-fw-user
op://Kubernetes/Homepage/proxmox-fw-token
op://Kubernetes/Homepage/opnsense-username
op://Kubernetes/Homepage/opnsense-password
op://Kubernetes/Homepage/omv-user
op://Kubernetes/Homepage/omv-pass
op://Kubernetes/Homepage/glances-pass
op://Kubernetes/Homepage/adguard-user
op://Kubernetes/Homepage/adguard-pass
op://Kubernetes/Homepage/weather-key
op://Kubernetes/Homepage/grafana-user
op://Kubernetes/Homepage/grafana-pass
op://Kubernetes/Homepage/seerr-api-key
```

## Usage

```bash
# Sign in first
eval $(op signin)

# Verify access
op read "op://Kubernetes/Grafana/password" >/dev/null && echo "OK"

# Use in Helm
helm-homelab upgrade prometheus ... \
  --set grafana.adminPassword="$(op read 'op://Kubernetes/Grafana/password')"

# Use in script (see scripts/upgrade-prometheus.sh)
GRAFANA_PASSWORD=$(op read "op://Kubernetes/Grafana/password")
```

## iCloud SMTP Details

| Setting | Value |
|---------|-------|
| Server | smtp.mail.me.com |
| Port | 587 |
| Security | STARTTLS |
| Auth username | Must be @icloud.com (not custom domain) |
| From address | Can be custom domain (noreply@rommelporras.com) |

**Note:** Generate app-specific password at https://appleid.apple.com

## Alert Email Recipients

Critical alerts go to:
- critical@rommelporras.com
- r3mmel023@gmail.com
- rommelcporras@gmail.com

## Related

- [[Conventions]] - How to use 1Password CLI
- [[Monitoring]] - Alertmanager configuration
