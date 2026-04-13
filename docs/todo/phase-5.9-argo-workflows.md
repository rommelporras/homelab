# Phase 5.9: Argo Workflows

> **Status:** Planned
> **Target:** v0.39.0
> **Prerequisite:** Phase 5.8 (v0.38.0 - GitOps migration complete, ArgoCD stable)
> **DevOps Topics:** Workflow orchestration, DAG-based automation, CronWorkflow
> **CKA Topics:** CRD-based automation, pod scheduling, RBAC

> **Purpose:** Install Argo Workflows and migrate selected CronJobs that benefit from
> multi-step DAG orchestration. Deploy as an ArgoCD-managed Application to dog-food
> the GitOps setup established in Phase 5.8.
>
> **Learning Goal:** Kubernetes-native workflow engine, DAG patterns, exit handlers,
> WorkflowTemplates, CronWorkflow scheduling, and how CRD-based automation differs
> from native CronJob resources.

> **Target versions (verified 2026-04-14):**
> - Argo Workflows app: **v4.0.4** (released 2026-04-02)
> - Helm chart `argo-workflows`: **1.0.7** (released 2026-04-03, bundles v4.0.4)
> - argoexec image: `quay.io/argoproj/argoexec:v4.0.4-nonroot`
> - Re-verify before install - the chart/app cadence is weekly and a newer patch
>   may be out by the time this phase is executed.

---

## 5.9.0 Pre-Installation

> **Gate:** ArgoCD must be stable and all Phase 5.8 migrations confirmed healthy
> before adding another CRD-heavy workload.

- [ ] 5.9.0.1 Verify ArgoCD is stable and all Applications are Synced/Healthy
  ```bash
  kubectl-homelab get applications -n argocd
  # Expected: all SYNCED and Healthy (except cilium which is manual-sync)

  kubectl-homelab get pods -n argocd
  # Expected: all Running, no CrashLoopBackOff
  ```

- [ ] 5.9.0.2 Check cluster resource headroom
  ```bash
  kubectl-homelab top nodes
  # Argo Workflows controller (headless): ~100m CPU, ~128Mi memory
  # Each workflow step runs a pod: transient, 50-100m CPU per step
  # Verify at least 200m CPU and 256Mi memory available across cluster
  ```

- [ ] 5.9.0.3 Re-verify latest chart/app versions
  ```bash
  helm-homelab repo add argo https://argoproj.github.io/argo-helm
  helm-homelab repo update
  helm-homelab search repo argo/argo-workflows --versions | head -10
  # Record the latest stable chart version and its appVersion.
  # If newer than 1.0.7 / v4.0.4, update the targetRevision in
  # manifests/argocd/apps/argo-workflows.yaml and the argoexec image
  # tag in helm/argo-workflows/values.yaml.
  ```

- [ ] 5.9.0.4 Verify VAP allows Argo Workflows images
  ```bash
  # The cluster VAP `restrict-image-registries` already allows quay.io/*.
  # Confirm with a dry-run against the exact argoexec tag:
  kubectl-admin run test-argoexec \
    --image=quay.io/argoproj/argoexec:v4.0.4-nonroot \
    --dry-run=server -n default
  # Expected: pod/test-argoexec created (server dry-run), no VAP denial.
  ```

- [ ] 5.9.0.5 Ensure NFS export directory exists on the NAS
  ```bash
  # argo-workflows reuses the same NFS path as the current vault CronJob.
  # The directory already exists (32 days of snapshots), so only verify:
  sudo mount -t nfs4 10.10.30.4:/Kubernetes /tmp/nfs
  ls -la /tmp/nfs/Backups/vault | head
  sudo umount /tmp/nfs
  # Expected: vault-YYYYMMDD.snap files present, directory writable by UID 65534.
  ```

---

## 5.9.1 Installation

