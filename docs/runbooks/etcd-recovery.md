# etcd disaster recovery - restore the cluster from a snapshot

> **Break-glass runbook. Use this ONLY when etcd is genuinely corrupted or lost and
> the cluster cannot recover on its own.** Restoring etcd rewrites all cluster state
> from a point-in-time snapshot - anything changed since that snapshot is gone. This
> is the deepest hole; try everything else first.
>
> **Before you touch this doc, rule out the far more common (and recoverable) cases:**
> a transiently unavailable API or etcd quorum loss is handled in
> [00-EMERGENCY.md §7](00-EMERGENCY.md#7-the-kubernetes-api-is-unreachable) -
> **read that first**. A single node down is survivable (2 of 3 = quorum) and needs
> no restore at all - see [00-EMERGENCY.md §8](00-EMERGENCY.md#8-a-node-is-down-or-notready).
> Restore is a LAST resort.
>
> Related: [backup.md](backup.md) (EtcdBackupStale alert), [cluster.md](cluster.md)
> (apiserver restarts), [../operations/node-lifecycle.md](../operations/node-lifecycle.md)
> (the calm version of the cp2/cp3 rejoin in §5), [../operations/restore.md](../operations/restore.md)
> (Longhorn / Velero / DB restores - NOT etcd), [../context/Backups.md](../context/Backups.md)
> (backup inventory), [../context/Upgrades.md](../context/Upgrades.md) (pre-upgrade etcd
> snapshot / rollback variant).
>
> `kubectl-homelab` = read-only restricted kubeconfig. `kubectl-admin` = full admin.
> Almost all the destructive work here is done over `ssh wawashi@<node>` with `sudo`,
> not kubectl. Timezone is Asia/Manila.

---

## 0. STOP - is etcd actually broken, or just transiently unavailable?

Restoring from a snapshot **discards every change made after the snapshot was
taken**. Do not do it to fix a slow API, a single crashed etcd pod, or one node
being down. Work through this gate first.

### 0.1 The cluster survives one node down - that is NOT an etcd disaster

etcd needs **2 of 3** members for quorum. One control-plane node down (or one
`etcd-*` pod restarting) is normal and self-healing. Only when **two** members are
gone does the API go read-only/unavailable. In that case the fix is to **get a node
back**, not to restore - see
[00-EMERGENCY.md §7 step 2](00-EMERGENCY.md#7-the-kubernetes-api-is-unreachable)
and [§8](00-EMERGENCY.md#8-a-node-is-down-or-notready).

### 0.2 Read-only checks (do these before deciding anything)

```bash
# 1. Are the etcd static pods Running? (there should be 3: etcd-k8s-cp1/2/3)
kubectl-homelab get pods -n kube-system -o wide | grep -E 'etcd|kube-apiserver'

# 2. Can you reach the API at all?
kubectl-homelab get nodes -o wide
ping -c2 10.10.30.10          # API VIP (api.k8s.rommelporras.com)
```

If `kubectl` itself is dead, check etcd health directly on each node. etcd's
container is distroless (no shell), so run `crictl` from the host:

```bash
# On each node - is the etcd container up and the process alive?
ssh wawashi@10.10.30.11 'sudo crictl ps | grep -E "etcd|kube-apiserver"'
ssh wawashi@10.10.30.12 'sudo crictl ps | grep -E "etcd|kube-apiserver"'
ssh wawashi@10.10.30.13 'sudo crictl ps | grep -E "etcd|kube-apiserver"'

# etcd's own logs on a node (look for corruption, panic, "database space exceeded",
# "mvcc: database file corruption", walpb, "failed to recover v3 backend"):
ssh wawashi@10.10.30.11 'sudo crictl logs $(sudo crictl ps -a --name etcd -q | head -1) 2>&1 | tail -60'
```

### 0.3 Query etcd member health directly (authoritative)

The health/quorum answer comes from etcd itself. `etcdctl` is **not on the node
by default** (the etcd image is distroless - see the CLAUDE.md gotcha "etcd image
is distroless"). Two ways to get it:

**Option A - use kubectl exec into a *healthy* etcd pod** (only works if the API is
up). `kubectl-homelab` is RBAC-blocked from `exec`, so use `kubectl-admin`. The
distroless etcd pod has no shell, but `etcdctl` the binary IS in the image, so you
can invoke it directly (no `sh -c`):

```bash
kubectl-admin -n kube-system exec etcd-k8s-cp1 -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint status --cluster -w table

kubectl-admin -n kube-system exec etcd-k8s-cp1 -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  member list -w table
```

**Option B - if the API is dead**, get an `etcdctl` binary onto a node from the
same release the cluster runs (`registry.k8s.io/etcd:3.6.6-0` -> etcd `v3.6.6`).
This is exactly how the `etcd-backup` CronJob obtains `etcdctl`:

```bash
ssh wawashi@10.10.30.11
ETCD_VER=v3.6.6
cd /tmp
wget -q "https://github.com/etcd-io/etcd/releases/download/${ETCD_VER}/etcd-${ETCD_VER}-linux-amd64.tar.gz"
tar xzf "etcd-${ETCD_VER}-linux-amd64.tar.gz"
# The tarball contains BOTH etcdctl and etcdutl:
sudo cp "etcd-${ETCD_VER}-linux-amd64/etcdctl" /usr/local/bin/
sudo cp "etcd-${ETCD_VER}-linux-amd64/etcdutl" /usr/local/bin/
sudo etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint status --cluster -w table
```

> No internet on the node (DNS/AdGuard down)? The GitHub download will fail. In that
> case pull `etcdctl` out of the already-cached distroless image instead:
> `sudo ctr -n k8s.io images mount registry.k8s.io/etcd:3.6.6-0 /mnt/etcd-img` then
> `sudo cp /mnt/etcd-img/usr/local/bin/etcdctl /usr/local/bin/` (path may differ by
> image build - run `sudo find /mnt/etcd-img -name etcdctl` to confirm), and
> `sudo ctr -n k8s.io images unmount /mnt/etcd-img` when done. `etcdutl` may or may
> not be present in the image; if it is not, use the deprecated `etcdctl snapshot
> restore` form shown in §4.4.

### 0.4 Decision

| What you see | Verdict | Action |
|--------------|---------|--------|
| 2 or 3 members healthy | etcd is FINE | Do NOT restore. The problem is elsewhere - back to [00-EMERGENCY.md](00-EMERGENCY.md). |
| 1 node down, other 2 healthy | Quorum holds | Do NOT restore. Get the node back - [00-EMERGENCY.md §8](00-EMERGENCY.md#8-a-node-is-down-or-notready). |
| 2 nodes down, hardware/OS recoverable | Quorum lost, data intact | Do NOT restore. Recover a node to regain quorum - [00-EMERGENCY.md §7](00-EMERGENCY.md#7-the-kubernetes-api-is-unreachable). |
| etcd logs show corruption / cannot recover backend, OR all 3 data dirs are lost/destroyed | etcd is BROKEN | Proceed to restore (this doc). |

**Only continue past this point if the last row matches.** If you are unsure, stop
and get help - a needless restore throws away real data.

---

## 1. Where the snapshots are

### 1.1 The etcd-backup CronJob

etcd is backed up daily by the `etcd-backup` CronJob in `kube-system`. **Nothing
else backs up etcd** - Velero and Longhorn do not. Verify it exists and has run:

```bash
kubectl-homelab get cronjob -n kube-system | grep -E 'NAME|etcd'
kubectl-homelab get jobs -n kube-system -l app=etcd-backup --sort-by=.metadata.creationTimestamp
```

Facts (from `manifests/kube-system/etcd-backup.yaml`, verified against the live
cluster 2026-07-08):

- **Schedule:** `30 3 * * *` in `Asia/Manila` = **03:30 daily Manila time**.
- **Writes to NFS:** server `10.10.30.4` (NAS/OMV), path `/Kubernetes/Backups/etcd`.
- **Filenames:** `etcd-YYYYMMDD-HHMMSS.db` (~177 MB each currently).
- **NFS retention: 3 days.** The job prunes with `find /backup -name "etcd-*.db"
  -mtime +3 -delete`. So the NAS holds only the last ~3-4 dailies.
  > **Note / doc discrepancy:** `docs/context/Backups.md` lists etcd retention as
  > "14 days", but the **deployed manifest prunes at 3 days** (`-mtime +3`). The
  > manifest is the source of truth for what is actually on the NAS. Confirmed live
  > 2026-07-08: only 4 dailies were present. Older-than-3-day etcd history exists
  > only in the off-site restic repo (7 daily / 4 weekly / 6 monthly, on OneDrive) -
  > see [../context/Backups.md](../context/Backups.md).

### 1.2 List the available snapshots on the NAS

You cannot SSH from WSL straight to the NAS. Hop through a node and mount the export
(mount, list, unmount). Use the repo's standard mount point `/tmp/nfs`:

```bash
ssh wawashi@10.10.30.11
sudo mkdir -p /tmp/nfs
sudo mount -t nfs4 10.10.30.4:/Kubernetes /tmp/nfs
ls -lah /tmp/nfs/Backups/etcd/
# When done looking:
sudo umount /tmp/nfs
```

You will see files like (real listing, cp1, 2026-07-08):

```
etcd-20260708-033008.db   177M   <- newest
etcd-20260707-033008.db
etcd-20260706-033008.db
etcd-20260705-033007.db
```

> Ignore any `*.db.part` file - that is a failed/partial run (a stale 0-byte
> `etcd-20260320-090315.db.part` is present on the NAS today). Never restore one.

---

## 2. Pick a snapshot

- **Default: the newest complete `.db`.** Least data loss.
- If corruption may have been written into etcd *before* it crashed, step back one
  or two days to a snapshot from before the corruption.
- **Verify the snapshot before trusting it.** From a node with `etcdctl`/`etcdutl`
  (see §0.3 Option B), copy the chosen file locally and check its status. A valid
  snapshot reports a hash, revision, and key count without error:

```bash
# On the node, with the NFS still mounted at /tmp/nfs:
sudo cp /tmp/nfs/Backups/etcd/etcd-20260708-033008.db /var/lib/etcd-snapshot.db
sudo etcdutl snapshot status /var/lib/etcd-snapshot.db -w table
#   (etcd 3.6: `etcdutl snapshot status`. `etcdctl snapshot status` also still works
#    but prints a deprecation warning in 3.6 - see the version note in §4.4.)
```

If `snapshot status` errors or shows 0 keys, that file is bad - pick an older one.

Note the numbers (revision, total keys) - you will sanity-check them again after
the restore.

---

## 3. Understand the plan before running anything

You will:

1. Restore the snapshot into a **fresh data directory on ONE node (cp1)** while its
   etcd + apiserver static pods are stopped.
2. Bring cp1 up as a **single-member** etcd (a one-node cluster).
3. **Reset cp2 and cp3, remove any stale etcd members, and rejoin them** so they
   re-replicate from cp1.

**WARNING - this is destructive and cluster-wide.** During the procedure the API is
down and all workloads are frozen. Do the restore on **cp1 only**; cp2/cp3 are
wiped and rejoined. Do not run the restore on more than one node.

Have ready: SSH to all three nodes, the chosen snapshot on cp1, and `etcdctl` +
`etcdutl` binaries on cp1 (§0.3 Option B).

---

## 4. Restore to ONE control plane (cp1)

All commands run **on cp1** (`ssh wawashi@10.10.30.11`, use `sudo`).

### 4.1 Confirm the exact etcd flags for THIS node

The restore flags must match this node's real etcd config. **Do not trust the values
below blindly - read them off the live manifest**, because kubeadm writes per-node
values:

```bash
ssh wawashi@10.10.30.11 'sudo grep -E -- "--name|--initial-advertise-peer-urls|--data-dir|--initial-cluster|--listen-peer-urls" /etc/kubernetes/manifests/etcd.yaml'
```

Verified values on cp1 (2026-07-08) - **confirm they still match**:

| Flag | cp1 value |
|------|-----------|
| `--name` | `k8s-cp1` |
| `--initial-advertise-peer-urls` | `https://10.10.30.11:2380` |
| `--listen-peer-urls` | `https://10.10.30.11:2380` |
| `--data-dir` | `/var/lib/etcd` |
| `--initial-cluster` | `k8s-cp1=https://10.10.30.11:2380` (already single-member on this node) |
| etcd image | `registry.k8s.io/etcd:3.6.6-0` (etcd v3.6.6) |

> Note: kubeadm sets `--initial-cluster` to **only this node** on nodes that joined
> via the runtime add-member flow, so cp1 already reads `k8s-cp1=...` alone. That is
> exactly what the single-node restore needs, so in practice §4.5 usually requires
> no edit at all. **Read the flag off the live manifest and match it** - do not
> assume all three peers are listed.

### 4.2 Stop the control-plane static pods on cp1

> **WARNING - this takes the API server and etcd down on cp1.** kubelet stops any
> static pod whose manifest leaves `/etc/kubernetes/manifests/`. Move them aside;
> keep them so you can restore them.

```bash
ssh wawashi@10.10.30.11
sudo mkdir -p /etc/kubernetes/manifests.bak
# Stop apiserver FIRST (so nothing writes to etcd), then etcd:
sudo mv /etc/kubernetes/manifests/kube-apiserver.yaml /etc/kubernetes/manifests.bak/
sudo mv /etc/kubernetes/manifests/etcd.yaml            /etc/kubernetes/manifests.bak/

# Wait for both containers to actually exit (should list nothing):
sleep 20
sudo crictl ps | grep -E 'etcd|kube-apiserver'
```

### 4.3 Move the old etcd data dir aside (do NOT delete it yet)

> **WARNING - do not delete the current data.** Rename it. If the restore goes
> wrong, the old directory is your only way back.

```bash
sudo mv /var/lib/etcd /var/lib/etcd.corrupt.$(date +%Y%m%d-%H%M%S)
```

### 4.4 Restore the snapshot into a fresh data dir

> **Version note (etcd 3.6):** `snapshot restore` moved to the **`etcdutl`** binary.
> `etcdctl snapshot restore` still works in 3.6 but prints a deprecation warning.
> Both binaries ship in the release tarball you downloaded in §0.3. Prefer `etcdutl`
> (the same form used in [../operations/restore.md](../operations/restore.md) and
> [../context/Upgrades.md](../context/Upgrades.md)). If your downloaded binary
> rejects a flag, run `etcdutl snapshot restore --help` and match the flags to that
> binary's version rather than guessing.

Restore **into `/var/lib/etcd`** (the data-dir the static pod expects). The
`--name` / `--initial-advertise-peer-urls` / `--initial-cluster` MUST match §4.1:

```bash
sudo etcdutl snapshot restore /var/lib/etcd-snapshot.db \
  --name=k8s-cp1 \
  --initial-cluster=k8s-cp1=https://10.10.30.11:2380 \
  --initial-advertise-peer-urls=https://10.10.30.11:2380 \
  --data-dir=/var/lib/etcd

# (Equivalent with the deprecated etcdctl form, if etcdutl is unavailable:)
# sudo ETCDCTL_API=3 etcdctl snapshot restore /var/lib/etcd-snapshot.db \
#   --name=k8s-cp1 \
#   --initial-cluster=k8s-cp1=https://10.10.30.11:2380 \
#   --initial-advertise-peer-urls=https://10.10.30.11:2380 \
#   --data-dir=/var/lib/etcd
```

Fix ownership so kubelet's etcd container can read it. The live `/var/lib/etcd` is
`root:root` mode `0700`, so match that:

```bash
sudo chown -R root:root /var/lib/etcd
sudo chmod 700 /var/lib/etcd
sudo ls -ld /var/lib/etcd   # expect: drwx------ root root
```

### 4.5 Make cp1 come up as a SINGLE-member cluster

For the restore, cp1 must start as a brand-new one-member cluster. In this cluster
cp1's `--initial-cluster` **already lists only `k8s-cp1`** (see §4.1 note), so most
of the time the un-edited manifest is correct as-is. **Only edit if §4.1 showed
extra peers.**

> **WARNING - if you DO edit, you are editing a static pod manifest.** Edit the
> **backup copy** at `/etc/kubernetes/manifests.bak/etcd.yaml`, then move it back.
> Change only the etcd flags; leave certs/volumes alone.

If (and only if) the manifest lists cp2/cp3 in `--initial-cluster`, edit it so that,
in the etcd container's command args:

- `--initial-cluster=k8s-cp1=https://10.10.30.11:2380` (only cp1),
- `--initial-cluster-state=new` (this is the default, so usually already fine),
- `--name`, `--initial-advertise-peer-urls`, `--listen-peer-urls`, `--data-dir`
  unchanged (already cp1's).

> The snapshot restore in §4.4 already wrote a fresh member/cluster identity into
> the data dir consistent with `--initial-cluster=k8s-cp1=...`, so etcd boots as a
> clean single member.

### 4.6 Start etcd, then the apiserver

```bash
# Bring etcd back first:
sudo mv /etc/kubernetes/manifests.bak/etcd.yaml /etc/kubernetes/manifests/
sleep 30
sudo crictl ps | grep etcd     # should be Running

# Confirm the single-member cluster is healthy (use etcdctl from §0.3 Option B):
sudo etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint status -w table
sudo etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  member list -w table          # should show ONLY k8s-cp1

# Now bring the apiserver back:
sudo mv /etc/kubernetes/manifests.bak/kube-apiserver.yaml /etc/kubernetes/manifests/
sleep 30
sudo crictl ps | grep kube-apiserver
```

Point kubectl at cp1 directly (the VIP may not be healthy yet, and the API cert
includes each node IP as a SAN):

```bash
# From WSL - temporarily target cp1's IP if the VIP is not answering:
kubectl --kubeconfig ~/.kube/homelab.yaml --server=https://10.10.30.11:6443 get nodes
```

At this point you have a **1-node cluster** restored from the snapshot. cp2 and cp3
will show `NotReady` and their etcd members are stale - fix that next.

---

## 5. Rejoin cp2 and cp3

etcd currently has one member (cp1). cp2 and cp3 still carry old etcd data that no
longer matches. Wipe their control-plane state and rejoin them one at a time. This
is the firefighting version of [../operations/node-lifecycle.md](../operations/node-lifecycle.md)
"add / replace a node" - refer there for the calm, step-by-step detail.

> **WARNING - `kubeadm reset` on a node destroys its Kubernetes state** (etcd member
> data, `/etc/kubernetes/*`, kubelet state). Do it deliberately, **one node at a
> time**, and confirm cp1's etcd stays healthy between each rejoin.

### 5.1 Remove any stale etcd members from cp1's view

From cp1, list members. After a clean single-node restore this should show **only**
`k8s-cp1`, so there is usually nothing to remove. Remove an entry only if a member
other than cp1 is actually listed:

```bash
# On cp1 - list current members:
sudo etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  member list -w table
# If any member other than k8s-cp1 is listed, remove it by its hex ID:
# sudo etcdctl --endpoints=https://127.0.0.1:2379 \
#   --cacert=/etc/kubernetes/pki/etcd/ca.crt \
#   --cert=/etc/kubernetes/pki/etcd/server.crt \
#   --key=/etc/kubernetes/pki/etcd/server.key \
#   member remove <MEMBER_ID_HEX>
```

### 5.2 Reset cp2, then rejoin

Get a fresh join command from cp1 (this uploads certs and prints a
`kubeadm join ... --control-plane` line):

```bash
# On cp1:
sudo kubeadm init phase upload-certs --upload-certs   # prints a certificate key
sudo kubeadm token create --print-join-command        # prints the base join command
# Combine them: append  --control-plane --certificate-key <key-from-upload-certs>
```

Then on **cp2**:

```bash
ssh wawashi@10.10.30.12
# WARNING - destroys cp2's k8s state. kubeadm reset already clears /var/lib/etcd and
# /etc/kubernetes; the extra rm -rf below is belt-and-suspenders for CNI leftovers:
sudo kubeadm reset -f
sudo rm -rf /etc/cni/net.d
# Rejoin as a control-plane node (use the exact command assembled above):
sudo kubeadm join api.k8s.rommelporras.com:6443 \
  --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash> \
  --control-plane \
  --certificate-key <cert-key>
```

> If DNS is broken and `api.k8s.rommelporras.com` won't resolve, either add
> `10.10.30.10 api.k8s.rommelporras.com` to `/etc/hosts` on cp2 first (same trick as
> [00-EMERGENCY.md §0](00-EMERGENCY.md#0-before-you-touch-anything---read-this)), or
> substitute `10.10.30.11:6443` (cp1's IP) in the join command - the API cert
> includes each node IP as a SAN.

Verify cp2 joined and etcd now has 2 members before touching cp3:

```bash
# From WSL / cp1:
kubectl --kubeconfig ~/.kube/homelab.yaml get nodes
# On cp1 - member list should now show k8s-cp1 AND k8s-cp2:
sudo etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  member list -w table
```

### 5.3 Reset cp3, then rejoin

Repeat §5.2 exactly, on **cp3** (`ssh wawashi@10.10.30.13`). Generate a fresh
join command again if the previous token/cert-key expired (default token TTL is
24h; the uploaded-cert key expires in ~2h). Confirm etcd ends with all **3**
members and quorum restored.

### 5.4 Watch for the kubelet sysctl trap after any reboot

If a node was rebooted during this (or reboots afterward), kubelet may fail to
start with `invalid kernel flag` and the node sits `Ready=Unknown`. This is the
known `protectKernelDefaults` sysctl issue - fix per
[00-EMERGENCY.md §7 step 3](00-EMERGENCY.md#7-the-kubernetes-api-is-unreachable):

```bash
ssh wawashi@<node> 'sudo journalctl -u kubelet -n 30 --no-pager | grep "invalid kernel flag"'
# If present:
ssh wawashi@<node> 'sudo sysctl -w vm.overcommit_memory=1 kernel.panic=10 kernel.panic_on_oops=1 && sudo systemctl restart kubelet'
```

---

## 6. Post-restore verification

Work top-down. The cluster came back from a point-in-time snapshot, so give
controllers a few minutes to reconcile.

### 6.1 Nodes and control plane

```bash
kubectl-admin get nodes -o wide                                  # all 3 Ready
kubectl-admin get pods -n kube-system -o wide | grep -E 'etcd|apiserver|kube-vip|controller-manager|scheduler'
ping -c2 10.10.30.10                                             # API VIP answering again
# etcd: 3 members, all started, one leader:
kubectl-admin -n kube-system exec etcd-k8s-cp1 -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint status --cluster -w table
```

### 6.2 Core cluster pods

```bash
kubectl-admin get pods -A | grep -vE 'Running|Completed'         # what's still not up?
kubectl-admin get pods -n kube-system | grep -iE 'cilium|coredns'
dig @10.10.30.53 google.com +short                              # DNS working end to end
```

> If AdGuard DNS (`10.10.30.53`) is unreachable from LAN clients after nodes moved
> around, it is likely the Cilium L2 lease mismatch - see
> [00-EMERGENCY.md §3.2](00-EMERGENCY.md#32-mode-a-l2-lease-mismatch-most-common-lan-only-outage).

### 6.3 ArgoCD is syncing

Everything except `cilium` is ArgoCD-managed; do NOT `kubectl apply` / `helm upgrade`
managed resources (selfHeal reverts them). Listing ArgoCD Applications is RBAC-blocked
on `kubectl-homelab`, so use `kubectl-admin`. Run `argocd` inside the controller pod:

```bash
kubectl-admin get applications -n argocd | grep -vE 'Synced.*Healthy'
kubectl-admin exec -n argocd statefulset/argocd-application-controller -- argocd app list --core
# Nudge a stuck app if needed:
kubectl-admin exec -n argocd statefulset/argocd-application-controller -- argocd app get <app> --core --refresh
```

`gitlab` is manual-sync by design (no `automated:` block); resync it by hand:

```bash
kubectl-admin exec -n argocd statefulset/argocd-application-controller -- argocd app sync gitlab --core
```

### 6.4 Longhorn volumes attaching

```bash
kubectl-admin get pods -n longhorn-system -o wide | grep -iE 'csi|instance-manager|manager'
kubectl-admin get volumes.longhorn.io -n longhorn-system        # state / robustness
kubectl-admin get pods -A | grep -iE 'ContainerCreating' | grep -v Completed
```

> **NEVER delete a PVC to fix a mount error** - it destroys the Longhorn volume and
> all replicas. Volumes may take a while to reattach after the API returns; give
> them time. Mount-stuck triage: [storage.md](storage.md),
> [00-EMERGENCY.md §6](00-EMERGENCY.md#6-storage--volume-stuck).

### 6.5 Vault unsealed and ESO syncing

After the control plane restarts, Vault comes up **sealed**; the `vault-unsealer`
pod normally re-unseals it within ~30s from the in-cluster `vault-unseal-keys`
Secret (keys also in 1Password "Vault Unseal Keys").

```bash
kubectl-homelab get pods -n vault                              # vault-unsealer Running?
kubectl-admin exec -n vault vault-0 -- vault status           # exit 0=unsealed, 2=sealed, 1=error
kubectl-admin get externalsecrets -A | grep -v SecretSynced   # any stuck ESO?
```

If it stays sealed, follow [00-EMERGENCY.md §10](00-EMERGENCY.md#10-vault-sealed--secrets-missing).

### 6.6 TLS certificates

cert-manager resources (`certificate`, `challenges`, `orders`) are RBAC-blocked on
`kubectl-homelab` - use `kubectl-admin`. The three wildcard certs live in the
`default` namespace:

```bash
kubectl-admin get certificate -A
kubectl-admin get certificate wildcard-k8s-tls -n default -o wide   # READY should be True
```

If a cert is missing/expired, cert-manager reissues via Cloudflare DNS-01 (issuer
`letsencrypt-prod`). See [certificates.md](certificates.md) and
[../operations/certificate-rotation-manual.md](../operations/certificate-rotation-manual.md).

> **WARNING - reissue by Secret deletion is destructive to the current cert.** The
> `cmctl` / `kubectl cert-manager` plugin is NOT installed, so there is no
> `cert-manager renew`. To force a reissue you delete the backing Secret and
> cert-manager recreates it: `kubectl-admin delete secret wildcard-k8s-tls -n default`.
> Do this ONLY if the cert is actually broken (a fresh DNS-01 challenge takes a few
> minutes and briefly leaves sites without a serving cert). If the existing
> Certificate is still `READY=True`, leave it alone - it survived the restore.

---

## 7. Cleanup (only after the cluster is verified healthy)

- On cp1, once you are confident, remove the saved-aside old data dir:
  `sudo rm -rf /var/lib/etcd.corrupt.<timestamp>` and `/var/lib/etcd-snapshot.db`.
  **Keep them until every check in §6 passes.**
- If you hand-edited cp1's `etcd.yaml` in §4.5, compare it against a freshly
  rejoined node's `/etc/kubernetes/manifests/etcd.yaml`. kubeadm rewrites this on
  join, so usually no manual edit remains needed post-rejoin. **If unsure, do NOT
  hand-edit `etcd.yaml`** - confirm the desired flags against a healthy rejoined
  node first.
- Note anything you changed at runtime; ArgoCD selfHeal reconciles managed
  resources back to Git, but node-level edits (static-pod manifests, sysctls,
  binaries in `/usr/local/bin`) are not in Git.

---

## 8. Version caveats - do not fabricate flags

- This cluster runs **etcd v3.6.6** (`registry.k8s.io/etcd:3.6.6-0`) and Kubernetes
  **v1.35.0** on Ubuntu 24.04 (M80q nodes, NIC `eno1`). Flag names and the binary
  split (`etcdctl` vs `etcdutl`) can change across etcd versions.
- **Always confirm the live values** in `/etc/kubernetes/manifests/etcd.yaml` on the
  node and against `etcdutl snapshot restore --help` for the exact binary you
  downloaded. If a flag here does not match, trust the node/binary, not this doc.
- The `kubeadm join --control-plane` flags (token TTL, `--certificate-key`
  handling) can differ across kubeadm versions - regenerate the join command with
  `kubeadm token create --print-join-command` + `kubeadm init phase upload-certs`
  rather than reusing an old one.
- M80q BIOS POST takes 5-7 minutes; a rebooted node looks dead longer than expected.

