# Phase 5.4 Implementation Prompts

> **Temporary file.** Delete after Phase 5.4 is complete.
> Usage: Start a new Claude Code session for each phase, paste the base prompt + the phase-specific section.

---

## Base Prompt (paste this at the start of EVERY session)

```
Read this entire message before doing anything. Do NOT commit, push, tag, or run any git commands. I handle all git operations myself.

You are implementing Phase 5.4 (Resilience & Backup) for a Kubernetes homelab. The master plan is at `docs/todo/phase-5.4-resilience-backup.md` - read it fully before touching any code. It has an Execution Order section near the top that defines the safe implementation sequence (Phases A through K with safety gates). Follow it exactly.

## Critical Rules

1. **NO GIT OPERATIONS.** Do not run git add, git commit, git push, git tag, or any git command. Do not use /commit or /release. I handle all git operations manually. If you think something should be committed, tell me and stop.
2. **Read the plan's Execution Order section first.** It defines phases with safety gates. Never skip a gate.
3. **This session handles the phase I specify only.** Do not work on other phases. When the phase is complete, stop and tell me what changed.
4. **Verify before and after every change.** Before modifying a manifest, read it. After applying, verify with kubectl. Evidence before assertions - show me command output, not "it works."
5. **If a task seems wrong or impossible, STOP.** Do not improvise or "fix" the plan by guessing. Tell me what's wrong and why. Examples: an image tag doesn't exist in the registry, a PVC name doesn't match, a path doesn't exist, a command fails.
6. **Never modify `docs/todo/phase-5.4-resilience-backup.md`.** It's the source of truth. If you find an error in it, report it - don't fix it.
7. **Destructive operations require my confirmation.** This includes: changing retention values (immediately prunes old backups), deleting PVCs, deleting namespaces, modifying running CronJobs, Helm upgrades. Tell me what you're about to do and wait for my go-ahead.
8. **Research before implementing.** If a task involves an image tag, check the registry. If it involves a Helm chart value, check the chart docs. If it involves a CRD field, check the API. Don't assume the plan is perfect - verify technical details against reality.

## Context

- 3-node HA cluster (kubeadm, Cilium, Longhorn, kube-vip) on Ubuntu 24.04
- Use `kubectl-homelab` (read-only) for verification, `kubectl-admin` for writes
- Use `helm-homelab` for Helm operations
- NAS at 10.10.30.4, SSH via `wawashi@10.10.30.11` (cp1). No direct NFS from WSL2.
- Read `CLAUDE.md` for full project conventions before starting
- Read `docs/context/Security.md` for accepted security risks
- The plan has been through 3 audit rounds. Trust the task specs but verify against the live cluster.
- Implementation prompts are at `docs/todo/phase-5.4-implementation-prompts.md` for reference

## When you finish the phase

1. List every file you created or modified
2. Show verification evidence (kubectl output, test results)
3. Flag anything that needs my attention before the next phase
4. Tell me what to commit (file list + suggested commit message)
5. STOP. Do not proceed to the next phase.

## If you get stuck

- File doesn't exist: it may be to-be-created. Check the task description.
- kubectl fails: try `kubectl-admin` instead of `kubectl-homelab` for writes.
- Helm upgrade fails: check `helm-homelab list -A` for current release state first.
- 3 failed attempts on the same approach: stop and tell me. Do not keep retrying.
```

---

## Phase-Specific Prompts

### Session 1: Phase A - Pre-work & Inventory (COMPLETED)

```
This session: Phase A (Pre-work & Inventory)

Tasks:
- 5.4.0.2 Clean up stale pods
- 5.4.0.4 Inventory existing PodDisruptionBudgets
- 5.4.0.5 Inventory existing resource limits (pods WITHOUT limits)
- 5.4.0.6 Check node memory overcommit
- 5.4.0.7 Inventory all PVCs and backup coverage

These are READ-ONLY audit tasks. Run the commands in the plan, capture the output, and report findings. Do not modify any manifests or cluster state. Compare results against what the plan documents - flag any discrepancies.
```

### Session 2: Phase B - Resource Management (COMPLETED)

