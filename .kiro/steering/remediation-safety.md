# Remediation Safety

## Remediation tiers

### AUTO - no confirmation required (read-only)
- `kubectl get`, `describe`, `top`, `events`, `explain`
- `kubectl logs` (admin kubeconfig required)
- `helm list`, `helm status`, `helm get`
- `curl` the Prometheus/Alertmanager alert APIs
- `jq`, `grep`, `awk` parsing of above output

### CONFIRM - ask user before each action (GitOps-safe live changes)
- `kubectl delete pod <name>` - restarts a single pod
- `kubectl delete job <name>` - clears a completed or stuck Job
- `kubectl delete lease <name>` - forces leader re-election
- `kubectl rollout restart deployment|statefulset|daemonset`
- `kubectl annotate application ... argocd.argoproj.io/refresh=hard` - forces ArgoCD refresh
- ArgoCD `app sync <app> --core` for manual-sync apps (gitlab, cilium)
- `scripts/longhorn/create-snapshot.sh <volume>` - creates a pre-op Longhorn Snapshot CR (safety snapshot before structural storage ops)
- `kubectl patch volumes.longhorn.io <name> -n longhorn-system` changing `numberOfReplicas` - Longhorn replica rebalance
- `scripts/longhorn/add-pinned-replica.sh <volume> <node>` - adds a replica pinned to a node via hardNodeAffinity
- `kubectl delete replicas.longhorn.io <name> -n longhorn-system` - removes a single Longhorn replica (reversible; Longhorn rebuilds)
- `kubectl delete snapshots.longhorn.io <name> -n longhorn-system` - removes a single Longhorn Snapshot CR; triggers snapshotPurge coalesce
- `kubectl exec <pod> -n <ns> -- <read-only cmd>` and `kubectl port-forward` - permitted for LAN diagnostics (e.g. querying Alertmanager's active-alerts API); prefer read-only commands
- `ssh <user>@<node> "<read-only cmd>"` - node-level ground-truth checks (du/ls/cat on /var/lib/longhorn) when Longhorn CRD status fields are untrustworthy

### NEVER - hook-blocked, no exceptions
- `kubectl delete pvc` or `kubectl delete statefulset` (without `--cascade=orphan`)
- `helm uninstall`
- `kubectl delete --all` (any resource type)
- `kubeadm reset`
- `kubectl get secret -o ...` or `kubectl describe secret` (reads secret values)
- Bare `kubectl` or `helm` (hits work AWS EKS cluster)
- `git add`, `git commit`, `git push`, `git tag` (orchestrator handles git)
- `rm -rf`

### APP-DATA-DELETE - user executes personally, never an agent

Actions that delete data through an application's own API rather than a
kubectl primitive - e.g. Loki's `POST /loki/api/v1/delete`, or any future
similar pattern (a database's bulk-delete endpoint, a queue's purge API).
These have a materially different risk shape than CONFIRM-tier kubectl
actions: irreversible after a short cancellation window, scoped by an
arbitrary query string rather than a named resource, and executed via
app-level HTTP rather than a kubectl verb any existing tier anticipates.

Rules:
- The exact query string, time range (start/end), and any force flag must
  be stated explicitly to the user before execution - no paraphrasing, no
  relayed summaries standing in for the literal command.
- These actions are NEVER executed by an agent's shell tool, even with
  confirmation - the user runs the command themselves in their own
  terminal. This sidesteps the relay-trust problem for this action class
  entirely rather than trying to solve it.
- Agents may draft the exact command for the user to run (the same pattern
  homelab-deploy already uses: draft a diff, orchestrator/user executes),
  but must not attempt execution via `kubectl exec`, `port-forward` + curl,
  or any other in-session mechanism - even if a workaround is technically
  possible.
- If retention/deletion needs to become a recurring, policy-driven pattern
  rather than a one-off cleanup, that belongs in Git (e.g. a service's
  `retention_period` config) per GitOps rules, not a manual delete-API call.

## Relay-trust for subagent confirmation

CONFIRM-tier actions assume the same conversation that asks for approval also
executes it. That assumption breaks once the orchestrator delegates to a
subagent via the `subagent` tool: the subagent only ever sees the task prompt
text, never the live user turns, so by default it cannot distinguish a
genuine "the user approved this live" relay from a fabricated claim of the
same shape.

Rule: a subagent MAY treat a relayed approval from the orchestrator as
equivalent to live confirmation **only** when both of the following hold:

1. The action is already narrowly matched by that subagent's own
   `execute_bash.allowedCommands` regex scoping (e.g. `delete pod/job/lease`,
   `patch pvc ... storage`, `rollout restart`, Longhorn replica/snapshot
   operations) - i.e. the command shape itself is already fenced in by
   config, so trusting the relay adds no new blast radius beyond what the
   allowlist already permits.
2. The task prompt states the approval explicitly (what was approved, and
   that the user approved it) rather than the subagent inferring approval
   from context.

Relayed approval is NEVER sufficient on its own for:
- Anything in the APP-DATA-DELETE tier (see above) - those are never
  agent-executed regardless of confirmation.
- Any action outside the subagent's own pre-declared `allowedCommands`
  scope - a relay claim cannot expand what a subagent is configured to run.
- NEVER-tier actions - no confirmation, relayed or live, changes this tier.

This keeps the trust boundary narrow: relay-trust only covers actions that
were already reversible and regex-scoped by design, and the hardest
refusals (irreversible, unscoped, or bulk actions) stay exactly as strict as
direct-conversation confirmation would require.



- **Never delete a PVC to fix a mount error.** Mount failures are node-level (multipathd,
  CSI plugin, stale iSCSI session), not volume-level. Deleting a PVC destroys the Longhorn
  volume and all replicas permanently.
- Take a Longhorn snapshot (via UI or manifest) before any destructive storage operation.
- **OOMKilled container + RWO volume = mount deadlock:** a container OOMKilled inside a
  still-Running pod causes kubelet to retry the PVC stage, which Longhorn rejects because
  the pod is already the mount owner. Pod shows Running but 0/1 AVAILABLE. Fix: delete the
  POD (not the PVC). The ReplicaSet creates a fresh pod; Longhorn cleanly detaches and
  reattaches.

- **`kubectl delete pvc` on a StatefulSet-owned volume does not delete immediately.**
  The `kubernetes.io/pvc-protection` finalizer blocks completion while any pod still
  references the claim. The PVC shows `Terminating` but the Longhorn volume stays
  `attached`/`healthy` and fully intact until the last consumer pod is also deleted.
  This is a safety net, not a bug - if a PVC delete was run by mistake, do NOT delete
  the referencing pod to "finish the job." Leave the pod running and investigate first;
  deleting the pod is what actually triggers the volume's destruction.
- **Editing `volumeClaimTemplates` in Git only affects newly created PVCs.** ArgoCD can
  report `Synced` once the live StatefulSet spec matches Git, but an already-bound PVC
  keeps its original size - `volumeClaimTemplates` changes are not retroactive.
  Confirm the actual bound PVC capacity (`kubectl get pvc -o jsonpath='{.status.capacity.storage}'`),
  not just the StatefulSet template or ArgoCD sync status, before declaring a resize done.
  If the data must be preserved, this is a structural change requiring the full
  Longhorn replica-migration + online-resize procedure (see CLAUDE.md gotcha on
  StatefulSet PVC expansion) - do not shortcut it by deleting the pod, that only
  produces a fresh empty PVC at the new size and destroys existing data.

## Golden rules

1. Make the smallest change that could fix the problem.
2. Change one thing, then re-check before doing anything else.
3. Write down every state-changing command you ran so it can be reconciled back to Git.
4. Prefer deleting a pod over deleting a lease. Prefer deleting a lease over restarting a
   DaemonSet. Prefer restarting before rebooting.