> **Mode:** Headless (no argo-server UI). Saves ~100m CPU and ~128Mi memory.
> The argo CLI and ArgoCD UI cover all operational needs.
> **Namespace:** `argo-workflows` (separate from `argocd` - different lifecycle and RBAC).
> **Image:** Non-root argoexec: `quay.io/argoproj/argoexec:v4.0.4-nonroot`
> **GitOps split:** two ArgoCD Applications - one for the Helm chart (controller
> + CRDs), one Git-type for companion manifests (RBAC, WorkflowTemplate,
> CronWorkflow, CNP, ExternalSecret, LimitRange, ResourceQuota, PV/PVC).

- [ ] 5.9.1.1 Bootstrap namespace (one-time imperative apply, then declarative)
  ```bash
  # The Helm Application has CreateNamespace=false and the argo-workflows-manifests
  # Git Application deploys into the same namespace, so the namespace must exist
  # before either syncs. Apply the manifest directly this one time:
  kubectl-admin apply -f manifests/argo-workflows/namespace.yaml
  # ArgoCD then takes ownership via the Git manifests app on first sync.
  kubectl-homelab get ns argo-workflows --show-labels
  # Expected labels: pod-security.kubernetes.io/enforce=baseline,
  # pod-security.kubernetes.io/warn=restricted, eso-enabled=true
  ```

- [x] 5.9.1.2 Update infrastructure AppProject destinations
  Edit `manifests/argocd/appprojects.yaml` and add to `infrastructure` project
  destinations:
  ```yaml
  - namespace: argo-workflows
    server: https://kubernetes.default.svc
  ```
  The project already whitelists `argoproj.github.io/argo-helm` as a source repo
  and `CustomResourceDefinition` / `ClusterRole*` as cluster resources, so no
  other AppProject changes are needed.
  **Done in this diff.**

- [ ] 5.9.1.3 Review helm values
  File: `helm/argo-workflows/values.yaml` (scaffolded). Confirm:
  - `controller.image.tag: v4.0.4` pinned (no `latest`)
  - `server.enabled: false` (headless)
  - `executor.image.tag: v4.0.4-nonroot`
  - `useDefaultArtifactRepo: false` (no S3 needed for our use case)
  - `workflow.serviceAccount.create: false` (we manage SAs via our RBAC manifests)
  - `workflow.rbac.create: false` (same reason)
  - Resource requests/limits match LimitRange values

- [ ] 5.9.1.4 Commit manifests and let ArgoCD install via root app-of-apps
  After committing `manifests/argocd/apps/argo-workflows.yaml` and
  `manifests/argocd/apps/argo-workflows-manifests.yaml`, the root app-of-apps
  auto-discovers both. Helm app deploys the chart, Git app deploys the companion
  manifests. Both run with `automated.prune: true, selfHeal: true`.

- [ ] 5.9.1.5 Verify controller is running and CRDs are registered
  ```bash
  kubectl-homelab get pods -n argo-workflows
  # Expected: argo-workflows-workflow-controller-... Running 1/1

  kubectl-homelab get crd | grep argoproj.io | grep -v argoproj.io/Application
  # Expected (new): workflows.argoproj.io, cronworkflows.argoproj.io,
  #   workflowtemplates.argoproj.io, workflowtaskresults.argoproj.io,
  #   workflowtasksets.argoproj.io, workflowartifactgctasks.argoproj.io,
  #   clusterworkflowtemplates.argoproj.io, workfloweventbindings.argoproj.io
  ```

- [ ] 5.9.1.6 Confirm CiliumNetworkPolicies are enforced
  ```bash
  kubectl-homelab get ciliumnetworkpolicy -n argo-workflows
  # Expected: argo-workflows-default-deny, argo-workflows-controller,
  #   argo-workflows-vault-snapshot
  ```

---

## 5.9.2 CronJob Analysis

> **Evaluation complete (March 2026):** All current cluster CronJobs analyzed
> against Argo Workflows capabilities. Updated April 2026 after verification
> against live cluster state.

Architecture overview: workflow-controller (reconciles CRDs) + argoexec sidecar
(runs in each workflow pod for progress reporting). argo-server (UI/API) is optional
and disabled in this deployment to save resources.

