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

- [x] 5.4.0.2 Clean up stale pods (clean - no stuck pods found)
  ```bash
  # Check for stuck pods (Init, CrashLoopBackOff, etc.)
  kubectl-homelab get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
  # Resolve any stuck pods before starting resilience work
  ```

- [x] 5.4.0.3 Fix timezone inconsistency on CronJobs
  **Convention:** `Asia/Manila` everywhere — never UTC. 2 of 9 CronJobs violate this:

  | CronJob | Current | Fix |
  |---------|---------|-----|
  | `version-check` (monitoring) | `Etc/UTC` | Change to `Asia/Manila`, adjust cron to `0 8 * * 0` (08:00 Sunday PHT, same effective time as current 00:00 UTC) |
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

- [x] 5.4.0.4 Inventory existing PodDisruptionBudgets (13 PDBs: gitlab 7, longhorn 5, cloudflare 1)
  ```bash
  kubectl-homelab get pdb -A
  ```
  **Current state (13 PDBs already exist):**
  | Namespace | PDBs | Details |
  |-----------|------|---------|
  | gitlab | 7 | gitaly, gitlab-shell, kas, minio-v1, registry-v1, sidekiq-all-in-1-v1, webservice-default |
  | longhorn-system | 5 | csi-attacher, csi-provisioner, instance-manager (x3, one per node) |
  | cloudflare | 1 | cloudflared |

- [x] 5.4.0.5 Inventory existing resource limits (gaps in cert-manager, gitlab sidecars, kube-system, longhorn, monitoring, tailscale)
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

- [x] 5.4.0.6 Check node memory overcommit (cp1 168%, cp2 99%, cp3 170% on limits; actual usage 58-66%)
  ```bash
  kubectl-homelab describe nodes | grep -A5 "Allocated resources"
  ```
  **Known issue:** Nodes are at 96-171% memory overcommit on limits (as of 2026-03-20). This means under
  full load, OOMKiller will intervene. Adding limits to currently-unlimited pods will
  increase overcommit further. Plan limit values carefully.

- [x] 5.4.0.7 Inventory all PVCs and backup coverage (37 PVCs, all accounted for)
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

## Execution Order

> **This section defines the safe execution sequence.** The rest of the document is
> organized by topic (resource management, Longhorn, Velero, etc.) for reference.
> An implementation agent MUST follow this execution order, not the document order.
> Tasks within a phase can run in parallel unless noted. Phases are sequential.

```
Phase A ─── Pre-work + Inventory
   │        5.4.0.2, 5.4.0.4-0.7 (NOT 5.4.0.3 - timezone fix is in Phase C)
   │        (read-only audits, no changes to running workloads)
   ▼
Phase B ─── Resource Management (STRICT ORDER: limits → limitrange → quota)
   │        5.4.1.1-1.6  Resource limits
   │        5.4.2.1-2.3  LimitRange defaults (BEFORE quotas)
   │        5.4.3.1-3.3  ResourceQuota (AFTER limitrange)
   ▼
Phase C ─── Scripts Reorg + Timezone Fixes
   │        5.4.4.23     Reorganize scripts/ directory + update doc refs + .gitignore
   │        5.4.0.3      Fix timezone on version-check + configarr CronJobs
   ▼
Phase D ─── Backup Infrastructure (3 parallel tracks)
   │   ┌── D1: Longhorn Volume Backups
   │   │       5.4.4.1-2   NFS target + configure Longhorn
   │   │       5.4.4.3-4   RecurringJobs (critical + important tiers)
   │   │       5.4.4.5     Test Longhorn backup + restore
   │   │
   │   ├── D2: In-Cluster CronJob Backups
   │   │       5.4.4.1a    Move invoicetron backup to NFS
   │   │       5.4.4.1b    Ghost MySQL backup CronJob
   │   │       5.4.4.1c    Evaluate GitLab backup strategy
   │   │       5.4.4.11-13 etcd backup (NFS dir, CronJob, test)
   │   │       5.4.4.16-21 New app backups (AdGuard, UptimeKuma, Karakeep,
   │   │                   Grafana, ARR configs, MySpeed)
   │   │       5.4.4.22    Verify all new CronJobs
   │   │       5.4.4.22a   Replace alpine+apk with keinos/sqlite3 image
   │   │
   │   └── D3: Velero
   │           5.4.4.6     Deploy Garage S3 (1P + ESO + bucket + NetworkPolicy)
   │           5.4.4.6a    Install velero CLI on WSL2
   │           5.4.4.7     Create Velero Helm values
   │           5.4.4.8     Install Velero
   │           5.4.4.9     Create scheduled backup
   │           5.4.4.10    Test Velero backup + restore
   ▼
─── GATE: All 3 tracks complete. Verify: ───────────────────────────
    - Longhorn RecurringJobs producing snapshots on NAS
    - All CronJob backups appearing in /Kubernetes/Backups/<app>/
    - Velero schedule shows successful backup
────────────────────────────────────────────────────────────────────
   ▼
Phase E ─── Off-Site Backup Script (WSL2)
   │        5.4.4.24     Create 1Password "Restic Backup Keys" item (USER)
   │        5.4.4.25     Add restic Vault path to seed script
   │        5.4.4.26     Create config.example + .gitignore entries
   │        5.4.4.27     Create homelab-backup.sh
   │        5.4.4.28     Install restic on WSL2
   │        5.4.4.29     Initialize restic repo + first pull + encrypt
   │        5.4.4.30     Add recovery key
   │        5.4.4.31     Test restore from restic repo
   ▼
─── GATE: First successful restic pull + encrypt completed ─────────
    Verify: restic snapshots shows at least 1 snapshot
────────────────────────────────────────────────────────────────────
   ▼
Phase F ─── Retention Reductions (SAFE NOW - restic has the data, manifest confirms)
   │        5.4.4.0a     Vault 15 → 3 days
   │        5.4.4.0b     Atuin 28 → 3 days
   │        5.4.4.0c     PKI 90 → 14 days
   │
   │        WARNING: These immediately prune old backups on next CronJob run.
   │        Phase E must be complete before executing this phase.
   ▼
Phase G ─── Monitoring & Alerting
   │        5.4.5.1-5.5  Prometheus alerts (backup health, CronJob failure,
   │                     stuck volumes, stuck pods)
   ▼
Phase H ─── Resilience Hardening (4 parallel tracks)
   │   ┌── H1: 5.4.6.1-6.2   Pod eviction timing
   │   ├── H2: 5.4.7.1-7.2   GitLab HA evaluation
   │   ├── H3: 5.4.8.3-8.4   Longhorn remaining items
   │   └── H4: 5.4.9.1-9.3   PodDisruptionBudgets
   ▼
Phase I ─── Automation Hardening
   │        5.4.10.1a-1c  version-checker signal quality
   │        5.4.10.2a     Nova CronJob fragility fix
   │        5.4.10.3a     Renovate decision
   │        5.4.10.4a     ARR stall resolver Discord notification
   │        5.4.10.5a-5b  Cluster janitor improvements
   ▼
Phase J ─── Cleanup + Documentation
   │        5.4.4.32     Clean up stale /Kubernetes/vault-snapshots/
   │        5.4.4.14     Decide on etcd backup encryption
   │        5.4.11.1-3   Update VERSIONS.md, Security.md, CHANGELOG.md
   ▼
─── GATE: Everything stable for 48 hours ──────────────────────────
────────────────────────────────────────────────────────────────────
   ▼
Phase K ─── Restore Drill (MANUAL ONLY - DO NOT AUTOMATE)
            5.4.4.15     Full restore drill on portfolio-dev
```

**Critical ordering constraints:**
1. **B: LimitRange BEFORE ResourceQuota** - without LimitRange defaults, pods without
   explicit limits are rejected by the quota admission controller
2. **C before D2** - new CronJob paths reference post-reorg script locations
3. **D complete before E** - off-site script needs data on NAS to pull
4. **E complete before F** - retention reductions delete old backups immediately;
   restic must have pulled them first
5. **D complete before G** - alerts reference metrics from Velero/Longhorn/CronJobs
6. **K is always last and manual** - restore drill destroys a namespace intentionally

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

- [x] 5.4.1.1 Audit current resource usage and gaps
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

- [x] 5.4.1.2 Fix known OOMKill: bazarr limit too tight (256Mi -> 512Mi)
  ```bash
  # bazarr: 256Mi limit, observed 227Mi (88% utilization) → OOMKilled
  # Increase to 512Mi to give proper headroom
  ```
  - Update `manifests/arr-stack/bazarr/deployment.yaml` memory limit: 256Mi → 512Mi
  - This is a **live issue** — fix before proceeding with other limit changes

- [x] 5.4.1.3 Set resource limits on Helm-managed workloads (cert-manager, gitlab sidecars, prometheus reloader, alloy reloader, grafana sidecar)
  - cert-manager: installed via Helm (v1.19.2) but no `helm/cert-manager/values.yaml` exists.
    Create `helm/cert-manager/values.yaml` with resource limits, then upgrade:
    ```yaml
    resources:
      requests: { cpu: 50m, memory: 64Mi }
      limits: { cpu: 200m, memory: 256Mi }
    cainjector:
      resources:
        requests: { cpu: 50m, memory: 64Mi }
        limits: { cpu: 200m, memory: 256Mi }
    webhook:
      resources:
        requests: { cpu: 50m, memory: 64Mi }
        limits: { cpu: 200m, memory: 128Mi }
    ```
  - external-secrets: limits already set in Phase 5.0 — verify they're applied
  - GitLab sidecars: review `helm/gitlab/values.yaml` for config-reloader, exporter containers
  - Review `helm/*/values.yaml` for any other components missing limits

