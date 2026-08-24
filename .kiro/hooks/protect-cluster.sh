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
# STRIP HEREDOC BODIES: heredoc content is inert file data, not commands.
# Keep the operator line (e.g. cat > f <<'EOF') and the closing delimiter
# line, but discard every body line in between. All pattern checks below
# run against SCAN (the stripped copy), not the raw COMMAND.
# =============================================================================
# Regex matches heredoc operator: <<  optional-  optional-quote  WORD  optional-quote
_hdoc_re='<<-?[[:space:]]*['"'"'"]?([A-Za-z0-9_]+)['"'"'"]?'
SCAN=""
_in_hdoc=0
_hdoc_delim=""
while IFS= read -r _line; do
  if (( _in_hdoc )); then
    # Closing delimiter: optional leading whitespace, exact delimiter word, optional trailing whitespace
    if [[ "${_line}" =~ ^[[:space:]]*"${_hdoc_delim}"[[:space:]]*$ ]]; then
      _in_hdoc=0
      _hdoc_delim=""
      SCAN+="${_line}"$'\n'
    fi
    # Body lines are silently dropped (inert content - do not scan)
  else
    SCAN+="${_line}"$'\n'
    # Detect a heredoc operator on this line and start skipping the body
    if [[ "${_line}" =~ ${_hdoc_re} ]]; then
      _in_hdoc=1
      _hdoc_delim="${BASH_REMATCH[1]}"
    fi
  fi
done <<< "${COMMAND}"

# =============================================================================
# HELPER: extract the leading command token, skipping VAR=val assignments.
# Derived from SCAN so heredoc bodies are already excluded.
# =============================================================================
FIRST_CMD=$(echo "${SCAN}" | awk '{for(i=1;i<=NF;i++) if ($i !~ /=/) {print $i; exit}}')

# =============================================================================
# HELPER: does SCAN invoke kubectl/helm as an actual command verb anywhere?
# Splits on shell operators (; && || |) and inspects only each segment's
# leading token (skipping VAR=val assignments), never the raw joined string.
# This avoids false positives on substrings inside arguments/paths, e.g.
# "git diff -- helm/loki/values.yaml" (path contains "helm" but is not a
# helm invocation) or "kubectl describe node k8s-cp1" (node name contains
# "cp" but is not a `kubectl cp` invocation).
# Prints "1" if any segment's command token is kubectl or helm.
# =============================================================================
_has_verb() {
  local verb="${1}"
  echo "${SCAN}" | awk -v verb="${verb}" '
    BEGIN { RS="&&|\\|\\||[;|]"; found=0 }
    {
      n = split($0, toks, /[[:space:]]+/)
      for (i = 1; i <= n; i++) {
        if (toks[i] == "") continue
        if (toks[i] ~ /=/) continue   # skip VAR=val assignments
        if (toks[i] == verb) found=1
        break                          # only the leading real token counts
      }
    }
    END { if (found) print "1" }
  '
}

# =============================================================================
# BARE KUBECTL / HELM -- must always include --kubeconfig or KUBECONFIG=
# Bare commands connect to the work AWS EKS cluster, not the homelab.
# =============================================================================

if [[ "${FIRST_CMD}" == "kubectl" || "${FIRST_CMD}" == "helm" ]]; then
  if ! echo "${SCAN}" | grep -qE '(--kubeconfig|KUBECONFIG=)'; then
    echo "BLOCKED: Bare '${FIRST_CMD}' without --kubeconfig or KUBECONFIG= would hit the work AWS EKS cluster." >&2
    echo "   Use: kubectl --kubeconfig ~/.kube/homelab-claude.yaml ..." >&2
    echo "   Or:  KUBECONFIG=~/.kube/homelab.yaml helm ..." >&2
    exit 2
  fi
fi

# kubectl/helm invoked as a command verb anywhere in a compound command
# (e.g. after && or ;) also counts. Checked via _has_verb (token-based,
# not substring) so path/argument text containing "kubectl"/"helm" never
# trips this.
if [[ "$(_has_verb kubectl)" == "1" ]] && ! echo "${SCAN}" | grep -qE '(--kubeconfig|KUBECONFIG=)'; then
  echo "BLOCKED: kubectl used without --kubeconfig or KUBECONFIG= qualifier." >&2
  echo "   Always use: kubectl --kubeconfig ~/.kube/homelab-claude.yaml ..." >&2
  exit 2
fi

if [[ "$(_has_verb helm)" == "1" ]] && ! echo "${SCAN}" | grep -qE '(--kubeconfig|KUBECONFIG=)'; then
  echo "BLOCKED: helm used without --kubeconfig or KUBECONFIG= qualifier." >&2
  echo "   Always use: KUBECONFIG=~/.kube/homelab.yaml helm ..." >&2
  exit 2
fi

# =============================================================================
# SECRET EXPOSURE -- kubectl get/describe secret[s] with value-revealing flags
# =============================================================================

# kubectl ... get secret[s] ... -o json|yaml|jsonpath (exposes base64-encoded values)
if echo "${SCAN}" | grep -qE '\bkubectl\b.*\bget\b.*\bsecrets?\b' && \
   echo "${SCAN}" | grep -qE '\-o[= ]*(json|yaml|jsonpath)'; then
  echo "BLOCKED: 'kubectl get secret -o json/yaml/jsonpath' exposes secret values." >&2
  echo "   Use 'kubectl get secret <name>' (no -o flag) for existence checks only." >&2
  exit 2
