# Argo Workflows Runbook

Covers: Argo Workflows controller health, Workflow/CronWorkflow failures, vault-snapshot migration.

Phase 5.9 deployed Argo Workflows v4.0.4 (headless - no argo-server UI) under the `argo-workflows` namespace. The first migrated workload is `vault-snapshot` (was a CronJob in the `vault` namespace).

## ArgoWorkflowsControllerDown

**Severity:** critical

The workflow-controller has been unreachable for 5+ minutes. No Workflows or CronWorkflows can execute - the scheduled vault-snapshot will not fire. All Argo Workflows CRDs still exist but nothing reconciles.

### Triage Steps

1. Check controller pod: `kubectl-admin get pod -n argo-workflows`
2. Check controller logs: `kubectl-admin logs -n argo-workflows deployment/argo-workflows-workflow-controller --tail=50`
3. Check ArgoCD Application: `kubectl-admin get application argo-workflows argo-workflows-manifests -n argocd`
4. Check Prometheus target: port-forward prometheus and open `/targets`, look for `argo-workflows-workflow-controller` (should be `up`).
5. If chart sync is stuck, restart the operator: `kubectl-admin rollout restart deployment -n argo-workflows argo-workflows-workflow-controller`

## ArgoWorkflowFailed

**Severity:** warning

One or more Workflows are currently in the `Failed` phase in a given namespace. In most cases this is either a step script error or a K8s transient (image pull, mount, OOM). The onExit handler on the `vault-snapshot` WorkflowTemplate posts to Discord `#incidents` on every failure, so this alert is backup signalling.

### Triage Steps

1. List recent workflows: `kubectl-admin get workflows -n argo-workflows --sort-by=.metadata.creationTimestamp | tail`
2. Inspect the failed workflow: `kubectl-admin get workflow <name> -n argo-workflows -o yaml | less`
3. Check pod logs - `podGC: OnPodSuccess` keeps failed pods around for triage:
   `kubectl-admin logs -n argo-workflows -l workflows.argoproj.io/workflow=<name> --all-containers --prefix`
4. Common causes:
   - Vault `permission denied` on snapshot - check the `vault-snapshot-argo` Kubernetes auth role and `snapshot-policy` Vault policy.
   - NFS mount errors - check the `vault-snapshots` PVC binding and the NFS export on 10.10.30.4.
   - Image pull - registry rate limit or tag typo.

## ArgoWorkflowError

**Severity:** warning

Workflows in `Error` phase indicate an infrastructure problem, not a step exit code. Typical causes: pod eviction, node not ready during execution, or argoexec sidecar misconfiguration.

### Triage Steps

1. Identify the workflow: `kubectl-admin get workflows -n argo-workflows --field-selector=status.phase=Error`
2. Inspect `.status.message` on the workflow CR for the infra error.
3. Check node health and recent evictions on the target node.
4. If it persists across multiple runs, suspect argoexec image/config drift - reconcile via `argocd app sync argo-workflows --core`.

## VaultSnapshotStale

**Severity:** warning

No successful workflow is currently tracked in the `argo-workflows` namespace. The `vault-snapshot` WorkflowTemplate uses `ttlStrategy.secondsAfterSuccess: 86400`, so a Succeeded Workflow CR registers `argo_workflows_gauge{phase="Succeeded"} >= 1` for 24h. When that drops to 0 and no new Succeeded workflow appears, this fires after 30m.

### Triage Steps

1. Check the CronWorkflow: `kubectl-admin get cronworkflow vault-snapshot -n argo-workflows -o yaml`
   - Is `.spec.suspend` true? Un-suspend if so.
   - Is `.status.lastScheduledTime` recent (within 24h)?
2. List recent workflows: `kubectl-admin get workflows -n argo-workflows --sort-by=.metadata.creationTimestamp`
3. If the last run failed, check logs as for `ArgoWorkflowFailed`.
4. Check controller logs for cron reconciliation errors: `kubectl-admin logs -n argo-workflows deployment/argo-workflows-workflow-controller --tail=200 | grep -i cron`
5. Trigger a manual run to prove the system works:
   ```
   kubectl-admin create -f - <<EOF
   apiVersion: argoproj.io/v1alpha1
   kind: Workflow
   metadata:
     generateName: vault-snapshot-manual-
     namespace: argo-workflows
   spec:
     workflowTemplateRef:
       name: vault-snapshot
   EOF
   ```

## Vault snapshot restore from NFS

The `vault-snapshot` CronWorkflow writes `vault-YYYYMMDD.snap` to `10.10.30.4:/Kubernetes/Backups/vault` with 3-day retention. Off-site copies are handled by the restic job on WSL2. To restore:

1. Copy the desired snapshot into vault-0: `kubectl-admin cp /path/to/vault-YYYYMMDD.snap vault/vault-0:/tmp/restore.snap`
2. Login with a root token: `kubectl-admin exec -n vault -it vault-0 -- vault login -`
3. Restore (force overwrites current data): `vault operator raft snapshot restore -force /tmp/restore.snap`
4. Unseal (three shards from 1Password "Vault Unseal Keys"): `vault operator unseal <key>` x3
5. Verify: `vault status` returns `Sealed: false`, `Initialized: true`.
