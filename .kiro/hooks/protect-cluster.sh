#!/usr/bin/env bash
# PreToolUse hook -- blocks dangerous cluster and filesystem operations.
# Enforces homelab access rules: always use --kubeconfig/KUBECONFIG=, never
# expose secret values, no destructive deletes, no recursive rm.
#
# BACKSTOP NOTICE: This hook is a last-resort backstop. The primary enforcement
# gate is each agent's execute_bash allow/deny config (shell tool settings).
# This hook is invoked via a workspace-relative path and assumes CWD is the
# workspace root. If the hook file is not found at that path, the call fails
# open (the tool use proceeds). This is why config-level enforcement is
# authoritative and this hook is defense-in-depth only.
#
# Exit 2 = block the tool call (message to LLM via stderr).
# Exit 0 = allow.

set -euo pipefail

INPUT=$(cat)
COMMAND=$(echo "${INPUT}" | jq -r '.tool_input.command // .parameters.command // ""')

# Nothing to check for non-shell tool calls.
if [[ -z "${COMMAND}" ]]; then
  exit 0
fi

# =============================================================================
# HELPER: extract the leading command token, skipping VAR=val assignments.
# =============================================================================
FIRST_CMD=$(echo "${COMMAND}" | awk '{for(i=1;i<=NF;i++) if ($i !~ /=/) {print $i; exit}}')

# =============================================================================
# BARE KUBECTL / HELM -- must always include --kubeconfig or KUBECONFIG=
# Bare commands connect to the work AWS EKS cluster, not the homelab.
# =============================================================================

if [[ "${FIRST_CMD}" == "kubectl" || "${FIRST_CMD}" == "helm" ]]; then
  if ! echo "${COMMAND}" | grep -qE '(--kubeconfig|KUBECONFIG=)'; then
    echo "BLOCKED: Bare '${FIRST_CMD}' without --kubeconfig or KUBECONFIG= would hit the work AWS EKS cluster." >&2
    echo "   Use: kubectl --kubeconfig ~/.kube/homelab-claude.yaml ..." >&2
    echo "   Or:  KUBECONFIG=~/.kube/homelab.yaml helm ..." >&2
    exit 2
  fi
fi

# KUBECONFIG= prefix followed by kubectl/helm also counts. Check those too.
# e.g. "KUBECONFIG=... kubectl ..." -- FIRST_CMD would be KUBECONFIG=... not kubectl
# so we need an additional check when kubectl/helm appears anywhere without the qualifier.
if echo "${COMMAND}" | grep -qE '\bkubectl\b' && ! echo "${COMMAND}" | grep -qE '(--kubeconfig|KUBECONFIG=)'; then
  echo "BLOCKED: kubectl used without --kubeconfig or KUBECONFIG= qualifier." >&2
  echo "   Always use: kubectl --kubeconfig ~/.kube/homelab-claude.yaml ..." >&2
  exit 2
fi

if echo "${COMMAND}" | grep -qE '\bhelm\b' && ! echo "${COMMAND}" | grep -qE '(--kubeconfig|KUBECONFIG=)'; then
  echo "BLOCKED: helm used without --kubeconfig or KUBECONFIG= qualifier." >&2
  echo "   Always use: KUBECONFIG=~/.kube/homelab.yaml helm ..." >&2
  exit 2
fi

# =============================================================================
# SECRET EXPOSURE -- kubectl get/describe secret[s] with value-revealing flags
# =============================================================================

# kubectl ... get secret[s] ... -o json|yaml|jsonpath (exposes base64-encoded values)
if echo "${COMMAND}" | grep -qE '\bkubectl\b.*\bget\b.*\bsecrets?\b' && \
   echo "${COMMAND}" | grep -qE '\-o[= ]*(json|yaml|jsonpath)'; then
  echo "BLOCKED: 'kubectl get secret -o json/yaml/jsonpath' exposes secret values." >&2
  echo "   Use 'kubectl get secret <name>' (no -o flag) for existence checks only." >&2
  exit 2
fi

# kubectl ... describe secret[s] (shows base64-decoded values in Data section)
if echo "${COMMAND}" | grep -qE '\bkubectl\b.*\bdescribe\b.*\bsecrets?\b'; then
  echo "BLOCKED: 'kubectl describe secret' exposes decoded secret values." >&2
  echo "   Use 'kubectl get secret <name>' (no -o flag) for existence checks only." >&2
  exit 2
