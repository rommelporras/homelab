---
tags: [homelab, kubernetes, storage, longhorn, nfs]
updated: 2026-04-28
---

# Storage

Longhorn distributed storage and NFS integration.

## Longhorn

| Setting | Value |
|---------|-------|
| Version | 1.11.1 |
| Namespace | longhorn-system |
| Data path | /var/lib/longhorn |
| Default replicas | 2 |
| StorageClass | longhorn (default) |

### Capacity

| Node | NVMe | OS/etcd | Available for Longhorn |
|------|------|---------|------------------------|
| Each | 512GB | ~100GB | ~400GB |
| Total (3 nodes) | 1.5TB | ~300GB | ~1.2TB raw |
| With 2x replication | — | — | ~600GB usable |

### Settings

| Setting | Value | Reason |
|---------|-------|--------|
| defaultReplicaCount | 2 | Balance HA and space |
| defaultDataPath | /var/lib/longhorn | Use NVMe |
| storageMinimalAvailablePercentage | 10 | Keep 10% for OS |
| dataLocality | best-effort | Schedule near data |
| nodeDownPodDeletionPolicy | delete-both-statefulset-and-deployment-pod | Auto-delete pods when node goes down (not drain) |
| orphanResourceAutoDeletion | `replica-data;instance` | Auto-cleanup orphaned replicas and instances |

### Access UI

```bash
kubectl-homelab -n longhorn-system port-forward svc/longhorn-frontend 8080:80
# Open http://localhost:8080
```

Or via: https://longhorn.k8s.rommelporras.com

## NFS (Dell 3090)

| Setting | Value |
|---------|-------|
| Server | 10.10.30.4 (omv.home.rommelporras.com) |
| System | OpenMediaVault 7.6.0-1 |
| NFS Version | NFSv4.1 |
| Pseudo-root | `/export` (fsid=0) |
| Hardware | Single drive — avoid heavy write I/O for config/DBs |

### NFS Export & Directory Convention

All K8s NFS storage uses a **single export** (`/export/Kubernetes`) with **one subdirectory per service group**. No new OMV shares needed for new services — just `mkdir` a new subdirectory.

**Isolation:** Each K8s PV mounts a specific subdirectory (e.g., `/Kubernetes/Media`). Pods cannot traverse above their mount point to see sibling directories. K8s PV/PVC binding, namespace isolation, and NetworkPolicy enforce access boundaries.

```
/export/Kubernetes/                   (OMV NFS export, NFSv4 path: /Kubernetes)
├── Immich/                           (photos/videos — PV: immich-nfs)
├── Media/                            (ARR stack — PV: arr-data-nfs, Phase 4.25)
│   ├── torrents/{movies,tv,music}/   (qBittorrent downloads)
│   └── media/{movies,tv,music}/      (Sonarr/Radarr hardlinked library)
├── Backups/                          (service database backups & snapshots)
│   ├── atuin/                        (Atuin PostgreSQL pg_dump, weekly CronJob)
│   ├── vault/                        (Vault Raft snapshots, daily CronWorkflow in argo-workflows ns)
│   ├── pki/                          (PKI certificate backups)
│   ├── longhorn/                     (Longhorn volume backups - backup target)
│   ├── etcd/                         (etcd snapshot backups)
│   ├── adguard/                      (AdGuard Home SQLite backups)
│   ├── uptime-kuma/                  (Uptime Kuma SQLite backups)
│   ├── grafana/                      (Grafana SQLite backups)
│   ├── karakeep/                     (Karakeep SQLite backups)
│   ├── myspeed/                      (MySpeed SQLite backups)
│   ├── arr/                          (ARR config SQLite backups)
│   ├── invoicetron/                  (Invoicetron PostgreSQL backups)
│   └── ghost-mysql/                  (Ghost MySQL backups)
├── Documents/                        (future — Nextcloud or Paperless-ngx)
└── (future services)/
```

