# Phase 5.4: Resilience & Backup

> **Status:** Planned
> **Target:** v0.34.0
> **Prerequisite:** Phase 5.3 (v0.33.0 — network policies in place)
> **DevOps Topics:** Resource management, disaster recovery, operational resilience, automation hardening
> **CKA Topics:** ResourceQuota, LimitRange, PodDisruptionBudget, Velero, tolerations, etcd backup, CronJob

> **Purpose:** Survive node failures, recover from disasters, prevent resource exhaustion
>
> **Learning Goal:** Kubernetes resource management and backup/restore strategies

---

## Pre-Work: Cluster Health Baseline

> **Why:** Start from a clean state. Stale pods and existing configurations affect planning.

- [x] 5.4.0.1 ~~Fix existing warning events~~ — **Done in v0.29.1**
  Fixed: Ghost probes (httpGet→tcpSocket), GitLab runner ESO template (empty runner-token),
  Grafana ESO template (static admin-user), Byparr image pin + probe tuning.
  Remaining: verify no new warning events before proceeding.
  ```bash
  # Check for remaining warning events
  kubectl-homelab get events -A --field-selector type=Warning --sort-by='.lastTimestamp' | head -20
  ```

- [ ] 5.4.0.2 Clean up stale pods
  ```bash
  # Check for stuck pods (Init, CrashLoopBackOff, etc.)
  kubectl-homelab get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
  # Resolve any stuck pods before starting resilience work
  ```

- [ ] 5.4.0.3 Fix timezone inconsistency on CronJobs
  **Convention:** `Asia/Manila` everywhere — never UTC. 2 of 9 CronJobs violate this:

  | CronJob | Current | Fix |
  |---------|---------|-----|
  | `version-check` (monitoring) | `Etc/UTC` | Change to `Asia/Manila`, adjust cron to `0 0 * * 0` (midnight PHT) |
  | `configarr` (arr-stack) | not set (defaults to controller TZ) | Add `timeZone: "Asia/Manila"` |
  | ~~`invoicetron-db-backup`~~ | ~~not set~~ | ~~Fixed in Phase 5.0 (has `Asia/Manila`)~~ |

  ```bash
  # Verify after fix
  kubectl-homelab get cronjobs -A -o json | jq -r '
    .items[] | .metadata.namespace + "/" + .metadata.name +
    " timezone=" + (.spec.timeZone // "NOT SET")
  '
  # All should show timezone=Asia/Manila
  ```

- [ ] 5.4.0.4 Inventory existing PodDisruptionBudgets
  ```bash
  kubectl-homelab get pdb -A
  ```
  **Current state (13 PDBs already exist):**
  | Namespace | PDBs | Details |
  |-----------|------|---------|
  | gitlab | 7 | gitaly, gitlab-shell, kas, minio-v1, registry-v1, sidekiq-all-in-1-v1, webservice-default |
  | longhorn-system | 5 | csi-attacher, csi-provisioner, instance-manager (x3, one per node) |
  | cloudflare | 1 | cloudflared |

- [ ] 5.4.0.5 Inventory existing resource limits
  ```bash
  # Pods WITHOUT limits (the actual gaps)
  kubectl-homelab get pods -A -o json | jq -r '
    .items[] | select(.status.phase=="Running") |
    select(.spec.containers[] | .resources.limits == null) |
    .metadata.namespace + "/" + .metadata.name
  '
  ```
  **Known gaps (most manifest workloads already have limits):**
  | Category | Without Limits |
  |----------|---------------|
  | Helm-managed | cert-manager (3 pods), GitLab (exporter, shell, kas, minio, postgresql, redis, toolbox) |
  | System | All kube-system pods, all longhorn-system pods, cilium agent/operator |
  | Monitoring | alertmanager, alloy (3 pods), loki, grafana, prometheus |
  | Other | tailscale |
  | Manifest | Minimal gaps — most already set in prior phases |

  > **Note:** external-secrets limits were already set in Phase 5.0 — no longer a gap.

- [ ] 5.4.0.6 Check node memory overcommit
  ```bash
  kubectl-homelab describe nodes | grep -A5 "Allocated resources"
  ```
  **Known issue:** Nodes are at 115-175% memory overcommit on limits. This means under
  full load, OOMKiller will intervene. Adding limits to currently-unlimited pods will
  increase overcommit further. Plan limit values carefully.

- [ ] 5.4.0.7 Inventory all PVCs and backup coverage
  ```bash
  kubectl-homelab get pvc -A -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,STORAGE:.spec.resources.requests.storage,STORAGECLASS:.spec.storageClassName,STATUS:.status.phase' --sort-by='.metadata.namespace'
  ```

  **PVC Backup Coverage Matrix (as of 2026-03-17):**

  **Critical (user data, hard/impossible to recreate):**
  | Namespace | PVC | Size | What's In It | DB Dump? | Longhorn Backup? |
  |-----------|-----|------|-------------|----------|------------------|
  | ghost-prod | ghost-content | 5Gi | Blog posts, images, themes | N/A (files) | Yes |
  | ghost-prod | mysql-data-ghost-mysql-0 | 10Gi | Ghost MySQL database | Phase 5.4 | Yes |
  | invoicetron-prod | data-invoicetron-db-0 | 10Gi | Invoice data PostgreSQL | Yes (migrating to NFS) | Yes |
  | invoicetron-prod | invoicetron-backups | 2Gi | pg_dump destination (migrating to NFS in 5.4.4.1a) | N/A (is the backup) | Yes |
  | gitlab | repo-data-gitlab-gitaly-0 | 50Gi | All git repos | Phase 5.4 | Yes |
  | gitlab | data-gitlab-postgresql-0 | 15Gi | GitLab metadata DB | Phase 5.4 | Yes |
  | gitlab | gitlab-minio | 20Gi | GitLab artifacts, uploads | Phase 5.4 | Yes |
  | vault | data-vault-0 | 5Gi | All secrets (Raft) | Yes (snapshots to NFS) | Yes |
  | atuin | postgres-data | 5Gi | Shell history DB | Yes (pg_dump to NFS) | Yes |
  | karakeep | karakeep-data | 2Gi | Bookmarks, tags | New CronJob | Yes |
  | karakeep | meilisearch-data | 1Gi | Search index | New CronJob | Yes |

  **Important (app state, painful to recreate):**
  | Namespace | PVC | Size | What's In It | DB Dump? | Longhorn Backup? |
  |-----------|-----|------|-------------|----------|------------------|
  | home | adguard-data | 5Gi | DNS rules, clients, query logs | New CronJob | Yes |
  | uptime-kuma | data-uptime-kuma-0 | 1Gi | Monitors, history, alerts | New CronJob | Yes |
  | monitoring | prometheus-grafana | 10Gi | Dashboards, datasources | New CronJob | Yes |
  | monitoring | prometheus-...-prometheus-0 | 50Gi | Metrics history | No (rebuildable, too large) | Yes |
  | monitoring | storage-loki-0 | 12Gi | Log history | No (rebuildable) | Yes |
  | monitoring | alertmanager-...-0 | 5Gi | Alert silences, state | No (small, rebuilds fast) | Yes |
  | arr-stack | *-config PVCs (10 total) | 1-5Gi each | App configs, DBs, API keys | New CronJob | Yes |
  | home | myspeed-data | 1Gi | Speedtest history | New CronJob | Yes |

  **Low priority (rebuildable or dev):**
  | Namespace | PVC | Size | What's In It | DB Dump? | Longhorn Backup? |
  |-----------|-----|------|-------------|----------|------------------|
  | ghost-dev | ghost-content + mysql-data | 15Gi | Dev copy of blog | No | Yes |
  | invoicetron-dev | data-invoicetron-db-0 | 10Gi | Dev DB | No | Yes |
  | ai | ollama-models | 10Gi | Downloaded models (re-pull) | No | No |
  | browser | firefox-config | 2Gi | Browser profile (disposable) | No | No |
  | gitlab | redis-data-gitlab-redis-master-0 | 5Gi | Cache (ephemeral) | No | Yes |
  | atuin | atuin-config | 10Mi | Config file (in manifests) | No | Yes |
  | arr-stack | arr-data (NFS) | 2Ti | Media files | No | N/A (on NAS) |

  > **Gap:** Most Longhorn PVCs have no logical (DB dump) backup. Longhorn volume-level
  > backup (5.4.4a) covers all PVCs at the block level, but a logical backup survives
  > Longhorn corruption. New CronJobs in 5.4.4e address this gap.

---

## 5.4.1 Resource Limits on All Workloads

> **Why:** Without limits, one misbehaving pod can starve an entire node.
> Pods without limits also can't be evicted by priority — kubelet kills them randomly under pressure.

> **IMPORTANT:** Most manifest workloads already have resource limits from prior phases.
> This section focuses on the actual gaps: Helm-managed sidecars, system components,
> and fixing incorrectly-sized limits.

### Limit Sizing Strategy

| Workload Type | Memory Limit | CPU Limit | QoS Class |
|--------------|-------------|-----------|-----------|
| Stateless apps (Ghost, Portfolio, Homepage) | 1.5-2x observed usage | 2x observed usage | Burstable |
| Databases (PostgreSQL, MySQL) | 4x shared_buffers/buffer_pool_size | requests == limits | **Guaranteed** |
| Sidecars (config-reloader, exporter) | 128-256Mi | 100-200m | Burstable |
| Queue/cache (Redis, Sidekiq) | 2x observed + headroom for spikes | requests == limits | **Guaranteed** |

> **Why Guaranteed QoS for databases:** Databases allocate memory upfront (shared_buffers).
> Burstable QoS means kubelet can reclaim memory under pressure, causing OOMKill during
> query spikes. With Guaranteed (requests == limits), the scheduler accounts for the full
> allocation and kubelet won't reclaim it.

