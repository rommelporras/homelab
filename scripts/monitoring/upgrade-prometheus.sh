#!/bin/bash
# =============================================================================
# Prometheus Stack Upgrade Script
# =============================================================================
# Upgrades kube-prometheus-stack with Alertmanager secrets injected from
# ESO-managed K8s Secrets (backed by Vault). No 1Password needed.
#
# Grafana admin password is fully declarative via existingSecret in Helm values.
# Only Alertmanager config requires runtime injection (raw config format
# doesn't support K8s secret references).
#
# Usage:
#   ./scripts/upgrade-prometheus.sh
#
# Prerequisites:
#   - ~/.kube/homelab.yaml kubeconfig exists
#   - ESO ExternalSecrets synced in monitoring namespace:
#     monitoring-smtp, monitoring-discord-webhooks, monitoring-healthchecks
#
# Secret Source: Vault → ESO → K8s Secrets → this script reads them
# =============================================================================

set -euo pipefail

# Use homelab kubeconfig (aliases aren't available in scripts)
export KUBECONFIG="$HOME/.kube/homelab.yaml"
KUBECTL="kubectl --kubeconfig $HOME/.kube/homelab.yaml"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
TEMP_SECRETS_FILE=$(mktemp)

# Cleanup on exit
cleanup() {
    rm -f "$TEMP_SECRETS_FILE"
}
trap cleanup EXIT

echo -e "${YELLOW}=== Prometheus Stack Upgrade ===${NC}"
echo ""

# Helper to read a key from a K8s secret
read_secret() {
    local ns="$1" name="$2" key="$3"
    $KUBECTL get secret -n "$ns" "$name" -o jsonpath="{.data.$key}" | base64 -d
}

# Verify ESO secrets exist
echo -e "${YELLOW}Checking ESO-managed secrets in monitoring namespace...${NC}"
for secret in monitoring-smtp monitoring-discord-webhooks monitoring-healthchecks; do
    if ! $KUBECTL get secret -n monitoring "$secret" &>/dev/null; then
        echo -e "${RED}Error: Secret '$secret' not found in monitoring namespace${NC}"
        echo "Ensure ExternalSecrets are synced: kubectl get externalsecrets -n monitoring"
        exit 1
    fi
done
echo -e "${GREEN}All required secrets found${NC}"

# Read secrets from ESO-managed K8s Secrets
echo -e "${YELLOW}Reading secrets from K8s (Vault-backed)...${NC}"

DISCORD_INCIDENTS_WEBHOOK=$(read_secret monitoring monitoring-discord-webhooks incidents)
DISCORD_APPS_WEBHOOK=$(read_secret monitoring monitoring-discord-webhooks apps)
DISCORD_INFRA_WEBHOOK=$(read_secret monitoring monitoring-discord-webhooks infra)
SMTP_USERNAME=$(read_secret monitoring monitoring-smtp username)
SMTP_PASSWORD=$(read_secret monitoring monitoring-smtp password)
HEALTHCHECKS_PING_URL=$(read_secret monitoring monitoring-healthchecks ping-url)

echo -e "${GREEN}Secrets loaded successfully${NC}"
echo "  - Discord incidents webhook: ****"
echo "  - Discord apps webhook: ****"
echo "  - Discord infra webhook: ****"
echo "  - SMTP username: ${SMTP_USERNAME}"
echo "  - SMTP password: ****"
echo "  - Healthchecks ping URL: ****"
echo "  - Grafana password: managed via existingSecret (no injection needed)"
echo ""

