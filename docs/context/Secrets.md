---
tags: [homelab, kubernetes, secrets, 1password]
updated: 2026-01-22
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
| iCloud SMTP Alertmanager | `username`, `password`, `server`, `port` | Alertmanager email |
| NUT Admin | `username`, `password` | NUT server |
| NUT Monitor | `username`, `password` | NUT clients, nut-exporter |
| Homepage | Multiple (see below) | Homepage dashboard widgets |

## 1Password Paths

```bash
# Grafana
op://Kubernetes/Grafana/password

# Cloudflare (cert-manager)
op://Kubernetes/Cloudflare DNS API Token/credential

# Discord webhooks
op://Kubernetes/Discord Webhook Incidents/credential
op://Kubernetes/Discord Webhook Status/credential

# SMTP (Alertmanager email)
op://Kubernetes/iCloud SMTP Alertmanager/username
op://Kubernetes/iCloud SMTP Alertmanager/password

# NUT
op://Kubernetes/NUT Admin/username
op://Kubernetes/NUT Admin/password
op://Kubernetes/NUT Monitor/username
op://Kubernetes/NUT Monitor/password

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
