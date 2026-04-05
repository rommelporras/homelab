# Verify ArgoCD Sync

Poll one or more ArgoCD Applications until they reach Synced/Healthy or fail.
Built for the "I just pushed a commit, did it actually land?" moment.

## Usage

```
/verify-sync                  → auto-detect affected apps from HEAD commit, verify each
/verify-sync <app>            → verify one app
/verify-sync <app1> <app2>    → verify multiple apps in parallel
/verify-sync --all-unhealthy  → verify every app currently not Synced/Healthy
```

## Why this exists

The homelab repo has had several multi-day silent drift windows where a
commit landed cleanly, ArgoCD pruned/applied as instructed, but a downstream
consumer broke at its next trigger (CronJob schedule, manual sync, next pod
restart). Example: commit `cd0beef` removed `discord-version-webhook`
ExternalSecret, but the `version-check` CronJob still referenced it; the
failure only surfaced at the Sunday schedule three days later.

This command closes that gap. After any non-trivial push, run it to confirm
reality matches intent before walking away.

## Instructions

### 1. Determine target apps

**No args:**
1. `git show --name-only --pretty=format: HEAD` — get changed files in HEAD
2. Map each file to one or more ArgoCD apps using these path rules:
   - `helm/<chart>/**` → the matching ArgoCD Application (usually `<chart>`, sometimes `<chart>-manifests`)
   - `manifests/argocd/apps/<app>.yaml` → that `<app>` AND `root` (the app-of-apps)
   - `manifests/monitoring/**` → `monitoring-manifests`
   - `manifests/<service>/**` → `<service>` (if an ArgoCD Application exists with that name) or the parent folder's app
   - `manifests/argocd/**` (other) → `argocd-manifests`
3. Deduplicate. If no files map to an app, print "No ArgoCD apps affected by HEAD commit" and exit.

**Explicit args:** use the provided app names directly.

**`--all-unhealthy`:** `kubectl-admin get applications -n argocd -o json | jq -r '.items[] | select(.status.sync.status != "Synced" or .status.health.status != "Healthy") | .metadata.name'` — poll every returned app.

### 2. For manual-sync apps, trigger sync first

Some apps (notably `gitlab`) have no `syncPolicy.automated` and won't act on a
git push without a manual nudge. Before polling, check each target app:

```bash
kubectl-admin get application <app> -n argocd -o jsonpath='{.spec.syncPolicy.automated}'
```

If empty, trigger a sync via the controller pod:

```bash
kubectl-admin exec -n argocd statefulset/argocd-application-controller -- argocd app sync <app> --core
```

Report `Triggered manual sync on <app>` so the user sees what happened.

### 3. Poll each target app

Per app, loop every 15 seconds up to 10 minutes (`MAX_WAIT=600` configurable):

```bash
kubectl-admin get application <app> -n argocd -o json | jq '{
  sync: .status.sync.status,
  health: .status.health.status,
  opPhase: .status.operationState.phase,
  opMsg: .status.operationState.message,
  revision: .status.sync.revision
}'
```

**Exit conditions per app:**
- `sync == "Synced" && health == "Healthy"` → ✅ PASS
- `opPhase == "Failed" || opPhase == "Error"` → ❌ FAIL (include `opMsg`)
- Elapsed ≥ MAX_WAIT → ⏱️ TIMEOUT (include last state)
- `sync == "Synced" && health == "Progressing"` → keep waiting (migrations, rollouts, StatefulSet roll)

### 4. Run targets in parallel

If multiple apps are being verified, run each in its own background
subprocess. Report interleaved status updates every 30 seconds:

```
[0:30] gitlab         sync=OutOfSync   health=Progressing   op=Running
[0:30] monitoring-m.. sync=Synced      health=Healthy        ✅ PASS
[1:00] gitlab         sync=Synced      health=Progressing   op=Succeeded (migrations running)
[3:45] gitlab         sync=Synced      health=Healthy        ✅ PASS
```

### 5. Final report

When all apps have finished (PASS/FAIL/TIMEOUT), print a summary table:

```
Verification complete.
┌───────────────────────┬──────────┬──────────┬──────────────┐
│ App                   │ Sync     │ Health   │ Result       │
├───────────────────────┼──────────┼──────────┼──────────────┤
│ gitlab                │ Synced   │ Healthy  │ ✅ PASS (3m45s) │
│ monitoring-manifests  │ Synced   │ Healthy  │ ✅ PASS (0m30s) │
│ root                  │ Synced   │ Healthy  │ ✅ PASS (0m45s) │
└───────────────────────┴──────────┴──────────┴──────────────┘
```

For FAIL rows, include a "next step" hint:
- If `opPhase == "Failed"`: "Check `kubectl-admin get app <name> -n argocd -o json | jq '.status.operationState'` for the blocker. Common causes: PreSync hook deadlock (see CLAUDE.md `ArgoCD stuck sync recovery`), pod OOMKill, missing secret reference."
- If TIMEOUT with `health == "Progressing"`: "Sync is running but slow. Check child resources: `kubectl-admin get all -n <destNamespace>`. StatefulSet rollouts and GitLab migrations can take 5-10 minutes."
- If TIMEOUT with `health == "Missing"`: "ArgoCD expects resources that don't exist. Check `kubectl-admin get application <app> -n argocd -o json | jq '.status.resources[] | select(.status != \"Synced\")'`."

### 6. Exit code

- All PASS → exit 0
- Any FAIL or TIMEOUT → exit 1

## Important rules

1. **Use `kubectl-admin`, not `kubectl-homelab`** — the restricted kubeconfig cannot read `applications.argoproj.io`.
2. **Never modify apps** — this command is read-only except for the one manual-sync trigger in step 2. Don't patch specs, don't edit manifests, don't force-sync unless the user adds `--force` (future extension).
3. **Parallel polling** — if verifying 3+ apps, they poll concurrently. Don't serialize; it wastes time.
4. **Respect the 10-minute timeout** — don't extend it silently. If an app needs longer (rare), the user can re-invoke.
5. **Surface the actual ArgoCD message** — don't paraphrase `opMsg`; print it verbatim. That's where the debugging breadcrumbs are.