### Full CronJob Evaluation

| CronJob | Namespace | Schedule | Complexity | AW Benefit | Verdict |
|---------|-----------|----------|------------|------------|---------|
| cluster-janitor | kube-system | 10 min | Single step | None | Keep CronJob |
| arr-stall-resolver | arr-stack | 30 min | Single step | None | Keep CronJob |
| arr-backup-bazarr | arr-stack | Daily | Single step | None | Keep CronJob |
| arr-backup-jellyfin | arr-stack | Daily | Single step | None | Keep CronJob |
| arr-backup-prowlarr | arr-stack | Daily | Single step | None | Keep CronJob |
| arr-backup-qbittorrent | arr-stack | Daily | Single step | None | Keep CronJob |
| arr-backup-radarr | arr-stack | Daily | Single step | None | Keep CronJob |
| arr-backup-recommendarr | arr-stack | Daily | Single step | None | Keep CronJob |
| arr-backup-seerr | arr-stack | Daily | Single step | None | Keep CronJob |
| arr-backup-sonarr | arr-stack | Daily | Single step | None | Keep CronJob |
| arr-backup-tdarr | arr-stack | Daily | Single step | None | Keep CronJob |
| adguard-backup | home | Daily | Single step | None | Keep CronJob |
| myspeed-backup | home | Daily | Single step | None | Keep CronJob |
| karakeep-backup | karakeep | Daily | Single step | None | Keep CronJob |
| grafana-backup | monitoring | Daily | Single step | None | Keep CronJob |
| uptime-kuma-backup | uptime-kuma | Daily | Single step | None | Keep CronJob |
| ghost-mysql-backup | ghost-prod | Daily | Single step | None | Keep CronJob |
| invoicetron-db-backup | invoicetron-prod | Daily | Single step | None | Keep CronJob |
| atuin-backup | atuin | Weekly | Single step | None | Keep CronJob |
| etcd-backup | kube-system | Daily | Single step | None | Keep CronJob |
| vault-snapshot | vault | Daily | Multi-step | DAG + exit handler | MIGRATE |
| configarr | arr-stack | Daily | Single step | None | Keep CronJob |
| version-check/Nova | monitoring | Weekly | Single step | None | Keep CronJob |
| cert-expiry-check | kube-system | Weekly | Single step | None | Keep CronJob |
| pki-backup | kube-system | Weekly | Single step | None | Keep CronJob |
| kube-bench-weekly | kube-system | Weekly | Single step | None | Keep CronJob |
| Longhorn recurring (4) | longhorn-system | Longhorn-native | N/A | N/A | Keep Longhorn |

**Result:** 1 CronJob (vault-snapshot) materially benefits from migration to
Argo Workflows. All others are single-step tasks with no inter-dependencies.
The ARR backups were previously 3 per-node CronJobs (cp1/cp2/cp3) but were
already restructured into 9 per-app CronJobs with podAffinity, eliminating the
parallelism benefit that would have justified migration.

### Strongest Candidates

**1. vault-snapshot (HIGH value) - Wave 1:**
Multi-step dependency `login -> snapshot -> prune` maps cleanly to a DAG.
Current shell script uses `set -e` so login failure silently skips snapshot.
DAG makes ordering explicit with exit handler for Discord notification on failure.

**2. Backup failure notification gap (MOOT - already covered):**
An earlier draft assumed the backup CronJobs had no failure alerting. On
re-audit `backup-alerts.yaml:CronJobFailed` already catches every failing
Job cluster-wide via `kube_job_status_failed{namespace!=""} > 0`. No Wave 2
work is needed. See section 5.9.4.

### Keep as CronJob (no benefit)

- `cluster-janitor`: 10-minute interval - per-step pod overhead too high
- `configarr`: black-box tool, no internal steps to model
- `version-check/Nova`: init container pattern is CKA study material, keep as-is
- `etcd-backup`, `pki-backup`, `cert-expiry-check`: single atomic shell script

