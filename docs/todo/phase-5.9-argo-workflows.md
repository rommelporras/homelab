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

---

## 5.9.0 Pre-Installation

> **Gate:** ArgoCD must be stable and all Phase 5.8 migrations confirmed healthy
> before adding another CRD-heavy workload.

- [ ] 5.9.0.1 Verify ArgoCD is stable and all Applications are Synced/Healthy
  ```bash
  kubectl-homelab get applications -n argocd
  # Expected: all SYNCED and Healthy

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

- [ ] 5.9.0.3 Verify argo Helm repo is available
  ```bash
  helm-homelab repo add argo https://argoproj.github.io/argo-helm
  helm-homelab repo update
  helm-homelab search repo argo/argo-workflows --versions | head -10
  # Record: CHART_VERSION=<version> APP_VERSION=<version>
  ```

- [ ] 5.9.0.4 Verify VAP allows Argo Workflows images (dry-run)
  ```bash
  # argoexec nonroot image comes from quay.io/argoproj/
  kubectl-admin run test-argoexec \
    --image=quay.io/argoproj/argoexec:v3.6.0-nonroot \
    --dry-run=server -n default
  # Expected: pod created (dry-run), no VAP denial
  ```

---

## 5.9.1 Installation

> **Mode:** Headless (no argo-server UI). Saves ~100m CPU and ~128Mi memory.
> The argo CLI and ArgoCD UI cover all operational needs.
> **Namespace:** `argo-workflows` (separate from `argocd` - different lifecycle and RBAC).
> **Image:** Non-root argoexec: `quay.io/argoproj/argoexec:<version>-nonroot`

- [ ] 5.9.1.1 Create namespace and PSS label
  ```bash
  kubectl-admin create namespace argo-workflows
  kubectl-admin label namespace argo-workflows \
    pod-security.kubernetes.io/enforce=baseline \
    pod-security.kubernetes.io/warn=restricted
  ```

- [ ] 5.9.1.2 Create LimitRange and ResourceQuota
  ```bash
  # manifests/argo-workflows/limitrange.yaml
  # manifests/argo-workflows/resourcequota.yaml
  # controller: 200m CPU request, 500m limit, 256Mi request, 512Mi limit
  # workflow pods: 100m CPU request, 500m limit, 128Mi request, 512Mi limit
  ```

- [ ] 5.9.1.3 Create Helm values file
  ```yaml
  # helm/argo-workflows/values.yaml
  controller:
    replicas: 1
    image:
      tag: <version>  # pin exact version
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
      limits:
        cpu: 500m
        memory: 512Mi
    securityContext:
      runAsNonRoot: true
      runAsUser: 1000
      allowPrivilegeEscalation: false
      capabilities:
        drop: ["ALL"]

  # Disable argo-server UI to save resources
  server:
    enabled: false

  executor:
    image:
      registry: quay.io
      repository: argoproj/argoexec
      tag: <version>-nonroot  # non-root argoexec
    resources:
      requests:
        cpu: 50m
        memory: 64Mi
      limits:
        cpu: 500m
        memory: 512Mi

  workflow:
    serviceAccount:
      create: true
    rbac:
      create: true

  # PSS: no privileged containers, host namespaces, etc.
  useDefaultArtifactRepo: false
  artifactRepository: {}
  ```

- [ ] 5.9.1.4 Install via ArgoCD (dog-fooding GitOps)
  ```yaml
  # manifests/argocd/apps/argo-workflows.yaml
  apiVersion: argoproj.io/v1alpha1
  kind: Application
  metadata:
    name: argo-workflows
    namespace: argocd
  spec:
    project: infrastructure
    sources:
      - repoURL: https://argoproj.github.io/argo-helm
        chart: argo-workflows
        targetRevision: <chart-version>
        helm:
          valueFiles:
            - $values/helm/argo-workflows/values.yaml
      - repoURL: https://github.com/rommelporras/homelab.git
        targetRevision: main
        ref: values
    destination:
      server: https://kubernetes.default.svc
      namespace: argo-workflows
    syncPolicy:
      automated:
        prune: true
        selfHeal: true
      syncOptions:
        - CreateNamespace=false
        - ServerSideApply=true
  ```

- [ ] 5.9.1.5 Deploy and verify controller is running
  ```bash
  kubectl-homelab get pods -n argo-workflows
  # Expected: workflow-controller Running 1/1

  kubectl-homelab get crd | grep argoproj.io
  # Expected: workflows.argoproj.io, cronworkflows.argoproj.io,
  #           workflowtemplates.argoproj.io, workflowartifactgctasks.argoproj.io
  ```

- [ ] 5.9.1.6 Apply CiliumNetworkPolicy
  ```yaml
  # manifests/argo-workflows/ciliumnetworkpolicy.yaml
  # Rules:
  # - workflow-controller egress to kube-apiserver:6443 (reconcile CRDs)
  # - argoexec (workflow pods) egress to workflow-controller:9090 (progress reports)
  # - argoexec egress to kube-apiserver:6443 (read secrets for workflow inputs)
  # - Prometheus ingress to workflow-controller:9090 (metrics scrape)
  # - ArgoCD repo-server egress to workflow-controller (health checks)
  ```

---

## 5.9.2 CronJob Analysis

> **Evaluation complete (March 2026):** All 23 current cluster CronJobs analyzed
> against Argo Workflows capabilities.

Architecture overview: workflow-controller (reconciles CRDs) + argoexec sidecar
(runs in each workflow pod for progress reporting). argo-server (UI/API) is optional
and disabled in this deployment to save resources.

### Full CronJob Evaluation

| CronJob | Schedule | Complexity | AW Benefit | Verdict |
|---------|----------|------------|------------|---------|
| cluster-janitor | 10 min | Single step | None | Keep CronJob |
| arr-stall-resolver | 30 min | Single step | None | Keep CronJob |
| arr-backup-cp1 | Daily | Single step | Parallel DAG | Marginal |
| arr-backup-cp2 | Daily | Single step | Parallel DAG | Marginal |
| arr-backup-cp3 | Daily | Single step | Parallel DAG | Marginal |
| adguard-backup | Daily | Single step | None | Keep CronJob |
| myspeed-backup | Daily | Single step | None | Keep CronJob |
| karakeep-backup | Daily | Single step | None | Keep CronJob |
| grafana-backup | Daily | Single step | None | Keep CronJob |
| uptime-kuma-backup | Daily | Single step | None | Keep CronJob |
| ghost-mysql-backup | Daily | Single step | None | Keep CronJob |
| invoicetron-db-backup | Daily | Single step | None | Keep CronJob |
| atuin-backup | Weekly | Single step | None | Keep CronJob |
| etcd-backup | Daily | Single step | None | Keep CronJob |
| vault-snapshot | Daily | Multi-step | DAG + exit handler | MIGRATE |
| configarr | Daily | Single step | None | Keep CronJob |
| version-check/Nova | Weekly | Single step | None | Keep CronJob |
| cert-expiry-check | Weekly | Single step | None | Keep CronJob |
| pki-backup | Weekly | Single step | None | Keep CronJob |
| Longhorn recurring (4) | Longhorn-native | N/A | N/A | Keep Longhorn |

**Result:** 1 of 23 current CronJobs (vault-snapshot) materially benefits from
migration. The arr-backup trio benefits marginally from parallelism. All others
are single-step tasks with no inter-dependencies.

### Strongest Candidates

**1. vault-snapshot (HIGH value) - Wave 1:**
Multi-step dependency `login -> snapshot -> prune` maps cleanly to a DAG.
Current shell script uses `set -e` so login failure silently skips snapshot.
DAG makes ordering explicit with exit handler for Discord notification on failure.

**2. arr-backup-cp1/2/3 consolidation (MEDIUM) - Wave 2:**
3 CronJobs become 1 CronWorkflow with parallel DAG tasks, one per node
(nodeSelector per step). Reduces CronJob count by 2 and adds failure notification
via shared WorkflowTemplate exit handler pattern.

**3. Backup failure notification gap (MEDIUM) - Wave 2:**
None of the 8 single-step backup CronJobs (ghost-mysql, atuin, adguard, myspeed,
karakeep, grafana, uptime-kuma, invoicetron-db) currently send Discord alerts on
failure. Argo exit handler pattern with `{{workflow.status}}` closes this for all
at once via a shared WorkflowTemplate.

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
> the snapshot step is silently skipped with no notification. A DAG makes the
> dependency explicit and adds failure alerting via exit handler.

### DAG Design

```
vault-login
    |
    v
