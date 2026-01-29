#!/bin/bash
# =============================================================================
# Prometheus Stack Upgrade Script
# =============================================================================
# Upgrades kube-prometheus-stack with secrets injected from 1Password
#
# Usage:
#   ./scripts/upgrade-prometheus.sh
#
# Prerequisites:
#   - 1Password CLI (op) installed and signed in
#   - ~/.kube/homelab.yaml kubeconfig exists
#
# 1Password Items Required:
#   - op://Kubernetes/Grafana/password
#   - op://Kubernetes/Discord Webhook Incidents/credential
#   - op://Kubernetes/Discord Webhook Status/credential
#   - op://Kubernetes/iCloud SMTP/username
#   - op://Kubernetes/iCloud SMTP/password
#   - op://Kubernetes/Healthchecks Ping URL/password
# =============================================================================

set -euo pipefail

# Use homelab kubeconfig (aliases aren't available in scripts)
export KUBECONFIG="$HOME/.kube/homelab.yaml"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
TEMP_SECRETS_FILE=$(mktemp)

# Cleanup on exit
cleanup() {
    rm -f "$TEMP_SECRETS_FILE"
}
trap cleanup EXIT

echo -e "${YELLOW}=== Prometheus Stack Upgrade ===${NC}"
echo ""

# Check 1Password session
echo -e "${YELLOW}Checking 1Password session...${NC}"
if ! op account get &>/dev/null; then
    echo -e "${RED}Error: Not signed in to 1Password${NC}"
    echo "Run: eval \$(op signin)"
    exit 1
fi
echo -e "${GREEN}1Password session active${NC}"

# Read secrets from 1Password
echo -e "${YELLOW}Reading secrets from 1Password...${NC}"

GRAFANA_PASSWORD=$(op read "op://Kubernetes/Grafana/password")
DISCORD_INCIDENTS_WEBHOOK=$(op read "op://Kubernetes/Discord Webhook Incidents/credential")
DISCORD_STATUS_WEBHOOK=$(op read "op://Kubernetes/Discord Webhook Status/credential")
SMTP_USERNAME=$(op read "op://Kubernetes/iCloud SMTP/username")
SMTP_PASSWORD=$(op read "op://Kubernetes/iCloud SMTP/password")
HEALTHCHECKS_PING_URL=$(op read "op://Kubernetes/Healthchecks Ping URL/password")

echo -e "${GREEN}Secrets loaded successfully${NC}"
echo "  - Grafana password: ****"
echo "  - Discord incidents webhook: ****"
echo "  - Discord status webhook: ****"
echo "  - SMTP username: ${SMTP_USERNAME}"
echo "  - SMTP password: ****"
echo "  - Healthchecks ping URL: ****"
echo ""

# Create temporary secrets values file
# This approach merges with values.yaml properly (--set can break array structures)
cat > "$TEMP_SECRETS_FILE" << EOF
grafana:
  adminPassword: "${GRAFANA_PASSWORD}"

alertmanager:
  config:
    global:
      smtp_auth_username: "${SMTP_USERNAME}"
      smtp_auth_password: "${SMTP_PASSWORD}"
    receivers:
      - name: 'discord-incidents-email'
        discord_configs:
          - webhook_url: "${DISCORD_INCIDENTS_WEBHOOK}"
            title: '🔴 {{ .Status | toUpper }}: {{ .CommonLabels.alertname }}'
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
      - name: 'discord-status'
        discord_configs:
          - webhook_url: "${DISCORD_STATUS_WEBHOOK}"
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

# Wait for rollout
echo ""
echo -e "${YELLOW}Waiting for Alertmanager rollout...${NC}"
kubectl -n monitoring rollout status statefulset/alertmanager-prometheus-kube-prometheus-alertmanager --timeout=120s

echo ""
echo -e "${GREEN}=== Upgrade Complete ===${NC}"
echo ""
echo "Verify configuration:"
echo "  kubectl -n monitoring logs -l app.kubernetes.io/name=alertmanager --tail=20"
echo ""
echo "Test alerts:"
echo "  kubectl apply -f manifests/monitoring/test-alert.yaml"