### Future Use Cases Where Argo Workflows Adds Real Value

| Use Case | Why AW over CronJob |
|----------|---------------------|
| Cluster upgrade automation | Multi-node DAG: drain->upgrade->uncordon->verify per node, with rollback on failure |
| Coordinated backup verification | DAG: all backups in parallel->verify all succeeded->notify. Retry individual failures |
| CI/CD pipelines (replace GitLab Runner) | Buildkit image builds on K8s, artifact passing, native K8s scheduling |
| Load testing | Parameterized workflows, multiple parallel workers, aggregate results |

---

## 5.9.3 Migration Wave 1 - vault-snapshot

> **Rationale:** vault-snapshot is the highest-value migration. The current CronJob
> runs a single container with a shell script using `set -e`. If `vault login` fails,
> `set -e` aborts the entire script (exit non-zero). The job fails but there is no
> Discord notification, so failures go undetected. A DAG makes the
> dependency explicit and adds failure alerting via exit handler.

### Behavior parity with existing CronJob

The migration preserves current behavior exactly:
- **Retention:** 3 days (`find -mtime +3 -delete`). The restic off-site job relies
  on this window. Do **not** change to a count-based policy.
- **Filename:** `vault-YYYYMMDD.snap` (date only). Changing to HH:MM:SS timestamps
  would break restic deduplication.
- **Active deadline:** 120s at Workflow level (matches current CronJob).
- **Concurrency:** `Forbid` at CronWorkflow level (matches current).
- **SA name:** new SA `vault-snapshot-workflow` in `argo-workflows` namespace
  (the existing `vault:vault-snapshot` SA stays in place until rollback cutoff).

### DAG Design

```
vault-snapshot  (login to Vault via K8s auth + raft snapshot -> NFS)
    |
    v
vault-prune     (delete snapshots older than 3 days on NFS)

onExit handler:
notify-on-failure  (fires only when workflow.status != Succeeded)
```

> **Why two steps, not three?** An earlier draft had a separate `vault-login`
> step, but Argo Workflows DAG nodes are separate pods - a Vault client token
> written to `/tmp` in pod 1 is not visible to pod 2. Passing the token via
> workflow output parameters serialises the secret into the workflow status
> object (visible to anyone with read access to the CRD). Combining login and
> snapshot into one container keeps the token ephemeral to a single pod, which
> matches the security posture of the original CronJob. The DAG still models
> the real dependency: `prune` must not run before `snapshot` succeeded.

### Vault Kubernetes auth role creation (MANUAL)

> **Chosen approach:** a parallel role `vault-snapshot-argo` that reuses the
> existing `vault-snapshot` policy but is bound only to the new SA. The
> legacy `vault-snapshot` role stays in place until the old CronJob is
> removed in 5.9.3.10. Both can run side-by-side during cutover. The
> WorkflowTemplate's snapshot step already hard-codes `role=vault-snapshot-argo`.

- [ ] 5.9.3.0 Create the parallel Vault Kubernetes auth role
  ```bash
  # MUST be run by the user in a terminal with `vault` CLI + admin token.
  # Claude does not have (and must never see) Vault credentials.
  vault write auth/kubernetes/role/vault-snapshot-argo \
    bound_service_account_names=vault-snapshot-workflow \
    bound_service_account_namespaces=argo-workflows \
    policies=vault-snapshot \
    ttl=5m

  # Verify:
  vault read auth/kubernetes/role/vault-snapshot-argo
  ```

- [ ] 5.9.3.11 Remove the legacy role after the old CronJob is gone
  ```bash
  # Only after 5.9.3.10 (old PV/PVC removed). No pods still use the
  # legacy role at this point.
  vault delete auth/kubernetes/role/vault-snapshot
  ```

### Vault CNP ingress rule (already in the diff)

`manifests/vault/networkpolicy.yaml` was patched under `vault-server-ingress`
to allow `io.kubernetes.pod.namespace: argo-workflows` with label
`app.kubernetes.io/component: vault-snapshot-workflow` to reach `:8200`.
Without this rule Cilium would drop the snapshot step's calls to Vault.

