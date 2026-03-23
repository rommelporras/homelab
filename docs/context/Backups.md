---
tags: [homelab, kubernetes, backup, restic, velero, longhorn]
updated: 2026-03-23
---

# Backups

Three-layer backup strategy. Everything runs automatically except the off-site backup (WSL2 manual).

## What runs automatically (in-cluster)

### Layer 1: Longhorn Volume Snapshots

NFS target: `10.10.30.4:/Kubernetes/Backups/longhorn`

| Schedule | Group | Cron (UTC) | Manila Time | Retain |
|----------|-------|------------|-------------|--------|
| daily-backup-critical | critical | 0 19 * * * | 03:00 daily | 14 |
| daily-backup-important | important | 0 20 * * * | 04:00 daily | 7 |
| weekly-backup-critical | critical | 0 21 * * 6 | 05:00 Sunday | 4 |
| weekly-backup-important | important | 0 22 * * 6 | 06:00 Sunday | 2 |

**Critical group** (14 daily + 4 weekly retain):
vault-data, gitlab-postgresql, gitlab-gitaly, gitlab-minio, ghost-prod-mysql, ghost-prod-content, invoicetron-prod-db, karakeep-data, meilisearch-data, atuin-postgres, velero/garage-data.

**Important group** (7 daily + 2 weekly retain):
adguard-data, myspeed-data, uptime-kuma, grafana, bazarr, jellyfin, prowlarr, qbittorrent, radarr, recommendarr, seerr, sonarr, tdarr-server, tdarr-configs, prometheus-db, ghost-dev-mysql, loki-storage, atuin-config.

**Excluded** (no Longhorn backup - intentional):
alertmanager-db (ephemeral silences/state), ghost-dev-content (recoverable from prod), ollama-models (re-downloadable), firefox-config (low-value browser state), gitlab-redis (ephemeral cache), invoicetron-dev-db (dev database).

### Layer 2: Velero K8s Resource Backups

S3 target: Garage (`velero` namespace).
Schedule: `daily-k8s-backup` at 20:30 UTC (04:30 Manila).
TTL: 720h (30 days).
Backs up all K8s resources (deployments, services, configmaps, etc.) except Secrets.
Covers 18 namespaces (all application + infrastructure except kube-system, longhorn-system, cilium, cert-manager).

```bash
# All velero CLI commands from WSL2 need --kubeconfig
alias velero='velero --kubeconfig ~/.kube/homelab.yaml'

# Check backup status
velero backup get
velero schedule get

# Restore a namespace from a backup
velero restore create <restore-name> --from-backup <backup-name> --include-namespaces <namespace>

# Describe a backup or restore
velero backup describe <name> --details
velero restore describe <restore-name>

# View restore/backup logs (requires port-forward - WSL2 can't resolve cluster DNS)
kubectl-admin port-forward svc/garage 3900:3900 -n velero &
velero restore logs <restore-name>
velero backup logs <backup-name>
# Kill the port-forward when done: kill %1
```

### Layer 3: CronJob Database/Config Dumps

NFS target: `10.10.30.4:/Kubernetes/Backups/<service>`

| CronJob | Namespace | Schedule (Manila) | Retention | What |
|---------|-----------|-------------------|-----------|------|
| vault-snapshot | vault | 02:00 daily | 3 days | Raft snapshot |
| ghost-mysql-backup | ghost-prod | 02:00 daily | 3 days | mysqldump |
| adguard-backup | home | 02:05 daily | 3 days | SQLite .backup |
| uptime-kuma-backup | uptime-kuma | 02:10 daily | 3 days | SQLite .backup |
| karakeep-backup | karakeep | 02:15 daily | 3 days | SQLite .backup |
| grafana-backup | monitoring | 02:20 daily | 3 days | SQLite .backup |
| arr-backup-cp1/cp2/cp3 | arr-stack | 02:25 daily | 3 days | SQLite .backup (per-node) |
| myspeed-backup | home | 02:30 daily | 3 days | SQLite .backup |
| etcd-backup | kube-system | 03:30 daily | 14 days | etcdctl snapshot |
| atuin-backup | atuin | 02:00 Sunday | 3 days | pg_dump |
| invoicetron-db-backup | invoicetron-prod | 09:00 daily | 3 days | pg_dump |
| pki-backup | kube-system | 20:00 Sunday | 14 days | /etc/kubernetes/pki copy |