| Subdirectory | NFSv4 Mount Path | K8s PV | Namespace | Status |
|-------------|-----------------|--------|-----------|--------|
| `Immich/` | `/Kubernetes/Immich` | `immich-nfs` | `immich` | Template only (PV and namespace not deployed) |
| `Media/` | `/Kubernetes/Media` | `arr-data-nfs` | `arr-stack` | Deployed |
| `Backups/atuin/` | `/Kubernetes/Backups/atuin` | inline NFS volume | `atuin` | Deployed (v0.28.1) |
| `Backups/vault/` | `/Kubernetes/Backups/vault` | `vault-snapshots-argo-nfs` | `argo-workflows` | Deployed (v0.39.0). Legacy `vault-snapshots-nfs` PV + PVC in `vault` ns remain temporarily; removal tracked in `docs/todo/deferred.md` 5.9.3.10. |
| `Backups/pki/` | `/Kubernetes/Backups/pki` | inline NFS volume | `kube-system` | Deployed |
| `Backups/longhorn/` | `/Kubernetes/Backups/longhorn` | Longhorn backup target | `longhorn-system` | Deployed |
| `Backups/etcd/` | `/Kubernetes/Backups/etcd` | inline NFS volume | `kube-system` | Deployed |
| `Backups/adguard/` | `/Kubernetes/Backups/adguard` | inline NFS volume | `home` | Deployed |
| `Backups/uptime-kuma/` | `/Kubernetes/Backups/uptime-kuma` | inline NFS volume | `uptime-kuma` | Deployed |
| `Backups/grafana/` | `/Kubernetes/Backups/grafana` | inline NFS volume | `monitoring` | Deployed |
| `Backups/karakeep/` | `/Kubernetes/Backups/karakeep` | inline NFS volume | `karakeep` | Deployed |
| `Backups/myspeed/` | `/Kubernetes/Backups/myspeed` | inline NFS volume | `home` | Deployed |
| `Backups/arr/` | `/Kubernetes/Backups/arr` | inline NFS volume | `arr-stack` | Deployed |
| `Backups/invoicetron/` | `/Kubernetes/Backups/invoicetron` | inline NFS volume | `invoicetron-prod` | Deployed |
| `Backups/ghost-mysql/` | `/Kubernetes/Backups/ghost-mysql` | inline NFS volume | `ghost-prod` | Deployed |
| `Documents/` | `/Kubernetes/Documents` | TBD | TBD | Future (Nextcloud/Paperless-ngx) |

**NFSv4 path note:** OMV has `/export` with `fsid=0` as the pseudo-root. Filesystem path `/export/Kubernetes/Media` becomes NFSv4 mount path `/Kubernetes/Media`.

### NFS PV Convention

All NFS PVs follow this pattern (established by `manifests/storage/nfs-immich.yaml`):

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: <service>-nfs
  labels:
    type: nfs
    app: <service>
spec:
  capacity:
    storage: <size>
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain    # ALWAYS Retain for NFS
  storageClassName: nfs
  mountOptions:
    - hard
    - nfsvers=4.1
    - rsize=65536
    - wsize=65536
    - timeo=600
  nfs:
    server: 10.10.30.4
    path: /Kubernetes/<Subdirectory>       # NFSv4 pseudo-root path
```

## Velero

Velero backs up Kubernetes resources (manifests, PV snapshots) to S3-compatible storage.

| Setting | Value |
|---------|-------|
| Namespace | `velero` |
| Backend | Garage S3 (`dxflrs/garage:v2.2.0`) |
| Scope | K8s resource backups (not application data) |

Garage is a lightweight self-hosted S3-compatible store running in the cluster. Velero uses it as the object store backend for schedule-based resource backups. Application data backups (SQLite dumps, PostgreSQL pg_dump, etcd snapshots) go to NFS under `Backups/` via CronJobs.

### Longhorn RecurringJob Backups

| Tier | Volumes | Daily Retention | Weekly Retention |
|------|---------|----------------|-----------------|
| Critical | ghost-content, ghost-mysql, invoicetron-db, gitlab-gitaly, gitlab-postgresql, gitlab-minio, vault, atuin-postgres, karakeep-data, meilisearch-data, velero/garage-data | 14 | 4 |
| Important | adguard-data, uptime-kuma, prometheus-grafana, alertmanager, loki, arr-stack configs, myspeed-data, invoicetron-backups | 7 | 2 |
| Excluded | prometheus-db (80Gi, rebuildable), ollama-models (re-pull), firefox-config (disposable), dev PVCs, redis | - | - |

Backup target: NFS NAS `/Kubernetes/Backups/longhorn/` (configured via Helm `defaultBackupStore.backupTarget`).

## When to Use What

| Storage | Use For |
|---------|---------|
| Longhorn | Databases, stateful apps (HA needed) |
| NFS | Media files, photos, backups (large, not HA-critical) |
| Velero + Garage S3 | K8s resource backups (manifests, namespace state) |

## Commands

```bash
# Check Longhorn pods
kubectl-homelab -n longhorn-system get pods

# List volumes
kubectl-homelab -n longhorn-system get volumes.longhorn.io

# List replicas
kubectl-homelab -n longhorn-system get replicas.longhorn.io

# Check PVCs
kubectl-homelab get pvc -A