```
This session: Phase B (Resource Management) - STRICT ORDER: limits -> limitrange -> quota

Tasks (in order):
- 5.4.1.1 Audit current resource usage and gaps
- 5.4.1.2 Fix known OOMKill: bazarr limit too tight (256Mi -> 512Mi)
- 5.4.1.3 Set resource limits on Helm-managed workloads missing limits
- 5.4.1.4 Set resource limits on remaining manifest workloads without limits
- 5.4.1.5 Verify no pods are OOMKilled or throttled after applying limits
- 5.4.1.6 Assess node overcommit after all limits applied
- 5.4.2.1 Create LimitRange for application namespaces
- 5.4.2.2 Apply LimitRange to all application namespaces
- 5.4.2.3 Verify defaults are applied to new pods
- 5.4.3.1 Audit actual namespace resource usage
- 5.4.3.2 Create ResourceQuota for application namespaces
- 5.4.3.3 Verify quotas are enforced

CRITICAL ORDER: LimitRange (5.4.2) MUST be deployed BEFORE ResourceQuota (5.4.3). Without LimitRange defaults, pods without explicit limits are rejected by the quota admission controller.

For Helm-managed workloads (5.4.1.3): cert-manager has no helm/cert-manager/values.yaml yet - you need to create it. Check current Helm release with `helm-homelab list -A | grep cert-manager` before upgrading.

Wait for my confirmation before applying each of: resource limit changes, LimitRange, ResourceQuota. These affect pod scheduling.
```

### Session 3: Phase C - Scripts Reorg + Timezone Fixes (COMPLETED)

```
This session: Phase C (Scripts Reorg + Timezone Fixes)

Tasks:
- 5.4.4.23 Reorganize scripts/ directory into backup/, vault/, ghost/, monitoring/, test/
  - Move existing scripts into subdirectories
  - Update .gitignore allowlist entries (critical: *password* and *secret* globs will hide moved files)
  - Update active doc references: SETUP.md, Architecture.md, Secrets.md, Monitoring.md, Conventions.md
  - Do NOT update completed/historical docs (docs/todo/completed/, docs/rebuild/, docs/reference/CHANGELOG.md)
- 5.4.0.3 Fix timezone on version-check (Etc/UTC -> Asia/Manila, cron 0 8 * * 0) and configarr (add timeZone: "Asia/Manila")

For the scripts reorg: the plan lists the exact directory structure and which files go where. After moving files, verify the .gitignore allowlist works by running `git status` - the moved vault/seed scripts MUST still appear as tracked (not hidden by *password* glob).

Tell me all files changed when done so I can commit in two batches: scripts reorg first, then timezone fixes.
```

### Session 4: Phase D1 - Longhorn Volume Backups (COMPLETED)

```
This session: Phase D1 (Longhorn Volume Backups)

Tasks:
- 5.4.4.1 Create NFS backup target directory on NAS
- 5.4.4.2 Configure Longhorn backup target
- 5.4.4.3 Create Longhorn RecurringJobs for critical tier (14 daily + 4 weekly)
- 5.4.4.4 Create Longhorn RecurringJobs for important tier (7 daily + 2 weekly)
- 5.4.4.5 Test Longhorn backup and restore

IMPORTANT: Longhorn RecurringJobs have no timeZone field - cron is interpreted as UTC. The plan documents this. Verify the cron expressions match the intended Manila times.

Volume group assignments are in the plan - apply labels to volumes to assign them to critical/important groups. Volumes NOT in either group (prometheus-db, loki, dev namespaces, ollama, firefox, etc.) are intentionally excluded.

For 5.4.4.1: use SSH to cp1 then NFS mount pattern (documented in plan).
For 5.4.4.2: this is a Longhorn setting change, not a manifest.
For 5.4.4.5: test with a non-critical volume (portfolio-prod or similar). Verify backup appears on NAS.
```

### Session 5: Phase D2 - In-Cluster CronJob Backups (COMPLETED)

> **Follow-up task 5.4.4.22a** (sqlite3 image fix) can be done in Session 6 or a quick
> standalone session. Replace `alpine:3.21` + `apk add sqlite` with `keinos/sqlite3:3.46.1`
> in 8 CronJobs: AdGuard, UptimeKuma, Karakeep, Grafana, ARR (cp1/cp2/cp3), MySpeed.
> Then re-trigger one test to verify.

