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
    pod-security.kubernetes.io/warn=restricted \
    eso-enabled="true"
  ```

- [ ] 5.9.1.1a Update infrastructure AppProject destinations
  ```yaml
  # manifests/argocd/appprojects.yaml - add to infrastructure project destinations:
  - namespace: argo-workflows
    server: https://kubernetes.default.svc
  ```

- [ ] 5.9.1.2 Create LimitRange and ResourceQuota
  ```bash
  # manifests/argo-workflows/limitrange.yaml
  # manifests/argo-workflows/resourcequota.yaml
  # controller: 200m CPU request, 500m limit, 256Mi request, 512Mi limit
  # workflow pods: 100m CPU request, 500m limit, 128Mi request, 512Mi limit
  ```

- [ ] 5.9.1.2a Create ESO ExternalSecret for Discord webhook
  ```yaml
  # manifests/argo-workflows/externalsecret-discord.yaml
  # Pulls monitoring/discord-webhooks from Vault
  # Target Secret: discord-webhooks in argo-workflows namespace
  # Keys: incidents (used by vault-snapshot exit handler)
  # Requires: eso-enabled label on namespace (step 5.9.1.1)
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
| version-check/Nova | kube-system | Weekly | Single step | None | Keep CronJob |
| cert-expiry-check | cert-manager | Weekly | Single step | None | Keep CronJob |
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

**2. Backup failure notification gap (MEDIUM) - Wave 2:**
The 9 ARR backup CronJobs and other single-step backup CronJobs have no failure
alerting. Rather than migrating them to CronWorkflows (which adds per-step pod
overhead with no orchestration benefit), add Prometheus `kube_job_status_failed`
alerts. See section 5.9.4 for details.

**3. Prometheus backup failure alerts (MEDIUM) - Wave 2:**
None of the single-step backup CronJobs (9 ARR backups + ghost-mysql, atuin,
adguard, myspeed, karakeep, grafana, uptime-kuma, invoicetron-db) currently send
alerts on failure. Prometheus `kube_job_status_failed` alerts are the right
approach - lower overhead than CronWorkflow migration for atomic scripts.

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
            - |
              SA_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
              VAULT_TOKEN=$(vault write -field=token auth/kubernetes/login \
                role=vault-snapshot jwt=$SA_TOKEN)
              echo "$VAULT_TOKEN" > /tmp/vault-token
              vault token lookup
          env:
            - name: VAULT_ADDR
              value: "http://vault.vault.svc.cluster.local:8200"

      - name: vault-snapshot-step
        container:
          image: hashicorp/vault:<version>
          command: [sh, -c]
          args:
            - |
              export VAULT_TOKEN=$(cat /tmp/vault-token)
              vault operator raft snapshot save /snapshots/vault-$(date +%Y%m%d-%H%M%S).snap
          env:
            - name: VAULT_ADDR
              value: "http://vault.vault.svc.cluster.local:8200"
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
  # Role: get/list secrets in argo-workflows namespace (discord-webhooks)
  # ClusterRoleBinding: system:auth-delegator (for Vault Kubernetes auth)
  # No cluster-level permissions needed for NFS (volume, no PVC)
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

## 5.9.4 Wave 2 - Backup Failure Alerts

> **Rationale:** None of the single-step backup CronJobs have failure alerting today.
> Prometheus `kube_job_status_failed` alerts are the right approach - lower overhead
> than migrating atomic scripts to CronWorkflows.

- [ ] 5.9.4.1 Create PrometheusRule for backup CronJob failures
  ```yaml
  # manifests/monitoring/alerts/backup-alerts.yaml
  apiVersion: monitoring.coreos.com/v1
  kind: PrometheusRule
  metadata:
    name: backup-job-alerts
    namespace: monitoring
    labels:
      release: prometheus
  spec:
    groups:
      - name: backup-jobs
        rules:
          - alert: BackupJobFailed
            expr: |
              kube_job_status_failed{
                job_name=~"(arr-backup|adguard-backup|myspeed-backup|karakeep-backup|grafana-backup|uptime-kuma-backup|ghost-mysql-backup|invoicetron-db-backup|atuin-backup|etcd-backup|pki-backup).*"
              } > 0
            for: 5m
            labels:
              severity: warning
              category: backup
            annotations:
              summary: "Backup job {{ $labels.job_name }} failed"
              description: "Backup job {{ $labels.job_name }} in {{ $labels.namespace }} has failed."
  ```

- [ ] 5.9.4.2 Verify alerts load in Prometheus
  ```bash
  # After applying, check Prometheus targets
  kubectl-homelab port-forward svc/prometheus-operated -n monitoring 9090:9090
  # Open http://localhost:9090/alerts and search for BackupJobFailed
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

**Wave 2 - Backup Alerts:**
- [ ] PrometheusRule backup-job-alerts loaded in Prometheus
- [ ] Test: trigger a backup job failure, verify alert fires
- [ ] Discord notification received via Alertmanager route

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

# arr-backup CronJobs are per-app in manifests/arr-stack/backup/ (not migrated)
# No rollback needed for backup CronJobs - they remain as native CronJobs
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
