---
tags: [homelab, kubernetes, secrets, 1password, vault, external-secrets]
updated: 2026-03-12
---

# Secrets

All secrets originate in 1Password and are delivered to Kubernetes via **HashiCorp Vault + External Secrets Operator (ESO)**.

## Architecture

```
1Password (source of truth)
    ↓ manual seed (scripts/seed-vault-from-1password.sh)
Vault KV v2 (secret/*)
    ↓ Kubernetes auth (ESO ServiceAccount)
External Secrets Operator
    ↓ ExternalSecret CRDs (per namespace)
K8s Secrets (auto-created, 1h refresh)
```

**Components:**
| Component | Namespace | Purpose |
|-----------|-----------|---------|
| Vault (standalone, Raft on Longhorn) | vault | Centralized secret store |
| Vault Auto-Unsealer | vault | Polls every 30s, unseals with 3 Shamir keys |
| ESO Controller + Webhook | external-secrets | Reconciles ExternalSecret → K8s Secret |
| ClusterSecretStore `vault-backend` | cluster-wide | Connects ESO to Vault via K8s auth |

## Security Boundary

**1Password is never accessed by automation.** The seed script (`scripts/seed-vault-from-1password.sh`) is run manually from a trusted terminal. Vault then serves secrets to ESO via Kubernetes auth — no `op` commands in any automated process.

**Why:** The 1Password personal account (Family plan) has access to all vaults. Running `op` from automation risks exposing personal credentials.

**Workflow:**
1. Run `eval $(op signin)` in a trusted terminal
2. Run `scripts/seed-vault-from-1password.sh` to populate Vault KV paths
3. ESO syncs Vault → K8s Secrets automatically (1h refresh)
4. Pods reference K8s Secrets as before — no application changes needed

## Secret File Convention

All `manifests/**/externalsecret.yaml` files are **ExternalSecret CRDs** committed to git. They contain:
- Vault KV path references (e.g., `key: cert-manager/cloudflare-api-token`)
- Target K8s Secret name and key mappings
- No real credential values

These files are the declarative "recipe" — ESO creates the actual K8s Secrets.

## Vault Break-Glass

Unseal keys and root token are stored in 1Password item **"Vault Unseal Keys"** (Kubernetes vault).
Local backup: `~/.vault-keys` (chmod 600). Delete after confirming 1Password backup.

## Vault KV Paths → ExternalSecrets

| Vault KV Path | K8s Secret Name | Namespace | ExternalSecret File |
|---------------|----------------|-----------|---------------------|
| cert-manager/cloudflare-api-token | cloudflare-api-token | cert-manager | manifests/cert-manager/externalsecret.yaml |
| cloudflare/cloudflared-token | cloudflared-token | cloudflare | manifests/cloudflare/externalsecret.yaml |
| arr-stack/api-keys | arr-api-keys | arr-stack | manifests/arr-stack/externalsecret.yaml |
| arr-stack/qbittorrent | qbittorrent-exporter-secret | arr-stack | manifests/arr-stack/externalsecret.yaml |
| atuin/secrets | atuin-secrets | atuin | manifests/atuin/externalsecret.yaml |
| browser/firefox-auth | firefox-auth | browser | manifests/browser/externalsecret.yaml |
| ghost-dev/mysql | ghost-mysql | ghost-dev | manifests/ghost-dev/externalsecret.yaml |
| ghost-dev/mail | ghost-mail | ghost-dev | manifests/ghost-dev/externalsecret.yaml |
| ghost-prod/mysql | ghost-mysql | ghost-prod | manifests/ghost-prod/externalsecret.yaml |
| ghost-prod/mail | ghost-mail | ghost-prod | manifests/ghost-prod/externalsecret.yaml |
| ghost-prod/tinybird | ghost-tinybird | ghost-prod | manifests/ghost-prod/externalsecret.yaml |
| gitlab/root-password | gitlab-root-password | gitlab | manifests/gitlab/externalsecret.yaml |
| gitlab/postgresql-password | gitlab-postgresql-password | gitlab | manifests/gitlab/externalsecret.yaml |
| gitlab/smtp-password | gitlab-smtp-password | gitlab | manifests/gitlab/externalsecret.yaml |
| gitlab-runner/runner-token | gitlab-runner-token | gitlab-runner | manifests/gitlab-runner/externalsecret.yaml |
| homepage/secrets | homepage-secrets | home | manifests/home/homepage/externalsecret.yaml |
| invoicetron-dev/db | invoicetron-db | invoicetron-dev | manifests/invoicetron/externalsecret-dev.yaml |
| invoicetron-dev/app | invoicetron-app | invoicetron-dev | manifests/invoicetron/externalsecret-dev.yaml |
| invoicetron-prod/db | invoicetron-db | invoicetron-prod | manifests/invoicetron/externalsecret-prod.yaml |
| invoicetron-prod/app | invoicetron-app | invoicetron-prod | manifests/invoicetron/externalsecret-prod.yaml |
| karakeep/secrets | karakeep-secrets | karakeep | manifests/karakeep/externalsecret.yaml |
| kube-system/discord-janitor-webhook | discord-janitor-webhook | kube-system | manifests/kube-system/cluster-janitor/externalsecret.yaml |
| monitoring/discord-version-webhook | discord-version-webhook | monitoring | manifests/monitoring/externalsecret.yaml |
| monitoring/nut-credentials | nut-credentials | monitoring | manifests/monitoring/externalsecret.yaml |
| invoicetron/deploy-token | gitlab-registry | invoicetron-dev | manifests/invoicetron/externalsecret-dev.yaml |
| invoicetron/deploy-token | gitlab-registry | invoicetron-prod | manifests/invoicetron/externalsecret-prod.yaml |
| monitoring/grafana | monitoring-grafana-admin | monitoring | manifests/monitoring/externalsecret.yaml |
| monitoring/smtp | monitoring-smtp | monitoring | manifests/monitoring/externalsecret.yaml |
| monitoring/discord-webhooks | monitoring-discord-webhooks | monitoring | manifests/monitoring/externalsecret.yaml |
| monitoring/healthchecks | monitoring-healthchecks | monitoring | manifests/monitoring/externalsecret.yaml |