- [ ] 5.4.1.1 Audit current resource usage and gaps
  ```bash
  kubectl-homelab top nodes
  kubectl-homelab top pods -A --sort-by=memory

  # Find pods without limits
  kubectl-homelab get pods -A -o json | jq -r '
    .items[] | select(.status.phase=="Running") |
    select(.spec.containers[] | .resources.limits == null) |
    .metadata.namespace + "/" + .metadata.name
  '

  # Check current OOMKilled pods
  kubectl-homelab get pods -A -o json | jq -r '
    .items[] |
    select(.status.containerStatuses[]?.lastState.terminated.reason == "OOMKilled") |
    .metadata.namespace + "/" + .metadata.name +
    " (limit: " + (.spec.containers[0].resources.limits.memory // "none") + ")"
  '
  ```

- [ ] 5.4.1.2 Fix known OOMKill: bazarr limit too tight
  ```bash
  # bazarr: 256Mi limit, observed 227Mi (88% utilization) → OOMKilled
  # Increase to 512Mi to give proper headroom
  ```
  - Update `manifests/arr-stack/bazarr/deployment.yaml` memory limit: 256Mi → 512Mi
  - This is a **live issue** — fix before proceeding with other limit changes

- [ ] 5.4.1.3 Set resource limits on Helm-managed workloads missing limits
  - cert-manager: set in `helm/cert-manager/values.yaml`
    ```yaml
    resources:
      requests: { cpu: 50m, memory: 64Mi }
      limits: { cpu: 200m, memory: 256Mi }
    # Also set for cainjector and webhook sub-components
    ```
  - external-secrets: limits already set in Phase 5.0 — verify they're applied
  - GitLab sidecars: review `helm/gitlab/values.yaml` for config-reloader, exporter containers
  - Review `helm/*/values.yaml` for any other components missing limits

