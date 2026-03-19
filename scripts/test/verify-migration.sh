#!/usr/bin/env bash
# Verifies ExternalSecret sync status and pod health across all namespaces
# Run after each migration wave to catch sync failures before proceeding
set -euo pipefail

KUBECONFIG=~/.kube/homelab.yaml
KUBECTL="kubectl --kubeconfig $KUBECONFIG"
FAILURES=0

echo "=== ExternalSecret Sync Status ==="
while IFS= read -r line; do
  ns=$(echo "$line" | awk '{print $1}')
  name=$(echo "$line" | awk '{print $2}')
  ready=$(echo "$line" | awk '{print $3}')
  status=$(echo "$line" | awk '{print $4}')

  if [[ "$ready" != "True" || "$status" != "SecretSynced" ]]; then
    echo "FAIL: $ns/$name — Ready=$ready Status=$status"
    FAILURES=$((FAILURES + 1))
  else
    echo "  OK: $ns/$name"
  fi
done <<< "$($KUBECTL get externalsecrets -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,READY:.status.conditions[0].status,STATUS:.status.conditions[0].reason' --no-headers 2>/dev/null)"

echo ""
echo "=== ClusterSecretStore Status ==="
$KUBECTL get clustersecretstores -o custom-columns='NAME:.metadata.name,READY:.status.conditions[0].status,MSG:.status.conditions[0].message'

echo ""
echo "=== Pod Health (non-Running pods) ==="
NOT_RUNNING=$($KUBECTL get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded --no-headers 2>/dev/null | grep -v Completed || true)
if [[ -n "$NOT_RUNNING" ]]; then
  echo "$NOT_RUNNING"
  FAILURES=$((FAILURES + $(echo "$NOT_RUNNING" | wc -l)))
else
  echo "  All pods Running or Completed"
fi

echo ""
echo "=== Vault Status ==="
$KUBECTL get pods -n vault -o wide
$KUBECTL exec -n vault vault-0 -- vault status -format=json 2>/dev/null | \
  jq '{sealed: .sealed, initialized: .initialized, version: .version}' || \
  echo "WARN: Could not query vault status (may need port-forward)"

echo ""
if [[ $FAILURES -gt 0 ]]; then
  echo "RESULT: $FAILURES failure(s) detected — investigate before proceeding"
  exit 1
else
  echo "RESULT: All checks passed"
fi
