#!/bin/bash
# Apply ARR Stack API keys secret from 1Password
#
# Prerequisites:
#   - 1Password CLI (op) installed and signed in: eval $(op signin)
#   - kubectl-homelab configured
#   - 1Password item "ARR Stack" in "Kubernetes" vault with fields:
#     prowlarr-api-key, sonarr-api-key, radarr-api-key, bazarr-api-key, tdarr-api-key
#
# Usage: ./scripts/apply-arr-secrets.sh

set -euo pipefail

# Alias not available in scripts — use full command
KUBECTL="kubectl --kubeconfig ${HOME}/.kube/homelab.yaml"

echo "Reading API keys from 1Password..."
PROWLARR_KEY="$(op read 'op://Kubernetes/ARR Stack/prowlarr-api-key')"
SONARR_KEY="$(op read 'op://Kubernetes/ARR Stack/sonarr-api-key')"
RADARR_KEY="$(op read 'op://Kubernetes/ARR Stack/radarr-api-key')"
BAZARR_KEY="$(op read 'op://Kubernetes/ARR Stack/bazarr-api-key')"
TDARR_KEY="$(op read 'op://Kubernetes/ARR Stack/tdarr-api-key')"

echo "Applying arr-api-keys secret to arr-stack namespace..."
$KUBECTL apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: arr-api-keys
  namespace: arr-stack
  labels:
    app: arr
type: Opaque
stringData:
  PROWLARR_API_KEY: "${PROWLARR_KEY}"
  SONARR_API_KEY: "${SONARR_KEY}"
  RADARR_API_KEY: "${RADARR_KEY}"
  BAZARR_API_KEY: "${BAZARR_KEY}"
  TDARR_API_KEY: "${TDARR_KEY}"
EOF

echo "Done. Secret arr-api-keys applied."
