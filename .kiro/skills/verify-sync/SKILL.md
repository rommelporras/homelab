---
name: verify-sync
description: |
  Triggered by: "verify sync", "check argocd", "did it deploy", "confirm sync",
  "did it land", "check if deployed". Polls ArgoCD Applications until they reach
  Synced/Healthy or fail. Auto-detects affected apps from HEAD commit, supports
  parallel polling for 3+ apps, triggers manual-sync when needed, and produces
  a final PASS/FAIL/TIMEOUT table with next-step hints.
---

# verify-sync

Poll one or more ArgoCD Applications until they reach Synced/Healthy or fail.
Built for the "I just pushed a commit, did it actually land?" moment.

Read-only except for one manual-sync trigger (step 2). All kubectl commands use
the admin kubeconfig - the restricted kubeconfig cannot read `applications.argoproj.io`.

## Background

The homelab repo has had several multi-day silent drift windows where a commit
landed cleanly, ArgoCD pruned/applied as instructed, but a downstream consumer
broke at its next trigger (CronJob schedule, manual sync, next pod restart).
Example: commit `cd0beef` removed `discord-version-webhook` ExternalSecret, but
the `version-check` CronJob still referenced it; the failure only surfaced at the
Sunday schedule three days later.

This skill closes that gap. After any non-trivial push, run it to confirm reality
matches intent before walking away.

## Step 1 - Determine target apps

**No args / triggered from chat:**

1. Get changed files in HEAD:
   ```bash
   git show --name-only --pretty=format: HEAD
   ```
2. Map each file to one or more ArgoCD apps using these path rules:
   - `helm/<chart>/**` - the matching ArgoCD Application (usually `<chart>`, sometimes `<chart>-manifests`)
   - `manifests/argocd/apps/<app>.yaml` - that `<app>` AND `root` (the app-of-apps)
   - `manifests/monitoring/**` - `monitoring-manifests`
   - `manifests/<service>/**` - `<service>` (if an ArgoCD Application exists with that name) or the parent folder's app
   - `manifests/argocd/**` (other) - `argocd-manifests`
3. Deduplicate. If no files map to an app, print "No ArgoCD apps affected by HEAD commit" and stop.

**Explicit app names provided by user:** use the provided names directly.

**"--all-unhealthy" mode:**
```bash
kubectl --kubeconfig ~/.kube/homelab.yaml get applications -n argocd -o json \
  | jq -r '.items[] | select(.status.sync.status != "Synced" or .status.health.status != "Healthy") | .metadata.name'
```
Poll every returned app.

## Step 2 - Trigger manual-sync for apps without automated syncPolicy

Some apps (notably `gitlab`) have no `syncPolicy.automated` and won't act on a
git push without a manual nudge. Before polling, check each target app:

```bash
kubectl --kubeconfig ~/.kube/homelab.yaml get application <app> -n argocd \
  -o jsonpath='{.spec.syncPolicy.automated}'
```

If empty, trigger a sync via the controller pod:

```bash
kubectl --kubeconfig ~/.kube/homelab.yaml \
  exec -n argocd statefulset/argocd-application-controller -- \
  argocd app sync <app> --core
```

Report `Triggered manual sync on <app>` so the user sees what happened.

## Step 3 - Poll each target app

Per app, loop every 15 seconds up to 10 minutes (`MAX_WAIT=600`):

```bash
kubectl --kubeconfig ~/.kube/homelab.yaml get application <app> -n argocd -o json \
  | jq '{
      sync: .status.sync.status,
      health: .status.health.status,
      opPhase: .status.operationState.phase,
      opMsg: .status.operationState.message,
      revision: .status.sync.revision
    }'
```

**Exit conditions per app:**
- `sync == "Synced" && health == "Healthy"` - PASS
- `opPhase == "Failed" || opPhase == "Error"` - FAIL (include `opMsg` verbatim)
- Elapsed >= MAX_WAIT - TIMEOUT (include last state)
- `sync == "Synced" && health == "Progressing"` - keep waiting (migrations, rollouts, StatefulSet roll)

## Step 4 - Run targets in parallel

If verifying 3 or more apps, run each in its own background subprocess. Report
interleaved status updates every 30 seconds:

```
[0:30] gitlab         sync=OutOfSync   health=Progressing   op=Running
[0:30] monitoring-m.. sync=Synced      health=Healthy        PASS
[1:00] gitlab         sync=Synced      health=Progressing   op=Succeeded (migrations running)
[3:45] gitlab         sync=Synced      health=Healthy        PASS
```

Do not serialize polls for 3+ apps - it wastes time.

## Step 5 - Final report

When all apps have finished (PASS/FAIL/TIMEOUT), print a summary table:

```
Verification complete.
+------------------------+---------+---------+------------------+
| App                    | Sync    | Health  | Result           |
+------------------------+---------+---------+------------------+
| gitlab                 | Synced  | Healthy | PASS (3m45s)     |
| monitoring-manifests   | Synced  | Healthy | PASS (0m30s)     |
| root                   | Synced  | Healthy | PASS (0m45s)     |
+------------------------+---------+---------+------------------+
```

**For FAIL rows, include a "next step" hint:**
- If `opPhase == "Failed"`: "Check `kubectl --kubeconfig ~/.kube/homelab.yaml get app <name> -n argocd -o json | jq '.status.operationState'` for the blocker. Common causes: PreSync hook deadlock (see CLAUDE.md ArgoCD stuck sync recovery), pod OOMKill, missing secret reference."
- If TIMEOUT with `health == "Progressing"`: "Sync is running but slow. Check child resources: `kubectl --kubeconfig ~/.kube/homelab.yaml get all -n <destNamespace>`. StatefulSet rollouts and GitLab migrations can take 5-10 minutes."
- If TIMEOUT with `health == "Missing"`: "ArgoCD expects resources that don't exist. Check `kubectl --kubeconfig ~/.kube/homelab.yaml get application <app> -n argocd -o json | jq '.status.resources[] | select(.status != \"Synced\")'`."

**Surface the actual ArgoCD message** - do not paraphrase `opMsg`; print it verbatim. That's where the debugging breadcrumbs are.

## Step 6 - Exit

- All PASS - exit 0
- Any FAIL or TIMEOUT - exit 1

## Important rules

1. **Use admin kubeconfig** - `kubectl --kubeconfig ~/.kube/homelab.yaml` - the restricted kubeconfig cannot read `applications.argoproj.io`.
2. **Read-only except step 2** - no patching specs, no editing manifests, no force-sync beyond the automated trigger.
3. **Parallel polling for 3+ apps** - do not serialize; it wastes time.
4. **Respect the 10-minute timeout** - do not extend silently. If an app needs longer (rare), the user can re-invoke.
5. **Never bare kubectl or helm** - plain commands connect to the work AWS EKS cluster.