- [ ] 5.4.1.4 Set resource limits on remaining manifest workloads without limits
  - Cross-reference the audit from 5.4.1.1 against manifests
  - Only modify workloads that actually lack limits (don't re-set existing ones)
  - Use the sizing strategy table above (stateless vs database vs sidecar)

- [ ] 5.4.1.5 Verify no pods are OOMKilled or throttled after applying limits
  ```bash
  # Check for OOMKilled (wait 24-48h after applying)
  kubectl-homelab get pods -A -o json | jq -r '
    .items[] |
    select(.status.containerStatuses[]?.lastState.terminated.reason == "OOMKilled") |
    .metadata.namespace + "/" + .metadata.name
  '

  # Check for CPU throttling via Prometheus
  # Query: rate(container_cpu_cfs_throttled_periods_total[5m]) / rate(container_cpu_cfs_periods_total[5m]) > 0.25
  # If >25% throttled, increase CPU limit
  ```

- [ ] 5.4.1.6 Assess node overcommit after all limits applied
  ```bash
  kubectl-homelab describe nodes | grep -A5 "Allocated resources"
  # If any node exceeds 150% memory overcommit, reduce non-critical limits
  # Priority order for reduction: dev namespaces > sidecars > stateless apps
  ```

> **Note on system namespaces:** kube-system, longhorn-system, and cilium pods are managed
> by kubeadm/Helm operators. Setting limits on these requires careful testing — a
> kube-apiserver OOMKill takes down the control plane. Defer system namespace limits
> to a separate evaluation after all application limits are stable.

---

## 5.4.2 LimitRange Defaults

> **CKA Topic:** LimitRange sets default requests/limits for pods that don't specify them — safety net for missed workloads

> **CRITICAL: Deploy LimitRange BEFORE or AT THE SAME TIME as ResourceQuota.**
> Once a ResourceQuota exists, ALL new pods MUST have resource requests/limits.
> Without LimitRange, any pod missing explicit limits will fail to schedule.
> LimitRange provides the defaults that satisfy the quota requirement.

> **Note:** LimitRange only applies to NEW pods. Existing pods are NOT retroactively updated.
> Restart existing pods after applying LimitRange if they need the defaults.

- [ ] 5.4.2.1 Create LimitRange for application namespaces
  ```yaml
  apiVersion: v1
  kind: LimitRange
  metadata:
    name: default-limits
    namespace: invoicetron-prod
  spec:
    limits:
      - default:
          cpu: 500m
          memory: 512Mi
        defaultRequest:
          cpu: 100m
          memory: 128Mi
        type: Container
  ```

- [ ] 5.4.2.2 Apply LimitRange to all application namespaces
  - Namespaces to cover: ghost-prod, ghost-dev, invoicetron-prod, invoicetron-dev,
    portfolio-prod, portfolio-dev, portfolio-staging, arr-stack, home, atuin,
    karakeep, ai, uptime-kuma
  - Adjust defaults based on namespace workload profile:
    - arr-stack: higher defaults (media apps use more memory)
    - portfolio-dev/staging: lower defaults (dev workloads)
  - Don't apply to: monitoring, kube-system, longhorn-system, vault,
    external-secrets, cert-manager, gitlab (Helm-managed — limits set in values)

- [ ] 5.4.2.3 Verify defaults are applied to new pods
  ```bash
  # Deploy a pod without resource specs and check it gets defaults
  kubectl-homelab run test --rm -it --image=busybox -n invoicetron-prod -- sh -c "exit 0"
  kubectl-homelab get pod test -n invoicetron-prod -o jsonpath='{.spec.containers[0].resources}'
  ```

---

## 5.4.3 Resource Quotas

> **CKA Topic:** ResourceQuota prevents namespace-level resource exhaustion

> **Prerequisite:** LimitRange (5.4.2) must be deployed first. Without LimitRange defaults,
> pods without explicit resource specs will be rejected by the quota admission controller.

- [ ] 5.4.3.1 Audit actual namespace resource usage
  ```bash
  # Per-namespace resource consumption
  for ns in ghost-prod invoicetron-prod portfolio-prod arr-stack home atuin karakeep; do
    echo "=== $ns ==="
    kubectl-homelab top pods -n $ns --no-headers 2>/dev/null | awk '{cpu+=$2; mem+=$3} END {print "CPU: "cpu"m, Memory: "mem"Mi"}'
  done
  ```
  Validate quota values against actual usage — don't use arbitrary numbers.

- [ ] 5.4.3.2 Create ResourceQuota for application namespaces
  ```yaml
  # Template — adjust per namespace based on audit results
  apiVersion: v1
  kind: ResourceQuota
  metadata:
    name: resource-quota
    namespace: invoicetron-prod
  spec:
    hard:
      requests.cpu: "2"
      requests.memory: 4Gi
      limits.cpu: "4"
      limits.memory: 8Gi
      pods: "10"
      persistentvolumeclaims: "5"
  ```
  - Set quota at ~1.5x current namespace total usage to allow headroom for scaling
  - Start with: ghost-prod, invoicetron-prod, portfolio-prod, arr-stack
  - Then: home, atuin, karakeep, ai, uptime-kuma
  - Don't quota: monitoring, kube-system, longhorn-system, vault, external-secrets,
    cert-manager, gitlab (system/infra namespaces need flexibility)

- [ ] 5.4.3.3 Verify quotas are enforced
  ```bash
  kubectl-homelab describe resourcequota -A
  # Check that "Used" values don't exceed "Hard" limits
  # If any namespace is >80% of quota, increase the quota
  ```

---

## 5.4.4 Backup Strategy

> **Purpose:** Recover from accidental deletion, corruption, or node failure

### Backup Architecture Decision

| Layer | Tool | What it backs up | Target |
|-------|------|-----------------|--------|
| **Volume data** | Longhorn native backup | PVC data (efficient block-level) | NFS on NAS |
| **K8s resources** | Velero + MinIO | Deployments, Services, ConfigMaps, Secrets, CRDs | MinIO on NFS PVC |
| **etcd** | CronJob + etcdctl | Cluster state (the most critical backup) | NFS on NAS |

> **Why this split?**
> - Velero does NOT natively support NFS as a BackupStorageLocation — it requires an
>   S3-compatible API. MinIO provides that API backed by NFS storage.
> - Longhorn native backup is more efficient than Velero FSB for volume data —
>   block-level incremental vs file-level copy.
> - etcd is NOT backed up by Velero — it requires separate `etcdctl snapshot save`.
> - Kopia is the only FSB engine (restic was deprecated in Velero v1.14, removed in v1.15).

### 5.4.4a Longhorn Volume Backups

- [ ] 5.4.4.1 Create NFS backup target directory on NAS
  ```bash
  ssh wawashi@10.10.30.11 "sudo mount -t nfs4 10.10.30.4:/Kubernetes/Backups /tmp/nfs && \
    sudo mkdir -p /tmp/nfs/longhorn && sudo umount /tmp/nfs"
  ```

- [ ] 5.4.4.2 Configure Longhorn backup target
  ```bash
  # Set backup target in Longhorn settings
  kubectl-homelab -n longhorn-system edit settings backup-target
  # Set to: nfs://10.10.30.4:/Kubernetes/Backups/longhorn
  ```

- [ ] 5.4.4.3 Create Longhorn RecurringJob for automated backups
  ```yaml
  apiVersion: longhorn.io/v1beta2
  kind: RecurringJob
  metadata:
    name: daily-backup
    namespace: longhorn-system
  spec:
    cron: "0 19 * * *"     # 03:00 Manila time (UTC+8)
    task: backup
    retain: 30              # 30 daily backups
    concurrency: 2
    groups:
      - default             # Applies to all volumes in default group
  ```

- [ ] 5.4.4.4 Create weekly RecurringJob for longer retention
  ```yaml
  apiVersion: longhorn.io/v1beta2
  kind: RecurringJob
  metadata:
    name: weekly-backup
    namespace: longhorn-system
  spec:
    cron: "0 19 * * 0"     # Sunday 03:00 Manila time
    task: backup
    retain: 12              # 12 weekly backups (~3 months)
    concurrency: 2
    groups:
      - default
  ```

- [ ] 5.4.4.5 Test Longhorn backup and restore
  ```bash
  # Trigger manual backup of a non-critical volume
  # Via Longhorn UI or CLI: create backup of portfolio-prod PVC

  # Test restore:
  # 1. Create a new PVC from backup
  # 2. Mount it in a test pod
  # 3. Verify data integrity
  # 4. Clean up test resources
  ```

### 5.4.4a.1 Existing Backup Hardening

> **Problem:** 3 existing backup CronJobs need fixes before adding new ones.

- [ ] 5.4.4.1a Move invoicetron backup from Longhorn to NFS
  **Current:** `invoicetron-db-backup` writes pg_dump to a Longhorn PVC.
  **Problem:** Backup lives on the same storage system as the data. If Longhorn has issues,
  you lose both. Vault and Atuin correctly use NFS (off-cluster).

  ```bash
  # Create NFS directory
  ssh wawashi@10.10.30.11 "sudo mount -t nfs4 10.10.30.4:/Kubernetes/Backups /tmp/nfs && \
    sudo mkdir -p /tmp/nfs/invoicetron && sudo umount /tmp/nfs"
  ```

  Update `manifests/invoicetron/backup-cronjob.yaml`:
  - Replace Longhorn PVC volume with NFS volume (`10.10.30.4:/Kubernetes/Backups/invoicetron`)
  - Delete the old Longhorn PVC after verifying NFS backups work
  - Add `timeZone: "Asia/Manila"` (fixes pre-work item too)

- [ ] 5.4.4.1b Add Ghost MySQL backup CronJob (ghost-prod)
  **Current:** Ghost prod has MySQL with user content — NO backup CronJob exists.
  This is the blog with real content. Data loss = lost posts.

  ```yaml
  # manifests/ghost-prod/backup-cronjob.yaml
  apiVersion: batch/v1
  kind: CronJob
  metadata:
    name: ghost-mysql-backup
    namespace: ghost-prod
  spec:
    schedule: "0 2 * * *"        # Daily 02:00 PHT
    timeZone: "Asia/Manila"
    concurrencyPolicy: Forbid
    successfulJobsHistoryLimit: 3
    failedJobsHistoryLimit: 3
    jobTemplate:
      spec:
        backoffLimit: 0
        activeDeadlineSeconds: 300
        template:
          spec:
            restartPolicy: Never
            automountServiceAccountToken: false
            securityContext:
              runAsNonRoot: true
              runAsUser: 999
              runAsGroup: 999
              seccompProfile:
                type: RuntimeDefault
            containers:
              - name: backup
                image: mysql:8.4.8   # Match deployed version
                command: ["/bin/bash", "-c"]
                args:
                  - |
                    BACKUP_FILE="/backup/ghost-$(date +%Y%m%d-%H%M%S).sql.gz"
                    mysqldump -h ghost-mysql -u root -p"$MYSQL_ROOT_PASSWORD" \
                      --single-transaction --routines --triggers ghost \
                      | gzip > "$BACKUP_FILE"
                    echo "Backup created: $BACKUP_FILE ($(du -h "$BACKUP_FILE" | cut -f1))"
                    # Prune backups older than 30 days
                    find /backup -name "ghost-*.sql.gz" -mtime +30 -delete
                env:
                  - name: MYSQL_ROOT_PASSWORD
                    valueFrom:
                      secretKeyRef:
                        name: ghost-mysql
                        key: root-password
                securityContext:
                  allowPrivilegeEscalation: false
                  capabilities:
                    drop: ["ALL"]
                  readOnlyRootFilesystem: true
                resources:
                  requests: { cpu: 50m, memory: 128Mi }
                  limits: { cpu: 200m, memory: 256Mi }
                volumeMounts:
                  - name: backup
                    mountPath: /backup
                  - name: tmp
                    mountPath: /tmp
            volumes:
              - name: backup
                nfs:
                  server: 10.10.30.4
                  path: /Kubernetes/Backups/ghost
              - name: tmp
                emptyDir: {}
  ```

  ```bash
  # Create NFS directory
  ssh wawashi@10.10.30.11 "sudo mount -t nfs4 10.10.30.4:/Kubernetes/Backups /tmp/nfs && \
    sudo mkdir -p /tmp/nfs/ghost && sudo umount /tmp/nfs"
  ```

- [ ] 5.4.4.1c Evaluate GitLab backup strategy
  GitLab has its own backup rake task. Evaluate options:

  | Option | Pros | Cons |
  |--------|------|------|
  | `gitlab-backup-schedule` Helm value | Native, covers all data | Heavy (full backup each time) |
  | Velero namespace backup (5.4.4b) | Already planned | Doesn't cover Gitaly internal state |
  | Manual `gitlab-backup create` CronJob | Flexible retention | More manifests to maintain |

  **Decision:** Use GitLab's built-in `backup.cronSchedule` in `helm/gitlab/values.yaml`:
  ```yaml
  global:
    appConfig:
      backups:
        bucket: gitlab-backups
        schedule: "0 3 * * *"   # Daily 03:00
  ```
  > Verify this works with the existing MinIO in the gitlab namespace before adding
  > a separate CronJob. If GitLab's MinIO already has backup capability, use it.

### 5.4.4b Velero for K8s Resource Backup

- [ ] 5.4.4.6 Deploy MinIO as S3 backend for Velero
  ```bash
  # Create NFS PV/PVC for MinIO storage
  ssh wawashi@10.10.30.11 "sudo mount -t nfs4 10.10.30.4:/Kubernetes/Backups /tmp/nfs && \
    sudo mkdir -p /tmp/nfs/velero-minio && sudo umount /tmp/nfs"

  kubectl-homelab create namespace velero
  # Deploy MinIO (Helm or manifest) with NFS-backed PVC
  # MinIO provides the S3 API that Velero requires
  ```

- [ ] 5.4.4.7 Add Velero Helm repo and create values
  ```bash
  helm-homelab repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts --force-update
  helm-homelab repo update
  ```
  ```yaml
  # helm/velero/values.yaml
  configuration:
    backupStorageLocation:
      - name: default
        provider: aws           # MinIO is S3-compatible
        bucket: velero
        config:
          region: minio
          s3ForcePathStyle: true
          s3Url: http://minio.velero.svc:9000
    volumeSnapshotLocation: []  # Longhorn handles volume snapshots
    defaultSnapshotsEnabled: false
    uploaderType: kopia          # Kopia only — restic is deprecated

  initContainers:
    - name: velero-plugin-for-aws
      image: velero/velero-plugin-for-aws:v1.11.0  # Pin version
      volumeMounts:
        - mountPath: /target
          name: plugins

  deployNodeAgent: true          # Required for Kopia FSB
  nodeAgent:
    resources:
      requests: { cpu: 100m, memory: 256Mi }
      limits: { cpu: 500m, memory: 1Gi }

  resources:
    requests: { cpu: 100m, memory: 256Mi }
    limits: { cpu: 500m, memory: 512Mi }
  ```

- [ ] 5.4.4.8 Install Velero
  ```bash
  helm-homelab install velero vmware-tanzu/velero \
    --namespace velero \
    --values helm/velero/values.yaml
  ```

- [ ] 5.4.4.9 Create scheduled backup for K8s resources
  ```bash
  # Daily backup at 03:30 Manila time (staggered from Longhorn at 03:00)
  # Retain 30 days (not 7 — corruption may not be noticed for weeks)
  velero schedule create daily-k8s-backup \
    --schedule="0 19 * * *" \
    --ttl 720h \
    --include-namespaces portfolio-prod,portfolio-dev,portfolio-staging,invoicetron-prod,invoicetron-dev,ghost-prod,ghost-dev,home,monitoring,arr-stack,atuin,karakeep,ai,uptime-kuma,vault,cloudflare,external-secrets \
    --default-volumes-to-fs-backup=false
  ```
  > **Note:** `--default-volumes-to-fs-backup=false` because Longhorn handles volume
  > backup natively. Velero only backs up K8s resource manifests here.

- [ ] 5.4.4.10 Test Velero backup and restore
  ```bash
  velero backup create test-backup --include-namespaces portfolio-dev
  velero backup describe test-backup --details
  velero backup logs test-backup
  ```

### 5.4.4c etcd Backup

> **CRITICAL:** etcd contains ALL cluster state. Losing etcd = rebuild from scratch.
> Neither Velero nor Longhorn backs up etcd. This needs a separate solution.

- [ ] 5.4.4.11 Create NFS directory for etcd backups
  ```bash
  ssh wawashi@10.10.30.11 "sudo mount -t nfs4 10.10.30.4:/Kubernetes/Backups /tmp/nfs && \
    sudo mkdir -p /tmp/nfs/etcd && sudo umount /tmp/nfs"
  ```

- [ ] 5.4.4.12 Create etcd backup CronJob
  ```yaml
  # The etcd backup must run ON the control plane node (needs access to etcd certs)
  # Option A: CronJob with hostPath mount to etcd PKI
  # Option B: Ansible cron task on cp1 running etcdctl snapshot save
  #
  # CronJob approach (runs in-cluster):
  apiVersion: batch/v1
  kind: CronJob
  metadata:
    name: etcd-backup
    namespace: kube-system
  spec:
    schedule: "30 19 * * *"       # 03:30 Manila time
    jobTemplate:
      spec:
        template:
          spec:
            nodeSelector:
              node-role.kubernetes.io/control-plane: ""
            tolerations:
              - key: node-role.kubernetes.io/control-plane
                effect: NoSchedule
            containers:
              - name: etcd-backup
                image: registry.k8s.io/etcd:3.5.16-0  # Match cluster etcd version
                command:
                  - /bin/sh
                  - -c
                  - |
                    BACKUP_FILE="/backup/etcd-$(date +%Y%m%d-%H%M%S).db"
                    etcdctl snapshot save "$BACKUP_FILE" \
                      --endpoints=https://127.0.0.1:2379 \
                      --cacert=/etc/kubernetes/pki/etcd/ca.crt \
                      --cert=/etc/kubernetes/pki/etcd/server.crt \
                      --key=/etc/kubernetes/pki/etcd/server.key
                    etcdctl snapshot status "$BACKUP_FILE" --write-table
                    # Prune backups older than 30 days
                    find /backup -name "etcd-*.db" -mtime +30 -delete
                volumeMounts:
                  - name: etcd-certs
                    mountPath: /etc/kubernetes/pki/etcd
                    readOnly: true
                  - name: backup
                    mountPath: /backup
            volumes:
              - name: etcd-certs
                hostPath:
                  path: /etc/kubernetes/pki/etcd
              - name: backup
                nfs:
                  server: 10.10.30.4
                  path: /Kubernetes/Backups/etcd
            restartPolicy: OnFailure
  ```

- [ ] 5.4.4.13 Test etcd backup and document restore procedure
  ```bash
  # Verify backup was created
  ssh wawashi@10.10.30.11 "sudo mount -t nfs4 10.10.30.4:/Kubernetes/Backups /tmp/nfs && \
    ls -la /tmp/nfs/etcd/ && sudo umount /tmp/nfs"

  # Document restore procedure (DO NOT test on live cluster):
  # 1. Stop kube-apiserver (move manifest from /etc/kubernetes/manifests/)
  # 2. etcdctl snapshot restore <backup-file> --data-dir=/var/lib/etcd-restored
  # 3. Replace /var/lib/etcd with restored data
  # 4. Restart etcd and kube-apiserver
  # 5. Verify cluster state: kubectl get nodes, kubectl get pods -A
  ```

- [ ] 5.4.4.14 Encrypt etcd backup before writing to NFS
  **Problem:** After Phase 5.2 enables etcd encryption at rest, etcd snapshots contain
  the encryption key AND encrypted data. If the NAS is compromised, the attacker has both.

  **Options:**
  | Option | Pros | Cons |
  |--------|------|------|
  | GPG encryption with passphrase from Vault | Strong, standard | Requires GPG in container |
  | OpenSSL AES-256-CBC | No extra tooling | Key management needed |
  | Skip (accept NAS trust) | Simple | NAS compromise = full secret exposure |

  > **Decision needed:** Evaluate whether the NAS is trusted enough. If it's on a separate
  > VLAN with restricted access, the risk may be acceptable for a homelab.

### 5.4.4d Restore Drill Procedure

> **Why:** A backup that hasn't been tested is not a backup. Run this drill quarterly.

- [ ] 5.4.4.15 Document full restore drill
  ```
  Drill Procedure (use portfolio-dev as test target):

  1. Pre-drill: Verify backup exists and is recent
     velero backup describe daily-k8s-backup-<latest>
     # Check Longhorn backup status in UI

  2. Simulate disaster: Delete the namespace
     kubectl-homelab delete namespace portfolio-dev
     # Wait for all resources to be removed

  3. Restore K8s resources from Velero
     velero restore create drill-restore --from-backup daily-k8s-backup-<latest> \
       --include-namespaces portfolio-dev
     velero restore describe drill-restore --details

  4. Restore volume data from Longhorn backup
     # Via Longhorn UI: restore PVC from latest backup
     # Verify the PVC is bound and data is present

  5. Verify application health
     kubectl-homelab get pods -n portfolio-dev
     kubectl-homelab get pvc -n portfolio-dev
     # Access the application and verify data integrity

  6. Document results
     - Restore time (K8s resources + volume data)
     - Any manual steps required
     - Data integrity check results

  Expected restore time: 5-15 minutes for small namespaces
  ```

### 5.4.4e New Application Backup CronJobs

> **Why:** Most application PVCs have no logical (DB dump) backup. Longhorn volume-level
> backup covers all PVCs at the block level, but a logical backup survives Longhorn
> corruption. Together they form a two-layer safety net per the three-layer protection model.

> **Three-Layer Protection Model:**
> ```
> PVC (live data)  ->  Longhorn snapshot to NAS  ->  DB dump to NAS  ->  Restic encrypted off-site
>                      (block-level, fast)           (logical, portable)   (encrypted, off-NAS)
> ```
> Any single layer can fail and data is still recoverable.

> **Pattern:** All CronJobs below follow the same template as existing Vault/Atuin backups:
> NFS volume mount, nightly schedule, retention via `find -mtime`, `timeZone: "Asia/Manila"`,
> `automountServiceAccountToken: false`, `seccompProfile: RuntimeDefault`.

- [ ] 5.4.4.16 Create AdGuard backup CronJob
  SQLite file copy + config directory to NFS.
  ```bash
  # Create NFS directory
  ssh wawashi@10.10.30.11 "sudo mount -t nfs4 10.10.30.4:/Kubernetes/Backups /tmp/nfs && \
    sudo mkdir -p /tmp/nfs/adguard && sudo umount /tmp/nfs"
  ```
  - Manifest: `manifests/home/adguard/backup-cronjob.yaml`
  - Schedule: `0 2 * * *` (daily 02:00 PHT)
  - Source: PVC `adguard-data` mounted directly (not via subPath). Deployment uses two
    subPath mounts (`conf/` and `work/`), but the backup CronJob must mount the raw PVC
    to capture both directories.
  - Target: NFS `10.10.30.4:/Kubernetes/Backups/adguard`
  - Retention: 30 days

- [ ] 5.4.4.17 Create UptimeKuma backup CronJob
  SQLite file copy to NFS.
  ```bash
  ssh wawashi@10.10.30.11 "sudo mount -t nfs4 10.10.30.4:/Kubernetes/Backups /tmp/nfs && \
    sudo mkdir -p /tmp/nfs/uptime-kuma && sudo umount /tmp/nfs"
  ```
  - Manifest: `manifests/uptime-kuma/backup-cronjob.yaml`
  - Schedule: `0 2 * * *` (daily 02:00 PHT)
  - Source: `/app/data/kuma.db` (SQLite)
  - Target: NFS `10.10.30.4:/Kubernetes/Backups/uptime-kuma`
  - Retention: 30 days

- [ ] 5.4.4.18 Create Karakeep backup CronJob
  Data directory + meilisearch to NFS.
  ```bash
  ssh wawashi@10.10.30.11 "sudo mount -t nfs4 10.10.30.4:/Kubernetes/Backups /tmp/nfs && \
    sudo mkdir -p /tmp/nfs/karakeep && sudo umount /tmp/nfs"
  ```
  - Manifest: `manifests/karakeep/backup-cronjob.yaml`
  - Schedule: `0 2 * * *` (daily 02:00 PHT)
  - Source: Karakeep data PVC + meilisearch data PVC
  - Target: NFS `10.10.30.4:/Kubernetes/Backups/karakeep`
  - Retention: 30 days

- [ ] 5.4.4.19 Create Grafana backup CronJob
  SQLite file copy to NFS.
  ```bash
  ssh wawashi@10.10.30.11 "sudo mount -t nfs4 10.10.30.4:/Kubernetes/Backups /tmp/nfs && \
    sudo mkdir -p /tmp/nfs/grafana && sudo umount /tmp/nfs"
  ```
  - Manifest: `manifests/monitoring/grafana-backup-cronjob.yaml`
  - Schedule: `0 2 * * *` (daily 02:00 PHT)
  - Source: `/var/lib/grafana/grafana.db` (SQLite)
  - Target: NFS `10.10.30.4:/Kubernetes/Backups/grafana`
  - Retention: 30 days

- [ ] 5.4.4.20 Create ARR configs backup CronJob
  Config directory copy (all 9 apps) to NFS.
  ```bash
  ssh wawashi@10.10.30.11 "sudo mount -t nfs4 10.10.30.4:/Kubernetes/Backups /tmp/nfs && \
    sudo mkdir -p /tmp/nfs/arr-configs && sudo umount /tmp/nfs"
  ```
  - Manifest: `manifests/arr-stack/backup-cronjob.yaml`
  - Schedule: `0 2 * * *` (daily 02:00 PHT)
  - Source: All 10 Longhorn PVCs: sonarr-config, radarr-config, prowlarr-config, bazarr-config,
    jellyfin-config, qbittorrent-config, tdarr-configs, tdarr-server, seerr-config, recommendarr-config
  - Target: NFS `10.10.30.4:/Kubernetes/Backups/arr-configs`
  - Retention: 30 days
  - **Note:** Single CronJob with multiple volume mounts, or separate CronJobs per app.
    Evaluate based on volume mount limits and scheduling simplicity.

- [ ] 5.4.4.21 Create MySpeed backup CronJob
  SQLite file copy to NFS.
  ```bash
  ssh wawashi@10.10.30.11 "sudo mount -t nfs4 10.10.30.4:/Kubernetes/Backups /tmp/nfs && \
    sudo mkdir -p /tmp/nfs/myspeed && sudo umount /tmp/nfs"
  ```
  - Manifest: `manifests/home/myspeed/backup-cronjob.yaml`
  - Schedule: `0 2 * * *` (daily 02:00 PHT)
  - Source: MySpeed data PVC (SQLite)
  - Target: NFS `10.10.30.4:/Kubernetes/Backups/myspeed`
  - Retention: 30 days

- [ ] 5.4.4.22 Verify all new backup CronJobs run successfully
  ```bash
  # Trigger manual run of each new CronJob
  kubectl-homelab create job --from=cronjob/<name> test-<name> -n <namespace>
  # Verify backup files appear on NAS
  ssh wawashi@10.10.30.11 "sudo mount -t nfs4 10.10.30.4:/Kubernetes/Backups /tmp/nfs && \
    find /tmp/nfs -type f -mmin -60 && sudo umount /tmp/nfs"
  ```

### 5.4.4f Off-Site Encrypted Backup

> **Why:** All cluster backups (etcd, Vault, DB dumps, PKI, Longhorn volume snapshots,
> app backups) land on a single NAS with one drive. If the NAS fails, all backups are lost.
> This section adds an encrypted, off-site copy using restic + rclone.

> **Tool:** Restic (AES-256-CTR + Poly1305-AES encryption, content-defined chunking dedup)
> **Output:** Encrypted restic repo on local storage, optionally synced to OneDrive via rclone

#### Architecture

```
NFS Mount (NAS)  ->  restic backup (encrypt + dedup)  ->  Local Repo  ->  rclone sync  ->  OneDrive folder
10.10.30.4                                                /mnt/backup/    (native app syncs to cloud)
```

**Two restic repositories (separate repos, separate retention):**

| Repo | Contents | Retention |
|------|----------|-----------|
| `k8s-configs` | All of `/Kubernetes/Backups/` (etcd, Vault, DB dumps, PKI, Longhorn snapshots, ARR configs, app SQLite backups) | `--keep-daily 7 --keep-weekly 4` |
| `k8s-media` | Immich photos (future, ~300GB growing) | `--keep-last 3` + tagged on-demand snapshots |

**Why two repos:** Different retention policies, different backup frequencies. Pruning the
media repo (300GB+) should not block a quick config backup.

**Explicitly excluded from restic:** `/Kubernetes/Media/` (torrents + media files)

#### Network Requirements

| Machine | VLAN | Subnet | NAS NFS Access |
|---------|------|--------|----------------|
| k8s nodes | SERVERS | 10.10.30.x | Yes (existing) |
| Aurora | TRUSTED_WIFI | 10.10.20.x | Yes (NFS share widened to 10.10.0.0/16) |
| Windows/WSL host | TRUSTED_WIFI | 10.10.20.x | Yes (network), No (WSL2 NFS mount blocked by kernel) |
| Gaming desktop | LAN | 10.10.10.x | Yes (NFS share widened to 10.10.0.0/16) |

NFS share `Kubernetes` on OMV widened to `10.10.0.0/16` (done 2026-03-17).
WSL2 cannot NFS mount due to kernel restriction. Run script on Aurora or gaming desktop.

NFS exports use UID/GID-based access. Verify read access for the backup user after
first mount on each new machine (OMV root_squash, anonuid settings).

#### Encryption & Key Management

**Algorithm:** Restic AES-256-CTR + Poly1305-AES (encrypt-then-MAC). Every blob independently
encrypted and authenticated. Master key derived via scrypt KDF from password.

**Key lifecycle:**
```
restic init (create repo)
    |
    v
Primary password generated (strong random, 32+ chars)
    |
    v
Store in 1Password FIRST (source of truth):
    Item: "Restic Backup Keys" in Kubernetes vault
    Fields: k8s-configs-password, k8s-media-password
    |
    v
Seed to Vault via seed-vault-from-1password.sh:
    secret/backups/restic-k8s-configs password=<from 1P>
    secret/backups/restic-k8s-media password=<from 1P>
    |
    v
restic key add (create recovery password, different from primary)
    |
    v
Store recovery key ONLY in 1Password: same item
    Fields: k8s-configs-recovery, k8s-media-recovery
```

| Password | Stored In | Purpose |
|----------|-----------|---------|
| Primary (per repo) | Vault + 1Password | Daily operational use by script |
| Recovery (per repo) | 1Password only | DR when Vault is unavailable |

**Script auth fallback:** Vault (`vault kv get`) -> interactive prompt (paste from 1Password).
`op read` not in fallback chain (Family plan has no Connect for unattended access).

**Key rotation:** `restic key add` (new) -> `restic key remove` (old) -> update Vault + 1Password.
Does not re-encrypt existing data blobs (restic limitation).

#### Tasks

- [ ] 5.4.4.23 Create 1Password item "Restic Backup Keys" in Kubernetes vault
  Fields: `k8s-configs-password`, `k8s-media-password`, `k8s-configs-recovery`, `k8s-media-recovery`
  > User creates this manually in 1Password (Claude cannot run `op` commands).

- [ ] 5.4.4.24 Add restic Vault paths to seed-vault-from-1password.sh
  Add `op://Kubernetes/Restic Backup Keys/k8s-configs-password` and
  `op://Kubernetes/Restic Backup Keys/k8s-media-password` to the seed script.

- [ ] 5.4.4.25 Create `scripts/homelab-backup.sh`
  ```bash
  # Usage:
  ./scripts/homelab-backup.sh configs         # Backup configs
  ./scripts/homelab-backup.sh media           # Backup media (Immich)
  ./scripts/homelab-backup.sh all             # Backup everything
  ./scripts/homelab-backup.sh restore configs # Restore (interactive)
  ./scripts/homelab-backup.sh restore media   # Restore (interactive)
  ./scripts/homelab-backup.sh prune media     # Explicit prune for media repo
  ```

  **Configuration file:** `~/.config/homelab-backup/config`
  ```bash
  NAS_HOST=10.10.30.4
  NAS_BACKUPS_PATH=/Kubernetes/Backups
  NAS_IMMICH_PATH=/Kubernetes/Immich
  NFS_MOUNT=/tmp/homelab-backup-nfs
  RESTIC_CONFIGS_REPO=/mnt/backup/restic-k8s-configs
  RESTIC_MEDIA_REPO=/mnt/backup/restic-k8s-media
  RCLONE_SYNC_ENABLED=false
  RCLONE_REMOTE=onedrive:k8s-backups
  ```

  **Script flow:**
  1. NFS mount the NAS (or verify already mounted)
  2. Read restic password (Vault -> interactive prompt)
  3. Initialize repo if first run (`restic init`)
  4. `restic backup` the appropriate paths
  5. `restic forget` with retention policy (`--prune` for configs only; media prune on-demand)
  6. `restic check --with-cache` (quick, index-only)
  7. Optionally `rclone sync` repo to OneDrive remote
  8. Unmount NFS
  9. Print summary (snapshot ID, size, duration)

  **Portability:** Works on Aurora (Fedora), Ubuntu, or any Linux with `restic` + `nfs-common`.
  Optional: `rclone`, `vault` CLI.

- [ ] 5.4.4.26 Initialize restic repos and test first backup
  ```bash
  # Initialize both repos
  restic -r /mnt/backup/restic-k8s-configs init
  restic -r /mnt/backup/restic-k8s-media init

  # Add recovery keys
  restic -r /mnt/backup/restic-k8s-configs key add
  restic -r /mnt/backup/restic-k8s-media key add

  # Run first backup
  ./scripts/homelab-backup.sh configs
  restic -r /mnt/backup/restic-k8s-configs snapshots
  ```

- [ ] 5.4.4.27 Test restore from restic repo
  ```bash
  # Restore a single directory to verify
  restic -r /mnt/backup/restic-k8s-configs restore latest \
    --target /tmp/restic-restore-test \
    --include /Kubernetes/Backups/vault
  # Verify data integrity
  ls -la /tmp/restic-restore-test/
  rm -rf /tmp/restic-restore-test
  ```

- [ ] 5.4.4.28 Configure rclone OneDrive sync (optional, on Aurora)
  ```bash
  rclone config  # Set up OneDrive remote
  # Test sync
  rclone sync /mnt/backup/restic-k8s-configs onedrive:k8s-backups/configs --dry-run
  # Enable in config
  sed -i 's/RCLONE_SYNC_ENABLED=false/RCLONE_SYNC_ENABLED=true/' ~/.config/homelab-backup/config
  ```

#### Recovery Procedures

**Scenario 1: Single app data corruption** (e.g., UptimeKuma SQLite corrupted)
1. Check NAS first - restore from latest DB dump in `/Kubernetes/Backups/uptime-kuma/`
2. If NAS backup is also bad - restore Longhorn volume from Longhorn UI snapshot
3. If Longhorn snapshot is also bad - `restic restore` from off-site repo

**Scenario 2: NAS failure** (single drive dies, all NFS data lost)
1. Get restic repo from OneDrive folder (or local copy)
2. Mount new/repaired NAS storage
3. `restic restore --target /mnt/nas/Kubernetes/Backups latest`
4. Longhorn volumes are independent (on NVMe) - still intact
5. Reconfigure Longhorn backup target to new NAS

**Scenario 3: Full cluster rebuild** (all 3 nodes lost)
1. Get restic repo from OneDrive
2. Retrieve restic password from 1Password (recovery key if Vault is gone)
3. Restore etcd snapshot -> rebuild cluster from etcd
4. Restore Vault snapshot -> unseal Vault (keys from 1Password)
5. Restore DB dumps -> restore databases
6. Apply manifests from git repo (GitLab/GitHub)
7. Restore Longhorn backups -> restore PVC data

**Scenario 4: Immich photo recovery**
1. `restic restore --target /mnt/nas/Kubernetes/Immich latest`
2. Or: `restic mount /mnt/restic-browse` for selective file recovery

> **Key dependency:** Every scenario is recoverable using only OneDrive + 1Password.
> No cluster access required.

---

## 5.4.5 Backup Monitoring & Alerting

> **Why:** A backup that silently fails is worse than no backup — false sense of security.

- [ ] 5.4.5.1 Add Prometheus alerts for backup health
  ```yaml
  # manifests/monitoring/alerts/backup-alerts.yaml
  apiVersion: monitoring.coreos.com/v1
  kind: PrometheusRule
  metadata:
    name: backup-alerts
    namespace: monitoring
  spec:
    groups:
      - name: backup.rules
        rules:
          - alert: VeleroBackupFailed
            expr: velero_backup_failure_total > velero_backup_success_total
            for: 1h
            labels:
              severity: critical
            annotations:
              summary: "Velero backup failures exceed successes"

          - alert: VeleroBackupStale
            expr: time() - velero_backup_last_successful_timestamp > 129600
            for: 30m
            labels:
              severity: warning
            annotations:
              summary: "No successful Velero backup in 36 hours"

          - alert: LonghornBackupFailed
            expr: longhorn_backup_state{state="Error"} > 0
            for: 15m
            labels:
              severity: warning
            annotations:
              summary: "Longhorn volume backup in error state"

          - alert: ResourceQuotaNearLimit
            expr: |
              kube_resourcequota{type="used"} / kube_resourcequota{type="hard"} > 0.85
            for: 15m
            labels:
              severity: warning
            annotations:
              summary: "Namespace {{ $labels.namespace }} using >85% of resource quota"
  ```

- [ ] 5.4.5.2 Add etcd backup age alert
  ```yaml
  # Check via file age on NFS or a custom exporter
  # If etcd backup CronJob hasn't succeeded in 36 hours → critical
  - alert: EtcdBackupStale
    expr: |
      time() - kube_cronjob_status_last_successful_time{cronjob="etcd-backup",namespace="kube-system"} > 129600
    for: 30m
    labels:
      severity: critical
    annotations:
      summary: "No successful etcd backup in 36 hours"
  ```

- [ ] 5.4.5.3 Add CronJob failure alerting
  **Problem:** If `vault-snapshot`, `invoicetron-db-backup`, or `ghost-mysql-backup` starts
  failing silently, nobody gets notified. Only cluster-janitor and version-check have Discord.

  ```yaml
  # Add to manifests/monitoring/alerts/backup-alerts.yaml (or new cronjob-alerts.yaml)
  - alert: CronJobFailed
    expr: |
      kube_job_status_failed{namespace!=""} > 0
    for: 15m
    labels:
      severity: warning
    annotations:
      summary: "Job {{ $labels.namespace }}/{{ $labels.job_name }} failed"
      description: "Check logs: kubectl-homelab logs -n {{ $labels.namespace }} job/{{ $labels.job_name }}"

  - alert: CronJobNotScheduled
    expr: |
      time() - kube_cronjob_status_last_successful_time > 2 * (
        kube_cronjob_spec_starting_deadline_seconds > 0
        or on() vector(86400)
      )
    for: 1h
    labels:
      severity: warning
    annotations:
      summary: "CronJob {{ $labels.namespace }}/{{ $labels.cronjob }} missed 2+ scheduled runs"
  ```

  > **Coverage:** This single alert covers ALL current and future CronJobs — no per-CronJob
  > configuration needed. The `CronJobNotScheduled` alert catches suspended or stuck CronJobs.

- [ ] 5.4.5.4 Add stuck Longhorn volume alerting
  **Problem:** Cluster Janitor correctly skips volumes with 0 running replicas (safety),
  but nobody is notified about these stuck volumes. Currently `pvc-6ab4368a...`
  (invoicetron-backups) is detached with all replicas stopped — invisible to operators.

  ```yaml
  # manifests/monitoring/alerts/longhorn-alerts.yaml (or add to backup-alerts.yaml)
  - alert: LonghornVolumeAllReplicasStopped
    expr: |
      longhorn_volume_robustness{robustness="unknown"} == 1
      and longhorn_volume_state{state="detached"} == 1
    for: 1h
    labels:
      severity: warning
    annotations:
      summary: "Longhorn volume {{ $labels.volume }} has no running replicas"
      description: "All replicas stopped. Cluster Janitor cannot clean this (safety). Manual intervention needed."

  - alert: LonghornVolumeDegraded
    expr: longhorn_volume_robustness{robustness="degraded"} == 1
    for: 30m
    labels:
      severity: warning
    annotations:
      summary: "Longhorn volume {{ $labels.volume }} is degraded (missing replica)"
  ```

- [ ] 5.4.5.5 Add stuck pod alerts
  ```yaml
  # manifests/monitoring/alerts/stuck-pod-alerts.yaml
  # Catches pods the cluster-janitor doesn't handle (it only cleans Failed pods)
  apiVersion: monitoring.coreos.com/v1
  kind: PrometheusRule
  metadata:
    name: stuck-pod-alerts
    namespace: monitoring
    labels:
      release: prometheus
  spec:
    groups:
      - name: stuck-pods
        rules:
          # Pod stuck in Init for >30 minutes (e.g., Grafana Init:0/1 stale pod)
          - alert: PodStuckInInit
            expr: |
              sum by (namespace, pod) (
                kube_pod_init_container_status_waiting{reason="CrashLoopBackOff"} == 1
                or
                (kube_pod_init_container_status_running == 1
                 and on(namespace, pod) kube_pod_status_phase{phase="Pending"} == 1)
              ) > 0
            for: 30m
            labels:
              severity: warning
            annotations:
              summary: "Pod {{ $labels.namespace }}/{{ $labels.pod }} stuck in Init for >30m"
              description: "Init container is not completing. Check events: kubectl describe pod {{ $labels.pod }} -n {{ $labels.namespace }}"

          # Pod stuck Pending for >15 minutes (scheduling failure, PVC not bound, etc.)
          - alert: PodStuckPending
            expr: |
              kube_pod_status_phase{phase="Pending"} == 1
              unless on(namespace, pod) kube_pod_init_container_status_running == 1
            for: 15m
            labels:
              severity: warning
            annotations:
              summary: "Pod {{ $labels.namespace }}/{{ $labels.pod }} stuck Pending for >15m"
              description: "Pod cannot be scheduled. Check events and resource availability."

          # CrashLoopBackOff for >1 hour (escalation beyond kube-prometheus-stack's 15m alert)
          - alert: PodCrashLoopingExtended
            expr: |
              max_over_time(kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff"}[5m]) == 1
            for: 1h
            labels:
              severity: critical
            annotations:
              summary: "Pod {{ $labels.namespace }}/{{ $labels.pod }} crash-looping for >1h"
              description: "Container {{ $labels.container }} has been in CrashLoopBackOff for over 1 hour. This will not self-heal — investigate root cause."

          # ImagePullBackOff for >15 minutes
          - alert: PodImagePullBackOff
            expr: |
              kube_pod_container_status_waiting_reason{reason="ImagePullBackOff"} == 1
              or
              kube_pod_container_status_waiting_reason{reason="ErrImagePull"} == 1
            for: 15m
            labels:
              severity: warning
            annotations:
              summary: "Pod {{ $labels.namespace }}/{{ $labels.pod }} ImagePullBackOff for >15m"
              description: "Image pull failing for container {{ $labels.container }}. Check image name, tag, and registry accessibility."
  ```
  > **Why alerts, not janitor cleanup?** Auto-deleting CrashLoop/ImagePull/Pending pods
  > doesn't fix anything — the controller recreates them and they get stuck again.
  > These states need human investigation. The janitor correctly handles only `Failed`
  > pods (terminal state, no controller retry).

---

## 5.4.6 Pod Eviction Timing

> **Problem:** When a node goes down, pods take ~5-6 min to reschedule (300s default toleration).

- [ ] 5.4.6.1 Set tolerationSeconds for stateless services
  ```yaml
  # Add to stateless Deployments (Ghost, Portfolio, Homepage, etc.):
  spec:
    template:
      spec:
        tolerations:
          - key: "node.kubernetes.io/not-ready"
            operator: "Exists"
            effect: "NoExecute"
            tolerationSeconds: 60
          - key: "node.kubernetes.io/unreachable"
            operator: "Exists"
            effect: "NoExecute"
            tolerationSeconds: 60
  ```
  > **Why 60s, not 30s:** Your M80q BIOS POST takes 5-7 minutes. A 30s toleration
  > causes pods to evict on every transient network blip (switch reboot, VLAN
  > reconfiguration, brief connectivity loss). 60s balances fast failover against
  > unnecessary pod migrations. The node won't recover in 60s anyway (POST is 5-7min),
  > so you still get fast rescheduling.

  > **Keep 300s for:** Databases (PostgreSQL, MySQL, Redis), StatefulSets with PVCs,
  > Vault (seal/unseal is expensive). Data consistency > speed for stateful workloads.

- [ ] 5.4.6.2 Document expected recovery times
  | Phase | Duration |
  |-------|----------|
  | M80q BIOS POST | ~5-7 min |
  | Kubernetes node NotReady detection | ~40s |
  | Pod eviction (default) | 300s |
  | Pod eviction (tuned stateless) | 60s |
  | Pod eviction (databases — keep default) | 300s |
  | Total worst-case stateless (default) | ~11 min |
  | Total worst-case stateless (tuned) | ~7 min |
  | Total worst-case database | ~11 min |

---

## 5.4.7 GitLab HA Evaluation

> **Problem:** GitLab webservice is single-replica. Node reboot takes down container registry,
> causing ImagePullBackOff cascade for invoicetron and portfolio.

- [ ] 5.4.7.1 Assess memory budget for 2 replicas
  ```bash
  kubectl-homelab top pods -n gitlab --sort-by=memory
  # Actual: webservice pod uses ~2214Mi
  # Adding a second replica = +2.2GB memory allocation
  # With nodes already at 115-175% memory overcommit on limits,
  # this needs careful evaluation
  ```
  **Decision criteria:**
  - If any node has <4GB allocatable memory remaining → don't scale
  - If scaling would push overcommit >200% → don't scale
  - Alternative: pre-pull images to local containerd cache (mitigates ImagePullBackOff
    without adding memory pressure)

- [ ] 5.4.7.2 If feasible: scale webservice + registry to 2 replicas
  ```yaml
  # helm/gitlab/values.yaml
  gitlab:
    webservice:
      replicas: 2
    registry:
      replicas: 2
  ```
  - Add podAntiAffinity to spread replicas across nodes
  - Monitor memory pressure for 48h after scaling

---

## 5.4.8 Longhorn Remaining Items

- [x] 5.4.8.1 ~~`node-down-pod-deletion-policy`~~ — **Done in v0.28.2**
- [x] 5.4.8.2 ~~`orphan-resource-auto-deletion`~~ — **Done in v0.28.2**

- [ ] 5.4.8.3 Document manual recovery procedure for stuck stopped replicas
  ```bash
  # 1. Identify stopped replicas
  kubectl-homelab -n longhorn-system get replicas.longhorn.io \
    -o custom-columns=NAME:.metadata.name,VOLUME:.spec.volumeName,NODE:.spec.nodeID,STATE:.status.currentState \
    | grep stopped

  # 2. Verify volume has at least 1 healthy replica
  kubectl-homelab -n longhorn-system get replicas.longhorn.io \
    -o custom-columns=VOLUME:.spec.volumeName,STATE:.status.currentState \
    | sort | uniq -c

  # 3. Delete stopped replicas (Longhorn auto-rebuilds)
  kubectl-homelab -n longhorn-system delete replicas.longhorn.io <name>

  # 4. Monitor rebuild
  kubectl-homelab -n longhorn-system get volumes.longhorn.io -w
  ```

- [ ] 5.4.8.4 Verify `replica-soft-anti-affinity` is `false`
  ```bash
  kubectl-homelab -n longhorn-system get settings replica-soft-anti-affinity -o jsonpath='{.value}'
  # Must be: false
  ```

---

## 5.4.9 PodDisruptionBudgets

> **CKA Topic:** PDBs prevent voluntary disruptions (drain, upgrade) from killing too many pods at once

Without PDBs, `kubectl drain` or a rolling upgrade can terminate all replicas of a service simultaneously. PDBs enforce a minimum availability guarantee during voluntary disruptions.

> **Existing PDBs (13 total):** GitLab (7), Longhorn (5), Cloudflare (1) — already created
> by their Helm charts. This section adds PDBs for namespaces that don't have them.

- [ ] 5.4.9.1 Add PDBs for services with 2+ replicas
  ```yaml
  apiVersion: policy/v1
  kind: PodDisruptionBudget
  metadata:
    name: ghost-pdb
    namespace: ghost-prod
  spec:
    minAvailable: 1
    selector:
      matchLabels:
        app: ghost
  ```
  - Apply to: any Deployment/StatefulSet with replicas >= 2 that doesn't already have a PDB
  - Check existing PDBs first: `kubectl-homelab get pdb -A`

- [ ] 5.4.9.2 Add PDBs for critical single-replica services
  ```yaml
  # For single-replica services, use maxUnavailable: 1 (NOT 0)
  # maxUnavailable: 0 permanently blocks kubectl drain — operational footgun
  # maxUnavailable: 1 allows drain while still preventing accidental double-eviction
  apiVersion: policy/v1
  kind: PodDisruptionBudget
  metadata:
    name: vault-pdb
    namespace: vault
  spec:
    maxUnavailable: 1
    selector:
      matchLabels:
        app.kubernetes.io/name: vault
  ```
  > **Why NOT `maxUnavailable: 0`?** It blocks ALL voluntary disruptions including
  > `kubectl drain`. During node maintenance, you'd have to delete the PDB first,
  > then recreate it after — defeating the purpose. `maxUnavailable: 1` on a
  > single-replica service still prevents eviction during normal operations
  > (PDB won't allow going below 0 available pods in the case of accidental
  > concurrent disruptions), but allows planned maintenance via drain.

  - Evaluate for: Vault, Prometheus, Grafana, AdGuard
  - Services that already have Helm-managed PDBs: skip (check with `kubectl-homelab get pdb -A`)

- [ ] 5.4.9.3 Verify PDBs are respected during drain
  ```bash
  kubectl-homelab get pdb -A
  # Test: cordon a node and attempt drain — PDB should block if it would violate budget
  kubectl-homelab cordon <node>
  kubectl-homelab drain <node> --ignore-daemonsets --delete-emptydir-data --dry-run=client
  kubectl-homelab uncordon <node>
  ```

---

## 5.4.10 Automation Hardening

> **Why:** Audit of existing CronJobs and version-checking tools revealed 88% false positive
> rate on version-checker, 3 overlapping tools with coverage gaps, dormant Renovate, and
> missing notifications on operational automations.

### 5.4.10.1 Fix version-checker Signal Quality

**Current state:** 145 of 164 images flagged as "outdated" — only 19 are up to date.
The `ContainerImageOutdated` alert fires on everything, making it useless.

**Root causes:**
| Issue | Count | Example |
|-------|-------|---------|
| Init containers counted separately | ~30 | Cilium: 12 entries (3 nodes x 4 containers) |
| Completed CronJob pods retained | ~15 | `invoicetron-db-backup`: 3 pods x 1 entry each |
| Broken registry detection | 3 | cert-manager: `latest_version="608111629"` (Quay build #) |
| Non-semver tags can't compare | ~10 | `alpine:3.21`, `python:3.12-alpine`, `busybox` |
| Legitimate outdated | ~87 | Real drift (but buried in noise) |

- [ ] 5.4.10.1a Evaluate version-checker filtering options
  ```bash
  # Check if version-checker supports container_type filtering
  kubectl-homelab -n monitoring exec deploy/version-checker -- \
    wget -qO- http://localhost:8080/metrics 2>/dev/null | \
    grep 'version_checker_is_latest_version{' | grep 'container_type="init"' | wc -l
  ```
  **Options:**
  | Option | Effort | Impact |
  |--------|--------|--------|
  | Add `enable.version-checker.io/init-containers: "false"` annotation | Low | Fixes init container duplicates (~30 entries) |
  | Exclude CronJob-created pods (reduce `successfulJobsHistoryLimit` to 1) | Low | Reduces CronJob pod noise |
  | Add `version-checker.io/image-override` for cert-manager | Medium | Fixes broken Quay detection |
  | Replace with Renovate-only (Phase 6) | Deferred | Permanent fix |

- [ ] 5.4.10.1b Fix `ContainerImageOutdated` alert to reduce noise
  ```yaml
  # Option A: Exclude init containers from the alert
  - alert: ContainerImageOutdated
    expr: |
      version_checker_is_latest_version{container_type="container"} == 0
    for: 7d
    ...

  # Option B: Add exclusions for known false positives
  - alert: ContainerImageOutdated
    expr: |
      version_checker_is_latest_version == 0
      unless on(image) version_checker_is_latest_version{image=~".*cert-manager.*"}
    for: 7d
    ...
  ```
  > Pick the option that reduces false positives most with least maintenance burden.

- [ ] 5.4.10.1c Reduce CronJob `successfulJobsHistoryLimit` where excessive
  CronJobs with `successfulJobsHistoryLimit: 3` create 3 completed pods that version-checker
  scans individually. Reduce to `1` where 3 isn't needed:
  - `invoicetron-db-backup`: 3 → 1 (don't need 3 completed backup pods)
  - `version-check`: 3 → 1
  - `arr-stall-resolver`: 3 → 1

### 5.4.10.2 Fix Nova CronJob Network Fragility

**Current:** The version-check CronJob runs `apk add --no-cache curl jq` on every execution.
If Alpine repos are unreachable at Sunday midnight, the job fails silently.

- [ ] 5.4.10.2a Switch version-check main container to `alpine/k8s:1.35.0`
  `alpine/k8s` already includes curl. Only `jq` needs installing — or bundle the script
  differently.

  **Alternative:** Build a minimal image with curl + jq baked in (overkill for homelab).

  **Simplest fix:** Change from `alpine:3.21` to `alpine/k8s:1.35.0` (already used by
  cluster-janitor, already pulled on all nodes):
  ```yaml
  # version-check-cronjob.yaml
  containers:
    - name: version-check
      image: alpine/k8s:1.35.0    # Was: alpine:3.21
      # Update script: remove "apk add" line, only install jq
  ```
  > `alpine/k8s` has curl but NOT jq. Install jq only (faster, less fragile than curl+jq).

### 5.4.10.3 Decide on Renovate

**Current state:** Renovate is installed but dormant. `dependencyDashboardApproval: true`
means zero PRs are created until someone checks GitHub issue #2. Only 1 PR was ever
created (initial config PR, closed). Primary remote is GitLab — GitHub issues aren't
checked regularly.

- [ ] 5.4.10.3a Choose one of:

  | Option | Action | Recommendation |
  |--------|--------|----------------|
  | **A. Activate** | Remove `dependencyDashboardApproval: true`, enable auto-merge for non-critical patches | Only if you'll review PRs weekly |
  | **B. Suspend** | Add `"enabled": false` to `renovate.json` | Honest — removes false sense of coverage |
  | **C. Defer to Phase 6** | Keep as-is, activate with ArgoCD | Already in deferred table |

  > **Recommendation:** Option B (suspend) or C (defer). A dormant tool is worse than no
  > tool — it creates a false sense of coverage. Phase 6 (ArgoCD) already plans to solve
  > automated version management properly.

### 5.4.10.4 Add Discord Notification to ARR Stall Resolver

**Current:** Stall resolver switches quality profiles to "Any" permanently and logs
`ACTION REQUIRED: manually revert`. But logs only go to Loki — if nobody queries them,
the revert reminder is invisible. Quality stays as "Any" forever.

- [ ] 5.4.10.4a Add Discord webhook to stall resolver
  ```yaml
  # Add env var to cronjob.yaml
  env:
    - name: DISCORD_WEBHOOK_URL
      valueFrom:
        secretKeyRef:
          name: arr-discord-webhook
          key: discord-webhook-url
  ```
  Update `resolve.py` to post a Discord notification when a profile is switched:
  ```
  "Stall Resolver switched '{title}' to '{FALLBACK_PROFILE}' profile.
  ACTION: Revert quality profile in {app_name} UI after download succeeds."
  ```
  > Only notify on profile switches (not on "no stalled downloads" — that's noise).

### 5.4.10.5 Cluster Janitor Improvements

- [ ] 5.4.10.5a Add Discord notification for stuck volumes (0 running replicas)
  Currently the janitor logs `SKIPPING ... has 0 running replicas` but doesn't notify.
  These stuck volumes need human attention.

  Update janitor script: if a volume is skipped due to 0 running replicas, send a
  Discord warning (once per volume, not every 10 minutes):
  ```bash
  # Track skipped volumes to avoid notification spam
  # Option: only notify if the skip hasn't been reported in the last 24h
  # (requires either a ConfigMap flag or a simple file-based check)
  ```
  > Simpler alternative: rely on the new `LonghornVolumeAllReplicasStopped` Prometheus
  > alert (5.4.5.4) instead of modifying the janitor. The alert covers this case
  > cluster-wide without per-CronJob logic.

- [ ] 5.4.10.5b Remove redundant `export TZ=Asia/Manila` from janitor script
  The CronJob already has `timeZone: "Asia/Manila"` — the env var is redundant.
  (Low priority, cosmetic.)

---

## 5.4.11 Documentation

- [ ] 5.4.11.1 Update VERSIONS.md
  ```
  | Velero | X.X.X | K8s resource backup and restore |
  | MinIO  | X.X.X | S3-compatible storage for Velero |
  | Restic | X.X.X | Encrypted off-site backup |
  | rclone | X.X.X | Cloud sync for off-site backup |
  ```

- [ ] 5.4.11.2 Update `docs/context/Security.md` with:
  - Resource quota strategy and namespace coverage
  - Backup architecture (3-layer: Longhorn, Velero, etcd)
  - Backup schedule, retention policy, and storage locations
  - Recovery time documentation
  - Restore drill procedure and schedule (quarterly)
  - Automation hardening decisions (version-checker filtering, Renovate status, CronJob alerting)
  - Off-site encrypted backup architecture (restic + rclone, two repos, three-layer model)
  - PVC inventory and backup coverage matrix
  - New application backup CronJobs (AdGuard, UptimeKuma, Karakeep, Grafana, ARR, MySpeed)
  - Restic key management (1Password source of truth, Vault operational, recovery keys)
  - Recovery procedures (4 scenarios: app corruption, NAS failure, full rebuild, Immich)

- [ ] 5.4.11.3 Update `docs/reference/CHANGELOG.md`

---

## Verification Checklist

- [x] Pre-work: existing warning events fixed (v0.29.1 — GitLab runner mount, Ghost probes, Grafana init, Byparr)
- [ ] Pre-work: stale pods cleaned up
- [ ] Pre-work: existing PDBs and resource limits inventoried
- [ ] bazarr OOMKill fixed (256Mi → 512Mi)
- [ ] All workload pods have resource requests and limits
- [ ] Node memory overcommit assessed and documented
- [ ] LimitRange defaults on application namespaces (deployed BEFORE quotas)
- [ ] ResourceQuotas on application namespaces (validated against actual usage)
- [ ] Longhorn backup target configured (NFS)
- [ ] Longhorn RecurringJobs: daily (30 retention) + weekly (12 retention)
- [ ] Longhorn backup tested and restore verified
- [ ] MinIO deployed for Velero S3 backend
- [ ] Velero installed with Kopia FSB engine
- [ ] Velero scheduled backup running daily (30-day retention, all namespaces)
- [ ] Velero backup tested and restore verified
- [ ] etcd backup CronJob running daily
- [ ] etcd backup tested and restore procedure documented
- [ ] etcd backup encryption evaluated (GPG/OpenSSL/accept NAS trust)
- [ ] Restore drill completed on non-prod namespace
- [ ] Backup health alerts in Prometheus (Velero, Longhorn, etcd, quota)
- [ ] Stuck pod alerts deployed (Init, Pending, CrashLoop, ImagePull)
- [ ] Pod eviction timing tuned (60s stateless, 300s databases)
- [ ] PodDisruptionBudgets on services without existing PDBs
- [ ] GitLab HA evaluated (scaled if memory permits, or image pre-pull alternative)
- [ ] Longhorn `replica-soft-anti-affinity` confirmed `false`
- [ ] Stopped replica recovery procedure documented
- [ ] All CronJobs have `timeZone: "Asia/Manila"` (2 to fix: version-check, configarr)
- [ ] CronJob failure alerting deployed (covers all current and future CronJobs)
- [ ] Stuck Longhorn volume alerting deployed (0 running replicas detection)
- [ ] Invoicetron backup migrated from Longhorn PVC to NFS
- [ ] Ghost MySQL backup CronJob deployed (daily to NFS)
- [ ] GitLab backup strategy evaluated and implemented
- [ ] version-checker `ContainerImageOutdated` alert excludes init containers
- [ ] Nova CronJob no longer depends on `apk add` for curl
- [ ] Renovate decision made (activated, suspended, or deferred to Phase 6)
- [ ] ARR Stall Resolver sends Discord notification on profile switches
- [ ] CronJob `successfulJobsHistoryLimit` reduced to 1 where appropriate
- [ ] PVC inventory documented with backup coverage matrix
- [ ] AdGuard backup CronJob deployed (daily SQLite copy to NFS)
- [ ] UptimeKuma backup CronJob deployed (daily SQLite copy to NFS)
- [ ] Karakeep backup CronJob deployed (daily data copy to NFS)
- [ ] Grafana backup CronJob deployed (daily SQLite copy to NFS)
- [ ] ARR configs backup CronJob deployed (daily config copy to NFS)
- [ ] MySpeed backup CronJob deployed (daily SQLite copy to NFS)
- [ ] All new backup CronJobs verified (manual trigger + NFS file check)
- [ ] Restic backup keys created in 1Password "Restic Backup Keys" item
- [ ] Restic Vault paths added to seed-vault-from-1password.sh
- [ ] `scripts/homelab-backup.sh` created and tested
- [ ] Restic repos initialized (k8s-configs + k8s-media)
- [ ] Restic recovery keys added (`restic key add`)
- [ ] First restic backup completed and restore verified
- [ ] rclone OneDrive sync configured (on Aurora, when ready)
- [ ] NFS share widened to 10.10.0.0/16 on OMV (done 2026-03-17)

---

## Rollback

**Resource limits cause OOMKilled:**
```bash
# Increase the limit in the manifest
# Or temporarily remove limits to stabilize
kubectl-homelab patch deployment <name> -n <ns> \
  --type=json -p='[{"op": "remove", "path": "/spec/template/spec/containers/0/resources/limits"}]'
```

**LimitRange/ResourceQuota causing pod scheduling failures:**
```bash
# If pods fail to schedule after quota is applied:
# 1. Check which pods are missing resource specs
kubectl-homelab get events -n <ns> --sort-by='.lastTimestamp' | grep "forbidden"
# 2. Either add resource specs to the pod OR temporarily remove the quota
kubectl-homelab delete resourcequota resource-quota -n <ns>
# 3. Fix the pod spec, then re-apply quota
```

**Velero backup fails:**
```bash
kubectl-homelab logs -n velero -l app.kubernetes.io/name=velero
velero backup describe <name> --details
# Common causes: MinIO unreachable, Kopia node agent not running,
# insufficient disk space on NFS
```

**Longhorn backup fails:**
```bash
kubectl-homelab -n longhorn-system logs -l app=longhorn-manager --tail=100
# Common causes: NFS target unreachable, backup target not configured,
# insufficient space on NAS
```

**etcd backup CronJob fails:**
```bash
kubectl-homelab logs -n kube-system -l job-name=etcd-backup-<timestamp>
# Common causes: etcd cert path changed, NFS mount failed,
# etcd version mismatch with etcdctl image
```

**Restic backup fails:**
```bash
# Check restic logs (script prints to stdout)
# Common causes: NFS mount failed, restic password wrong, repo corrupted
restic -r /mnt/backup/restic-k8s-configs check
# If repo is corrupted, rebuild from NAS data:
restic -r /mnt/backup/restic-k8s-configs-new init
./scripts/homelab-backup.sh configs  # backs up to new repo
```

**New app backup CronJobs fail:**
```bash
# Check job logs
kubectl-homelab logs -n <namespace> job/<job-name>
# Common causes: NFS mount failed, PVC not mounted, permission denied
# Verify NFS target exists on NAS
ssh wawashi@10.10.30.11 "sudo mount -t nfs4 10.10.30.4:/Kubernetes/Backups /tmp/nfs && \
  ls /tmp/nfs/<app>/ && sudo umount /tmp/nfs"
```

---

## Deferred to Phase 6 (ArgoCD)

These items are explicitly NOT in Phase 5:

| Item | Why Deferred |
|------|-------------|
| Manifest directory reorganization | ArgoCD ApplicationSets use directory structure — reorganize right before ArgoCD setup |
| Automated version management | ArgoCD + Renovate Bot solves this permanently. Renovate may be suspended until then (see 5.4.10.3) |
| App version updates (Ghost, etc.) | One-off bumps are maintenance, not a phase. Automated pipeline comes with ArgoCD |

---

## Final: Commit and Release

- [ ] `/audit-security` then `/commit`
- [ ] `/audit-docs` then `/commit`
- [ ] `/release v0.34.0 "Resilience & Backup"`
- [ ] `mv docs/todo/phase-5.4-resilience-backup.md docs/todo/completed/`