**Note:** Grafana uses `existingSecret` (fully declarative). Alertmanager SMTP/webhooks/healthchecks
are ESO-managed K8s Secrets read by `scripts/upgrade-prometheus.sh` at Helm upgrade time
(Alertmanager raw config format requires literal values — can't reference K8s secrets directly).

## 1Password Vault

**Vault:** `Kubernetes`

Do NOT modify items in the `Proxmox` vault (legacy infrastructure).

## Item Reference

| Item | Fields | Used By |
|------|--------|---------|
| Grafana | `password` | kube-prometheus-stack |
| Cloudflare DNS API Token | `credential` | cert-manager (Let's Encrypt) |
| Discord Webhooks | `incidents`, `apps`, `infra`, `versions`, `janitor`, `speedtest` | Alertmanager, Version Check CronJob, Cluster Janitor, MySpeed |
| iCloud SMTP | `username`, `password`, `server`, `port` | Alertmanager, GitLab |
| GitLab | `username`, `password`, `postgresql-password`, `postgresql-postgres-password`, `runner-token` | GitLab CE, GitLab Runner |
| Healthchecks Ping URL | `website` | Alertmanager Watchdog (dead man's switch) |
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
| Atuin | `db-username`, `db-password`, `db-database`, `db-uri`, `personal-email`, `personal-password`, `encryption-key`, `eam-email`, `eam-password` | Atuin server (PostgreSQL + account credentials) |
| Vault Unseal Keys | `unseal-key-1` thru `unseal-key-5`, `root-token` | Vault init break-glass (3 of 5 keys needed to unseal) |
| Cloudflare Tunnel | `token` | cloudflared Deployment (cloudflare namespace) |
| iCloud SMTP | (reused) | Ghost mail (ghost-dev, ghost-prod) |

## 1Password Paths

```bash
# Grafana
op://Kubernetes/Grafana/password

# Cloudflare (cert-manager)
op://Kubernetes/Cloudflare DNS API Token/credential

# Discord webhooks (single consolidated item, 6 fields)
op://Kubernetes/Discord Webhooks/incidents
op://Kubernetes/Discord Webhooks/apps
op://Kubernetes/Discord Webhooks/infra
op://Kubernetes/Discord Webhooks/versions
op://Kubernetes/Discord Webhooks/janitor
op://Kubernetes/Discord Webhooks/speedtest

# SMTP (Alertmanager, GitLab)
op://Kubernetes/iCloud SMTP/username
op://Kubernetes/iCloud SMTP/password

# GitLab
op://Kubernetes/GitLab/username
op://Kubernetes/GitLab/password
op://Kubernetes/GitLab/postgresql-password

# GitLab (runner-token is in the GitLab item, not a separate item)
op://Kubernetes/GitLab/runner-token
op://Kubernetes/GitLab/postgresql-postgres-password

# Healthchecks (dead man's switch)
op://Kubernetes/Healthchecks Ping URL/website

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

# Atuin (PostgreSQL + account credentials)
op://Kubernetes/Atuin/db-username
op://Kubernetes/Atuin/db-password
op://Kubernetes/Atuin/db-database
op://Kubernetes/Atuin/db-uri
op://Kubernetes/Atuin/personal-email
op://Kubernetes/Atuin/personal-password
op://Kubernetes/Atuin/encryption-key
op://Kubernetes/Atuin/eam-email
op://Kubernetes/Atuin/eam-password

# Homepage (widget credentials — 24 fields)
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
op://Kubernetes/Homepage/adguard-fw-user
op://Kubernetes/Homepage/adguard-fw-pass
op://Kubernetes/Homepage/weather-key
op://Kubernetes/Homepage/grafana-user
op://Kubernetes/Homepage/grafana-pass
op://Kubernetes/Homepage/seerr-api-key
op://Kubernetes/Homepage/immich-key
op://Kubernetes/Homepage/openwrt-user
op://Kubernetes/Homepage/openwrt-pass
op://Kubernetes/Homepage/tailscale-device
op://Kubernetes/Homepage/tailscale-key
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