# Create temporary secrets values file
# Alertmanager raw config requires literal values — can't use K8s secret refs.
# Grafana uses existingSecret in values.yaml, so no injection needed here.
cat > "$TEMP_SECRETS_FILE" << EOF
alertmanager:
  config:
    global:
      smtp_auth_username: "${SMTP_USERNAME}"
      smtp_auth_password: "${SMTP_PASSWORD}"
    receivers:
      - name: 'discord-incidents-email'
        discord_configs:
          - webhook_url: "${DISCORD_INCIDENTS_WEBHOOK}"
            send_resolved: true
            title: '{{ if eq .Status "firing" }}🔴{{ else }}✅{{ end }} {{ .Status | toUpper }}: {{ .CommonLabels.alertname }}'
            message: |
              {{ range .Alerts }}
              **{{ .Labels.alertname }}** ({{ .Labels.severity }})
              {{ .Annotations.summary }}
              {{ if .Annotations.description }}{{ .Annotations.description }}{{ end }}
              {{ end }}
        email_configs:
          # Multiple recipients for critical alerts (redundancy)
          - to: 'critical@rommelporras.com, r3mmel023@gmail.com, rommelcporras@gmail.com'
            send_resolved: true
            headers:
              Subject: '[{{ .Status | toUpper }}] {{ .CommonLabels.alertname }}'
      - name: 'discord-infra'
        discord_configs:
          - webhook_url: "${DISCORD_INFRA_WEBHOOK}"
            send_resolved: true
            title: '{{ if eq .Status "firing" }}⚠️{{ else }}✅{{ end }} {{ .Status | toUpper }}: {{ .CommonLabels.alertname }}'
            message: |
              {{ range .Alerts }}
              **{{ .Labels.alertname }}** ({{ .Labels.severity }})
              {{ .Annotations.summary }}
              {{ if .Annotations.description }}{{ .Annotations.description }}{{ end }}
              {{ end }}
      - name: 'discord-apps'
        discord_configs:
          - webhook_url: "${DISCORD_APPS_WEBHOOK}"
            send_resolved: true
            title: '{{ if eq .Status "firing" }}⚠️{{ else }}✅{{ end }} {{ .Status | toUpper }}: {{ .CommonLabels.alertname }}'
            message: |
              {{ range .Alerts }}
              **{{ .Labels.alertname }}** ({{ .Labels.severity }})
              {{ .Annotations.summary }}
              {{ if .Annotations.description }}{{ .Annotations.description }}{{ end }}
              {{ end }}
      - name: 'null'
      - name: 'healthchecks-heartbeat'
        webhook_configs:
          - url: "${HEALTHCHECKS_PING_URL}"
            send_resolved: false
EOF

# Confirm upgrade
echo -e "${YELLOW}Ready to upgrade prometheus in monitoring namespace${NC}"
echo "Chart: oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack"
echo "Version: 81.0.0"
echo ""
read -p "Continue? (y/N) " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

# Run Helm upgrade
echo ""
echo -e "${YELLOW}Running Helm upgrade...${NC}"

helm upgrade prometheus oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack \
    --namespace monitoring \
    --version 81.0.0 \
    --values "$REPO_ROOT/helm/prometheus/values.yaml" \
    --values "$TEMP_SECRETS_FILE"

echo ""
echo -e "${GREEN}Helm upgrade complete!${NC}"

# Force Alertmanager restart to guarantee config reload
# Helm upgrade may not restart the pod if only the config Secret/ConfigMap changed
# (StatefulSet spec unchanged = no rollout). Without this, Alertmanager serves stale config.
echo ""
echo -e "${YELLOW}Restarting Alertmanager to pick up new config...${NC}"
$KUBECTL -n monitoring rollout restart statefulset/alertmanager-prometheus-kube-prometheus-alertmanager
$KUBECTL -n monitoring rollout status statefulset/alertmanager-prometheus-kube-prometheus-alertmanager --timeout=120s

# Verify config was loaded successfully
echo ""
echo -e "${YELLOW}Verifying Alertmanager config loaded...${NC}"
sleep 5
if $KUBECTL -n monitoring logs -l app.kubernetes.io/name=alertmanager --tail=5 2>/dev/null | grep -q "Completed loading of configuration file"; then
    echo -e "${GREEN}Alertmanager config loaded successfully${NC}"
else
    echo -e "${RED}WARNING: Could not confirm Alertmanager config load — check logs manually${NC}"
    echo "  kubectl -n monitoring logs -l app.kubernetes.io/name=alertmanager --tail=20"
fi

echo ""
echo -e "${GREEN}=== Upgrade Complete ===${NC}"
echo ""
echo "Verify configuration:"
echo "  kubectl -n monitoring logs -l app.kubernetes.io/name=alertmanager --tail=20"
echo ""
echo "Test alerts:"
echo "  kubectl apply -f manifests/monitoring/alerts/test-alert.yaml"
