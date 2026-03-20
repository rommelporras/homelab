#!/usr/bin/env bash
# Seed ALL Vault KV paths from 1Password source of truth
#
# Prerequisites:
#   - 1Password CLI (op) installed and signed in: eval $(op signin)
#   - vault CLI installed
#   - VAULT_ADDR set (via .zshrc or export) or port-forward running on localhost:8200
#   - Vault initialized, unsealed, and configured (scripts/configure-vault.sh)
#   - Logged into vault: vault login <root-token>
#
# Usage: ./scripts/seed-vault-from-1password.sh
#
# WARNING: Run in safe terminal only — reads secrets from 1Password
set -euo pipefail

export VAULT_ADDR="${VAULT_ADDR:-http://localhost:8200}"

echo "=== Seeding Vault from 1Password ==="
echo "Ensure you have: eval \$(op signin) && vault login"

# cert-manager
echo "  cert-manager/cloudflare-api-token"
vault kv put secret/cert-manager/cloudflare-api-token \
  api-token="$(op read 'op://Kubernetes/Cloudflare DNS API Token/credential')"

# cloudflare
echo "  cloudflare/cloudflared-token"
vault kv put secret/cloudflare/cloudflared-token \
  token="$(op read 'op://Kubernetes/Cloudflare Tunnel/token')"

# arr-stack
echo "  arr-stack/api-keys"
vault kv put secret/arr-stack/api-keys \
  PROWLARR_API_KEY="$(op read 'op://Kubernetes/ARR Stack/prowlarr-api-key')" \
  SONARR_API_KEY="$(op read 'op://Kubernetes/ARR Stack/sonarr-api-key')" \
  RADARR_API_KEY="$(op read 'op://Kubernetes/ARR Stack/radarr-api-key')" \
  BAZARR_API_KEY="$(op read 'op://Kubernetes/ARR Stack/bazarr-api-key')" \
  TDARR_API_KEY="$(op read 'op://Kubernetes/ARR Stack/tdarr-api-key')"

echo "  arr-stack/qbittorrent"
vault kv put secret/arr-stack/qbittorrent \
  QBITTORRENT_PASS="$(op read 'op://Kubernetes/ARR Stack/password')"

# atuin
echo "  atuin/secrets"
vault kv put secret/atuin/secrets \
  POSTGRES_USER="$(op read 'op://Kubernetes/Atuin/db-username')" \
  POSTGRES_PASSWORD="$(op read 'op://Kubernetes/Atuin/db-password')" \
  POSTGRES_DB="$(op read 'op://Kubernetes/Atuin/db-database')" \
  ATUIN_DB_URI="$(op read 'op://Kubernetes/Atuin/db-uri')"

# browser
echo "  browser/firefox-auth"
vault kv put secret/browser/firefox-auth \
  username="$(op read 'op://Kubernetes/Firefox Browser/username')" \
  password="$(op read 'op://Kubernetes/Firefox Browser/password')"

# ghost-dev
echo "  ghost-dev/mysql"
vault kv put secret/ghost-dev/mysql \
  root-password="$(op read 'op://Kubernetes/Ghost Dev MySQL/root-password')" \
  user-password="$(op read 'op://Kubernetes/Ghost Dev MySQL/user-password')"

echo "  ghost-dev/mail"
vault kv put secret/ghost-dev/mail \
  smtp-host="smtp.mail.me.com" \
  smtp-user="$(op read 'op://Kubernetes/iCloud SMTP/username')" \
  smtp-password="$(op read 'op://Kubernetes/iCloud SMTP/password')" \
  from-address="noreply@rommelporras.com"

# ghost-prod
echo "  ghost-prod/mysql"
vault kv put secret/ghost-prod/mysql \
  root-password="$(op read 'op://Kubernetes/Ghost Prod MySQL/root-password')" \
  user-password="$(op read 'op://Kubernetes/Ghost Prod MySQL/user-password')"

echo "  ghost-prod/mail"
vault kv put secret/ghost-prod/mail \
  smtp-host="smtp.mail.me.com" \
  smtp-user="$(op read 'op://Kubernetes/iCloud SMTP/username')" \
  smtp-password="$(op read 'op://Kubernetes/iCloud SMTP/password')" \
  from-address="noreply@rommelporras.com"

echo "  ghost-prod/tinybird"
vault kv put secret/ghost-prod/tinybird \
  api-url="$(op read 'op://Kubernetes/Ghost Tinybird/api-url')" \
  admin-token="$(op read 'op://Kubernetes/Ghost Tinybird/admin-token')" \
  workspace-id="$(op read 'op://Kubernetes/Ghost Tinybird/workspace-id')" \
  tracker-token="$(op read 'op://Kubernetes/Ghost Tinybird/tracker-token')"

# gitlab
echo "  gitlab/root-password"
vault kv put secret/gitlab/root-password \
  password="$(op read 'op://Kubernetes/GitLab/password')"