vault-snapshot
    |
    v
vault-prune-old-snapshots
    |
    v (always, via exit handler)
discord-notify (on failure only)
```

- [ ] 5.9.3.1 Create WorkflowTemplate for vault-snapshot
  ```yaml
  # manifests/argo-workflows/templates/vault-snapshot-template.yaml
  apiVersion: argoproj.io/v1alpha1
  kind: WorkflowTemplate
  metadata:
    name: vault-snapshot
    namespace: argo-workflows
  spec:
    entrypoint: vault-snapshot-dag
    onExit: notify-on-failure
    serviceAccountName: vault-snapshot-workflow
    templates:
      - name: vault-snapshot-dag
        dag:
          tasks:
            - name: login
              template: vault-login
            - name: snapshot
              template: vault-snapshot-step
              dependencies: [login]
            - name: prune
              template: vault-prune
              dependencies: [snapshot]

      - name: vault-login
        container:
          image: hashicorp/vault:<version>
          command: [sh, -c]
          args:
            - vault login -method=token token=$VAULT_TOKEN
          env:
            - name: VAULT_ADDR
              value: "http://vault.vault.svc.cluster.local:8200"
            - name: VAULT_TOKEN
              valueFrom:
                secretKeyRef:
                  name: vault-snapshot-token
                  key: token

      - name: vault-snapshot-step
        container:
          image: hashicorp/vault:<version>
          command: [sh, -c]
          args:
            - vault operator raft snapshot save /snapshots/vault-$(date +%Y%m%d-%H%M%S).snap
          volumeMounts:
            - name: snapshots
              mountPath: /snapshots

      - name: vault-prune
        container:
          image: alpine/k8s:<version>
          command: [sh, -c]
          args:
            - ls -t /snapshots/vault-*.snap | tail -n +8 | xargs rm -f
          volumeMounts:
            - name: snapshots
              mountPath: /snapshots

      - name: notify-on-failure
        container:
          image: curlimages/curl:<version>
          command: [sh, -c]
          args:
            - |
              if [ "{{workflow.status}}" != "Succeeded" ]; then
                curl -s -X POST $DISCORD_WEBHOOK \
                  -H "Content-Type: application/json" \
                  -d "{\"content\":\"vault-snapshot workflow {{workflow.status}} at {{workflow.finishedAt}}\"}"
              fi
          env:
            - name: DISCORD_WEBHOOK
              valueFrom:
                secretKeyRef:
                  name: discord-webhooks
                  key: incidents

    volumes:
      - name: snapshots
        nfs:
          server: 10.10.30.4
          path: /export/Kubernetes/Backups/vault
  ```

- [ ] 5.9.3.2 Create CronWorkflow to schedule the template
  ```yaml
  # manifests/argo-workflows/cronworkflows/vault-snapshot-cron.yaml
  apiVersion: argoproj.io/v1alpha1
  kind: CronWorkflow
  metadata:
    name: vault-snapshot
    namespace: argo-workflows
  spec:
    schedule: "0 2 * * *"  # 02:00 Asia/Manila daily
    timezone: "Asia/Manila"
    concurrencyPolicy: Forbid
    startingDeadlineSeconds: 3600
    workflowSpec:
      workflowTemplateRef:
        name: vault-snapshot
  ```

- [ ] 5.9.3.3 Create RBAC for vault-snapshot workflow ServiceAccount
  ```yaml
  # manifests/argo-workflows/rbac/vault-snapshot-rbac.yaml
  # ServiceAccount: vault-snapshot-workflow in argo-workflows namespace
  # Role: get/list secrets in argo-workflows namespace (vault-snapshot-token)
  # No cluster-level permissions needed (NFS volume, no PVC)
  ```

- [ ] 5.9.3.4 Remove the old vault-snapshot CronJob
  ```bash
  # Verify new CronWorkflow ran successfully first
  kubectl-homelab get cronworkflow vault-snapshot -n argo-workflows
  kubectl-homelab get workflows -n argo-workflows --sort-by=.metadata.creationTimestamp

  # Then delete old CronJob
  kubectl-admin delete cronjob vault-snapshot -n vault
  ```

- [ ] 5.9.3.5 Verify first CronWorkflow run
  ```bash
  # Trigger manual run to validate
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
  # Watch: login pod completes, then snapshot pod, then prune pod
  # All should reach Completed state

  kubectl-homelab get workflow -n argo-workflows
  # Expected: Succeeded
  ```

---

## 5.9.4 Migration Wave 2 - Backup CronJobs

> **Rationale:** Three separate arr-backup CronJobs (cp1, cp2, cp3) run identical
> logic on different nodes. Consolidating into one CronWorkflow reduces resource
> overhead and enables parallel execution. The shared exit handler pattern also
> closes the Discord notification gap for all 8 single-step backup CronJobs.

### Shared Notify WorkflowTemplate

- [ ] 5.9.4.1 Create shared notify-on-failure WorkflowTemplate
  ```yaml
  # manifests/argo-workflows/templates/notify-on-failure.yaml
  # Reusable exit handler: posts to Discord incidents webhook if
  # {{workflow.status}} != "Succeeded"
  # Used by: arr-backup-cron, any future workflow needing failure alerts
  ```

### ARR Backup Consolidation

- [ ] 5.9.4.2 Create arr-backup WorkflowTemplate with parallel DAG
  ```yaml
  # manifests/argo-workflows/templates/arr-backup-template.yaml
  # DAG tasks: backup-cp1, backup-cp2, backup-cp3 (all parallel, no dependencies)
  # Each task uses nodeSelector to target its specific node
  # onExit: notify-on-failure (shared template ref)
  #
  # Task node affinity example:
  #   nodeSelector:
  #     kubernetes.io/hostname: cp1
  ```

- [ ] 5.9.4.3 Create arr-backup CronWorkflow
  ```yaml
  # manifests/argo-workflows/cronworkflows/arr-backup-cron.yaml
  # Schedule: same as existing arr-backup-cp1 (daily 03:00 Asia/Manila)
  # concurrencyPolicy: Forbid
  # workflowTemplateRef: arr-backup
  ```

- [ ] 5.9.4.4 Remove old arr-backup-cp{1,2,3} CronJobs after successful test run
  ```bash
  kubectl-admin delete cronjob arr-backup-cp1 arr-backup-cp2 arr-backup-cp3 -n arr-stack
  ```

### Single-Step Backup Failure Notifications

> These 8 CronJobs have no multi-step benefit from Argo Workflows, but they have
> zero failure notification today. Options: (a) migrate to CronWorkflow with exit
> handler, or (b) add a Prometheus alert on `kube_job_status_failed`. Option (b)
> is lower overhead and avoids unnecessary migration.

- [ ] 5.9.4.5 Decide: Prometheus alert vs CronWorkflow migration for single-step backups
  ```
  Recommended: add kube_job_status_failed alerts in manifests/monitoring/alerts/backup-alerts.yaml
  for ghost-mysql, atuin, adguard, myspeed, karakeep, grafana, uptime-kuma, invoicetron-db.
  Argo migration adds per-step pod overhead with no benefit for atomic scripts.
  ```

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

- [ ] 5.9.6.1a Create ServiceMonitor for workflow-controller
  ```yaml
  # manifests/monitoring/servicemonitors/argo-workflows-servicemonitor.yaml
  apiVersion: monitoring.coreos.com/v1
  kind: ServiceMonitor
  metadata:
    name: argo-workflows-controller
    namespace: monitoring
    labels:
      release: prometheus
  spec:
    namespaceSelector:
      matchNames:
        - argo-workflows
    selector:
      matchLabels:
        app.kubernetes.io/name: argo-workflows-workflow-controller
    endpoints:
      - port: metrics
        interval: 30s
  ```

### 5.9.6.2 PrometheusRules

- [ ] 5.9.6.2a Create alert rules
  ```yaml
  # manifests/monitoring/alerts/argo-workflows-alerts.yaml
  apiVersion: monitoring.coreos.com/v1
  kind: PrometheusRule
  metadata:
    name: argo-workflows-alerts
    namespace: monitoring
    labels:
      release: prometheus
  spec:
    groups:
      - name: argo-workflows
        rules:
          - alert: ArgoWorkflowFailed
            expr: |
              sum by (name, namespace) (argo_workflows_count{status="Failed"}) > 0
            for: 5m
            labels:
              severity: warning
              category: infra
            annotations:
              summary: "Argo Workflow {{ $labels.name }} failed"
              description: "Workflow {{ $labels.name }} in {{ $labels.namespace }} has failed."

          - alert: ArgoWorkflowControllerDown
            expr: |
              up{job=~".*argo-workflows.*"} == 0
            for: 5m
            labels:
              severity: critical
              category: infra
            annotations:
              summary: "Argo Workflows controller is down"
              description: "Workflow controller unreachable for 5 minutes. No workflows can execute."

          - alert: ArgoCronWorkflowMissedSchedule
            expr: |
              time() - argo_workflows_cronworkflows_last_run > 2 * argo_workflows_cronworkflows_schedule_seconds
            for: 10m
            labels:
              severity: warning
              category: infra
            annotations:
              summary: "CronWorkflow {{ $labels.name }} missed schedule"
              description: "CronWorkflow has not run within 2x its expected interval."
  ```

### 5.9.6.3 Grafana Dashboard

- [ ] 5.9.6.3a Create Argo Workflows dashboard
  ```
  Follow homelab convention:
  - Row 1: Pod Status (workflow-controller pod)
  - Row 2: Workflow Execution (success/failure rates, duration histogram)
  - Row 3: CronWorkflow Status (last run time, missed schedules)
  - Row 4: Resource Usage (CPU/Memory with request/limit lines)
  - Descriptions on every panel and row
  - ConfigMap with grafana_dashboard: "1" label, grafana_folder: "Homelab" annotation
  ```

---

## Verification Checklist

**Deployment:**
- [ ] `argo-workflows` namespace exists with PSS baseline label
- [ ] workflow-controller pod Running 1/1
- [ ] argo-server NOT deployed (headless mode confirmed)
- [ ] CRDs registered: workflows, cronworkflows, workflowtemplates

**Wave 1 - vault-snapshot:**
- [ ] vault-snapshot WorkflowTemplate deployed
- [ ] vault-snapshot CronWorkflow deployed and scheduled
- [ ] Manual test run completed with status Succeeded
- [ ] All 3 DAG steps (login, snapshot, prune) completed in order
- [ ] Old vault-snapshot CronJob removed from `vault` namespace
- [ ] NFS snapshot file present at `/export/Kubernetes/Backups/vault/`

**Wave 2 - arr-backup:**
- [ ] arr-backup WorkflowTemplate deployed with parallel DAG
- [ ] arr-backup CronWorkflow deployed and scheduled
- [ ] Manual test run completed - all 3 parallel tasks Succeeded
- [ ] Old arr-backup-cp1/2/3 CronJobs removed from `arr-stack` namespace
- [ ] Shared notify-on-failure WorkflowTemplate deployed

**Networking:**
- [ ] CiliumNetworkPolicy applied for argo-workflows namespace
- [ ] controller can reach kube-apiserver:6443
- [ ] argoexec can reach controller:9090
- [ ] Prometheus scrapes controller:9090 metrics

**Monitoring:**
- [ ] ServiceMonitor for workflow-controller created
- [ ] Alert: CronWorkflow missed schedule (absent for >2 scheduled intervals)
- [ ] Alert: Workflow failed (workflow_status=Failed count > 0)
- [ ] Grafana dashboard deployed with workflow success/failure rates

**Security:**
- [ ] controller runs as non-root (runAsUser: 1000)
- [ ] argoexec uses nonroot image tag
- [ ] workflow ServiceAccounts have minimal RBAC (no cluster-admin)
- [ ] No secrets in WorkflowTemplate specs (all via secretKeyRef)

**GitOps:**
- [ ] ArgoCD Application for argo-workflows is Synced/Healthy
- [ ] CronWorkflows managed via ArgoCD (no kubectl apply outside Git)

---

## Rollback

**Remove Argo Workflows entirely:**
```bash
# Delete ArgoCD Application (removes all managed resources)
kubectl-admin delete application argo-workflows -n argocd

