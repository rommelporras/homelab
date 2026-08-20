#!/usr/bin/env bash
# Add a Longhorn Replica CR pinned to a specific cluster node via hardNodeAffinity.
#
# Usage: add-pinned-replica.sh <volume-name> <node-name>
#
# Why this script exists:
#   This operation applies a YAML manifest via heredoc piped into
#   `kubectl apply -f -`. Free-form heredoc kubectl invocations cannot be
#   safely allowlisted by regex in the agent config because the manifest
#   content is determined at runtime. This script is the controlled,
#   deterministic wrapper that agents are allowlisted to call by exact path.
#   It accepts only two strictly validated arguments and constructs exactly
#   one Longhorn Replica CR — nothing else.
#
# What this does:
#   1. Validates volume-name (alphanumeric, hyphens, underscores, dots only)
#   2. Validates node-name against the known cluster node allowlist (k8s-cp1/cp2/cp3)
#   3. Generates a unique replica name: <volume-name>-r-<node-short>-<UTC-timestamp>
#   4. Applies a Longhorn Replica CR in the longhorn-system namespace with
#      hardNodeAffinity set to the given node
#   5. Prints the created Replica object name on success
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

# Closed allowlist — only known homelab control-plane nodes accepted
ALLOWED_NODES=("k8s-cp1" "k8s-cp2" "k8s-cp3")

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
  echo "Usage: $(basename "${0}") <volume-name> <node-name>"
  echo ""
  echo "  volume-name  Name of the Longhorn volume to add a replica for."
  echo "               Allowed characters: alphanumeric, hyphens, underscores, dots."
  echo ""
  echo "  node-name    Cluster node to pin the replica to."
  echo "               Allowed values: k8s-cp1, k8s-cp2, k8s-cp3"
  echo ""
  echo "Example:"
  echo "  $(basename "${0}") gitlab-data k8s-cp2"
  exit 2
}

# ---------------------------------------------------------------------------
# Argument validation
# ---------------------------------------------------------------------------
if [[ $# -ne 2 ]]; then
  echo "Error: exactly two arguments required." >&2
  echo "" >&2
  usage
fi

VOLUME_NAME="${1}"
NODE_NAME="${2}"

# Validate volume name — safe pattern only
if [[ ! "${VOLUME_NAME}" =~ ^[a-zA-Z0-9._-]+$ ]]; then
  echo "Error: invalid volume name '${VOLUME_NAME}'." >&2
  echo "       Allowed characters: alphanumeric, hyphens (-), underscores (_), dots (.)." >&2
  exit 1
fi

# Validate node name against closed allowlist
node_valid=false
for allowed in "${ALLOWED_NODES[@]}"; do
  if [[ "${NODE_NAME}" == "${allowed}" ]]; then
    node_valid=true
    break
  fi
done

if [[ "${node_valid}" != "true" ]]; then
  echo "Error: invalid node name '${NODE_NAME}'." >&2
  echo "       Allowed values: k8s-cp1, k8s-cp2, k8s-cp3" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Generate replica name
# ---------------------------------------------------------------------------
TIMESTAMP="$(date -u +%Y%m%d-%H%M%S)"
# Use last segment of node name (cp1/cp2/cp3) for a shorter but readable name
NODE_SHORT="${NODE_NAME##*-}"
REPLICA_NAME="${VOLUME_NAME}-r-${NODE_SHORT}-${TIMESTAMP}"

# ---------------------------------------------------------------------------
# Apply Replica CR
# ---------------------------------------------------------------------------
kubectl --kubeconfig "${KUBECONFIG_PATH}" apply -f - <<EOF
apiVersion: longhorn.io/v1beta2
kind: Replica
metadata:
  name: ${REPLICA_NAME}
  namespace: ${LONGHORN_NS}
spec:
  volumeName: ${VOLUME_NAME}
  hardNodeAffinity: ${NODE_NAME}
EOF

echo "Replica created: ${REPLICA_NAME}"