fi

# kubectl ... describe secret[s] (shows base64-decoded values in Data section)
if echo "${SCAN}" | grep -qE '\bkubectl\b.*\bdescribe\b.*\bsecrets?\b'; then
  echo "BLOCKED: 'kubectl describe secret' exposes decoded secret values." >&2
  echo "   Use 'kubectl get secret <name>' (no -o flag) for existence checks only." >&2
  exit 2
fi

# =============================================================================
# DESTRUCTIVE KUBECTL DELETES
# =============================================================================

# delete pvc / persistentvolumeclaim / statefulset (data-destroying resources)
if echo "${SCAN}" | grep -qE '\bkubectl\b.*\bdelete\b.*\b(pvc|persistentvolumeclaim|statefulset)\b'; then
  echo "BLOCKED: Deleting PVCs, PersistentVolumeClaims, or StatefulSets is not allowed." >&2
  echo "   These are data-destroying operations. Perform manually after explicit confirmation." >&2
  exit 2
fi

# kubectl delete --all (any scope -- single namespace or cluster-wide is too risky)
# Note: \b does not match before '--' since '-' is not a word character; use \s instead.
if echo "${SCAN}" | grep -qE '\bkubectl\b.*\bdelete\b.*\s--all(\s|$)'; then
  echo "BLOCKED: 'kubectl delete --all' mass-deletes resources and is not allowed." >&2
  echo "   Scope the delete to a specific named resource in a specific namespace." >&2
  exit 2
fi

# =============================================================================
# KUBECTL EXEC / CP / PORT-FORWARD -- permitted (LAN homelab); warn-only
# =============================================================================

# ArgoCD manual-sync via the controller pod is a documented CONFIRM-tier GitOps op (gitops.md).
# Allow ONLY: argocd app sync|get|list ... --core into argocd-application-controller. Nothing else.
if echo "${SCAN}" | grep -qE 'kubectl.*--kubeconfig.*homelab\.yaml.*exec -n argocd statefulset/argocd-application-controller -- argocd app (sync|get|list)( [^ ]+)? --core'; then
  exit 0
fi

# =============================================================================
# HELPER: does SCAN contain kubectl followed later by one of the given verbs
# as a standalone whitespace-delimited token? Unlike \bexec\b/\bcp\b/\b..\b,
# this does not match a verb name embedded inside a larger token such as a
# node name (k8s-cp1) or a flag value (alloc-cpu), because those are not
# surrounded by whitespace on both sides.
# =============================================================================
_kubectl_has_token_verb() {
  echo "${SCAN}" | grep -qE '\bkubectl\b' || return 1
  echo "${SCAN}" | awk '
    {
      n = split($0, toks, /[[:space:]]+/)
      for (i = 1; i <= n; i++) {
        if (toks[i] == "exec" || toks[i] == "cp" || toks[i] == "port-forward") { print "1"; exit }
      }
    }
  ' | grep -q 1
}

if _kubectl_has_token_verb; then
  echo "WARNING: kubectl exec/cp/port-forward detected -- permitted on this LAN homelab (owner decision)." >&2
  echo "   Per-agent allowlists still gate access (homelab-deploy denies these). Use read-only intent where possible." >&2
fi

# =============================================================================
# DESTRUCTIVE HELM OPERATIONS
# =============================================================================

if echo "${SCAN}" | grep -qE '\bhelm\b.*(uninstall|delete)\b'; then
  echo "BLOCKED: 'helm uninstall/delete' deletes live resources and causes outages." >&2
  echo "   For Helm-to-ArgoCD handover, delete the Helm release secret only:" >&2
  echo "   kubectl ... delete secrets -n <ns> -l name=<release>,owner=helm" >&2
  exit 2
fi

# =============================================================================
# KUBEADM RESET
# =============================================================================

if echo "${SCAN}" | grep -qE '\bkubeadm\b.*\breset\b'; then
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

if echo "${SCAN}" | grep -qE '\brm\s+(-[a-zA-Z]*r[a-zA-Z]*|-[a-zA-Z]*R[a-zA-Z]*|--recursive)'; then
  echo "BLOCKED: Recursive rm is not allowed." >&2
  echo "   Delete files individually or ask the user to run this manually." >&2
  exit 2
fi

# =============================================================================
# NON-BLOCKING WARNINGS (exit 0 -- informational only)
# =============================================================================

# etcdctl -- direct etcd access touches all cluster state
if echo "${SCAN}" | grep -qE '\betcdctl\b'; then
  echo "WARNING: etcdctl detected -- this tool reads/writes raw cluster state directly." >&2
fi

# kubeadm (non-reset) -- surface visibility that kubeadm is being used
if echo "${SCAN}" | grep -qE '\bkubeadm\b' && ! echo "${SCAN}" | grep -qE '\bkubeadm\b.*\breset\b'; then
  echo "WARNING: kubeadm detected -- verify this is a read-only operation." >&2
fi

exit 0