# If ArgoCD Application is gone, uninstall Helm release directly
helm-homelab uninstall argo-workflows -n argo-workflows

# Remove CRDs
kubectl-admin delete crd \
  workflows.argoproj.io \
  cronworkflows.argoproj.io \
  workflowtemplates.argoproj.io \
  workflowartifactgctasks.argoproj.io \
  clusterworkflowtemplates.argoproj.io

# Remove namespace
kubectl-admin delete namespace argo-workflows
```

**Restore migrated CronJobs if rollback needed:**
```bash
# vault-snapshot: re-apply original CronJob manifest
kubectl-admin apply -f manifests/vault/snapshot-cronjob.yaml

# arr-backup: re-apply original 3 CronJob manifests
kubectl-admin apply -f manifests/arr-stack/backup-cronjob-cp1.yaml
kubectl-admin apply -f manifests/arr-stack/backup-cronjob-cp2.yaml
kubectl-admin apply -f manifests/arr-stack/backup-cronjob-cp3.yaml
```

**CiliumNP too restrictive:**
```bash
# Temporarily remove to debug
kubectl-admin delete ciliumnetworkpolicy argo-workflows-default-deny -n argo-workflows
# Re-apply after fixing rules
```

---

## Final: Commit and Release

- [ ] `/audit-security` then `/commit`
- [ ] `/audit-docs` then `/commit`
- [ ] `/release v0.39.0 "Argo Workflows"`
- [ ] `mv docs/todo/phase-5.9-argo-workflows.md docs/todo/completed/`
