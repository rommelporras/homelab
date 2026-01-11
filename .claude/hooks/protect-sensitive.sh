#!/bin/bash
# PreToolUse hook - Infrastructure security protection
# Blocks writes to sensitive files and dangerous operations

# Parse JSON input from stdin
INPUT=$(cat)

# Extract tool name, file_path, and command
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')
FILE_PATH=$(echo "$INPUT" | jq -r '.parameters.file_path // empty')
COMMAND=$(echo "$INPUT" | jq -r '.parameters.command // empty')

# =============================================================================
# FILE PROTECTION (Write/Edit operations)
# =============================================================================

if [[ "$TOOL" == "Write" || "$TOOL" == "Edit" ]]; then

  # --- Protected file patterns (Infrastructure) ---
  PROTECTED_PATTERNS=(
    ".env"
    ".env.local"
    "kubeconfig"
    ".kube/config"
    "admin.conf"
    "credentials"
    "secrets.yaml"
    "secrets.yml"
    "secret.yaml"
    "secret.yml"
    ".pem"
    ".key"
    ".crt"
    "id_rsa"
    "id_ed25519"
    "ssh_host"
    "etcd-snapshot"
    "encryption-config"
    "token"
    "password"
    "serviceAccountKey"
  )

  for pattern in "${PROTECTED_PATTERNS[@]}"; do
    if [[ "$FILE_PATH" == *"$pattern"* ]]; then
      echo "BLOCKED: Cannot modify sensitive file: $FILE_PATH"
      echo "   Pattern matched: '$pattern'"
      echo "   Security: Credentials and secrets must be modified manually"
      exit 1
    fi
  done

  # --- Warn on manifest changes with secrets ---
  if [[ "$FILE_PATH" == *".yaml"* ]] || [[ "$FILE_PATH" == *".yml"* ]]; then
    if grep -q "kind: Secret" "$FILE_PATH" 2>/dev/null; then
      echo "WARNING: Modifying file that may contain Kubernetes secrets"
      echo "   File: $FILE_PATH"
      echo "   Review carefully before committing"
    fi
  fi

fi

# =============================================================================
# COMMAND PROTECTION (Bash operations)
# =============================================================================

if [[ "$TOOL" == "Bash" && -n "$COMMAND" ]]; then

  # --- Destructive command patterns ---
  DANGEROUS_PATTERNS=(
    "rm -rf /"
    "rm -rf /*"
    "rm -rf ~"
    "> /dev/sd"
    "mkfs."
    ":(){:|:&};:"
    "dd if=/dev"
    "chmod -R 777"
  )

  for pattern in "${DANGEROUS_PATTERNS[@]}"; do
    if [[ "$COMMAND" == *"$pattern"* ]]; then
      echo "BLOCKED: Dangerous command detected"
      echo "   Command: $COMMAND"
      echo "   Pattern: '$pattern'"
      exit 1
    fi
  done

  # --- Git force push protection ---
  if [[ "$COMMAND" == *"git push"*"--force"* ]] || [[ "$COMMAND" == *"git push"*"-f"* ]]; then
    if [[ "$COMMAND" == *"main"* ]] || [[ "$COMMAND" == *"master"* ]]; then
      echo "BLOCKED: Force push to main/master is not allowed"
      echo "   Command: $COMMAND"
      echo "   Use regular push or create a PR"
      exit 1
    fi
  fi

  # --- Kubernetes destructive operations ---
  if [[ "$COMMAND" == *"kubectl delete"*"--all"* ]]; then
    if [[ "$COMMAND" == *"namespace"* ]] || [[ "$COMMAND" == *"-A"* ]]; then
      echo "BLOCKED: Deleting all resources across namespaces"
      echo "   Command: $COMMAND"
      echo "   This could destroy the entire cluster"
      exit 1
    fi
  fi

  # --- etcd operations warning ---
  if [[ "$COMMAND" == *"etcdctl"* ]]; then
    echo "WARNING: etcd operation detected"
    echo "   Command: $COMMAND"
    echo "   Be careful with etcd - it stores all cluster state"
  fi

  # --- kubeadm reset warning ---
  if [[ "$COMMAND" == *"kubeadm reset"* ]]; then
    echo "WARNING: kubeadm reset will destroy the cluster node"
    echo "   Command: $COMMAND"
    echo "   This cannot be undone. Proceeding..."
  fi

fi

# Allow operation
exit 0
