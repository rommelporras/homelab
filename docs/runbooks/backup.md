# Backup Runbook

Covers: Velero backups, Longhorn snapshots, etcd snapshots, CronJob health, resource quotas

## VeleroBackupFailed

**Severity:** critical

Velero has more backup failures than successes. This indicates a systemic issue with the Velero backup process - not just a one-off failure. The daily backup schedule may be broken or Garage S3 connectivity may be down.

### Triage Steps

1. Check Velero backups: kubectl-homelab get backups.velero.io -n velero --sort-by=.metadata.creationTimestamp
2. Describe failed backup: kubectl-homelab describe backup <name> -n velero
3. Check Velero logs: kubectl-homelab logs -n velero -l app.kubernetes.io/name=velero --tail=100
4. Check Garage S3 connectivity: kubectl-homelab get backupstoragelocations -n velero

## VeleroBackupStale

**Severity:** warning

Velero has not completed a successful backup in over 36 hours. The daily schedule may be stuck, suspended, or producing only failures.

### Triage Steps

1. Check schedule: kubectl-homelab get schedules.velero.io -n velero
2. Check recent backups: kubectl-homelab get backups.velero.io -n velero --sort-by=.metadata.creationTimestamp
3. Check Velero logs: kubectl-homelab logs -n velero -l app.kubernetes.io/name=velero --tail=100

## LonghornBackupFailed

**Severity:** warning

A Longhorn volume backup is in Error state (`longhorn_backup_state == 4`). This may indicate a problem with the backup target configuration, NFS connectivity to the NAS, or a Longhorn manager issue.

### Triage Steps

1. Check Longhorn backups: kubectl-homelab get backups.longhorn.io -n longhorn-system
2. Check backup target: kubectl-homelab get settings.longhorn.io -n longhorn-system backup-target
3. Check Longhorn manager logs: kubectl-homelab logs -n longhorn-system -l app=longhorn-manager --tail=100

## GarageDown

**Severity:** critical

Garage S3 backend is unreachable. Velero backups will fail. Without Garage, all S3-based backup storage is unavailable.

### Triage Steps

1. Check Garage pod status: kubectl-homelab get pods -n velero -l app=garage
2. Check Garage logs: kubectl-homelab logs -n velero -l app=garage --tail=50
3. Check PVC usage (full disk causes Garage to stop accepting writes): kubectl-homelab get pvc -n velero
4. Check CiliumNetworkPolicy (Velero must be able to reach Garage): kubectl-homelab get ciliumnetworkpolicy -n velero

## ResourceQuotaNearLimit

**Severity:** warning

A namespace is using more than 85% of one of its resource quota limits. If the quota is exhausted, new pods or other resources in that namespace will fail to schedule.

### Triage Steps

1. Check quota usage across all namespaces: `kubectl-homelab get resourcequota -A`
2. Describe the specific quota to see used vs hard limits: `kubectl-homelab describe resourcequota -n <namespace>`
3. Identify which resource type is near the limit (cpu, memory, pods, persistentvolumeclaims, etc.)
4. Review running workloads in the namespace: `kubectl-homelab get pods -n <namespace>`
5. Either reduce resource usage or increase the quota limit in the namespace manifest.

## EtcdBackupStale

**Severity:** critical

The `etcd-backup` CronJob in `kube-system` has not completed successfully in over 36 hours. etcd is the source of truth for all cluster state - if etcd is lost without a recent backup, cluster recovery may not be possible.

### Triage Steps

1. Check CronJob: kubectl-homelab get cronjob etcd-backup -n kube-system
2. Check recent jobs: kubectl-homelab get jobs -n kube-system -l app=etcd-backup --sort-by=.metadata.creationTimestamp
3. Check pod logs: kubectl-homelab logs -n kube-system -l job-name=etcd-backup-<timestamp>
4. Check NFS mount: verify 10.10.30.4:/Kubernetes/Backups/etcd is accessible

## CronJobFailed

**Severity:** warning

A Kubernetes Job (spawned by a CronJob) has entered a failed state and has not recovered within 15 minutes.

### Triage Steps

1. Identify the failing job from the alert labels (`namespace` and `job_name`).
2. Check job logs: `kubectl-homelab logs -n <namespace> job/<job_name>`
3. Describe the job to check failure reason and events: `kubectl-homelab describe job <job_name> -n <namespace>`
4. Check events in the namespace: `kubectl-homelab get events -n <namespace> --sort-by=.metadata.creationTimestamp`
5. Describe the parent CronJob: `kubectl-homelab describe cronjob <cronjob_name> -n <namespace>`

## CronJobNotScheduled

**Severity:** warning

A CronJob has not succeeded in over twice its expected interval (based on `startingDeadlineSeconds`, defaulting to 24 hours if unset). The CronJob may be suspended, consistently failing, or missing its schedule window.

### Triage Steps

1. Check CronJob status: kubectl-homelab get cronjob {{ $labels.cronjob }} -n {{ $labels.namespace }}
2. Check if suspended: kubectl-homelab get cronjob {{ $labels.cronjob }} -n {{ $labels.namespace }} -o jsonpath='{.spec.suspend}'
3. Check recent jobs: kubectl-homelab get jobs -n {{ $labels.namespace }} --sort-by=.metadata.creationTimestamp
