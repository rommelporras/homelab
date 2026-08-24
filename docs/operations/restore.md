# Restoring data - Longhorn volumes, Velero namespaces, databases

> **What this is:** the three restore how-tos for this cluster - a Longhorn volume
> from a snapshot/backup, a whole namespace from Velero, and a single database from
> its NAS dump. Use it when data is lost, corrupted, or you rolled something back
> and need the old state. Backups you cannot restore are theater - these are the
> procedures that make the backups real.
>
> For what runs and where it lands, see [../context/Backups.md](../context/Backups.md).
> For backup **failures/alerts**, see [../runbooks/backup.md](../runbooks/backup.md).
> When something is actively on fire, start at
> [../runbooks/00-EMERGENCY.md](../runbooks/00-EMERGENCY.md).
> [day-to-day.md](day-to-day.md) links here from its Backups section.
>
> Last verified against the live cluster: 2026-07-08.

**Two things NOT covered here (already documented - do not duplicate):**

- **Vault snapshot restore** (Raft `.snap`): see
  [../runbooks/argo-workflows.md](../runbooks/argo-workflows.md#vault-snapshot-restore-from-nfs).
- **etcd restore** (cluster state of last resort - break glass): the full disaster
  procedure lives in [../runbooks/etcd-recovery.md](../runbooks/etcd-recovery.md)
  (etcd 3.6 uses `etcdutl snapshot restore ... --data-dir=/var/lib/etcd`; the
  deprecated `etcdctl` form still works). The pre-upgrade rollback variant is noted
  in [../context/Upgrades.md](../context/Upgrades.md).

**Access reminder (this matters for every command below):**

- `kubectl-homelab` = read-only (`~/.kube/homelab-claude.yaml`). It is RBAC-blocked
  from: `exec`, `logs`, `get` a named secret, and listing ArgoCD `applications` /
  `velero.io` `schedules`+`backups` / cert-manager `certificates`. Every restore
  action here needs write/exec/cp, so most commands use **`kubectl-admin`**
  (`~/.kube/homelab.yaml`, full cluster-admin).
- SSH to nodes: `ssh wawashi@10.10.30.11` (cp1), `.12` (cp2), `.13` (cp3). No direct
  SSH from WSL to the NAS - hop through a node.
- GitOps: everything except `cilium` is ArgoCD-managed. Do **not** `kubectl apply` /
  `helm upgrade` managed resources - selfHeal reverts them. Restores operate on data
  (volumes, DB rows, K8s objects Velero owns), not on the declarative manifests.

---

## 1. Longhorn volume restore (from a snapshot or a backup)

> **GOLDEN RULE (repeated because it is the mistake that ends homelabs):**
> **NEVER delete a PVC to fix a mount error, and never delete a PVC hoping the
> restore will "re-create" it.** Deleting a PVC destroys the Longhorn volume and
> every replica permanently. The safe restore path below **creates a NEW volume**
> and only swaps it in afterwards - the original is never touched until you choose to.

**Snapshot vs backup - know which you have:**

- **Snapshot** (`snapshots.longhorn.io`) = point-in-time copy living *on the same
  disks* as the volume. Fast to restore, but gone if the node/disk dies. Good for
  "I broke something 10 minutes ago."
- **Backup** (`backups.longhorn.io`) = copy pushed off-cluster to the NAS
  (`10.10.30.4:/Kubernetes/Backups/longhorn`). Survives disk loss. Good for
  "the volume is corrupt / the node is dead."

> **Only some volumes are backed up.** A volume gets Longhorn *backups* only if it
> carries the label `recurring-job-group.longhorn.io/critical` or `.../important`.
> Everything has *snapshots* only if it is in a backup group too. **Verify the
> label before you assume a volume is recoverable from the NAS:**
>
> ```bash
> # Find the PVC's Longhorn volume name first (PVCs map to pvc-<uuid> volumes):
> kubectl-homelab get pvc <pvc-name> -n <ns> -o jsonpath='{.spec.volumeName}{"\n"}'
> # Then check its backup-group labels (value is "enabled"):
> kubectl-admin get volume.longhorn.io <pvc-uuid> -n longhorn-system \
>   -o json | grep 'recurring-job-group.longhorn.io'
> ```
>
> If you see only `.../default` and nothing for `critical`/`important`, there is
> **no NAS backup** - you can only restore from a local snapshot (if one exists).
> The group membership is listed per volume in
> [../context/Backups.md](../context/Backups.md) (Layer 1).

### 1a. Do it in the Longhorn UI (recommended - fewer footguns)

The UI is the safe, visual path and it handles the volume-create + PVC wiring for you.

1. Open **`https://longhorn.k8s.rommelporras.com`**.
2. **From a backup:** *Backup* tab -> find the volume -> pick the timestamp ->
   **Restore Latest Backup** (or a specific one). Give the restored volume a NEW
   name (e.g. `<original>-restored`). Longhorn pulls it from the NAS.
   **From a snapshot:** *Volume* -> click the volume -> *Snapshots and Backups* ->
   pick the snapshot -> **Revert** reverts the *existing* volume in place (the
   volume must be detached first), or create a new volume from it.
3. Once the restored volume shows `Detached` / healthy, either:
   - point a **new** PVC at it (*Volume* -> *Create PV/PVC*), or
   - stop the workload, then swap it into the existing PVC (see 1c).

### 1b. Or list from the CLI (read-only - safe to run any time)

```bash
# Snapshots (on-disk, fast). READYTOUSE=true means restorable.
kubectl-homelab get snapshots.longhorn.io -n longhorn-system

# Backups (off-cluster on the NAS). STATE=Completed means restorable.
kubectl-admin get backups.longhorn.io -n longhorn-system \
  --sort-by=.status.snapshotCreatedAt

# Which volume backs which PVC?  (map pvc-<uuid> -> app)
kubectl-homelab get pvc -A -o custom-columns=\
NS:.metadata.namespace,PVC:.metadata.name,VOL:.spec.volumeName
```

> Both CRDs read fine on `kubectl-homelab` today; `backups.longhorn.io` is shown
> with `kubectl-admin` here only to be safe if RBAC tightens. The `--sort-by` puts
> the newest restorable backup last.

### 1c. Swapping the restored volume into a PVC (the careful part)

> **WARNING - state-mutating.** This stops the app and rebinds storage. Do it with
> the app scaled to 0 so nothing writes mid-swap. **Take a fresh snapshot of the
> CURRENT volume first** (Longhorn UI -> volume -> *Take Snapshot*) so you can
> reverse course. Do NOT delete the old PVC as part of this - leave it until you
> have verified the app on the restored data.

The cleanest, lowest-risk approach for a single app:

1. **Scale the workload to 0** so the volume detaches cleanly:
   ```bash
   kubectl-admin scale deploy/<name> -n <ns> --replicas=0   # or statefulset/<name>
   kubectl-homelab get pods -n <ns>   # wait until the consumer pod is gone
   ```
2. In the **Longhorn UI**, restore the backup/snapshot to a **new volume** (1a).
3. **Create a PV + PVC bound to that restored volume** via the Longhorn UI
   (*Volume* -> *Create PV/PVC*), giving the PVC the **exact name the workload
   expects** in a *different* namespace or after you have renamed the old PVC out
   of the way. Because PVC names are immutable and the workload references one by
   name, the reliable pattern is: verify on a throwaway PVC name first, and only
   rename/replace the production PVC once you trust the data.
4. Scale the workload back up and verify (1d).

> **Why not just `kubectl edit pvc`?** A bound PVC's `volumeName` is immutable - you
> cannot re-point an existing PVC at a different volume by editing it. That is why
> the swap goes through create-new-PVC (or restore-in-place via UI *Revert*), not an
> edit. When in doubt, prefer UI *Revert* on the existing volume (reverts data in
> place, keeps the same PVC binding) over a manual PV/PVC dance.

### 1d. Verify

```bash
kubectl-homelab get pvc -n <ns>                 # Bound, correct volume
kubectl-homelab get volumes.longhorn.io -n longhorn-system | grep <pvc-uuid>  # healthy/attached
kubectl-homelab get pods -n <ns> -o wide        # app Running/Ready
```
Then open the app and confirm the data is the version you expected.

---

## 2. Velero namespace restore

Velero backs up **K8s resources** (Deployments, Services, ConfigMaps, PVCs, etc.)
for ~20 app/infra namespaces to Garage S3, daily, 30-day TTL. It does **NOT** back
up Secrets, and it does **NOT** back up volume *data* by itself in this setup - the
data comes from Longhorn (§1). Use Velero when a namespace's *objects* were deleted
or mangled and you want the declared resources back.

### 2a. Prerequisites - do these FIRST or the restore hangs

> **WARNING - order matters.** Velero does not restore Secrets. Restored pods will
> come up needing env/config from Secrets that **ESO must re-mint from Vault**. If
> **Vault is sealed**, ESO cannot sync, the Secrets never appear, and every restored
> pod sits in `Init`/`CreateContainerConfigError` waiting forever. Fix this first:

1. **Vault must be unsealed.** Normally the `vault-unsealer` pod auto-unseals.
   Confirm, or unseal manually per
   [../runbooks/00-EMERGENCY.md §10](../runbooks/00-EMERGENCY.md#10-vault-sealed--secrets-missing):
   ```bash
   kubectl-admin exec -n vault vault-0 -- vault status   # want Sealed: false
   ```
2. **ESO must be resynced** so the restored namespace's ExternalSecrets mint their
   Secrets. After the namespace is back (or right after restore), check and nudge:
   ```bash
   kubectl-homelab get externalsecret -n <ns>            # want SecretSynced / Ready True
   kubectl-admin annotate externalsecret <name> -n <ns> \
     force-sync="$(date +%s)" --overwrite                # force a refresh now
   ```
   The namespace must carry the label `eso-enabled: "true"` for ESO to touch it.
   Details: [managing-secrets.md](managing-secrets.md).

### 2b. List backups (needs admin - velero.io is RBAC-blocked on homelab)

```bash
# CRD form:
kubectl-admin get backups.velero.io -n velero \
  --sort-by=.metadata.creationTimestamp | tail
kubectl-admin get schedules.velero.io -n velero          # the daily-k8s-backup schedule
kubectl-admin get backupstoragelocations.velero.io -n velero   # PHASE Available?
```

Backups are named `daily-k8s-backup-<YYYYMMDDHHMMSS>`. If you prefer the `velero`
CLI, alias it to the admin kubeconfig (it cannot resolve cluster DNS from WSL for
log fetches without a port-forward - see
[../context/Backups.md](../context/Backups.md) Layer 2):

```bash
alias velero='velero --kubeconfig ~/.kube/homelab.yaml'
velero backup get
```

### 2c. Create the restore

> **WARNING - state-mutating.** A Velero restore *creates/overwrites* K8s objects
> in the target namespace. By default Velero **skips resources that already exist**
> (it does not clobber a live object), so restoring into a partially-live namespace
> is usually safe-additive, but review what you are restoring. Prefer restoring the
> **most recent** good backup, and restrict to the one namespace you need.

```bash
# Restore a single namespace from a specific backup:
velero restore create <restore-name> \
  --from-backup daily-k8s-backup-<YYYYMMDDHHMMSS> \
  --include-namespaces <namespace>

# Watch it:
velero restore describe <restore-name>
velero restore get
```

Or the pure-kubectl equivalent if the `velero` binary is unavailable - create a
`Restore` CR:

```bash
kubectl-admin create -f - <<'EOF'
apiVersion: velero.io/v1
kind: Restore
metadata:
  generateName: restore-
  namespace: velero
spec:
  backupName: daily-k8s-backup-<YYYYMMDDHHMMSS>
  includedNamespaces:
    - <namespace>
EOF
```

### 2d. Ordering considerations

- **Namespace-scoped, one at a time.** Restore the namespace you need, not the whole
  cluster. Cross-namespace dependencies (a DB in one ns, an app in another) mean you
  may need to restore both, DB namespace first, then wait for it Ready.
- **Volumes vs objects.** Velero restores the *PVC objects*; the actual disk data is
  Longhorn's job (§1). If the underlying Longhorn volume was also lost, restore the
  volume from its backup **first** (§1), then Velero-restore the namespace so the
  PVC re-binds to the restored volume.
- **Secrets last-mile.** Right after the restore, re-check ESO (§2a step 2) - that is
  the single most common reason a Velero-restored app stays unhealthy.
- **ArgoCD will reconcile.** For ArgoCD-managed namespaces, once objects are back
  ArgoCD may sync them to the git-declared state anyway - which is usually what you
  want. If an app is stuck OutOfSync after restore, see
  [argocd-guide.md](argocd-guide.md) /
  [../runbooks/00-EMERGENCY.md §9](../runbooks/00-EMERGENCY.md#9-argocd--gitops-stuck).

### 2e. Verify

```bash
kubectl-homelab get all -n <namespace>
kubectl-homelab get pods -n <namespace> | grep -vE 'Running|Completed'
kubectl-homelab get externalsecret -n <namespace> | grep -v SecretSynced   # empty = good
```

---

## 3. Database restore (Postgres / MySQL / SQLite)

Every DB has a daily/weekly **logical dump on the NAS** at
`10.10.30.4:/Kubernetes/Backups/<service>` (Layer 3 in
[../context/Backups.md](../context/Backups.md)). Restore = copy the dump into the
DB pod and replay it. **The dump format differs per service - match the restore
tool to it or you will silently do nothing / corrupt data.**

| Service | Pod | Engine | Dump path (NAS) | Dump format | Restore tool |
|---------|-----|--------|-----------------|-------------|--------------|
| invoicetron-prod | `invoicetron-db-0` (ns `invoicetron-prod`) | Postgres | `/Kubernetes/Backups/invoicetron/invoicetron-<ts>.sql` | **plain SQL** (`>`) | `psql` |
| atuin | `postgres-<hash>` (ns `atuin`, a Deployment) | Postgres | `/Kubernetes/Backups/atuin/atuin-backup-<date>.pg_dump` | **custom** (`-Fc`) | `pg_restore` |
| ghost-prod | `ghost-mysql-0` (ns `ghost-prod`) | MySQL | `/Kubernetes/Backups/ghost/ghost-<ts>.sql.gz` | gzipped SQL | `mysql` |
| karakeep | `karakeep-<hash>` (ns `karakeep`) | SQLite | `/Kubernetes/Backups/karakeep/karakeep-<ts>/<db>.db` | `.backup` copy | file copy / `.restore` |
| gitlab | `gitlab-postgresql-0` (ns `gitlab`) | Postgres | (GitLab-managed; see note) | - | - |

> **Note on GitLab:** GitLab's own backup tooling (`gitlab-backup`) is the supported
> path for its Postgres + Gitaly + object storage - do **not** hand-restore just the
> Postgres of a live GitLab. That is out of scope here; treat GitLab restore as a
> whole-app operation.

**Find the dump you want (from a node - WSL cannot mount the NAS directly):**

```bash
ssh wawashi@10.10.30.11 \
  'sudo mount -t nfs4 10.10.30.4:/Kubernetes /tmp/nfs 2>/dev/null; \
   ls -lh /tmp/nfs/Backups/<service>/; sudo umount /tmp/nfs'
```

The dump you actually restore, though, should be copied straight into the DB pod
with `kubectl-admin cp` (below) - you do not need to stage it on a node.

> **WARNING - all of §3 is destructive.** A restore overwrites live data. Before
> any of it: (1) take a **Longhorn snapshot** of the DB's data volume (Longhorn UI
> -> the DB's `pvc-<uuid>` -> *Take Snapshot*) so you can roll back, and (2)
> consider scaling the *app* (not the DB) to 0 so nothing writes mid-restore.

### 3a. Postgres - plain SQL dump (invoicetron)

The invoicetron dump is plain SQL, so it is replayed with **`psql`**, not
`pg_restore`. Because it is a plain-SQL dump (no `--clean`), drop-and-recreate the
target DB for a clean restore, or replay into an empty DB.

```bash
# 1. Copy the dump into the DB pod:
kubectl-admin cp <local-or-node-path>/invoicetron-<ts>.sql \
  invoicetron-prod/invoicetron-db-0:/tmp/restore.sql

# 2. (Recommended) recreate the DB clean, then replay. Run inside the pod as the
#    postgres superuser. Password lives in the invoicetron-db Secret - do NOT print it;
#    psql inside the pod uses the pod's own auth/socket.
kubectl-admin exec -n invoicetron-prod -it invoicetron-db-0 -- bash

#    --- inside the pod ---
#    This image sets POSTGRES_USER=invoicetron, so 'invoicetron' IS the superuser
#    and there is NO 'postgres' role. Connect to the 'postgres' maintenance DB
#    (always created by initdb) to drop/recreate the app DB you can't be connected to:
psql -U invoicetron -d postgres -c "DROP DATABASE IF EXISTS invoicetron;"
psql -U invoicetron -d postgres -c "CREATE DATABASE invoicetron OWNER invoicetron;"
psql -U invoicetron -d invoicetron -f /tmp/restore.sql
#    ----------------------
```

> If you cannot / do not want to drop the DB, and the dump has no `DROP` statements,
> replaying it into a non-empty DB will error on existing objects. For a clean
> in-place overwrite prefer the drop-and-recreate above. **Only the exact superuser
> role name and whether the dump includes `CREATE`/`DROP` can be confirmed by reading
> the dump header (`head -40 restore.sql`) - do that before choosing the path;
> do not assume.**

### 3b. Postgres - custom-format dump (atuin)

The atuin dump is a **custom-format** (`pg_dump -Fc`) archive, so it uses
**`pg_restore`**. Custom format supports `--clean --if-exists` to drop objects
before recreating them - the safe replay flags.

```bash
# atuin's DB is a Deployment; target the running pod by label:
ATUIN_PG=$(kubectl-admin get pod -n atuin -l app=postgres \
  -o jsonpath='{.items[0].metadata.name}')

kubectl-admin cp <path>/atuin-backup-<date>.pg_dump \
  atuin/$ATUIN_PG:/tmp/restore.pg_dump

kubectl-admin exec -n atuin -it "$ATUIN_PG" -- \
  pg_restore --clean --if-exists -U atuin -d atuin /tmp/restore.pg_dump
```

> Verify the pod's label selector first (`kubectl-homelab get pods -n atuin
> --show-labels`) - the Deployment is named `postgres`; the `-l app=postgres`
> selector above is the common shape but confirm it before relying on it.

### 3c. MySQL (ghost)

The ghost dump is gzipped plain SQL of the `ghost` database, taken with
`--single-transaction --routines --triggers`. Restore = decompress and pipe into
`mysql`. Use the **root** credential (the backup uses root).

```bash
kubectl-admin cp <path>/ghost-<ts>.sql.gz \
  ghost-prod/ghost-mysql-0:/tmp/restore.sql.gz

# Replay inside the pod. Root password is in the ghost-mysql Secret; passing it via
# an env the pod already has avoids putting it on the command line. Confirm the env
# var name in the pod (it is MYSQL_ROOT_PASSWORD in the backup job's context):
kubectl-admin exec -n ghost-prod -it ghost-mysql-0 -- bash

#    --- inside the pod ---
gunzip -c /tmp/restore.sql.gz | mysql -u root -p"$MYSQL_ROOT_PASSWORD" ghost
#    ----------------------
```

> A plain `mysqldump` replay **does not drop tables it does not overwrite** - rows
> for tables not present in the dump remain. For a truly clean restore into a fresh
> DB: `mysql -u root -p... -e "DROP DATABASE ghost; CREATE DATABASE ghost;"` first,
> then replay. Do that only with a Longhorn snapshot taken.

### 3d. SQLite (karakeep and the other `.backup`-style dumps)

SQLite dumps here are consistent `.backup`-API copies of the live `.db` files, one
subdirectory per run (`karakeep-<ts>/<dbname>.db`). Restore = stop the app, copy the
`.db` file back onto the PVC in place of the live one, start the app. **Never `cp` a
live SQLite DB while the app is writing** - that is exactly the corruption the
`.backup` API avoids; the same care applies on restore, so scale the app down first.

```bash
# 1. Scale the app to 0 so nothing holds the DB open:
kubectl-admin scale deploy/karakeep -n karakeep --replicas=0
kubectl-homelab get pods -n karakeep      # wait until karakeep-* is gone

# 2. The PVC (karakeep-data) is now detached. Restore into it via a throwaway pod
#    that mounts the same PVC, or via the backup CronJob's own pattern. Simplest:
#    run a one-off pod mounting karakeep-data at /data and the NAS at /backup, then
#    copy the .db back. (Adapt image/paths; keinos/sqlite3 has the sqlite3 tool.)
#    -> confirm the exact .db filename(s) from the backup dir before copying.

# 3. Scale back up and verify:
kubectl-admin scale deploy/karakeep -n karakeep --replicas=1
kubectl-homelab get pods -n karakeep
```

> **This SQLite path is deliberately not a one-liner** because it needs a pod that
> mounts the RWO `karakeep-data` PVC (a bare `kubectl cp` cannot target a detached
> PVC, and the app pod is scaled down). The exact `.db` filenames vary
> (`meilisearch` is intentionally NOT backed up - it is a rebuildable index). Read
> the backup subdirectory (`ls .../karakeep-<ts>/`) to see the real files before
> copying. If unsure, restore the whole `karakeep-<ts>/` directory contents back
> onto `/data`.

### 3e. CRITICAL - restoring a dump taken BEFORE a password rotation

> **WARNING - credential lockstep.** For Postgres/MySQL, the DB user's password is
> stored **inside the database** (in `pg_authid` / `mysql.user`). If you restore a
> dump taken *before* you rotated that DB password, the restored DB will contain the
> **OLD** password hash - but Vault/ESO/the app env now hold the **NEW** one. The
> app then fails auth (`P1001` / `password authentication failed`) on its next
> restart, often hours later.

After any DB restore, **re-align the DB user password with Vault**:

1. Run `ALTER USER <user> WITH PASSWORD '<current-value>';` (Postgres) or
   `ALTER USER '<user>'@'%' IDENTIFIED BY '<current-value>';` (MySQL) on the pod,
   using the **current** value that Vault holds.
2. Do **not** re-seed Vault to match the old dump - align the DB *up* to Vault.
3. Restart the consuming app so it re-reads the Secret:
   `kubectl-admin rollout restart deploy/<app> -n <ns>`.

The full DB-lockstep rules (which paths are DB-user passwords vs plain app secrets,
and the correct rotation order) are in
[managing-secrets.md](managing-secrets.md#db-passwords-need-lockstep-read-this).
This is the single most common way a "successful" DB restore breaks the app a day later.

### 3f. Verify

```bash
kubectl-homelab get pods -n <ns>                       # DB + app Running/Ready
kubectl-admin exec -n <ns> <db-pod> -- \
  psql -U <user> -d <db> -c '\dt'                       # Postgres: tables present
# MySQL:  ... -- mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e 'SHOW TABLES;' <db>
```
Then open the app and confirm the data is the version you expected, and that login
works (proves 3e held).

---

## When the AI comes back

Tell it, in order: which restore you ran, the exact backup/snapshot/dump you
restored from, every `kubectl-admin` command that changed state (`cp`, `exec`
replays, `scale`, `delete lease`, Velero `restore create`, any `ALTER USER`), and
whether the app is verified healthy. So it can confirm the restore held, reconcile
anything runtime back into git (ArgoCD selfHeal will revert manifest-level drift),
and record anything new here.

## Related

- [../context/Backups.md](../context/Backups.md) - what runs, where it lands, retention
- [../runbooks/backup.md](../runbooks/backup.md) - backup **failure** alerts (Velero/Longhorn/etcd/CronJob)
- [../runbooks/argo-workflows.md](../runbooks/argo-workflows.md#vault-snapshot-restore-from-nfs) - Vault snapshot restore
- [../runbooks/etcd-recovery.md](../runbooks/etcd-recovery.md) - etcd disaster restore (break glass)
- [../context/Upgrades.md](../context/Upgrades.md) - etcd pre-upgrade rollback snapshot
- [managing-secrets.md](managing-secrets.md) - DB-lockstep, ESO/Vault
- [../runbooks/storage.md](../runbooks/storage.md) · [../runbooks/00-EMERGENCY.md](../runbooks/00-EMERGENCY.md)