### Manifests

All manifests are scaffolded under `manifests/argo-workflows/` and referenced by
`manifests/argocd/apps/argo-workflows-manifests.yaml` (Git-type Application,
recurse: true).

- [x] 5.9.3.1 WorkflowTemplate `manifests/argo-workflows/templates/vault-snapshot-template.yaml`
  - entrypoint: `vault-snapshot-dag`
  - onExit: `notify-on-failure` (uses `when:` to fire only on non-success)
  - `activeDeadlineSeconds: 120`
  - `ttlStrategy: { secondsAfterCompletion: 86400, secondsAfterSuccess: 86400, secondsAfterFailure: 259200 }`
  - `podGC: { strategy: OnPodSuccess }`
  - Labels on each template pod so CNP can target them:
    `app.kubernetes.io/component: vault-snapshot-workflow`
  - Reuses same NFS PV/PVC (`vault-snapshots` created in `argo-workflows` ns
    pointing at the same NAS path `/Kubernetes/Backups/vault`).
  - Image pins: `hashicorp/vault:1.21.4` (snapshot step - login + raft snapshot
    in one container), `alpine/k8s:1.35.3` (prune + notify steps).

- [x] 5.9.3.2 CronWorkflow `manifests/argo-workflows/cronworkflows/vault-snapshot-cron.yaml`
  - `schedule: "0 2 * * *"` (matches current)
  - `timezone: "Asia/Manila"`
  - `concurrencyPolicy: Forbid`
  - `startingDeadlineSeconds: 3600`
  - `successfulJobsHistoryLimit: 3`
  - `failedJobsHistoryLimit: 3`
  - `workflowSpec.workflowTemplateRef.name: vault-snapshot`