```
This session: Phase D2 (In-Cluster CronJob Backups)

Tasks:
- 5.4.4.1a Move invoicetron backup from Longhorn PVC to NFS (retention: 3 days)
- 5.4.4.1b Add Ghost MySQL backup CronJob (ghost-prod)
- 5.4.4.1c Evaluate GitLab backup strategy
- 5.4.4.11 Create NFS directory for etcd backups
- 5.4.4.12 Create etcd backup CronJob
- 5.4.4.13 Test etcd backup
- 5.4.4.16-21 Create new app backup CronJobs (AdGuard, UptimeKuma, Karakeep, Grafana, ARR configs, MySpeed)
- 5.4.4.22 Verify all new backup CronJobs

CRITICAL NOTES:
- etcd image (registry.k8s.io/etcd:3.6.6-0) is DISTROLESS. The plan uses an initContainer to copy etcdctl, then alpine/k8s runs the backup. Do not use /bin/sh in the etcd image.
- SQLite backups MUST use `sqlite3 <db> ".backup <dest>"` (NOT raw cp). Raw file copy corrupts live SQLite with WAL mode.
- ARR configs backup: pods are spread across 3 nodes. RWO PVCs can't cross nodes. The plan specifies per-node CronJobs. Verify current node assignments before creating manifests.
- Schedules are staggered: Ghost 02:00, AdGuard 02:05, UptimeKuma 02:10, Karakeep 02:15, Grafana 02:20, ARR 02:25, MySpeed 02:30. etcd at 03:30.
- All CronJobs need: timeZone: "Asia/Manila", concurrencyPolicy: Forbid, automountServiceAccountToken: false, seccompProfile: RuntimeDefault, resource limits.

For each CronJob: create the NFS directory on NAS first (SSH pattern), then create the manifest, then trigger a manual test run and verify the backup file appears.
```

### Session 6: Phase D3 - Velero (COMPLETED)

> **Versions upgraded:** Velero v1.15.x -> v1.18.0 (chart 12.0.0), plugin v1.11.1 -> v1.14.0,
> CLI v1.15.2 -> v1.18.0. v1.15.x charts no longer available in Helm repo.
>
> **Implementation notes:**
> - All resources deployed as declarative manifests in `manifests/velero/` (ArgoCD-ready)
> - velero-s3-credentials via ExternalSecret with template (not imperative kubectl create)
> - Schedule via Schedule CRD manifest (not `velero schedule create` CLI)
> - Garage v2 admin API required python3 for JSON construction (shell escaping corrupted bodies)
> - Garage /health returns 503 until layout assigned - required startupProbe + publishNotReadyAddresses
> - ESO webhook CiliumNP fix: port 443->10250 (container port vs service port) + host entity
> - Test backup: 34 items from portfolio-dev, 0 errors

```
This session: Phase D3 (Velero)

IMPORTANT: MinIO was replaced with Garage S3 (MinIO repo archived Feb 2026).
Garage: dxflrs/garage:v2.2.0, lightweight S3-compatible store (~21MB image, ~3MB idle RAM).

Tasks:
- 5.4.4.6 Deploy Garage S3 as backend for Velero (10-step checklist in plan)
- 5.4.4.6a Install velero CLI on WSL2
- 5.4.4.7 Add Velero Helm repo and create values
- 5.4.4.8 Install Velero
- 5.4.4.9 Create scheduled backup for K8s resources
- 5.4.4.10 Test Velero backup and restore

Garage deployment (task 5.4.4.6 has full details):
1. Create velero namespace manifest with PSS label
2. 1Password item "Garage S3" with rpc-secret, admin-token, metrics-token, s3 keys (ask me to create)
3. Vault seed script update
4. ExternalSecret for Garage secrets
5. ConfigMap with garage.toml (replication_factor=1, db_engine=sqlite, S3 on port 3900, admin on 3903)
6. StatefulSet (single replica, Longhorn PVC, env vars from ESO secret)
7. Post-deploy init Job via admin API: assign layout, create key, create bucket, allow permissions
8. K8s Secret velero-s3-credentials (AWS format for Velero)
9. CiliumNetworkPolicy
10. ServiceMonitor for Garage metrics

Key Garage details:
- S3 API on port 3900, admin+metrics on port 3903
- Readiness probe: GET /health on port 3903
- Secrets via env vars: GARAGE_RPC_SECRET, GARAGE_ADMIN_TOKEN, GARAGE_METRICS_TOKEN
- Use db_engine=sqlite (safer than lmdb on unclean K8s pod shutdown)
- Post-deploy init MUST run: layout assign + layout apply before any S3 operations work

Velero details:
- velero-plugin-for-aws:v1.14.0 (compatible with Velero v1.18.0)
- deployNodeAgent: false (Longhorn handles volume backups)
- checksumAlgorithm: "" in BSL config (AWS SDK v2 CRC32 breaks Garage)
- --exclude-resources secrets (prevent vault-unseal-keys in Garage)
- metrics.serviceMonitor.enabled: true (required for backup alerts in Phase G)
- You CANNOT run op commands. Ask me to create the 1Password item.

For 5.4.4.10: test backup on portfolio-dev. Verify with `velero backup describe`.
```