fi

# =============================================================================
# DESTRUCTIVE KUBECTL DELETES
# =============================================================================

# delete pvc / persistentvolumeclaim / statefulset (data-destroying resources)
if echo "${COMMAND}" | grep -qE '\bkubectl\b.*\bdelete\b.*\b(pvc|persistentvolumeclaim|statefulset)\b'; then
  echo "BLOCKED: Deleting PVCs, PersistentVolumeClaims, or StatefulSets is not allowed." >&2
  echo "   These are data-destroying operations. Perform manually after explicit confirmation." >&2
  exit 2
fi

# kubectl delete --all (any scope -- single namespace or cluster-wide is too risky)
# Note: \b does not match before '--' since '-' is not a word character; use \s instead.
if echo "${COMMAND}" | grep -qE '\bkubectl\b.*\bdelete\b.*\s--all(\s|$)'; then
  echo "BLOCKED: 'kubectl delete --all' mass-deletes resources and is not allowed." >&2
  echo "   Scope the delete to a specific named resource in a specific namespace." >&2
  exit 2
fi

# =============================================================================
# KUBECTL EXEC / CP / PORT-FORWARD -- interactive/file-access operations
# =============================================================================

# ArgoCD manual-sync via the controller pod is a documented CONFIRM-tier GitOps op (gitops.md).
# Allow ONLY: argocd app sync|get|list ... --core into argocd-application-controller. Nothing else.
if echo "${COMMAND}" | grep -qE 'kubectl.*--kubeconfig.*homelab\.yaml.*exec -n argocd statefulset/argocd-application-controller -- argocd app (sync|get|list)( [^ ]+)? --core'; then
  exit 0
fi

if echo "${COMMAND}" | grep -qE '\bkubectl\b.*\b(exec|cp|port-forward)\b'; then
  echo "BLOCKED: 'kubectl exec/cp/port-forward' is not allowed." >&2
  echo "   These operations allow arbitrary command execution or file access on cluster pods." >&2
  exit 2
fi

# =============================================================================
# DESTRUCTIVE HELM OPERATIONS
# =============================================================================

if echo "${COMMAND}" | grep -qE '\bhelm\b.*(uninstall|delete)\b'; then
  echo "BLOCKED: 'helm uninstall/delete' deletes live resources and causes outages." >&2
  echo "   For Helm-to-ArgoCD handover, delete the Helm release secret only:" >&2
  echo "   kubectl ... delete secrets -n <ns> -l name=<release>,owner=helm" >&2
  exit 2
fi

# =============================================================================
# KUBEADM RESET
# =============================================================================

if echo "${COMMAND}" | grep -qE '\bkubeadm\b.*\breset\b'; then
  echo "BLOCKED: 'kubeadm reset' destroys the cluster node and is never allowed." >&2
  exit 2
fi

# =============================================================================
# GIT WRITE OPERATIONS -- enforcement moved to agent config level.
# homelab-sre and homelab-deploy deny git write commands via their
# deniedCommands lists. homelab-orchestrator is permitted to commit/push
# and requires user approval before doing so. Hook-level blocking here
# would prevent the orchestrator from fulfilling its git-owner role.
# =============================================================================

# =============================================================================
# RECURSIVE RM
# =============================================================================

if echo "${COMMAND}" | grep -qE '\brm\s+(-[a-zA-Z]*r[a-zA-Z]*|-[a-zA-Z]*R[a-zA-Z]*|--recursive)'; then
  echo "BLOCKED: Recursive rm is not allowed." >&2
  echo "   Delete files individually or ask the user to run this manually." >&2
  exit 2
fi

# =============================================================================
# NON-BLOCKING WARNINGS (exit 0 -- informational only)
# =============================================================================

# etcdctl -- direct etcd access touches all cluster state
if echo "${COMMAND}" | grep -qE '\betcdctl\b'; then
  echo "WARNING: etcdctl detected -- this tool reads/writes raw cluster state directly." >&2
fi

# kubeadm (non-reset) -- surface visibility that kubeadm is being used
if echo "${COMMAND}" | grep -qE '\bkubeadm\b' && ! echo "${COMMAND}" | grep -qE '\bkubeadm\b.*\breset\b'; then
  echo "WARNING: kubeadm detected -- verify this is a read-only operation." >&2
fi

exit 0