NAS retention is short (3 days) because the off-site backup pulls everything to restic.
etcd and PKI keep 14 days because they run less frequently and are critical for cluster recovery.

---

## What you run manually (WSL2 off-site backup)

### Quick reference

```bash
cd ~/personal/homelab

# Weekly routine (run all 3 in order):
./scripts/backup/homelab-backup.sh pull      # rsync from NAS to WSL2 staging
./scripts/backup/homelab-backup.sh encrypt   # restic backup to OneDrive
./scripts/backup/homelab-backup.sh prune     # clean old staging folders

# Check status anytime:
./scripts/backup/homelab-backup.sh status

# One-liner:
./scripts/backup/homelab-backup.sh pull && ./scripts/backup/homelab-backup.sh encrypt && ./scripts/backup/homelab-backup.sh prune
```

### How it works

1. **pull** - SSH to cp1, NFS mount the NAS backup dir, rsync everything to `C:\rcporras\homelab\backup\YYYY-MM-DD\`, write `.offsite-manifest.json` on NAS
2. **encrypt** - restic backup the staging folder to OneDrive (`C:\Users\rcporras\OneDrive - Hexagon\Personal\Homelab\Backup\`), apply retention policy (forget+prune), verify repo integrity, update manifest with snapshot ID
3. **prune** - delete staging folders older than 7 days from `C:\rcporras\homelab\backup\`. Safety: will NOT delete folders that haven't been encrypted to restic yet.

Restic retention: 7 daily, 4 weekly, 6 monthly snapshots.

### First-time setup

Only needed once per machine:

```bash
./scripts/backup/homelab-backup.sh setup
```

This fetches the restic password from Vault (or prompts for the 1Password value `op://Kubernetes/Restic Backup Keys/k8s-configs-password`) and initializes the restic repo. Requires `vault login` first, or paste the password manually.

### Config

- Template: `scripts/backup/config.example` (versioned)
- Your config: `scripts/backup/config` (gitignored)
- Password: `scripts/backup/.password` (gitignored, fetched by setup)

### Restore from off-site

```bash
# List available snapshots
./scripts/backup/homelab-backup.sh status

# Restore a specific snapshot to a directory
./scripts/backup/homelab-backup.sh restore
# Prompts for snapshot ID and target directory (default: /tmp/homelab-restore)
```

After restoring files, use them to rebuild services:
- Database dumps: `pg_restore` / `mysql < dump.sql`
- SQLite: copy `.backup` file to the PVC mount path
- etcd: `etcdctl snapshot restore`
- Vault: `vault operator raft snapshot restore`
- PKI: copy certs back to `/etc/kubernetes/pki/`

---

## Monitoring & Alerts

All backup systems have Prometheus alerts. If something fails, you get notified via Discord.

| Alert | What it catches | Severity | Discord Channel |
|-------|----------------|----------|-----------------|
| VeleroBackupFailed | Velero failures > successes | critical | #incidents |
| VeleroBackupStale | No Velero backup in 36h | warning | #apps (*) |
| LonghornBackupFailed | Longhorn backup error state | warning | #infra |
| EtcdBackupStale | No etcd backup in 36h | critical | #incidents |
| CronJobFailed | Any Job failure (covers all CronJobs) | warning | #apps (*) |
| CronJobNotScheduled | CronJob missed 2+ runs | warning | #apps (*) |

(*) VeleroBackupStale, CronJobFailed, and CronJobNotScheduled route to #apps until Phase 5.5 updates the Alertmanager routing regex to include them in #infra.

Check alert status: Grafana > Alerting, or `kubectl-homelab get prometheusrules -n monitoring`.

---

## Retention summary

| Layer | Location | Retention | Encrypted |
|-------|----------|-----------|-----------|
| Longhorn snapshots | NAS NFS | 7-14 daily, 2-4 weekly | No (NAS VLAN) |
| Velero resources | Garage S3 (in-cluster) | 30 days (TTL 720h) | No |
| CronJob dumps | NAS NFS | 3 days (14 for etcd/pki) | No (NAS VLAN) |
| Off-site (restic) | OneDrive | 7 daily, 4 weekly, 6 monthly | Yes (AES-256) |

The NAS is short-term staging. Deep history lives in the encrypted restic repo on OneDrive.