### Session 7: Phase E - Off-Site Backup Script (COMPLETED)

> **Implementation notes:**
> - rsync needed `--rsync-path="sudo rsync"` (NAS backup files are root-owned by CronJobs)
> - rsync needed `--no-specials --no-devices` (NTFS on WSL2 can't create Unix sockets)
> - jq `--argjson` hit shell ARG_MAX with 2495 files - switched to temp files + `--slurpfile`
> - Manifest writing uses temp files piped via SSH (avoids shell expansion limits)
> - Seed script updated: `VAULT_ADDR="${VAULT_ADDR:-http://localhost:8200}"` (respects .zshrc)
> - Bonus fix: CiliumNP `prometheus-operator-ingress` needed `remote-node` entity
>   (cross-node API server webhook traffic uses `remote-node` identity in Cilium tunnel mode)
> - Script grew from planned 430 to 647 lines due to bug fixes and robust error handling

```
This session: Phase E (Off-Site Backup Script on WSL2)

Tasks:
- 5.4.4.24 Create 1Password item "Restic Backup Keys" (ask me to do this manually)
- 5.4.4.25 Add restic Vault path to scripts/vault/seed-vault-from-1password.sh
- 5.4.4.26 Create scripts/backup/config.example and .gitignore entries
- 5.4.4.27 Create scripts/backup/homelab-backup.sh (6 subcommands)
- 5.4.4.28 Install restic on WSL2
- 5.4.4.29 Initialize restic repo and test first pull + encrypt
- 5.4.4.30 Add recovery key to restic repo
- 5.4.4.31 Test restore from restic repo

The script has 6 subcommands: setup, pull, encrypt, status, prune, restore.

KEY DESIGN DECISIONS (read the plan carefully):
- All NAS access via SSH to cp1 (WSL2 can't NFS mount - corporate blocker)
- pull: SSH to cp1, NFS mount, rsync TO WSL2, write .offsite-manifest.json on NAS, unmount
- encrypt: restic backup to OneDrive sync folder, update manifest with snapshot ID via SSH
- Staging: /mnt/c/rcporras/homelab/backup/YYYY-MM-DD/ (date folders)
- Restic repo: /mnt/c/Users/rcporras/OneDrive - Hexagon/Personal/Homelab/Backup/
- Config: scripts/backup/config.example (versioned), scripts/backup/config (.gitignored)
- Password: scripts/backup/.password (.gitignored, caught by *password* glob)
- Retention: restic --keep-daily 7 --keep-weekly 4 --keep-monthly 6

The off-site manifest (.offsite-manifest.json) is written to NAS via SSH during pull and encrypt. CronJobs do NOT read it - it's for the status subcommand and human visibility only.

For 5.4.4.24: tell me to create the 1Password item, then I'll run the seed script.
For 5.4.4.29: run setup first, then pull, then encrypt, then status. Show output of each.
```

### Session 8: Phase F+G - Retention Reductions + Monitoring (DONE)

> Completed 2026-03-21. All 3 retention reductions applied, 12 alert rules across 3 files
> created and verified in Prometheus. Longhorn metrics are numeric gauges (not label-based).
> LonghornVolumeDegraded deduplicated (already in storage-alerts.yaml).

```
This session: Phase F (Retention Reductions) + Phase G (Monitoring & Alerting)

PREREQUISITE GATE: Phase E must be complete. Verify: `restic snapshots` shows at least 1 snapshot. If not, STOP - do not reduce retention without off-site backup confirmed.

Phase F tasks:
- 5.4.4.0a Reduce Vault snapshot retention (15 -> 3 days)
- 5.4.4.0b Reduce Atuin backup retention (28 -> 3 days)
- 5.4.4.0c Reduce PKI backup retention (90 -> 14 days)

WARNING: These changes immediately delete backups older than the new limit on the next CronJob run. Confirm the restic repo has pulled all existing backups before applying.

Phase G tasks:
- 5.4.5.1 Add Prometheus alerts for backup health (Velero, Longhorn, quota)
- 5.4.5.2 Add etcd backup age alert
- 5.4.5.3 Add CronJob failure alerting
- 5.4.5.4 Add stuck Longhorn volume alerting
- 5.4.5.5 Add stuck pod alerts

All alert manifests go in manifests/monitoring/alerts/. Must have labels `release: prometheus` for Prometheus Operator discovery. After applying, verify alerts appear in Prometheus UI.
```

### Session 9: Phase H+I - Resilience + Automation Hardening (DONE)

> Completed 2026-03-21. 28 deployments got 60s tolerations, 8 PDBs created (21 total),
> GitLab HA skipped (170%+ overcommit). Version-checker fixed: alpine/k8s (no apk),
> container_type filter on alert, CiliumNP for CronJob (pre-existing bug from 5.3).
> Renovate suspended. ARR stall resolver gets Discord (needs 1P field + vault seed).
> Janitor stuck volumes covered by LonghornVolumeAllReplicasStopped alert.

```
This session: Phase H (Resilience Hardening) + Phase I (Automation Hardening)

These are largely independent tasks. Work through them in order.

Phase H tasks:
- 5.4.6.1 Set tolerationSeconds for stateless services (60s not-ready/unreachable)
- 5.4.6.2 Document expected recovery times
- 5.4.7.1 Assess memory budget for GitLab 2 replicas
- 5.4.7.2 If feasible: scale webservice + registry to 2 replicas
- 5.4.8.3 Document manual recovery procedure for stuck stopped replicas
- 5.4.8.4 Verify replica-soft-anti-affinity is false
- 5.4.9.1 Add PDBs for services with 2+ replicas
- 5.4.9.2 Add PDBs for critical single-replica services
- 5.4.9.3 Verify PDBs are respected during drain (dry-run only)

Phase I tasks:
- 5.4.10.1a-1c version-checker signal quality fixes
- 5.4.10.2a Switch version-check to alpine/k8s:1.35.0
- 5.4.10.3a Renovate decision (suspend or defer)
- 5.4.10.4a ARR stall resolver Discord notification (NOTE: arr-discord-webhook secret does not exist yet - create ExternalSecret first)
- 5.4.10.5a-5b Cluster janitor improvements

For GitLab HA (5.4.7): check memory budget FIRST. If nodes are >150% overcommit, don't scale - document decision instead.
For PDBs (5.4.9): use maxUnavailable: 1 for single-replica services (NOT 0 - that blocks drain).
For drain test (5.4.9.3): use --dry-run=client ONLY. Do not actually drain a node.
```

### Session 10: Phase J - Documentation + Cleanup (DONE)

> Completed 2026-03-21. Stale vault-snapshots removed from NAS. etcd backup encryption
> decision: accept NAS trust (same VLAN, off-site encrypted, short retention). VERSIONS.md
> updated (velero-plugin-for-aws, keinos/sqlite3, Velero CLI, restic). Security.md updated
> (backup architecture, retention, recovery, resource quotas, PDBs, automation). Architecture.md
> updated (three-layer backup, Garage S3 decision). Storage.md updated (NFS directories Deployed,
> Longhorn RecurringJob tiers, namespace fixes). Secrets.md updated (Garage S3, restic paths).
> CHANGELOG.md updated with full Phase 5.4 summary.

```
This session: Phase J (Cleanup + Documentation)

Tasks:
- 5.4.4.32 Clean up stale /Kubernetes/vault-snapshots/ on NAS (verify empty first with ls, then rmdir)
- 5.4.4.14 Decide on etcd backup encryption (GPG/OpenSSL/accept NAS trust)
- 5.4.11.1 Update VERSIONS.md with Velero, Garage, Restic versions
- 5.4.11.2 Update docs/context/Security.md with backup architecture, retention, recovery procedures
- 5.4.11.2 Also update: Architecture.md, Storage.md, Secrets.md
- 5.4.11.3 Update docs/reference/CHANGELOG.md

For CHANGELOG: summarize all changes made across all phases. Use the git log to identify all commits made during Phase 5.4 implementation.

For Security.md: the plan lists all topics to cover. Read the current Security.md first to understand the existing structure before adding sections.

After this session, I will manually run /audit-security, /audit-docs, /commit, and /release.
```

---

## Phase K - Restore Drill (MANUAL - NOT AN AGENT SESSION)

Phase K is the restore drill (5.4.4.15). Run this yourself:

1. Verify backups exist: Velero, Longhorn, CronJobs all producing data
2. Delete portfolio-dev namespace
3. Restore from Velero
4. Restore PVC from Longhorn
5. Verify application health
6. Document results

**Never give this to an agent.** It intentionally destroys a namespace.