echo "  gitlab/postgresql-password"
vault kv put secret/gitlab/postgresql-password \
  postgresql-password="$(op read 'op://Kubernetes/GitLab/postgresql-password')" \
  postgresql-postgres-password="$(op read 'op://Kubernetes/GitLab/postgresql-postgres-password')"

echo "  gitlab/smtp-password"
vault kv put secret/gitlab/smtp-password \
  password="$(op read 'op://Kubernetes/iCloud SMTP/password')"

# gitlab-runner (runner-token is in the "GitLab" 1P item, not a separate item)
echo "  gitlab-runner/runner-token"
vault kv put secret/gitlab-runner/runner-token \
  runner-token="$(op read 'op://Kubernetes/GitLab/runner-token')"

# homepage (31 fields — widget credentials from Homepage + ARR Stack + Karakeep 1P items)
echo "  homepage/secrets (31 fields)"
vault kv put secret/homepage/secrets \
  HOMEPAGE_VAR_ADGUARD_FW_PASS="$(op read 'op://Kubernetes/Homepage/adguard-fw-pass')" \
  HOMEPAGE_VAR_ADGUARD_FW_USER="$(op read 'op://Kubernetes/Homepage/adguard-fw-user')" \
  HOMEPAGE_VAR_ADGUARD_PASS="$(op read 'op://Kubernetes/Homepage/adguard-pass')" \
  HOMEPAGE_VAR_ADGUARD_USER="$(op read 'op://Kubernetes/Homepage/adguard-user')" \
  HOMEPAGE_VAR_BAZARR_API_KEY="$(op read 'op://Kubernetes/ARR Stack/bazarr-api-key')" \
  HOMEPAGE_VAR_GLANCES_PASS="$(op read 'op://Kubernetes/Homepage/glances-pass')" \
  HOMEPAGE_VAR_GLANCES_USER="glances" \
  HOMEPAGE_VAR_GRAFANA_PASS="$(op read 'op://Kubernetes/Homepage/grafana-pass')" \
  HOMEPAGE_VAR_GRAFANA_USER="$(op read 'op://Kubernetes/Homepage/grafana-user')" \
  HOMEPAGE_VAR_IMMICH_KEY="$(op read 'op://Kubernetes/Homepage/immich-key')" \
  HOMEPAGE_VAR_JELLYFIN_KEY="$(op read 'op://Kubernetes/ARR Stack/jellyfin-api-key')" \
  HOMEPAGE_VAR_KARAKEEP_KEY="$(op read 'op://Kubernetes/Karakeep/api-key')" \
  HOMEPAGE_VAR_OMV_PASS="$(op read 'op://Kubernetes/Homepage/omv-pass')" \
  HOMEPAGE_VAR_OMV_USER="$(op read 'op://Kubernetes/Homepage/omv-user')" \
  HOMEPAGE_VAR_OPENWRT_PASS="$(op read 'op://Kubernetes/Homepage/openwrt-pass')" \
  HOMEPAGE_VAR_OPENWRT_USER="$(op read 'op://Kubernetes/Homepage/openwrt-user')" \
  HOMEPAGE_VAR_OPNSENSE_KEY="$(op read 'op://Kubernetes/Homepage/opnsense-username')" \
  HOMEPAGE_VAR_OPNSENSE_SECRET="$(op read 'op://Kubernetes/Homepage/opnsense-password')" \
  HOMEPAGE_VAR_PROWLARR_API_KEY="$(op read 'op://Kubernetes/ARR Stack/prowlarr-api-key')" \
  HOMEPAGE_VAR_PROXMOX_FW_TOKEN="$(op read 'op://Kubernetes/Homepage/proxmox-fw-token')" \
  HOMEPAGE_VAR_PROXMOX_FW_USER="$(op read 'op://Kubernetes/Homepage/proxmox-fw-user')" \
  HOMEPAGE_VAR_PROXMOX_PVE_TOKEN="$(op read 'op://Kubernetes/Homepage/proxmox-pve-token')" \
  HOMEPAGE_VAR_PROXMOX_PVE_USER="$(op read 'op://Kubernetes/Homepage/proxmox-pve-user')" \
  HOMEPAGE_VAR_QBIT_PASS="$(op read 'op://Kubernetes/ARR Stack/password')" \
  HOMEPAGE_VAR_QBIT_USER="$(op read 'op://Kubernetes/ARR Stack/username')" \
  HOMEPAGE_VAR_RADARR_API_KEY="$(op read 'op://Kubernetes/ARR Stack/radarr-api-key')" \
  HOMEPAGE_VAR_SEERR_API_KEY="$(op read 'op://Kubernetes/Homepage/seerr-api-key')" \
  HOMEPAGE_VAR_SONARR_API_KEY="$(op read 'op://Kubernetes/ARR Stack/sonarr-api-key')" \
  HOMEPAGE_VAR_TAILSCALE_DEVICE="$(op read 'op://Kubernetes/Homepage/tailscale-device')" \
  HOMEPAGE_VAR_TAILSCALE_KEY="$(op read 'op://Kubernetes/Homepage/tailscale-key')" \
  HOMEPAGE_VAR_WEATHER_KEY="$(op read 'op://Kubernetes/Homepage/weather-key')"

