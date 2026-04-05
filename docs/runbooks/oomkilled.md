# OOMKilled Runbook

Covers: container memory limit exhaustion, OOM loops that stall parent workloads

## ContainerOOMKilled

**Severity:** warning

A container was OOMKilled (exit code 137) in the last 10 minutes. Kubernetes killed it because it exceeded its memory limit. May be a one-off spike or the start of an OOM loop — if it recurs, `ContainerOOMKilledRepeat` will promote to critical.

Silent OOMs in Jobs and init containers are the hardest to spot: the parent workload (Deployment, CronJob, ArgoCD sync) just appears "stuck" because the Job never reaches `.status.succeeded`. This alert exists to surface that class of failure.

### Triage Steps

1. Identify the container and its last termination reason:
   ```bash
   kubectl-admin get pod <pod> -n <namespace> -o json | jq '.status.containerStatuses[] | {name, lastState: .lastState.terminated, restartCount}'
   ```
   Look for `reason: OOMKilled` and `exitCode: 137`.

2. Check actual memory usage vs limit:
   ```bash
   kubectl-admin top pod <pod> -n <namespace> --containers
   kubectl-admin get pod <pod> -n <namespace> -o jsonpath='{.spec.containers[*].resources.limits}'
   ```
   If usage is consistently close to the limit, the limit is too low.

3. Check recent changes that may have raised memory pressure:
   - Helm chart upgrades (new app versions often need more RAM — GitLab 18.x is a known offender)
   - New workload on the same node competing for memory
   - Recent config changes that enabled new features

4. Short-term fix: raise `resources.limits.memory`. For Helm charts, edit the values file (e.g. `helm/<chart>/values.yaml`). For manifest-based workloads, edit the file under `manifests/<service>/` and let ArgoCD sync.

5. Long-term: if the container consistently needs more memory than expected, profile it (pprof for Go, heap dumps for JVM/Ruby) before blindly raising limits — may be a leak.

### Common culprits in this homelab

- **gitlab-migrations-*** — GitLab 18.x migrations need ≥1.5Gi. See CLAUDE.md gotcha "GitLab migrations memory limit".
- **karakeep** — AI tagging jobs spike memory during embedding generation.
- **ollama** — large model loads can push past configured limits.
- **prometheus** — increased scrape target count or retention can cause gradual OOM growth.

## ContainerOOMKilledRepeat

**Severity:** critical

A container has been OOMKilled 3 or more times in the last hour. This is an OOM loop — the container is stuck in a cycle of starting, exhausting memory, being killed, and restarting. It is making no forward progress and is actively blocking its parent workload (Job not completing, Deployment rollout stalled, ArgoCD sync stuck waiting on a hook).

This was the exact signature of the GitLab migrations incident that left the gitlab ArgoCD app in Missing/OutOfSync for hours: a Job with `restartPolicy: OnFailure` in an infinite OOM loop, never reaching `.status.succeeded`.

### Triage Steps

1. Identify the container and confirm it's looping, not recovering:
   ```bash
   kubectl-admin get pod <pod> -n <namespace> -o json | jq '.status.containerStatuses[] | {name, restartCount, state, lastState: .lastState.terminated}'
   ```
   High `restartCount` climbing + `lastState.terminated.reason: OOMKilled` confirms the loop.

2. Check if it's a Job whose parent workflow is blocked:
   ```bash
   kubectl-admin get job -n <namespace>
   kubectl-admin get application -n argocd 2>/dev/null | grep -iE "<namespace>|<app>"
   ```
   If an ArgoCD app shows Missing/Progressing while its Job is OOM-looping, you've found the blocker.

3. **Stop the loop before fixing** — break the cycle so the stale state clears:
   ```bash
   kubectl-admin delete pod <pod> -n <namespace>          # for Deployment/StatefulSet children
   kubectl-admin delete job <job> -n <namespace>          # for standalone Jobs
   ```
   For Jobs managed by Helm/ArgoCD, deletion is safe — the next sync will recreate with the corrected values.

4. Fix the memory limit in git:
   - **Helm chart:** edit `helm/<chart>/values.yaml`, update `resources.limits.memory` to at least 2x current value (leave headroom).
   - **Manifest:** edit the file under `manifests/<service>/`.
   - Commit and push. For manual-sync apps (gitlab), trigger sync manually afterward: `kubectl-admin exec -n argocd statefulset/argocd-application-controller -- argocd app sync <app> --core`.

5. Verify the fix landed and the Job succeeds:
   ```bash
   kubectl-admin get pod <new-pod> -n <namespace> -o json | jq '.spec.containers[].resources.limits.memory'
   # watch for Complete / Succeeded
   kubectl-admin get job <job> -n <namespace> -w
   ```

6. If it OOMs AGAIN at the new limit, do not keep raising blindly — profile the process (pprof/heap dump) or investigate whether the workload is doing something pathological (unbounded loop, leak, runaway query).

### Related CLAUDE.md gotchas

- **GitLab migrations memory limit** — specific fix for gitlab OOMKill loop.
- **ArgoCD stuck sync recovery (ghost `operationState`)** — if the OOM loop left ArgoCD in a weird state after cleanup, use this recovery procedure.