- [x] 5.9.3.3 RBAC `manifests/argo-workflows/rbac/vault-snapshot-rbac.yaml`
  - ServiceAccount `vault-snapshot-workflow` in `argo-workflows`
  - Role grants `get` on the specific `discord-webhooks` Secret (for the notify
    step's `secretKeyRef`), plus `create/patch` on `workflowtaskresults` and
    `get/watch` on `pods/log` required by the argoexec sidecar.
  - No cluster-level permissions. Vault Kubernetes auth binding is configured
    on the Vault side (step 5.9.3.0), not via K8s RBAC.

- [x] 5.9.3.4 NFS PV/PVC `manifests/argo-workflows/pv-pvc.yaml`
  - PV `vault-snapshots-argo-nfs` (different name than `vault-snapshots-nfs` to
    avoid conflict with the in-use vault namespace PV during migration)
  - PVC `vault-snapshots` in `argo-workflows` (same mount path/server as existing,
    so both the old CronJob and new Workflow write to the same NFS directory)
  - StorageClass: `nfs`, AccessMode: `RWX`, Retain policy, explicit `claimRef`
    + `volumeName` for deterministic binding.

- [x] 5.9.3.5 ExternalSecret `manifests/argo-workflows/externalsecret-discord.yaml`
  - Pulls `secret/monitoring/discord-webhooks` property `incidents`
  - Target: `discord-webhooks` Secret in `argo-workflows` ns, key `incidents`
  - Refresh 1h, creationPolicy Owner (matches monitoring pattern)

### Cutover procedure

- [ ] 5.9.3.6 Trigger a manual Workflow run (BEFORE disabling the old CronJob)
  ```bash
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

  kubectl-homelab get pods -n argo-workflows -w
  # Watch: login pod Completed -> snapshot pod Completed -> prune pod Completed
  # Expect no notify-on-failure pod (workflow succeeded).

  kubectl-homelab get workflows -n argo-workflows
  # STATUS: Succeeded
  ```

- [ ] 5.9.3.7 Verify a new snapshot file appeared on the NAS
  ```bash
  sudo mount -t nfs4 10.10.30.4:/Kubernetes /tmp/nfs
  ls -lh /tmp/nfs/Backups/vault/vault-$(date +%Y%m%d).snap
  sudo umount /tmp/nfs
  # Expected: file size > 0, owner uid 65534
  ```

- [ ] 5.9.3.8 Suspend the old CronJob (do not delete yet)
  ```bash
  kubectl-admin patch cronjob vault-snapshot -n vault \
    -p '{"spec":{"suspend":true}}'
  # Let the CronWorkflow run on its 02:00 schedule for a day or two;
  # confirm in ArgoCD UI that the argo-workflows-manifests app stays Healthy.
  ```

- [ ] 5.9.3.9 Remove the old vault-snapshot CronJob
  Delete the relevant stanzas in `manifests/vault/snapshot-cronjob.yaml`:
  - Keep the PV `vault-snapshots-nfs` and PVC `vault-snapshots` in the `vault`
    namespace until step 5.9.3.10 (ArgoCD prune would otherwise blow them away
    while the argo-workflows PV hasn't mounted yet).
  - Remove the CronJob and ServiceAccount stanzas.
  - Commit, let ArgoCD sync, verify the CronJob resource disappeared.

- [ ] 5.9.3.10 Remove the now-unused NFS PV/PVC in the `vault` namespace
  After 5-7 days of successful CronWorkflow runs, delete the vault-namespace
  PV/PVC stanzas from `manifests/vault/snapshot-cronjob.yaml`. The NFS export
  on the NAS is not affected - only the PV/PVC K8s objects are removed. The
  argo-workflows PV continues to mount the same NAS path.

---

## 5.9.4 Wave 2 - Backup Failure Alerts - ALREADY COVERED

> **Audit finding (2026-04-14):** The earlier draft of this phase assumed none
> of the backup CronJobs had failure alerting. That assumption is wrong.
> `manifests/monitoring/alerts/backup-alerts.yaml` already defines a
> `CronJobFailed` rule with `kube_job_status_failed{namespace!=""} > 0`
> for 15m - this matches every failing Job in every namespace, including
> every backup CronJob listed in 5.9.2. `CronJobNotScheduled` covers missed
> schedules. No new rules are needed.
>
> **Action:** delete this section at plan-closeout time. It is retained here
> only so the Wave 2 reasoning is visible in review.

- [x] 5.9.4.1 ~~BackupJobFailed PrometheusRule~~ - covered by existing
  `backup-alerts.yaml:CronJobFailed` (generic to all namespaces).
- [x] 5.9.4.2 ~~CronJob missed-schedule alert~~ - covered by existing
  `backup-alerts.yaml:CronJobNotScheduled`.

Note: `CronJobFailed` / `CronJobNotScheduled` rely on `kube_job_status_failed`
and `kube_cronjob_status_last_successful_time` (kube-state-metrics). These
are **not** emitted for `CronWorkflow`-created Workflows (different CRD,
different pod owner). The new Argo Workflows rules in 5.9.6.2 cover workflow
failures separately via `argo_workflows_count{status="Failed"}`.

---

## 5.9.5 Future Use Cases

> Deferred until Phase 5.9+ use cases materialize. Documented here for planning.

### Cluster Upgrade Automation

When K8s 1.36 ships, a ClusterUpgrade workflow can replace the manual upgrade
runbook in `docs/context/Upgrades.md`:

```
drain-cp1 -> upgrade-cp1 -> uncordon-cp1
                                |
                            drain-cp2 -> upgrade-cp2 -> uncordon-cp2
                                                             |
                                                         drain-cp3 -> upgrade-cp3 -> uncordon-cp3
                                                                                          |
                                                                                      verify-cluster
```

Exit handler posts to Discord `#infra` on failure with node identity.
DAG enforces upgrade sequence - no manual gating needed.

### CI/CD Pipeline Migration

Replace GitLab Runner with Argo Workflows for homelab image builds:
- Buildkit as a workflow step (no privileged runner needed)
- Artifact passing via S3-compatible store (Garage)
- Native K8s scheduling - no separate runner VM overhead
- WorkflowTemplates as reusable build steps (lint, test, build, push)

### Coordinated Backup Verification

Weekly CronWorkflow:
```
[all backups in parallel] -> verify-all-succeeded -> report-to-discord
```
Uses `withItems` over backup list. Retry policy on individual failures.
Single Discord notification with aggregate pass/fail instead of per-job alerts.

---

## 5.9.6 Monitoring

### 5.9.6.1 ServiceMonitor

- [x] 5.9.6.1a `manifests/monitoring/servicemonitors/argo-workflows-servicemonitor.yaml`
  - Scrapes `argo-workflows-workflow-controller-metrics` svc on port `metrics`
    (9090/TCP inside the argo-workflows namespace).
  - Label `release: prometheus` for Prometheus Operator selector.

### 5.9.6.2 PrometheusRules

- [x] 5.9.6.2a `manifests/monitoring/alerts/argo-workflows-alerts.yaml`
  Rules scaffolded (4):
  - `ArgoWorkflowsControllerDown` - `up{job=~".*argo-workflows.*workflow-controller.*"} == 0` for 5m, critical
  - `ArgoWorkflowFailed` - `sum by (name, namespace) (argo_workflows_count{status="Failed"}) > 0` for 5m, warning
  - `ArgoWorkflowError` - same, but `status="Error"` (infra failure vs step failure)
  - `VaultSnapshotStale` - no successful vault-snapshot workflow in 26+ hours

### 5.9.6.3 Grafana Dashboard

- [x] 5.9.6.3a `manifests/monitoring/dashboards/argo-workflows-dashboard-configmap.yaml`
  A minimal 4-row starter is already scaffolded:
  - Row 1: Pod Status (workflow-controller + CRD count)
  - Row 2: Workflow Execution (status breakdown + duration p95)
  - Row 3: CronWorkflow triggered-count
  - Row 4: Resource Usage (CPU/Memory with request/limit lines)

  **Expand after the first Prometheus scrape lands.** The PromQL used in the
  starter was written against documented metric names but not verified against
  a live scrape (the chart isn't deployed yet). Once `argo_workflows_*`
  metrics appear in Prometheus, iterate on panel queries and add:
  - Per-template success/failure pie
  - Queue depth (`argo_workflows_queue_depth_count`)
  - Pod phase distribution (`argo_pod_phase`)
  - Workflow leaderboard (longest recent runs)

---

## Verification Checklist

**Deployment:**
- [ ] `argo-workflows` namespace exists with PSS baseline + eso-enabled labels
- [ ] workflow-controller pod Running 1/1
- [ ] argo-server NOT deployed (headless mode confirmed)
- [ ] CRDs registered: workflows, cronworkflows, workflowtemplates, workflowtaskresults, workflowtasksets, workflowartifactgctasks, clusterworkflowtemplates, workfloweventbindings

**Wave 1 - vault-snapshot:**
- [ ] Vault K8s auth role updated to trust `argo-workflows:vault-snapshot-workflow`
- [ ] vault-snapshot WorkflowTemplate deployed
- [ ] vault-snapshot CronWorkflow deployed and scheduled
- [ ] Manual test run completed with status Succeeded
- [ ] All 3 DAG steps (login, snapshot, prune) completed in order
- [ ] Old vault-snapshot CronJob suspended (then removed after 5-7 days)
- [ ] NFS snapshot file `vault-YYYYMMDD.snap` present on NAS (owner uid 65534)
- [ ] Old-path PV/PVC cleanup (`manifests/vault/snapshot-cronjob.yaml`) committed

**Wave 2 - Backup Alerts (mooted - existing coverage confirmed):**
- [ ] Verify `backup-alerts.yaml:CronJobFailed` is loaded in Prometheus
  and has fired at least once historically (i.e. regex works).
- [ ] Confirm the Alertmanager route used by `severity=warning,category=`
  (no category set) still delivers to `#apps`.

**Networking:**
- [ ] CiliumNetworkPolicies applied for argo-workflows namespace
- [ ] controller can reach kube-apiserver:6443 (via `kube-apiserver` entity)
- [ ] argoexec can reach workflow-controller:9090 (progress reports)
- [ ] Prometheus scrapes controller:9090 metrics
- [ ] vault-snapshot workflow pods can reach vault.vault.svc:8200
- [ ] notify-on-failure pods can reach discord.com:443 (FQDN egress + DNS rule)

**Monitoring:**
- [ ] ServiceMonitor for workflow-controller scraping successfully
- [ ] Alert: CronWorkflow missed schedule (absent for >2 scheduled intervals)
- [ ] Alert: Workflow failed (workflow_status=Failed count > 0)
- [ ] Grafana dashboard deployed with workflow success/failure rates

**Security:**
- [ ] controller runs as non-root (runAsUser: 1000)
- [ ] argoexec uses `-nonroot` image tag
- [ ] workflow ServiceAccounts have minimal RBAC (no cluster-admin)
- [ ] No secrets in WorkflowTemplate specs (all via secretKeyRef)

**GitOps:**
- [ ] ArgoCD Application `argo-workflows` (Helm) Synced/Healthy
- [ ] ArgoCD Application `argo-workflows-manifests` (Git) Synced/Healthy
- [ ] CronWorkflows managed via ArgoCD (no kubectl apply outside Git)

---

## Rollback

**If the migration needs to be reversed before 5.9.3.10 cleanup:**
1. Re-enable the old CronJob: `kubectl-admin patch cronjob vault-snapshot -n vault -p '{"spec":{"suspend":false}}'`
2. Delete the CronWorkflow (keeps template + RBAC): `kubectl-admin delete cronworkflow vault-snapshot -n argo-workflows`
3. Or revert the ArgoCD apps - delete both Applications below - to remove the entire Argo Workflows install while keeping the NFS snapshot directory intact.

**Remove Argo Workflows entirely:**
```bash
# Delete ArgoCD Applications (prune removes all managed resources)
kubectl-admin delete application argo-workflows-manifests -n argocd
kubectl-admin delete application argo-workflows -n argocd

# If ArgoCD Applications are gone, Helm release can be removed directly via
# Secret deletion (NEVER `helm uninstall` - see gotchas in CLAUDE.md):
kubectl-admin delete secret -n argo-workflows -l name=argo-workflows,owner=helm

# Remove CRDs (blocks deletion of all Workflow/CronWorkflow/WorkflowTemplate objects)
kubectl-admin delete crd \
  workflows.argoproj.io \
  cronworkflows.argoproj.io \
  workflowtemplates.argoproj.io \
  workflowtaskresults.argoproj.io \
  workflowtasksets.argoproj.io \
  workflowartifactgctasks.argoproj.io \
  workfloweventbindings.argoproj.io \
  clusterworkflowtemplates.argoproj.io

# Remove namespace
kubectl-admin delete namespace argo-workflows

# Restore the old CronJob manifest if it was already pruned
kubectl-admin apply -f manifests/vault/snapshot-cronjob.yaml

# Remove the argo-workflows ns from the infrastructure AppProject destinations.
```

**CiliumNP too restrictive (symptoms: workflow pods fail to call Vault or Discord):**
```bash
# Temporarily drop the workflow-level policy to isolate whether CNP is at fault:
kubectl-admin delete ciliumnetworkpolicy argo-workflows-vault-snapshot -n argo-workflows
# Re-run the workflow. If it succeeds, the CNP rules are wrong - fix them and re-apply.
# The default-deny policy should stay in place throughout.
```

---

## Final: Commit and Release

- [ ] `/audit-security` then `/commit`
- [ ] `/audit-docs` then `/commit`
- [ ] `/ship v0.39.0 "Argo Workflows"`
- [ ] `mv docs/todo/phase-5.9-argo-workflows.md docs/todo/completed/`