# invoicetron-dev
echo "  invoicetron-dev/db"
vault kv put secret/invoicetron-dev/db \
  postgres-password="$(op read 'op://Kubernetes/Invoicetron Dev/postgres-password')"

echo "  invoicetron-dev/app"
vault kv put secret/invoicetron-dev/app \
  database-url="$(op read 'op://Kubernetes/Invoicetron Dev/database-url')" \
  better-auth-secret="$(op read 'op://Kubernetes/Invoicetron Dev/better-auth-secret')"

# invoicetron-prod
echo "  invoicetron-prod/db"
vault kv put secret/invoicetron-prod/db \
  postgres-password="$(op read 'op://Kubernetes/Invoicetron Prod/postgres-password')"

echo "  invoicetron-prod/app"
vault kv put secret/invoicetron-prod/app \
  database-url="$(op read 'op://Kubernetes/Invoicetron Prod/database-url')" \
  better-auth-secret="$(op read 'op://Kubernetes/Invoicetron Prod/better-auth-secret')"

# karakeep
echo "  karakeep/secrets"
vault kv put secret/karakeep/secrets \
  nextauth-secret="$(op read 'op://Kubernetes/Karakeep/nextauth-secret')" \
  meili-master-key="$(op read 'op://Kubernetes/Karakeep/meili-master-key')"

# kube-system (cluster janitor)
echo "  kube-system/discord-janitor-webhook"
vault kv put secret/kube-system/discord-janitor-webhook \
  webhook-url="$(op read 'op://Kubernetes/Discord Webhooks/janitor')"

# monitoring
echo "  monitoring/discord-version-webhook"
vault kv put secret/monitoring/discord-version-webhook \
  webhook-url="$(op read 'op://Kubernetes/Discord Webhooks/versions')"

echo "  monitoring/nut-credentials"
vault kv put secret/monitoring/nut-credentials \
  username="upsmon" \
  password="$(op read 'op://Kubernetes/NUT Monitor/password')"

echo "  monitoring/grafana"
vault kv put secret/monitoring/grafana \
  password="$(op read 'op://Kubernetes/Grafana/password')"

echo "  monitoring/healthchecks"
vault kv put secret/monitoring/healthchecks \
  ping-url="$(op read 'op://Kubernetes/Healthchecks Ping URL/website')"

echo "  monitoring/smtp"
vault kv put secret/monitoring/smtp \
  username="$(op read 'op://Kubernetes/iCloud SMTP/username')" \
  password="$(op read 'op://Kubernetes/iCloud SMTP/password')"

# monitoring/discord-webhooks (Alertmanager channels — seeded now, ExternalSecret migration in Phase 5)
echo "  monitoring/discord-webhooks (5 channels)"
vault kv put secret/monitoring/discord-webhooks \
  incidents="$(op read 'op://Kubernetes/Discord Webhooks/incidents')" \
  apps="$(op read 'op://Kubernetes/Discord Webhooks/apps')" \
  infra="$(op read 'op://Kubernetes/Discord Webhooks/infra')" \
  versions="$(op read 'op://Kubernetes/Discord Webhooks/versions')" \
  speedtest="$(op read 'op://Kubernetes/Discord Webhooks/speedtest')"

# invoicetron deploy token (gitlab-registry imagePullSecret — shared by both namespaces)
echo "  invoicetron/deploy-token"
vault kv put secret/invoicetron/deploy-token \
  username="$(op read 'op://Kubernetes/Invoicetron Deploy Token/username')" \
  password="$(op read 'op://Kubernetes/Invoicetron Deploy Token/password')"

# velero (Garage S3 object store for Velero backups)
echo "  velero/garage"
vault kv put secret/velero/garage \
  rpc-secret="$(op read 'op://Kubernetes/Garage S3/rpc-secret')" \
  admin-token="$(op read 'op://Kubernetes/Garage S3/admin-token')" \
  metrics-token="$(op read 'op://Kubernetes/Garage S3/metrics-token')"

echo "  velero/s3-credentials"
vault kv put secret/velero/s3-credentials \
  aws_access_key_id="$(op read 'op://Kubernetes/Garage S3/s3-access-key-id')" \
  aws_secret_access_key="$(op read 'op://Kubernetes/Garage S3/s3-secret-access-key')"

# backups (restic off-site encryption)
echo "  backups/restic-k8s-configs"
vault kv put secret/backups/restic-k8s-configs \
  password="$(op read 'op://Kubernetes/Restic Backup Keys/k8s-configs-password')"

echo ""
echo "=== Verification ==="
vault kv list secret/
echo ""
echo "Seed complete. Verify paths above match expected structure."
