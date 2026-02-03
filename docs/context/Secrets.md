---
tags: [homelab, kubernetes, secrets, 1password]
updated: 2026-02-03
---

# Secrets

All secrets are stored in 1Password. Never hardcode credentials.

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

# Ghost Mail (reuses iCloud SMTP - see above)

# Uptime Kuma
op://Kubernetes/Uptime Kuma/username
op://Kubernetes/Uptime Kuma/password

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
