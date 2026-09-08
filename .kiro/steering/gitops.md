# GitOps

## ArgoCD is the source of truth

All services except `cilium` are managed by ArgoCD. Changes to desired state go
through Git. Direct imperative changes are reverted by selfHeal within ~3 minutes.

## Rules

- **Never `kubectl apply` ArgoCD-managed resources.** selfHeal reverts them.
- **Never `helm upgrade` ArgoCD-managed releases.** Same revert applies.
- **Never `helm uninstall` any release.** It deletes live resources and causes
  outages. The only safe handover path is Secret deletion (see below).
- **Helm-to-ArgoCD handover:** delete the Helm release secret only -
  `kubectl --kubeconfig ~/.kube/homelab.yaml delete secrets -n <ns> -l name=<release>,owner=helm`.
  Never `helm uninstall`.

## Normal change flow

1. Edit the manifest or Helm values file in the repo.
2. Commit and push to `main`.
3. ArgoCD auto-syncs within ~3 minutes.

### Push decision after commit

Commit and push are different actions with different blast radii - a commit is
fully local and freely reversible; a push triggers live cluster reconciliation.
They still need separate approval gates. But once a commit is approved and
made, don't ask a second bare question about pushing - state a decision, per
the engineering steering "Decide, don't survey" rule.

**Push immediately (state that you're doing so, don't ask) when all of:**
- The change is revertable via `git revert` with no lingering live-state risk.
- It targets a `selfHeal: true` app (see Manual-sync apps table for the
  exceptions) - auto-sync picks it up regardless of exact timing, so holding
  the push adds delay without adding safety.
- It's not a structural/destructive change (PVC resize, StatefulSet
  cascade-orphan, secret rotation, anything from the CONFIRM/NEVER tiers in
  remediation-safety.md).

**Hold and ask explicitly when any of:**
- The change touches a manual-sync app (`gitlab`, `cilium`) - pushing without
  immediately following up with a manual sync leaves a window of drift, and
  the manual sync itself is worth flagging.
- The change is structural or destructive per remediation-safety.md tiers.
- The user hasn't indicated intent to ship today (e.g. mid-investigation,
  drafting for later review).

For `gitlab` and `cilium` (manual-sync apps): after pushing a change to
`helm/gitlab/values.yaml` or its Application, trigger sync immediately:

```bash
kubectl --kubeconfig ~/.kube/homelab.yaml \
  exec -n argocd statefulset/argocd-application-controller -- \
  argocd app sync gitlab --core
```

## Manual-sync apps

| App | Reason |
|-----|--------|
| `cilium` | CNI - chicken-and-egg deadlock with automated sync |
| `gitlab` | Helm hooks conflict with ArgoCD auto-prune |

All other apps carry `selfHeal: true`.

## ArgoCD CLI

Use the `argocd` binary inside the controller pod via `--core` mode (no login or
port-forward required):

```bash
kubectl --kubeconfig ~/.kube/homelab.yaml \
  exec -n argocd statefulset/argocd-application-controller -- \
  argocd app get <app> --core
```

## Checking sync status

```bash
kubectl --kubeconfig ~/.kube/homelab.yaml get applications -n argocd
```