# Check StorageClass
kubectl-homelab get storageclass
```

## Longhorn: Stuck Stopped Replicas Recovery

When a node reboots or goes NotReady briefly, Longhorn may mark some replicas as "stopped." The `LonghornVolumeAllReplicasStopped` alert fires when all replicas of a volume are stopped. The cluster janitor CronJob handles stopped replicas automatically, but manual intervention may be needed for edge cases.

```bash
# 1. Identify stopped replicas
kubectl-homelab -n longhorn-system get replicas.longhorn.io \
  -o custom-columns=NAME:.metadata.name,VOLUME:.spec.volumeName,NODE:.spec.nodeID,STATE:.status.currentState \
  | grep stopped

# 2. Verify the volume has at least 1 healthy replica before deleting
kubectl-homelab -n longhorn-system get replicas.longhorn.io \
  -o custom-columns=VOLUME:.spec.volumeName,STATE:.status.currentState \
  | sort | uniq -c

# 3. Delete stopped replicas (Longhorn auto-rebuilds replacement)
kubectl-admin -n longhorn-system delete replicas.longhorn.io <name>

# 4. Monitor rebuild progress
kubectl-homelab -n longhorn-system get volumes.longhorn.io -w
```

**Volumes used only by CronJobs** show as detached with stopped replicas between runs - this is normal, not an error. The cluster janitor cleans these automatically.

## Longhorn: Known Issues

### multipathd blocks iSCSI device mounts (Ubuntu 24.04)

multipathd on Ubuntu 24.04 intercepts iSCSI block devices before Longhorn can mount them. Symptoms: new volume mounts fail with `mke2fs "apparently in use by the system"`.

All 3 nodes have `/etc/multipath.conf` with this blacklist:

```
blacklist {
    devnode "^sd[a-z0-9]+"
}
```

If the config is lost (e.g. after an OS upgrade), re-add the blacklist and restart the service:

```bash
sudo systemctl restart multipathd
```

Reference: https://github.com/longhorn/longhorn/issues/11411

## Node-level disk usage tripwire (not GitOps-managed)

Added 2026-09-08 after a disk-fill incident where forensic reconstruction was
inconclusive - the default `node_filesystem_avail_bytes` metric (60s scrape
resolution, root filesystem total only) couldn't isolate which directory
drove a ~180GiB drain in ~30 minutes on cp2.

`scripts/node/disk-usage-textfile.sh` runs on each node via a systemd timer
(every 2 minutes) and writes `node_directory_size_bytes{directory="..."}` for
`/var/lib/containerd`, `/var/lib/longhorn`, and `/var/log` to node-exporter's
textfile collector directory. node-exporter (configured in
`helm/prometheus/values.yaml` with `--collector.textfile.directory`) picks it
up automatically on its next scrape - no new exporter, no new pod.

**This is intentionally not a Kubernetes manifest or ArgoCD-managed.** It's
node-level OS configuration, same category as `/etc/multipath.conf` above or
the `protectKernelDefaults` sysctls (see CLAUDE.md gotchas) - and it needs to
keep working even if kubelet/containerd are unhealthy, which is exactly the
condition it exists to observe. A DaemonSet would add a new pod lifecycle to
reason about and would itself be a candidate for failing during the exact
crisis window it's meant to instrument.

**Install on each node (one-time, not automated by any agent):**

```bash
sudo install -m 0755 scripts/node/disk-usage-textfile.sh /usr/local/bin/disk-usage-textfile.sh
sudo install -m 0644 scripts/node/disk-usage-textfile.service /etc/systemd/system/
sudo install -m 0644 scripts/node/disk-usage-textfile.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now disk-usage-textfile.timer
```

**Verify:**

```bash
sudo systemctl status disk-usage-textfile.timer
cat /var/lib/node_exporter/textfile_collector/disk_usage.prom
```

**Query in Grafana/Prometheus:** `node_directory_size_bytes{directory="containerd"}`
(or `longhorn`, `log`) - `rate()` or a raw graph over time shows the slope of
a drain in progress, which is the data point the 2026-09-08 investigation
didn't have.

No alert is wired to this yet - it's a diagnostic data source, not an alerting
signal. If a specific directory's growth rate proves to be a reliable early
warning after being observed through a real incident, promote it to an alert
then (see `docs/todo/deferred.md` if a decision to add one is deferred).

## Related

- [[Architecture]] - Why Longhorn on NVMe, three-layer backup strategy
- [[Cluster]] - Node storage specs
- [[Security]] - Backup retention, etcd backup security, recovery procedures
- [[Versions]] - Longhorn version
- [Longhorn hardware runbook](../runbooks/longhorn-hardware.md) - PCIe AER triage, NVMe reseat procedure, `LonghornVolumeAutoSalvaged` triage
- [Storage runbook](../runbooks/storage.md) - volume-level alerts (Degraded, ReplicaFailed, AllReplicasStopped), NVMe SMART alerts
