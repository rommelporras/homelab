#!/usr/bin/env bash
# Create a Longhorn Snapshot custom resource for a given volume.
#
# Usage: create-snapshot.sh <volume-name>
#
# Why this script exists:
#   This operation applies a YAML manifest via heredoc piped into
#   `kubectl apply -f -`. Free-form heredoc kubectl invocations cannot be
#   safely allowlisted by regex in the agent config because the manifest
#   content is determined at runtime. This script is the controlled,
#   deterministic wrapper that agents are allowlisted to call by exact path.
#   It accepts only one strictly validated argument and constructs exactly
#   one Longhorn Snapshot CR — nothing else.
#
# What this does:
#   1. Validates the volume-name argument (alphanumeric, hyphens, underscores, dots only)
#   2. Generates a unique snapshot name: <volume-name>-<UTC-timestamp>
#   3. Applies a Longhorn Snapshot CR in the longhorn-system namespace
#   4. Prints the created Snapshot object name on success
#
# Requirements:
#   - Admin kubeconfig at ~/.kube/homelab.yaml (cluster-admin access required)
#   - kubectl in PATH

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
KUBECONFIG_PATH="${HOME}/.kube/homelab.yaml"
LONGHORN_NS="longhorn-system"

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
  echo "Usage: $(basename "${0}") <volume-name>"
  echo ""
  echo "  volume-name  Name of the Longhorn volume to snapshot."
  echo "               Allowed characters: alphanumeric, hyphens, underscores, dots."
  echo ""
  echo "Example:"
  echo "  $(basename "${0}") gitlab-data"
  exit 2
}

# ---------------------------------------------------------------------------
# Argument validation
# ---------------------------------------------------------------------------
if [[ $# -ne 1 ]]; then
  echo "Error: exactly one argument required." >&2
  echo "" >&2
  usage
fi

VOLUME_NAME="${1}"

# Safe pattern: alphanumeric, hyphens, underscores, dots — no shell metacharacters
if [[ ! "${VOLUME_NAME}" =~ ^[a-zA-Z0-9._-]+$ ]]; then
  echo "Error: invalid volume name '${VOLUME_NAME}'." >&2
  echo "       Allowed characters: alphanumeric, hyphens (-), underscores (_), dots (.)." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Generate snapshot name
# ---------------------------------------------------------------------------
TIMESTAMP="$(date -u +%Y%m%d-%H%M%S)"
SNAPSHOT_NAME="${VOLUME_NAME}-${TIMESTAMP}"

# ---------------------------------------------------------------------------
# Apply Snapshot CR
# ---------------------------------------------------------------------------
kubectl --kubeconfig "${KUBECONFIG_PATH}" apply -f - <<EOF
apiVersion: longhorn.io/v1beta2
kind: Snapshot
metadata:
  name: ${SNAPSHOT_NAME}
  namespace: ${LONGHORN_NS}
spec:
  volume: ${VOLUME_NAME}
EOF

echo "Snapshot created: ${SNAPSHOT_NAME}"
