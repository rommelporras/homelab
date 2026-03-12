#!/usr/bin/env bash
# Configure Vault after initialization: KV v2, Kubernetes auth, policies, audit
#
# Prerequisites:
#   - vault CLI installed
#   - Port-forward running: kubectl --kubeconfig ~/.kube/homelab.yaml port-forward -n vault vault-0 8200:8200
#   - Vault initialized and unsealed
#   - ~/.vault-keys file with root token from vault operator init
#
# Usage: ./scripts/configure-vault.sh
#
# WARNING: Run in safe terminal only — reads root token from local file
set -euo pipefail

export VAULT_ADDR=http://localhost:8200

# Login with root token
vault login "$(grep 'Initial Root Token' ~/.vault-keys | awk '{print $NF}')"

echo "=== Enabling KV v2 ==="
vault secrets enable -path=secret kv-v2

echo "=== Enabling Kubernetes auth ==="
vault auth enable kubernetes
vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc.cluster.local"

echo "=== Creating ESO policy ==="
vault policy write eso-policy - <<'EOF'
path "secret/data/*" { capabilities = ["read"] }
path "secret/metadata/*" { capabilities = ["read", "list"] }
EOF

echo "=== Creating ESO role ==="
vault write auth/kubernetes/role/eso \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=eso-policy \
  ttl=24h

echo "=== Enabling audit (file → stdout) ==="
vault audit enable file file_path=stdout

echo "=== Creating snapshot policy ==="
vault policy write snapshot-policy - <<'EOF'
path "sys/storage/raft/snapshot" { capabilities = ["read"] }
EOF

vault write auth/kubernetes/role/vault-snapshot \
  bound_service_account_names=vault-snapshot \
  bound_service_account_namespaces=vault \
  policies=snapshot-policy \
  ttl=1h

echo ""
echo "=== Verification ==="
vault secrets list
vault auth list
vault policy list
vault audit list
echo ""
echo "Vault configuration complete. Next: run scripts/seed-vault-from-1password.sh"