- [x] 5.4.1.4 Set resource limits on remaining manifest workloads (all already had limits, only gap: tailscale proxy - operator-managed, out of scope)
  - Cross-reference the audit from 5.4.1.1 against manifests
  - Only modify workloads that actually lack limits (don't re-set existing ones)
  - Use the sizing strategy table above (stateless vs database vs sidecar)

- [x] 5.4.1.5 Verify no pods are OOMKilled or throttled after applying limits (0 OOMKills)
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

- [x] 5.4.1.6 Assess node overcommit after all limits applied (cp1 168%, cp2 99%, cp3 170% - actual usage 58-66%, acceptable)
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

- [x] 5.4.2.1 Create LimitRange for application namespaces (3 tiers: standard 500m/512Mi, higher 1000m/1Gi, lower 250m/256Mi)
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

- [x] 5.4.2.2 Apply LimitRange to all 13 application namespaces
  - Namespaces to cover: ghost-prod, ghost-dev, invoicetron-prod, invoicetron-dev,
    portfolio-prod, portfolio-dev, portfolio-staging, arr-stack, home, atuin,
    karakeep, ai, uptime-kuma
  - Adjust defaults based on namespace workload profile:
    - arr-stack: higher defaults (media apps use more memory)
    - portfolio-dev/staging: lower defaults (dev workloads)
  - Don't apply to: monitoring, kube-system, longhorn-system, vault,
    external-secrets, cert-manager, gitlab (Helm-managed — limits set in values)

- [x] 5.4.2.3 Verify defaults are applied to new pods (test pod in invoicetron-prod received defaults)
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

- [x] 5.4.3.1 Audit actual namespace resource usage
  ```bash
  # Per-namespace resource consumption
  for ns in ghost-prod invoicetron-prod portfolio-prod arr-stack home atuin karakeep; do
    echo "=== $ns ==="
    kubectl-homelab top pods -n $ns --no-headers 2>/dev/null | awk '{cpu+=$2; mem+=$3} END {print "CPU: "cpu"m, Memory: "mem"Mi"}'
  done
  ```
  Validate quota values against actual usage — don't use arbitrary numbers.

- [x] 5.4.3.2 Create ResourceQuota for 13 application namespaces (~1.5x current usage)
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

- [x] 5.4.3.3 Verify quotas are enforced (all namespaces Used < Hard, none exceeds 80%)
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
| **K8s resources** | Velero + Garage S3 | Deployments, Services, ConfigMaps, Secrets (namespace-scoped only) | Garage on Longhorn PVC |
| **etcd** | CronJob + etcdctl | Cluster state (the most critical backup) | NFS on NAS |

> **Note:** CRDs are cluster-scoped and require `--include-cluster-resources=true` if needed.

> **Why this split?**
> - Velero does NOT natively support NFS as a BackupStorageLocation — it requires an
>   S3-compatible API. Garage provides that API backed by Longhorn storage.
> - Longhorn native backup is more efficient than Velero FSB for volume data —
>   block-level incremental vs file-level copy.
> - etcd is NOT backed up by Velero — it requires separate `etcdctl snapshot save`.
> - Kopia is the only FSB engine (restic was deprecated in Velero v1.14, removed in v1.15).

### 5.4.4a Longhorn Volume Backups

- [x] 5.4.4.1 Create NFS backup target directory on NAS (/Kubernetes/Backups/longhorn)
  ```bash
  ssh wawashi@10.10.30.11 "sudo mount -t nfs4 10.10.30.4:/Kubernetes/Backups /tmp/nfs && \
    sudo mkdir -p /tmp/nfs/longhorn && sudo umount /tmp/nfs"
  ```

- [x] 5.4.4.2 Configure Longhorn backup target (via Helm defaultBackupStore.backupTarget, not settings CRD - removed in v1.10)
  ```bash
  # Set backup target in Longhorn settings
  kubectl-homelab -n longhorn-system edit settings backup-target
  # Set to: nfs://10.10.30.4:/Kubernetes/Backups/longhorn
  ```

- [x] 5.4.4.3 Create Longhorn RecurringJobs for critical tier (14 daily + 4 weekly, 10 volumes labeled)
  Two tiers: critical (prod data, longer retain) and important (app state, shorter retain).
  Volumes are assigned to groups via Longhorn volume labels, not the `default` group.
  See "Longhorn Exclusions" in the Retention Strategy section for volumes to skip.

  ```yaml
  # Critical tier: prod databases, git repos, secrets
  apiVersion: longhorn.io/v1beta2
  kind: RecurringJob
  metadata:
    name: daily-backup-critical
    namespace: longhorn-system
  spec:
    cron: "0 19 * * *"     # 03:00 Manila time (UTC+8). NOTE: Longhorn RecurringJob has no timeZone field - cron is always interpreted as UTC
    task: backup
    retain: 14              # 14 daily backups (deep history in restic)
    concurrency: 2
    groups:
      - critical
  ---
  apiVersion: longhorn.io/v1beta2
  kind: RecurringJob
  metadata:
    name: weekly-backup-critical
    namespace: longhorn-system
  spec:
    cron: "0 21 * * 0"     # Sunday 05:00 Manila time (staggered from daily at 03:00). NOTE: Longhorn RecurringJob has no timeZone field - cron is always interpreted as UTC
    task: backup
    retain: 4               # 4 weekly backups (~1 month)
    concurrency: 2
    groups:
      - critical
  ```

- [x] 5.4.4.4 Create Longhorn RecurringJobs for important tier (7 daily + 2 weekly, 14 volumes labeled)
  ```yaml
  # Important tier: app configs, monitoring, home services
  apiVersion: longhorn.io/v1beta2
  kind: RecurringJob
  metadata:
    name: daily-backup-important
    namespace: longhorn-system
  spec:
    cron: "0 20 * * *"     # 04:00 Manila time (UTC+8). NOTE: Longhorn RecurringJob has no timeZone field - cron is always interpreted as UTC
    task: backup
    retain: 7               # 7 daily backups
    concurrency: 2
    groups:
      - important
  ---
  apiVersion: longhorn.io/v1beta2
  kind: RecurringJob
  metadata:
    name: weekly-backup-important
    namespace: longhorn-system
  spec:
    cron: "0 22 * * 0"     # Sunday 06:00 Manila time (staggered from daily at 04:00). NOTE: Longhorn RecurringJob has no timeZone field - cron is always interpreted as UTC
    task: backup
    retain: 2               # 2 weekly backups
    concurrency: 2
    groups:
      - important
  ```

  **Volume group assignments:**

  | Group | Volumes |
  |-------|---------|
  | `critical` | ghost-prod/*, invoicetron-prod/data-db, gitlab/*, vault/data, atuin/postgres-data, karakeep/* |
  | `important` | home/adguard-data, home/myspeed-data, monitoring/prometheus-grafana, uptime-kuma/*, arr-stack/*-config, arr-stack/tdarr-server |
  | (no group) | prometheus-db, loki, alertmanager, ghost-dev/*, invoicetron-dev/*, ollama, browser/firefox-config, atuin-config, invoicetron-backups, gitlab/redis |

- [x] 5.4.4.5 Test Longhorn backup and restore (myspeed-data: backup 1.3MB, restore verified)
  ```bash
  # Trigger manual backup of a non-critical volume
  # Via Longhorn UI or CLI: create backup of portfolio-prod PVC

  # Test restore:
  # 1. Create a new PVC from backup
  # 2. Mount it in a test pod
  # 3. Verify data integrity
  # 4. Clean up test resources
  ```

### Retention Strategy: NAS as Short-Term Staging

> **Principle:** NAS is a staging area, not the final archive. Keep NAS retention short
> (just enough to survive between off-site pulls). The restic repo on OneDrive holds
> the deep history.
>
> ```
> CronJobs write to NAS daily  ->  Pull to WSL2 weekly  ->  Restic on OneDrive keeps history
>       (short retention)           (7 days staging)          (deep retention)
>       3 days on NAS (14 for PKI)  date folders              --keep-daily 7 --keep-weekly 4 --keep-monthly 6
> ```

**NAS Retention Tiers:**

| Tier | NAS Retention | Applies To | Rationale |
|------|--------------|------------|-----------|
| **Critical (prod data)** | 3 days | Ghost MySQL, GitLab, Invoicetron, etcd, Atuin | Off-site manifest confirms pull; 3 days covers a missed weekend |
| **Critical (low-churn)** | 3 days | Vault snapshots | Changes rarely (~47KB/day), manifest tracks off-site status |
| **Important (app state)** | 3 days | AdGuard, Grafana, UptimeKuma, Karakeep, MySpeed | Same 3-day buffer, manifest confirms off-site |
| **Config (rebuildable)** | 3 days | ARR configs | Painful but not catastrophic to lose |
| **Infrastructure** | 14 days | PKI certs (weekly schedule) | Weekly schedule means 3 days keeps only 0-1 backup; 14 days keeps ~2 weekly |

**Longhorn Block-Level Tiers:**

| Tier | Daily Retain | Weekly Retain | Applies To |
|------|-------------|---------------|------------|
| **Critical** | 14 | 4 | ghost-prod, invoicetron-prod, gitlab, vault, atuin, karakeep |
| **Important** | 7 | 2 | adguard, grafana, uptime-kuma, ARR configs, myspeed |

**Longhorn Exclusions (do NOT back up):**

| Volume | Actual Size | Why Excluded |
|--------|------------|--------------|
| prometheus-db | 59.9GB | Rebuildable, massive daily churn |
| storage-loki-0 | 13GB | Rebuildable, high churn |
| alertmanager-db | small | Rebuilds fast |
| ghost-dev/* | 1.9GB | Dev copy of prod |
| invoicetron-dev/* | 304MB | Dev data |
| ollama-models | 5.8GB | Re-pull from registry |
| firefox-config | 2.6GB | Disposable |
| atuin-config | 5MB | Config in manifests |
| invoicetron-backups PVC | 172MB | Migrating to NFS |
| gitlab redis | 661MB | Ephemeral cache |

**Restic (OneDrive) - Deep Archive Retention:**

```
RESTIC_KEEP_DAILY=7
RESTIC_KEEP_WEEKLY=4
RESTIC_KEEP_MONTHLY=6
```

This gives ~6 months of monthly snapshots on OneDrive - the real disaster recovery history.

### 5.4.4a.1 Existing Backup Hardening

> **Problem:** 3 existing backup CronJobs need fixes before adding new ones.
> Also reduce NAS retention on existing backups (NAS is staging, restic is archive).

> **WARNING: Run restic pull + encrypt BEFORE applying these retention reductions.**
> Reducing `find -mtime +N` immediately deletes backups older than N days on the next
> CronJob run. PKI (90->30 days) would lose ~8 weeks of history. Pull to restic first.

- [x] 5.4.4.0a Reduce Vault snapshot NAS retention from 15 to 3 days
  Update `manifests/vault/snapshot-cronjob.yaml`: `find -mtime +15` -> `find -mtime +3`

- [x] 5.4.4.0b Reduce Atuin backup NAS retention from 28 to 3 days
  Update `manifests/atuin/backup-cronjob.yaml`: `find -mtime +28` -> `find -mtime +3`

- [x] 5.4.4.0c Reduce PKI backup NAS retention from 90 to 14 days
  Update `manifests/kube-system/pki-backup.yaml`: `find -mtime +90` -> `find -mtime +14`
  (PKI runs weekly - 3 days would keep only 0-1 backups; 14 days keeps ~2 weekly)

- [x] 5.4.4.1a Move invoicetron backup from Longhorn to NFS (PVC->NFS, 30d->3d retention)
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
  - After NFS migration: verify at least 7 consecutive NFS backups appear on NAS before
    deleting the old Longhorn PVC:
    ```bash
    ssh wawashi@10.10.30.11 "sudo mount -t nfs4 10.10.30.4:/Kubernetes/Backups /tmp/nfs && \
      ls -la /tmp/nfs/invoicetron/ && sudo umount /tmp/nfs"
    # Must show 7+ files before proceeding
    ```
  - Then delete: `kubectl-admin delete pvc invoicetron-backups -n invoicetron-prod`
  - `timeZone: "Asia/Manila"` already exists (confirmed in manifest)
  - Reduce retention from 30 to 3 days (`find -mtime +3`). Deep history is in restic.

- [x] 5.4.4.1b Add Ghost MySQL backup CronJob (ghost-prod, 02:00, 3d retention, NetworkPolicy updated)
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
                    # Write mysql config to avoid password on command line (/proc exposure)
                    cat > /tmp/.my.cnf <<MYCNF
                    [mysqldump]
                    host=ghost-mysql
                    user=root
                    password=$MYSQL_ROOT_PASSWORD
                    MYCNF
                    BACKUP_FILE="/backup/ghost-$(date +%Y%m%d-%H%M%S).sql.gz"
                    mysqldump --defaults-extra-file=/tmp/.my.cnf \
                      --single-transaction --routines --triggers ghost \
                      | gzip > "$BACKUP_FILE"
                    rm -f /tmp/.my.cnf
                    echo "Backup created: $BACKUP_FILE ($(du -h "$BACKUP_FILE" | cut -f1))"
                    # Prune backups older than 3 days (deep history in restic, manifest tracks off-site)
                    find /backup -name "ghost-*.sql.gz" -mtime +3 -delete
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

- [x] 5.4.4.1c Evaluate GitLab backup strategy (deferred native backup - chart v9.8.2 doesn't expose cron schedule; covered by Longhorn + Velero)
  GitLab has its own backup rake task. Evaluate options:

  | Option | Pros | Cons |
  |--------|------|------|
  | `gitlab-backup-schedule` Helm value | Native, covers all data | Heavy (full backup each time) |
  | Velero namespace backup (5.4.4b) | Already planned | Doesn't cover Gitaly internal state |
  | Manual `gitlab-backup create` CronJob | Flexible retention | More manifests to maintain |

  **Decision:** Use GitLab's built-in backup schedule in `helm/gitlab/values.yaml`.
  > **IMPORTANT:** Verify the exact Helm value path against GitLab chart docs before implementing.
  > The path may be `gitlab.toolbox.backups.cron.schedule` (not `global.appConfig.backups.schedule`).
  ```yaml
  # Verify path - one of these:
  # Option A: gitlab.toolbox.backups.cron.schedule
  # Option B: global.appConfig.backups.schedule
  gitlab:
    toolbox:
      backups:
        cron:
          enabled: true
          schedule: "0 3 * * *"   # Daily 03:00 Manila (verify chart supports timeZone)
  ```
  > Verify this works with the existing MinIO in the gitlab namespace before adding
  > a separate CronJob. If GitLab's MinIO already has backup capability, use it.

### 5.4.4b Velero for K8s Resource Backup

- [x] 5.4.4.6 Deploy Garage S3 as backend for Velero
  Garage (garagehq.deuxfleurs.fr) replaces MinIO (repo archived Feb 2026). Garage is a
  lightweight S3-compatible object store (~21MB image, ~3MB idle RAM, Rust, AGPL-3.0).
  Single-node mode with `replication_factor = 1` for backup target.
  Image: `dxflrs/garage:v2.2.0`

  **Deployment components:**
  1. Create `velero` namespace manifest with PSS label (`pod-security.kubernetes.io/enforce: baseline`)
  2. Create 1Password item "Garage S3" in Kubernetes vault with fields:
     `rpc-secret` (openssl rand -hex 32), `admin-token` (openssl rand -base64 32),
     `metrics-token` (openssl rand -base64 32), `s3-access-key-id`, `s3-secret-access-key`
     > User creates in 1Password. Generate S3 keys after Garage is running via admin API.
  3. Add Garage Vault paths to `scripts/vault/seed-vault-from-1password.sh`
  4. Create ExternalSecret for Garage secrets in `velero` namespace
  5. Create ConfigMap with `garage.toml`:
     ```toml
     metadata_dir = "/var/lib/garage/meta"
     data_dir = "/var/lib/garage/data"
     db_engine = "sqlite"
     replication_factor = 1
     compression_level = 1

     rpc_bind_addr = "[::]:3901"
     rpc_public_addr = "127.0.0.1:3901"
     # rpc_secret from GARAGE_RPC_SECRET env var

     [s3_api]
     s3_region = "garage"
     api_bind_addr = "[::]:3900"
     root_domain = ".s3.garage.localhost"

     [admin]
     api_bind_addr = "0.0.0.0:3903"
     # admin_token from GARAGE_ADMIN_TOKEN env var
     # metrics_token from GARAGE_METRICS_TOKEN env var
     ```
  6. Deploy Garage StatefulSet (single replica) with:
     - Longhorn PVC for data (NFS optional - Longhorn is simpler for single-node)
     - Secrets from ESO ExternalSecret via env vars (GARAGE_RPC_SECRET, GARAGE_ADMIN_TOKEN, GARAGE_METRICS_TOKEN)
     - Resource limits: requests 50m/64Mi, limits 500m/256Mi
     - Ports: 3900 (S3 API), 3901 (RPC), 3903 (admin + metrics)
     - Readiness probe: `GET /health` on port 3903
     - Service: ClusterIP exposing ports 3900 + 3903
  7. Post-deploy init Job (via admin API on port 3903):
     - Get node ID: `GET /v2/GetClusterStatus`
     - Assign layout: `POST /v2/UpdateClusterLayout` with zone + capacity
     - Apply layout: `POST /v2/ApplyClusterLayout` with version 1
     - Create API key: `POST /v2/CreateKey` (name: velero-key)
     - Create bucket: `POST /v2/CreateBucket` (globalAlias: velero-backups)
     - Allow key on bucket: `POST /v2/AllowBucketKey` (read + write + owner)
     - Store S3 access key ID + secret in 1Password (user updates the item)
  8. Create ExternalSecret `velero-s3-credentials` with template composing AWS credentials
     file format from Vault path `secret/velero/s3-credentials` (declarative, ArgoCD-ready)
  9. Create CiliumNetworkPolicy for velero namespace (Garage<->Velero, Prometheus->metrics)
  10. Create ServiceMonitor for Garage metrics (port 3903, bearer token auth)

  > **Note:** Don't use `kubectl create namespace` - create via manifest with PSS labels.
  > Use `db_engine = "sqlite"` (not lmdb) - safer on unclean pod shutdown in K8s.
  > `checksumAlgorithm: ""` required in Velero BSL config (AWS SDK v2 CRC32 breaks Garage).

- [x] 5.4.4.6a Install velero CLI on WSL2
  ```bash
  # Download and install velero CLI (server components come via Helm)
  # Upgraded from plan's v1.15.2 to v1.18.0 (v1.15.x no longer in Helm repo)
  VELERO_VERSION=v1.18.0
  curl -fsSL https://github.com/vmware-tanzu/velero/releases/download/${VELERO_VERSION}/velero-${VELERO_VERSION}-linux-amd64.tar.gz | \
    tar xz -C /tmp && sudo mv /tmp/velero-${VELERO_VERSION}-linux-amd64/velero /usr/local/bin/
  velero version --client-only
  ```

- [x] 5.4.4.7 Add Velero Helm repo and create values
  ```bash
  helm-homelab repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts --force-update
  helm-homelab repo update
  ```
  ```yaml
  # helm/velero/values.yaml
  # Upgraded: chart 12.0.0 (Velero v1.18.0), plugin v1.14.0
  configuration:
    backupStorageLocation:
      - name: default
        provider: aws           # Garage is S3-compatible, uses AWS plugin
        bucket: velero-backups
        default: true
        credential:
          name: velero-s3-credentials    # K8s Secret with Garage S3 access/secret key
          key: cloud
        config:
          region: garage
          s3ForcePathStyle: "true"
          s3Url: http://garage.velero.svc.cluster.local:3900
          checksumAlgorithm: ""  # Required: AWS SDK v2 CRC32 breaks Garage
    volumeSnapshotLocation: []  # Longhorn handles volume snapshots

  initContainers:
    - name: velero-plugin-for-aws
      image: velero/velero-plugin-for-aws:v1.14.0  # Compatible with Velero v1.18.0
      imagePullPolicy: IfNotPresent
      volumeMounts:
        - mountPath: /target
          name: plugins

  deployNodeAgent: false         # Not needed - Longhorn handles volume backups

  resources:
    requests: { cpu: 100m, memory: 256Mi }
    limits: { cpu: 500m, memory: 512Mi }

  metrics:
    enabled: true
    serviceMonitor:
      enabled: true
      additionalLabels:
        release: prometheus     # Required for Prometheus Operator discovery
  ```

  > **Note:** Without the ServiceMonitor, Prometheus never scrapes Velero metrics and
  > the VeleroBackupFailed/VeleroBackupStale alerts (5.4.5.1) silently never fire.
  > `deployNodeAgent: false` - Longhorn handles volume backups, Velero only backs up K8s resources.
  > `velero-plugin-for-aws:v1.14.0` - compatible with Velero v1.18.0.

- [x] 5.4.4.8 Install Velero
  ```bash
  helm-homelab install velero vmware-tanzu/velero \
    --namespace velero \
    --values helm/velero/values.yaml
  ```

- [x] 5.4.4.9 Create scheduled backup for K8s resources
  Deployed as declarative `manifests/velero/schedule.yaml` (Schedule CRD) instead of
  imperative `velero schedule create` - preparation for ArgoCD in Phase 6.
  ```yaml
  # manifests/velero/schedule.yaml
  # Daily backup at 04:30 Manila time (20:30 UTC)
  # TTL 720h = 30 days, secrets excluded, no volume backup (Longhorn handles that)
  schedule: "30 20 * * *"
  includedNamespaces: [portfolio-prod, portfolio-dev, portfolio-staging, ...]
  excludedResources: [secrets]
  defaultVolumesToFsBackup: false
  ```
  > **Note:** `defaultVolumesToFsBackup: false` because Longhorn handles volume
  > backup natively. Velero only backs up K8s resource manifests here.
  > Secrets excluded - vault-unseal-keys would be stored unencrypted in Garage. Vault data covered by dedicated snapshot CronJob.

- [x] 5.4.4.10 Test Velero backup and restore
  Test backup on portfolio-dev: 34 items backed up, 0 errors, completed in 1s.
  ```bash
  velero backup create test-backup --include-namespaces portfolio-dev
  velero backup describe test-backup --details
  velero backup logs test-backup
  ```

### 5.4.4c etcd Backup

> **CRITICAL:** etcd contains ALL cluster state. Losing etcd = rebuild from scratch.
> Neither Velero nor Longhorn backs up etcd. This needs a separate solution.

- [x] 5.4.4.11 Create NFS directory for etcd backups (/Kubernetes/Backups/etcd)
  ```bash
  ssh wawashi@10.10.30.11 "sudo mount -t nfs4 10.10.30.4:/Kubernetes/Backups /tmp/nfs && \
    sudo mkdir -p /tmp/nfs/etcd && sudo umount /tmp/nfs"
  ```

- [x] 5.4.4.12 Create etcd backup CronJob (03:30, alpine initContainer downloads etcdctl, hostNetwork for localhost:2379)
  ```yaml
  # The etcd backup must run ON the control plane node (needs access to etcd certs)
  # Option A: CronJob with hostPath mount to etcd PKI
  # Option B: Ansible cron task on cp1 running etcdctl snapshot save
  #
  # IMPORTANT: registry.k8s.io/etcd:3.6.6-0 is DISTROLESS - no shell, no coreutils.
  # Use alpine/k8s (already on all nodes) with etcdctl downloaded from the etcd release.
  # Two containers: init downloads etcdctl, main runs backup + prune.
  apiVersion: batch/v1
  kind: CronJob
  metadata:
    name: etcd-backup
    namespace: kube-system
  spec:
    schedule: "30 3 * * *"        # 03:30 Manila time
    timeZone: "Asia/Manila"
    concurrencyPolicy: Forbid
    successfulJobsHistoryLimit: 1
    failedJobsHistoryLimit: 3
    jobTemplate:
      spec:
        backoffLimit: 0
        activeDeadlineSeconds: 300
        template:
          spec:
            restartPolicy: Never
            automountServiceAccountToken: false
            nodeSelector:
              node-role.kubernetes.io/control-plane: ""
            tolerations:
              - key: node-role.kubernetes.io/control-plane
                effect: NoSchedule
            securityContext:
              seccompProfile:
                type: RuntimeDefault
            initContainers:
              - name: get-etcdctl
                image: registry.k8s.io/etcd:3.6.6-0
                # Copy etcdctl binary from distroless image to shared volume
                command: ["cp", "/usr/local/bin/etcdctl", "/tools/etcdctl"]
                volumeMounts:
                  - name: tools
                    mountPath: /tools
            containers:
              - name: etcd-backup
                image: alpine/k8s:1.35.0  # Has shell + coreutils, already on all nodes
                command: ["/bin/sh", "-c"]
                args:
                  - |
                    BACKUP_FILE="/backup/etcd-$(date +%Y%m%d-%H%M%S).db"
                    /tools/etcdctl snapshot save "$BACKUP_FILE" \
                      --endpoints=https://127.0.0.1:2379 \
                      --cacert=/etc/kubernetes/pki/etcd/ca.crt \
                      --cert=/etc/kubernetes/pki/etcd/server.crt \
                      --key=/etc/kubernetes/pki/etcd/server.key
                    /tools/etcdctl snapshot status "$BACKUP_FILE" --write-out=table
                    echo "Backup created: $BACKUP_FILE ($(du -h "$BACKUP_FILE" | cut -f1))"
                    # Prune backups older than 3 days (deep history in restic, manifest tracks off-site)
                    find /backup -name "etcd-*.db" -mtime +3 -delete
                securityContext:
                  allowPrivilegeEscalation: false
                  capabilities:
                    drop: ["ALL"]
                resources:
                  requests: { cpu: 50m, memory: 64Mi }
                  limits: { cpu: 200m, memory: 256Mi }
                volumeMounts:
                  - name: tools
                    mountPath: /tools
                    readOnly: true
                  - name: etcd-certs
                    mountPath: /etc/kubernetes/pki/etcd
                    readOnly: true
                  - name: backup
                    mountPath: /backup
            volumes:
              - name: tools
                emptyDir: {}
              - name: etcd-certs
                hostPath:
                  path: /etc/kubernetes/pki/etcd
              - name: backup
                nfs:
                  server: 10.10.30.4
                  path: /Kubernetes/Backups/etcd
  ```

- [x] 5.4.4.13 Test etcd backup and document restore procedure (109MB snapshot verified)
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

  > **DO NOT AUTOMATE. MANUAL DRILL ONLY.** The following procedure intentionally
  > destroys a namespace to test restore. Never execute this via an implementation agent
  > or automated script. Run by hand, with confirmation at each step.

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
>                      (block-level, fast)           (logical, portable)   (DB dumps + app backups only)
> ```
> Any single layer can fail and data is still recoverable.
> Note: Restic off-site covers DB dumps, app file backups, etcd, Vault, and PKI from
> `/Kubernetes/Backups/`. Longhorn block-level snapshots stay on NAS only (too large for off-site).

> **Pattern:** All CronJobs below follow the same template as existing Vault/Atuin backups:
> NFS volume mount, nightly schedule, retention via `find -mtime`, `timeZone: "Asia/Manila"`,
> `automountServiceAccountToken: false`, `seccompProfile: RuntimeDefault`.
>
> **Schedule staggering:** Existing vault-snapshot runs at 02:00. Stagger new CronJobs
> across 02:00-02:30 to avoid NFS contention (all write to the same NAS):
> Ghost MySQL 02:00, AdGuard 02:05, UptimeKuma 02:10, Karakeep 02:15,
> Grafana 02:20, ARR configs 02:25, MySpeed 02:30. Atuin (weekly) stays at 02:00.

- [x] 5.4.4.16 Create AdGuard backup CronJob (02:05, SQLite .backup, 17MB verified)
  SQLite backup via `.backup` API (NOT raw file copy - raw cp of live SQLite corrupts on WAL mode).
  Container needs `sqlite3` installed (alpine + `apk add sqlite`).
  ```bash
  # Create NFS directory
  ssh wawashi@10.10.30.11 "sudo mount -t nfs4 10.10.30.4:/Kubernetes/Backups /tmp/nfs && \
    sudo mkdir -p /tmp/nfs/adguard && sudo umount /tmp/nfs"
  ```
  - Manifest: `manifests/home/adguard/backup-cronjob.yaml`
  - Schedule: `5 2 * * *` (daily 02:05 PHT - staggered)
  - Source: PVC `adguard-data` mounted directly (not via subPath). Deployment uses two
    subPath mounts (`conf/` and `work/`), but the backup CronJob must mount the raw PVC
    to capture both directories.
  - Backup method: `sqlite3 /data/work/data.db ".backup /backup/adguard-$(date ...).db"`
    for SQLite files, `cp -a /data/conf/ /backup/conf-$(date ...)` for config
  - Target: NFS `10.10.30.4:/Kubernetes/Backups/adguard`
  - Retention: 3 days (deep history in restic, manifest tracks off-site)

- [x] 5.4.4.17 Create UptimeKuma backup CronJob (02:10, SQLite .backup, 19MB verified)
  SQLite backup via `.backup` API (NOT raw file copy).
  ```bash
  ssh wawashi@10.10.30.11 "sudo mount -t nfs4 10.10.30.4:/Kubernetes/Backups /tmp/nfs && \
    sudo mkdir -p /tmp/nfs/uptime-kuma && sudo umount /tmp/nfs"
  ```
  - Manifest: `manifests/uptime-kuma/backup-cronjob.yaml`
  - Schedule: `10 2 * * *` (daily 02:10 PHT - staggered)
  - Source: `/app/data/kuma.db` (SQLite)
  - Backup method: `sqlite3 /data/kuma.db ".backup /backup/kuma-$(date ...).db"`
  - Target: NFS `10.10.30.4:/Kubernetes/Backups/uptime-kuma`
  - Retention: 3 days (deep history in restic, manifest tracks off-site)

- [x] 5.4.4.18 Create Karakeep backup CronJob (02:15, karakeep-data only, meilisearch rebuildable, 33MB verified)
  Data directory + meilisearch to NFS.
  ```bash
  ssh wawashi@10.10.30.11 "sudo mount -t nfs4 10.10.30.4:/Kubernetes/Backups /tmp/nfs && \
    sudo mkdir -p /tmp/nfs/karakeep && sudo umount /tmp/nfs"
  ```
  - Manifest: `manifests/karakeep/backup-cronjob.yaml`
  - Schedule: `15 2 * * *` (daily 02:15 PHT - staggered)
  - Source: Karakeep data PVC + meilisearch data PVC
  - Target: NFS `10.10.30.4:/Kubernetes/Backups/karakeep`
  - Retention: 3 days (deep history in restic, manifest tracks off-site)

- [x] 5.4.4.19 Create Grafana backup CronJob (02:20, SQLite .backup, NetworkPolicy updated, 3.5MB verified)
  SQLite backup via `.backup` API (NOT raw file copy).
  ```bash
  ssh wawashi@10.10.30.11 "sudo mount -t nfs4 10.10.30.4:/Kubernetes/Backups /tmp/nfs && \
    sudo mkdir -p /tmp/nfs/grafana && sudo umount /tmp/nfs"
  ```
  - Manifest: `manifests/monitoring/grafana-backup-cronjob.yaml`
  - Schedule: `20 2 * * *` (daily 02:20 PHT - staggered)
  - Source: `/var/lib/grafana/grafana.db` (SQLite)
  - Backup method: `sqlite3 /data/grafana.db ".backup /backup/grafana-$(date ...).db"`
  - Target: NFS `10.10.30.4:/Kubernetes/Backups/grafana`
  - Retention: 3 days (deep history in restic, manifest tracks off-site)

- [x] 5.4.4.20 Create ARR configs backup CronJobs (3 per-node CronJobs: cp1/cp2/cp3, 02:25, 244MB total verified)
  **IMPORTANT:** ARR pods are spread across all 3 nodes (cp1: prowlarr/qbittorrent,
  cp2: bazarr/radarr/sonarr/tdarr, cp3: jellyfin). A single CronJob CANNOT mount
  all 10 RWO PVCs - they're attached to different nodes.

  **Approach:** Separate per-node CronJobs with nodeSelector matching the app's node.
  Each CronJob mounts only the PVCs on its node.
  ```bash
  ssh wawashi@10.10.30.11 "sudo mount -t nfs4 10.10.30.4:/Kubernetes/Backups /tmp/nfs && \
    sudo mkdir -p /tmp/nfs/arr-configs && sudo umount /tmp/nfs"
  ```
  - Manifests: `manifests/arr-stack/backup-cronjob-cp1.yaml` (prowlarr, qbittorrent)
               `manifests/arr-stack/backup-cronjob-cp2.yaml` (bazarr, radarr, sonarr, tdarr-*, seerr, recommendarr)
               `manifests/arr-stack/backup-cronjob-cp3.yaml` (jellyfin)
  - Schedule: `25 2 * * *` (daily 02:25 PHT - staggered, all 3 run in parallel)
  - For SQLite config DBs: use `sqlite3 <db> ".backup <dest>"` (NOT raw cp)
  - For non-SQLite configs: `cp -a` is fine
  - Target: NFS `10.10.30.4:/Kubernetes/Backups/arr-configs/<app>/`
  - Retention: 3 days
  - **Note:** If apps move between nodes (rescheduled), nodeSelector needs updating.
    Consider using podAffinity matching each app's labels instead for resilience.

- [x] 5.4.4.21 Create MySpeed backup CronJob (02:30, SQLite .backup, 100KB verified)
  SQLite backup via `.backup` API (NOT raw file copy).
  ```bash
  ssh wawashi@10.10.30.11 "sudo mount -t nfs4 10.10.30.4:/Kubernetes/Backups /tmp/nfs && \
    sudo mkdir -p /tmp/nfs/myspeed && sudo umount /tmp/nfs"
  ```
  - Manifest: `manifests/home/myspeed/backup-cronjob.yaml`
  - Schedule: `30 2 * * *` (daily 02:30 PHT - staggered)
  - Source: MySpeed data PVC (SQLite)
  - Backup method: `sqlite3 /data/myspeed.db ".backup /backup/myspeed-$(date ...).db"`
  - Target: NFS `10.10.30.4:/Kubernetes/Backups/myspeed`
  - Retention: 3 days (deep history in restic, manifest tracks off-site)

- [x] 5.4.4.22 Verify all new backup CronJobs run successfully (all 11 CronJobs tested, backups on NAS)
  ```bash
  # Trigger manual run of each new CronJob
  kubectl-homelab create job --from=cronjob/<name> test-<name> -n <namespace>
  # Verify backup files appear on NAS AND are not corrupt
  ssh wawashi@10.10.30.11 "sudo mount -t nfs4 10.10.30.4:/Kubernetes/Backups /tmp/nfs && \
    find /tmp/nfs -type f -mmin -60 && sudo umount /tmp/nfs"
  # For SQLite backups, verify integrity:
  # sqlite3 <backup-file> "PRAGMA integrity_check;"
  # For gzipped dumps, verify: gzip -t <file>
  ```

- [x] 5.4.4.22a Replace `alpine:3.21` + `apk add sqlite` with `keinos/sqlite3:3.46.1`
  8 CronJobs updated. Added runAsNonRoot: true + readOnlyRootFilesystem: true (no more
  root needed). Removed internet egress from Grafana backup NetworkPolicy (no more CDN fetch).
  Eliminates runtime internet dependency and 2-min Grafana latency.

### 5.4.4f Off-Site Encrypted Backup

> **Why:** All cluster backups (etcd, Vault, DB dumps, PKI, Longhorn volume snapshots,
> app backups) land on a single NAS with one drive. If the NAS fails, all backups are lost.
> This section adds an encrypted, off-site copy using restic on WSL2.

> **Tool:** Restic (AES-256-CTR + Poly1305-AES encryption, content-defined chunking dedup)
> **Trigger:** Manual on-demand (not automated - WSL2 is not always running)

> **Note:** "restic" here refers to the standalone backup CLI tool (https://restic.net),
> NOT the deprecated Velero FSB engine (also named "restic", removed in Velero v1.15).

#### Architecture

```
WSL2 --SSH--> cp1 --NFS mount--> NAS (/Kubernetes/Backups)
                                       |
                                  rsync back to WSL2
                                       |
                                       v
                        Staging: /mnt/c/rcporras/homelab/backup/
                                  YYYY-MM-DD/<app>/files...
                                       |
                                  restic backup (encrypt + dedup)
                                       |
                                       v
                        Restic repo: /mnt/c/Users/rcporras/
                          OneDrive - Hexagon/Personal/Homelab/Backup/
                                       |
                                  Windows OneDrive client syncs to cloud
                                       |
                                  (optional) manual copy to Google Drive via browser
```

**One restic repository:** `k8s-configs` only. Media repo (Immich) deferred - no data yet.

**Explicitly excluded from restic:** `/Kubernetes/Media/` (torrents + media files)

#### Machine Constraints

| Machine | Storage | NAS Access | Cloud Target | Status |
|---------|---------|------------|-------------|--------|
| WSL2 (work laptop) | 2TB NVMe | No NFS (corporate blocker), SSH to cp1 | OneDrive (auto-sync) + Google Drive (manual browser) | Active |
| Aurora (Fedora Kinoite) | 500GB | Direct NFS | Google Drive (rclone or manual) | Deferred |

WSL2 cannot NFS-mount the NAS due to corporate network restrictions. Instead, it SSHes
to k8s-cp1 (which can NFS-mount), rsyncs the backup data back, then encrypts locally.

NFS share `Kubernetes` on OMV widened to `10.10.0.0/16` (done 2026-03-17).

#### Scripts Directory Reorganization

> **Why:** `scripts/` has 7 files at the root level. Adding backup files would make it
> cluttered. Group by purpose before adding new scripts.

**Before (flat):**
```
scripts/
├── configure-vault.sh
├── seed-vault-from-1password.sh
├── sync-ghost-prod-to-dev.sh
├── sync-ghost-prod-to-local.sh
├── test-cloudflare-networkpolicy.sh
├── upgrade-prometheus.sh
└── verify-migration.sh
```

**After (grouped):**
```
scripts/
├── backup/
│   ├── homelab-backup.sh
│   ├── config.example          (versioned template)
│   ├── config                  (.gitignored)
│   └── .password               (.gitignored)
├── vault/
│   ├── configure-vault.sh
│   ├── seed-vault-from-1password.sh
│   └── verify-migration.sh
├── ghost/
│   ├── sync-ghost-prod-to-dev.sh
│   └── sync-ghost-prod-to-local.sh
├── monitoring/
│   └── upgrade-prometheus.sh
└── test/
    └── test-cloudflare-networkpolicy.sh
```

**Active docs to update after reorg** (completed/historical docs stay as-is):
- `docs/SETUP.md` - seed-vault path
- `docs/context/Architecture.md` - seed-vault path
- `docs/context/Secrets.md` - seed-vault, upgrade-prometheus paths
- `docs/context/Monitoring.md` - upgrade-prometheus path
- `docs/context/Conventions.md` - scripts directory listing

#### Two-Step Backup Workflow

**Step 1: `pull`** - SSH to cp1, NFS mount on cp1, rsync FROM cp1 TO WSL2 staging, update manifest on NAS
**Step 2: `encrypt`** - restic backup staging folder to OneDrive repo, update manifest with snapshot ID

All NAS access is via SSH to cp1 (WSL2 cannot NFS-mount due to corporate restrictions).

`pull` flow:
1. `ssh cp1 "sudo mount -t nfs4 10.10.30.4:/Kubernetes/Backups /tmp/homelab-backup-nfs"`
2. `rsync -avz wawashi@cp1:/tmp/homelab-backup-nfs/ staging/YYYY-MM-DD/` (pulls TO WSL2)
3. `ssh cp1` - write/update `.offsite-manifest.json` on NAS (see Off-Site Manifest below)
4. `ssh cp1 "sudo umount /tmp/homelab-backup-nfs"`

`encrypt` flow:
1. `restic backup` staging folder to OneDrive repo
2. `restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune`
3. `restic check --with-cache`
4. `ssh cp1` - update `.offsite-manifest.json` with restic snapshot ID + encrypt timestamp

Two steps give a checkpoint to inspect pulled data before encrypting. Each step
can be run independently (e.g., re-encrypt without re-pulling).

**Subcommands:**
```bash
./scripts/backup/homelab-backup.sh setup     # One-time: seed password, init repo
./scripts/backup/homelab-backup.sh pull      # SSH to cp1 -> NFS mount -> rsync to staging -> update manifest
./scripts/backup/homelab-backup.sh encrypt   # restic backup staging -> OneDrive repo -> update manifest
./scripts/backup/homelab-backup.sh status    # Read manifest from NAS via SSH, show backup state
./scripts/backup/homelab-backup.sh prune     # Delete staging folders older than N days (checks encryption first)
./scripts/backup/homelab-backup.sh restore   # List snapshots, select one, restore to target dir
```

**Typical usage (weekly habit):**
```bash
./scripts/backup/homelab-backup.sh pull
./scripts/backup/homelab-backup.sh encrypt
./scripts/backup/homelab-backup.sh prune
```

#### Off-Site Manifest

> **Why:** NAS CronJobs use blind time-based pruning (`find -mtime +3`). Without knowing
> whether files have been pulled off-site, they either keep data too long (wasting NAS space)
> or delete too early (losing unpulled backups). The manifest bridges this gap.

**File:** `/Kubernetes/Backups/.offsite-manifest.json` on NAS

```json
{
  "last_pull": "2026-03-20T14:30:00+08:00",
  "last_encrypt": "2026-03-20T14:35:00+08:00",
  "restic_snapshot": "abc123de",
  "pulled_files": {
    "vault/vault-20260319.snap": "2026-03-20",
    "vault/vault-20260318.snap": "2026-03-20",
    "atuin/atuin-backup-2026-03-15.pg_dump": "2026-03-20",
    "ghost/ghost-20260320-020000.sql.gz": "2026-03-20",
    "etcd/etcd-20260320-033000.db": "2026-03-20",
    "arr-configs/sonarr/sonarr.db": "2026-03-20"
  }
}
```

**How it's written (all via SSH from WSL2):**

```bash
# pull step - after rsync completes, before unmount:
ssh wawashi@10.10.30.11 "sudo mount -t nfs4 10.10.30.4:/Kubernetes/Backups /tmp/nfs && \
  cat > /tmp/manifest-update.sh << 'SCRIPT'
    # Build file list from what was just rsync'd
    MANIFEST=/tmp/nfs/.offsite-manifest.json
    TIMESTAMP=\$(date -Iseconds)
    # ... jq or python to merge pulled files into manifest ...
    # Update last_pull timestamp
  SCRIPT
  bash /tmp/manifest-update.sh && \
  sudo umount /tmp/nfs"

# encrypt step - after restic backup succeeds:
ssh wawashi@10.10.30.11 "sudo mount -t nfs4 10.10.30.4:/Kubernetes/Backups /tmp/nfs && \
  # Update last_encrypt and restic_snapshot in .offsite-manifest.json
  sudo umount /tmp/nfs"
```

**How it's read (`status` subcommand):**

```bash
# status reads manifest via SSH (mount, read, unmount on cp1):
ssh wawashi@10.10.30.11 "sudo mount -t nfs4 10.10.30.4:/Kubernetes/Backups /tmp/nfs && \
  cat /tmp/nfs/.offsite-manifest.json && \
  sudo umount /tmp/nfs"
```

**`status` output example:**
```
Off-Site Manifest (/Kubernetes/Backups/.offsite-manifest.json):
  Last pull:     2026-03-20 14:30 PHT (2 days ago)
  Last encrypt:  2026-03-20 14:35 PHT (snapshot abc123de)
  Files pulled:  47 files across 12 apps
  ⚠️  WARNING: 3 files on NAS not yet pulled (newer than last pull)

Staging:  /mnt/c/rcporras/homelab/backup/
  Latest pull:  2026-03-20 (142MB)
  Folders:      3 (2026-03-17, 2026-03-18, 2026-03-20)
  Total size:   418MB

Restic repo:  /mnt/c/Users/rcporras/OneDrive - Hexagon/Personal/Homelab/Backup/
  Snapshots:    12
  Latest:       2026-03-20 (abc123de)
  Repo size:    89MB (deduplicated)
```

**Design decisions:**
- Manifest is written by `pull` and `encrypt` only (not by CronJobs)
- CronJobs keep simple `find -mtime +3 -delete` (dumb, reliable, no manifest dependency)
- If manifest is missing or corrupt, `pull`/`encrypt` recreate it - not a hard failure
- The manifest is informational + safety check, not a control mechanism for CronJobs

#### Staging Directory Structure

Date-stamped folders so you can browse and delete specific days:

```
/mnt/c/rcporras/homelab/backup/
├── 2026-03-19/
│   ├── atuin/
│   │   └── atuin-backup-2026-03-15.pg_dump
│   ├── vault/
│   │   ├── vault-20260318.snap
│   │   └── vault-20260317.snap
│   ├── pki/
│   │   └── pki-20260315-120002/
│   ├── ghost/
│   │   └── ghost-20260319-020000.sql.gz
│   ├── invoicetron/
│   │   └── invoicetron-20260319.sql.gz
│   ├── etcd/
│   │   └── etcd-20260319-033000.db
│   ├── adguard/
│   ├── grafana/
│   ├── arr-configs/
│   ├── uptime-kuma/
│   ├── karakeep/
│   └── myspeed/
├── 2026-03-18/
│   └── ... (previous pull)
└── 2026-03-17/
    └── ... (older pull)
```

Restic repo (OneDrive) is machine-managed encrypted blobs - not human-browsable.

#### Configuration & Secrets

**`scripts/backup/config.example`** (versioned, no secrets):
```bash
# Copy to config and edit for your machine
# cp config.example config

# SSH access to NAS (via k8s node)
SSH_HOST=wawashi@10.10.30.11
NFS_SERVER=10.10.30.4
NFS_EXPORT=/Kubernetes/Backups
NFS_MOUNT=/tmp/homelab-backup-nfs

# Local staging (raw backups, human-browsable)
STAGING_DIR=/mnt/c/rcporras/homelab/backup

# Restic repo (encrypted, synced to cloud)
RESTIC_REPO="/mnt/c/Users/rcporras/OneDrive - Hexagon/Personal/Homelab/Backup"

# Retention
STAGING_KEEP_DAYS=7
RESTIC_KEEP_DAILY=7
RESTIC_KEEP_WEEKLY=4
RESTIC_KEEP_MONTHLY=6

# Vault address (for fetching restic password)
VAULT_ADDR=https://vault.k8s.rommelporras.com
VAULT_SECRET_PATH=secret/backups/restic-k8s-configs
VAULT_SECRET_KEY=password

# Backup sources to pull from NFS
BACKUP_SOURCES="atuin vault pki ghost invoicetron etcd adguard grafana arr-configs uptime-kuma karakeep myspeed"
```

**`scripts/backup/config`** + **`scripts/backup/.password`** - `.gitignored`, machine-specific.

**`setup` subcommand flow:**
1. Verify `config` exists (error if not - tell user to copy from `config.example`)
2. Try Vault: `vault kv get -field=password secret/backups/restic-k8s-configs`
3. If Vault unavailable: prompt user to paste from 1Password (`op://Kubernetes/Restic Backup Keys/k8s-configs-password`)
4. Write password to `scripts/backup/.password`
5. Initialize restic repo if first run
6. Print confirmation with config, repo path, and status

Password file is read by restic via `--password-file` (never CLI argument).

#### Encryption & Key Management

**Algorithm:** Restic AES-256-CTR + Poly1305-AES (encrypt-then-MAC). Every blob independently
encrypted and authenticated. Master key derived via scrypt KDF from password.

IT admins with OneDrive access see encrypted blobs - cannot read backup content.

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
    Fields: k8s-configs-password, k8s-configs-recovery
    |
    v
Seed to Vault via scripts/vault/seed-vault-from-1password.sh:
    secret/backups/restic-k8s-configs password=<from 1P>
    |
    v
restic key add (create recovery password, different from primary)
    |
    v
Store recovery key ONLY in 1Password: same item
    Field: k8s-configs-recovery
```

| Password | Stored In | Purpose |
|----------|-----------|---------|
| Primary | Vault + 1Password | Daily operational use by script |
| Recovery | 1Password only | DR when Vault is unavailable |

**Script auth fallback:** Vault (`vault kv get`) -> interactive prompt (paste from 1Password).
`op read` not in fallback chain (Family plan has no Connect for unattended access).

**Key rotation:** `restic key add` (new) -> `restic key remove` (old) -> update Vault + 1Password.
Does not re-encrypt existing data blobs (restic limitation).

#### NAS Storage Budget

**Current:** 1.8TB total, 578GB available (69% used). Media: 842GB. Backups: 11MB.

> **Principle:** NAS holds short-term staging only. Deep history lives in restic on OneDrive.
> See Retention Strategy section above for tier definitions.

**Projected NAS backup usage (all CronJobs deployed, 3-day retention + manifest):**

| Category | Retention | Estimated Steady-State |
|----------|-----------|----------------------|
| DB dumps - critical (Ghost, GitLab, Invoicetron, Atuin) | 3 days | ~900MB |
| DB dumps - critical (etcd, Vault) | 3 days | ~300MB |
| App file backups (AdGuard, Grafana, UptimeKuma, Karakeep, MySpeed) | 3 days | ~2GB |
| ARR configs (10 PVCs) | 3 days | ~15GB |
| PKI certs | 14 days weekly | ~30KB |
| Longhorn critical tier (14 daily + 4 weekly, excl. prometheus/loki/dev) | tiered | ~40-55GB |
| Longhorn important tier (7 daily + 2 weekly) | tiered | ~15-25GB |
| Off-site manifest (.offsite-manifest.json) | permanent | ~10KB |
| **Total** | | **~73-98GB** |

578GB available vs ~98GB needed = **~480GB headroom**. Media can grow comfortably.

> **Key savings:** 3-day NAS retention (with off-site manifest tracking) + Longhorn
> exclusions (prometheus/loki/dev). All history preserved in restic on OneDrive
> (deep archive: 7 daily + 4 weekly + 6 monthly). Manifest confirms off-site status
> so 3-day retention is safe even if you miss a weekly pull.

#### Error Handling

**`pull` failures:**

| Failure | Behavior |
|---------|----------|
| SSH to cp1 fails | Error + exit: `Cannot reach k8s-cp1. Check VPN/network.` |
| NFS mount fails on cp1 | Error + exit: `NFS mount failed on cp1. Check NAS is online.` |
| rsync partial failure | Continue with warnings. Missing source dirs skipped (CronJob may not be deployed yet). |
| Today's date folder exists | rsync overwrites (idempotent): `Updating existing pull for 2026-03-19` |
| NFS umount fails on cp1 | Warn but don't error (stale mount cleans up on reboot) |

**`encrypt` failures:**

| Failure | Behavior |
|---------|----------|
| No staging folder | Error: `No backup data found. Run ./homelab-backup.sh pull first` |
| Password file missing | Error: `Run ./homelab-backup.sh setup first` |
| Restic repo locked | Warn, suggest `restic unlock`. Don't auto-unlock. |
| OneDrive path missing | Error: `OneDrive path not found. Is OneDrive running?` |

**`prune` safety:**

| Scenario | Behavior |
|----------|----------|
| Would delete all folders | Refuse: `Would delete all staging data. Keep at least 1 folder.` |
| No folders older than N days | No-op: `Nothing to prune.` |
| Folder not yet encrypted | Warn: `2026-03-19 has not been encrypted yet. Skipping.` (check if restic has a snapshot tagged with that date) |

**General:**
- Every subcommand validates config exists before proceeding
- All operations print what they will do before doing it
- Non-zero exit codes propagate (`pull && encrypt` works)
- No `set -e` (too brittle for SSH + mount + rsync). Explicit error checks per operation.

#### Tasks

- [x] 5.4.4.23 Reorganize `scripts/` directory (vault/, ghost/, monitoring/, test/, backup/)
  Moved 7 scripts via `git mv`. Updated .gitignore allowlist, SETUP.md, Architecture.md,
  Secrets.md, Monitoring.md, Conventions.md. Empty `scripts/backup/` created for Phase E.

- [x] 5.4.4.24 Create 1Password item "Restic Backup Keys" in Kubernetes vault (both fields set)

- [x] 5.4.4.25 Add restic Vault path to `scripts/vault/seed-vault-from-1password.sh`

- [x] 5.4.4.26 Create `scripts/backup/config.example` and `.gitignore` entries

- [x] 5.4.4.27 Create `scripts/backup/homelab-backup.sh` (647 lines, 6 subcommands, all tested)

- [x] 5.4.4.28 Install restic on WSL2 (restic 0.16.4)

- [x] 5.4.4.29 Initialize restic repo and test first backup (repo c1af1560, 2495 files/426MB pulled, snapshot d09b2244)

- [x] 5.4.4.30 Add recovery key to restic repo (stored in 1Password k8s-configs-recovery)

- [x] 5.4.4.31 Test restore from restic repo (vault/ restored, md5 checksum matches original)

- [ ] 5.4.4.32 Clean up stale `/Kubernetes/vault-snapshots/` on NAS
  Empty directory, superseded by `/Kubernetes/Backups/vault/`.
  ```bash
  ssh wawashi@10.10.30.11 "sudo mount -t nfs4 10.10.30.4:/Kubernetes /tmp/nfs && \
    sudo rmdir /tmp/nfs/vault-snapshots && sudo umount /tmp/nfs"
  ```

#### Recovery Procedures

**Scenario 1: Single app data corruption** (e.g., UptimeKuma SQLite corrupted)
1. Check NAS first - restore from latest DB dump in `/Kubernetes/Backups/uptime-kuma/`
2. If NAS backup is also bad - restore Longhorn volume from Longhorn UI snapshot
3. If Longhorn snapshot is also bad - `restic restore` from off-site repo

**Scenario 2: NAS failure** (single drive dies, all NFS data lost)
1. Get restic repo from OneDrive sync folder (or staging copy on WSL2 2TB NVMe)
2. Mount new/repaired NAS storage
3. `restic restore --target /mnt/nas/Kubernetes/Backups latest`
4. Longhorn volumes are independent (on NVMe) - still intact
5. Reconfigure Longhorn backup target to new NAS

**Scenario 3: Full cluster rebuild** (all 3 nodes lost)
1. Get restic repo from OneDrive (synced on work laptop)
2. Retrieve restic password from 1Password (recovery key if Vault is gone)
3. Restore etcd snapshot -> rebuild cluster from etcd
4. Restore Vault snapshot -> unseal Vault (keys from 1Password)
5. Restore DB dumps -> restore databases
6. Apply manifests from git repo (GitLab/GitHub)
7. Restore Longhorn backups -> restore PVC data

> **Key dependency:** Every scenario is recoverable using only OneDrive + 1Password.
> No cluster access required.

---

## 5.4.5 Backup Monitoring & Alerting

> **Why:** A backup that silently fails is worse than no backup — false sense of security.

- [x] 5.4.5.1 Add Prometheus alerts for backup health
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
  > **Implementation note:** `longhorn_backup_state` is a numeric gauge (4=Error), not label-based.
  > Actual expr: `longhorn_backup_state == 4`. Also added runbooks to all alerts.

- [x] 5.4.5.2 Add etcd backup age alert
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

- [x] 5.4.5.3 Add CronJob failure alerting
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

- [x] 5.4.5.4 Add stuck Longhorn volume alerting
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
  > **Implementation note:** Longhorn metrics are numeric gauges, not label-based.
  > `longhorn_volume_robustness`: 0=unknown, 1=healthy, 2=degraded, 3=faulted.
  > `longhorn_volume_state`: 2=attached, 3=detached.
  > LonghornVolumeDegraded already exists in `storage-alerts.yaml` - only
  > LonghornVolumeAllReplicasStopped was added to `longhorn-alerts.yaml` to avoid duplication.

- [x] 5.4.5.5 Add stuck pod alerts
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
  - `arr-stall-resolver`: 3 → 1 (runs 48x/day, 3 completed pods per run creates excessive version-checker noise)

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
  **Prerequisite:** Create 1Password field `discord-webhook-url` in the `ARR Stack` item,
  add Vault path to `scripts/vault/seed-vault-from-1password.sh`, and create ExternalSecret
  `arr-discord-webhook` in `arr-stack` namespace. The secret does not exist yet.
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

- [x] 5.4.10.5b Fix janitor timezone - `TZ=Asia/Manila` replaced with `TZ=UTC-8`
  `alpine/k8s` has no tzdata installed, so `Asia/Manila` was silently ignored.
  Discord messages showed UTC time with "PHT" label. Fixed: POSIX `UTC-8` = UTC+8 hours.

---

## 5.4.11 Documentation

- [ ] 5.4.11.1 Update VERSIONS.md
  ```
  | Velero | X.X.X | K8s resource backup and restore |
  | Garage | v2.2.0 | S3-compatible storage for Velero (replaces MinIO, archived Feb 2026) |
  | Restic | X.X.X | Encrypted off-site backup |
  ```

- [ ] 5.4.11.2 Update `docs/context/Security.md` with:
  - Resource quota strategy and namespace coverage
  - Backup architecture (3-layer: Longhorn, Velero, etcd)
  - Backup schedule, retention policy, and storage locations
  - Recovery time documentation
  - Restore drill procedure and schedule (quarterly)
  - Automation hardening decisions (version-checker filtering, Renovate status, CronJob alerting)
  - Off-site encrypted backup architecture (restic on WSL2, OneDrive sync, two-step pull/encrypt)
  - PVC inventory and backup coverage matrix
  - New application backup CronJobs (AdGuard, UptimeKuma, Karakeep, Grafana, ARR, MySpeed)
  - Restic key management (1Password source of truth, Vault operational, recovery keys)
  - Recovery procedures (4 scenarios: app corruption, NAS failure, full rebuild, Immich)
  - `docs/context/Architecture.md` (backup architecture, three-layer model)
  - `docs/context/Storage.md` (Longhorn backup target, NFS backup directories)
  - `docs/context/Secrets.md` (Restic Backup Keys 1Password item, Vault paths)

- [ ] 5.4.11.3 Update `docs/reference/CHANGELOG.md`

---

## Verification Checklist

- [x] Pre-work: existing warning events fixed (v0.29.1 — GitLab runner mount, Ghost probes, Grafana init, Byparr)
- [x] Pre-work: stale pods cleaned up (none found)
- [x] Pre-work: existing PDBs and resource limits inventoried
- [x] bazarr OOMKill fixed (256Mi -> 512Mi)
- [x] All workload pods have resource requests and limits (only gap: tailscale proxy, operator-managed)
- [x] Node memory overcommit assessed and documented (cp1 168%, cp2 99%, cp3 170%)
- [x] LimitRange defaults on application namespaces (deployed BEFORE quotas)
- [x] ResourceQuotas on application namespaces (validated against actual usage)
- [x] Longhorn backup target configured (NFS via Helm defaultBackupStore)
- [x] Longhorn RecurringJobs: critical tier (14 daily + 4 weekly) + important tier (7 daily + 2 weekly)
- [x] Longhorn volume group assignments applied (10 critical, 14 important, rest excluded)
- [x] Longhorn backup tested and restore verified (myspeed-data)
- [x] Garage S3 deployed for Velero S3 backend (dxflrs/garage:v2.2.0, declarative manifests)
- [x] Velero installed (v1.18.0, chart 12.0.0, deployNodeAgent: false)
- [x] Velero scheduled backup running daily (30-day retention, secrets excluded)
- [x] Velero backup tested and restore verified (34 items from portfolio-dev, 0 errors)
- [x] etcd backup CronJob running daily (03:30, 109MB snapshot)
- [x] etcd backup tested and restore procedure documented
- [ ] etcd backup encryption evaluated (GPG/OpenSSL/accept NAS trust)
- [ ] Restore drill completed on non-prod namespace
- [ ] Backup health alerts in Prometheus (Velero, Longhorn, etcd, quota)
- [ ] Stuck pod alerts deployed (Init, Pending, CrashLoop, ImagePull)
- [ ] Pod eviction timing tuned (60s stateless, 300s databases)
- [ ] PodDisruptionBudgets on services without existing PDBs
- [ ] GitLab HA evaluated (scaled if memory permits, or image pre-pull alternative)
- [ ] Longhorn `replica-soft-anti-affinity` confirmed `false`
- [ ] Stopped replica recovery procedure documented
- [x] All CronJobs have `timeZone: "Asia/Manila"` (fixed: version-check, configarr)
- [ ] CronJob failure alerting deployed (covers all current and future CronJobs)
- [ ] Stuck Longhorn volume alerting deployed (0 running replicas detection)
- [x] Invoicetron backup migrated from Longhorn PVC to NFS (retention: 3 days)
- [x] Ghost MySQL backup CronJob deployed (daily to NFS, 02:00)
- [x] GitLab backup strategy evaluated (deferred native backup, covered by Longhorn + Velero)
- [ ] version-checker `ContainerImageOutdated` alert excludes init containers
- [ ] Nova CronJob no longer depends on `apk add` for curl
- [ ] Renovate decision made (activated, suspended, or deferred to Phase 6)
- [ ] ARR Stall Resolver sends Discord notification on profile switches
- [ ] CronJob `successfulJobsHistoryLimit` reduced to 1 where appropriate
- [ ] PVC inventory documented with backup coverage matrix
- [x] AdGuard backup CronJob deployed (daily SQLite .backup to NFS, 02:05)
- [x] UptimeKuma backup CronJob deployed (daily SQLite .backup to NFS, 02:10)
- [x] Karakeep backup CronJob deployed (daily data copy to NFS, 02:15)
- [x] Grafana backup CronJob deployed (daily SQLite .backup to NFS, 02:20)
- [x] ARR configs backup CronJob deployed (3 per-node CronJobs, 02:25)
- [x] MySpeed backup CronJob deployed (daily SQLite .backup to NFS, 02:30)
- [x] All new backup CronJobs verified (manual trigger + NFS file check, all 11 verified)
- [x] SQLite backup CronJobs use keinos/sqlite3 image (runAsNonRoot, readOnlyRootFilesystem, no internet)
- [x] Scripts directory reorganized (vault/, ghost/, monitoring/, test/, backup/)
- [x] `.gitignore` allowlist updated for moved script paths
- [x] Active doc references updated for script path changes
- [x] Restic backup keys created in 1Password "Restic Backup Keys" item
- [x] Restic Vault path added to `scripts/vault/seed-vault-from-1password.sh`
- [x] `scripts/backup/homelab-backup.sh` created with all 6 subcommands (430 lines)
- [x] `scripts/backup/config.example` versioned, `config` + `.password` gitignored
- [x] Restic repo initialized (k8s-configs, repo c1af1560)
- [x] Restic recovery key added (stored in 1Password k8s-configs-recovery)
- [x] First backup completed: pull (426MB) -> encrypt (snapshot d09b2244) -> status verified
- [x] Restore tested from restic repo (vault/ md5 checksum match)
- [ ] Stale `/Kubernetes/vault-snapshots/` cleaned up on NAS
- [ ] NFS share widened to 10.10.0.0/16 on OMV (done 2026-03-17)
- [ ] Vault snapshot NAS retention reduced (15 -> 3 days) after restic pull
- [ ] Atuin backup NAS retention reduced (28 -> 3 days) after restic pull
- [ ] PKI backup NAS retention reduced (90 -> 14 days) after restic pull
- [x] Off-site manifest (.offsite-manifest.json) created on NAS after first pull

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
# Common causes: Garage unreachable, Kopia node agent not running,
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
# Common causes: SSH failed, restic password wrong, repo corrupted, OneDrive not running
restic -r "<RESTIC_REPO>" --password-file scripts/backup/.password check
# If repo is corrupted, rebuild:
# 1. Move old repo aside
# 2. Run ./scripts/backup/homelab-backup.sh setup (re-initializes)
# 3. Run ./scripts/backup/homelab-backup.sh pull && ./scripts/backup/homelab-backup.sh encrypt
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
