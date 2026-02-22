#!/usr/bin/env bash
# PreToolUse hook — Kubernetes-specific security protection.
# Global hooks already cover: .env files, SSH keys, .pem, destructive commands,
# force push, and secret content scanning. This hook adds k8s-only patterns.
#
# Exit 2 = block the tool call.

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .parameters.file_path // empty')
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // .parameters.command // empty')

# =============================================================================
# FILE PROTECTION — k8s-specific sensitive files (Write/Edit)
# =============================================================================

if [[ "$TOOL" == "Write" || "$TOOL" == "Edit" ]] && [[ -n "$FILE_PATH" ]]; then

  K8S_PATTERNS=(
    "kubeconfig"
    ".kube/config"
    "admin.conf"
    "secrets.yaml"
    "secrets.yml"
    "secret.yaml"
    "secret.yml"
    ".key"
    ".crt"
    "ssh_host"
    "etcd-snapshot"
    "encryption-config"
    "serviceAccountKey"
  )

  for pattern in "${K8S_PATTERNS[@]}"; do
    if [[ "$FILE_PATH" == *"$pattern"* ]]; then
      echo "BLOCKED: Cannot modify k8s-sensitive file: $FILE_PATH" >&2
      echo "   Pattern matched: '$pattern'" >&2
      echo "   Edit this file manually in your terminal." >&2
      exit 2
    fi
  done

  # Warn on Secret manifest edits (non-blocking)
  if [[ "$FILE_PATH" == *".yaml"* || "$FILE_PATH" == *".yml"* ]]; then
    if grep -q "kind: Secret" "$FILE_PATH" 2>/dev/null; then
      echo "WARNING: Modifying file that may contain Kubernetes secrets: $FILE_PATH" >&2
    fi
  fi

fi

# =============================================================================
# COMMAND PROTECTION — k8s-specific dangerous operations (Bash)
# =============================================================================

if [[ "$TOOL" == "Bash" && -n "$COMMAND" ]]; then

  # Block mass-deletion across namespaces
  if [[ "$COMMAND" == *"kubectl delete"*"--all"* ]]; then
    if [[ "$COMMAND" == *"namespace"* || "$COMMAND" == *"-A"* ]]; then
      echo "BLOCKED: Deleting all resources across namespaces." >&2
      echo "   Command: $COMMAND" >&2
      exit 2
    fi
  fi

  # Warn on etcd operations (non-blocking)
  if [[ "$COMMAND" == *"etcdctl"* ]]; then
    echo "WARNING: etcd operation detected — stores all cluster state." >&2
  fi

  # Warn on kubeadm reset (non-blocking)
  if [[ "$COMMAND" == *"kubeadm reset"* ]]; then
    echo "WARNING: kubeadm reset will destroy this cluster node." >&2
  fi

fi

exit 0
