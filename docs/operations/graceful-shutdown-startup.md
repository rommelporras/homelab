# Graceful full-cluster shutdown and cold-start (planned maintenance)

> **Use this when you are deliberately powering the whole rack down and back up** -
> house electrical work, a UPS self-test, moving the rack. This is the PLANNED
> path. It is NOT the automated power-loss path (that is NUT-driven, see
> [../context/UPS.md](../context/UPS.md)) and NOT the "everything is on fire"
> emergency sweep ([../runbooks/00-EMERGENCY.md](../runbooks/00-EMERGENCY.md) §11).
>
> Read-only checks use `kubectl-homelab`. Anything that changes state uses
> `kubectl-admin` (full cluster-admin). SSH to nodes as `wawashi@10.10.30.11`
> (cp1), `.12` (cp2), `.13` (cp3). Timezone is Asia/Manila.
>
> Related: [../context/UPS.md](../context/UPS.md) ·
> [../runbooks/00-EMERGENCY.md](../runbooks/00-EMERGENCY.md) ·
> [../operations/node-lifecycle.md](../operations/node-lifecycle.md) (single-node
> drain/reboot) · [../operations/restore.md](../operations/restore.md) ·
> [../runbooks/etcd-recovery.md](../runbooks/etcd-recovery.md) (break-glass,
> NOT this doc) · [../rebuild/v0.29.0-vault-eso.md](../rebuild/v0.29.0-vault-eso.md)
> (Bootstrap Order) · [../context/Backups.md](../context/Backups.md) ·
> [../runbooks/storage.md](../runbooks/storage.md)

---

## 0. Know the layout before you start

| Node | IP | Role that matters here |
|------|-----|------------------------|
| k8s-cp1 | 10.10.30.11 | **NUT server + UPS USB cable** (see UPS.md). Power it **last**, boot it **first**. |
| k8s-cp2 | 10.10.30.12 | control-plane + etcd member |
| k8s-cp3 | 10.10.30.13 | control-plane + etcd member |

- **etcd quorum needs 2 of 3 nodes.** You can lose one node and stay writable.
  During a clean shutdown you WILL cross below quorum on purpose - that is fine
  because you are stopping the whole thing, not trying to keep it serving.
- **cp1 owns the UPS.** The UPS USB cable is physically attached to cp1 and cp1
  runs the NUT server (`upsd`). Keep cp1 alive longest so the NUT chain and any
  in-flight monitoring stays sane, and bring it up first on the way back.
- API VIP `10.10.30.10` (kube-vip, lease `plndr-cp-lock`). Gateway VIP
  `10.10.30.20`. AdGuard DNS `10.10.30.53` (single replica, `Local`). NAS OMV
  `10.10.30.4`, NFS export `/Kubernetes` with a `Backups/` subtree.

---

## SHUTDOWN

### 1. Pre-shutdown checklist (do NOT skip - this is your safety net)

Everything here is read-only except the Longhorn snapshots. Confirm each item
before you cut power. If a backup is stale, decide consciously whether to proceed.

#### 1a. Note current cluster state (so you can compare on the way back)

```bash
kubectl-homelab get nodes -o wide
kubectl-homelab get pods -A | grep -vE 'Running|Completed'   # ideally empty
```

Record ArgoCD state so you know what "healthy" looked like before you shut down.
Listing Applications is RBAC-blocked on `kubectl-homelab`, so use `kubectl-admin`:

```bash
kubectl-admin get applications -n argocd    # note anything NOT Synced/Healthy NOW
```

> `gitlab` (manual-sync) and `cilium` (the CNI) legitimately may not show
> `Synced Healthy`. Everything else should. Write down anything already off so you
> don't blame the reboot for it later.

#### 1b. Confirm a recent etcd backup exists

The `etcd-backup` CronJob runs daily at 03:30 Asia/Manila and writes to the NFS
target `10.10.30.4:/Kubernetes/Backups/etcd` (3-day retention pruned on the NAS;
deep history is in the off-site restic copy - see
[../context/Backups.md](../context/Backups.md)).

```bash
kubectl-homelab get cronjob etcd-backup -n kube-system    # LAST SCHEDULE recent?
kubectl-admin get jobs -n kube-system | grep etcd-backup  # newest job Completed?
```

To be certain the `.db` file actually landed on the NAS, mount the NFS export from
a node and list it (any node can NFS-read it; `/tmp/nfs` matches the repo
convention and is guaranteed writable):

```bash
ssh wawashi@10.10.30.11 'sudo mkdir -p /tmp/nfs && \
  sudo mount -t nfs4 10.10.30.4:/Kubernetes /tmp/nfs && \
  ls -lht /tmp/nfs/Backups/etcd/ | head; \
  sudo umount /tmp/nfs'
```

> If the newest `etcd-*.db` is older than ~24h, trigger a fresh one before
> powering down:
> `kubectl-admin create job -n kube-system etcd-backup-manual --from=cronjob/etcd-backup`
> then wait for it to Complete (`kubectl-admin get jobs -n kube-system | grep etcd-backup-manual`).

#### 1c. Confirm a recent Velero backup

The Velero schedule `daily-k8s-backup` runs at **20:30 UTC (= 04:30 Asia/Manila)** -
the Velero Schedule has no timezone field so it runs in UTC, NOT local time. Don't
judge freshness by the clock; check the actual last-backup timestamp below.
Velero resources are RBAC-blocked on `kubectl-homelab` - use `kubectl-admin`:

```bash
kubectl-admin get schedules.velero.io -n velero        # daily-k8s-backup Enabled?
kubectl-admin get backups.velero.io -n velero | tail   # newest one Completed?
```

#### 1d. Take Longhorn snapshots of critical volumes

Longhorn already snapshots the labelled volumes on a recurring schedule
(`critical` daily at 19:00 UTC = 03:00 Manila, `important` daily at 20:00 UTC =
04:00 Manila - Longhorn RecurringJobs run in UTC; see
[../context/Backups.md](../context/Backups.md)). For a planned power-down, take
**fresh on-demand snapshots of the stateful volumes** so you have a clean restore
point taken minutes before the outage.

- **Easiest and verified path: Longhorn UI** at
  `https://longhorn.k8s.rommelporras.com` -> **Volume** -> select each attached
  volume -> **Take Snapshot**. Do this for the databases and anything you care
  about (vault, gitlab postgres, ghost mysql, invoicetron-db, atuin, the arr
  configs). This is the path CLAUDE.md endorses ("take a Longhorn snapshot via UI
  or kubectl-admin").
- First list what is attached so you know what to snapshot:
  ```bash
  kubectl-homelab get volumes.longhorn.io -n longhorn-system \
    -o custom-columns='NAME:.metadata.name,STATE:.status.state,ROBUST:.status.robustness'
  ```

> **Not every volume is backed up off-box.** Only volumes in the `critical` or
> `important` recurring-job groups get NFS backups. A snapshot is on-cluster only;
> if the NVMe dies, the snapshot dies with it. For irreplaceable data, verify a
> real backup exists (§1b/1c and Longhorn UI -> Backup) before you touch power.

#### 1e. Confirm Vault is healthy (it will need to re-unseal on the way back)

```bash
kubectl-homelab get pods -n vault              # vault-0 AND vault-unsealer Running?
```

You do not need to do anything to Vault before shutdown - it seals cleanly on
power-off and auto-unseals on boot (§9). Just confirm the unsealer pod is alive
now, and that you can find the 1Password item **"Vault Unseal Keys"** as a manual
fallback if the auto-unseal ever fails.

---

### 2. Shutdown order and why

Bring nodes down **worker-load-first, cp1 last**. There is no dedicated worker
here (all 3 are control-plane), so the order is:

```
cp3 (10.10.30.13)  ->  cp2 (10.10.30.12)  ->  cp1 (10.10.30.11, UPS host, last)
```

Reasons:

- **cp1 last** - it runs the NUT server and has the UPS USB cable. Keep it up
  while the others go down (mirrors the staggered UPS timers in
  [../context/UPS.md](../context/UPS.md) where cp1 shuts down last).
- **etcd quorum** - shutting down cp3 then cp2 drops etcd below quorum (only cp1
  left). That is expected and fine for a full planned shutdown. Do NOT try to keep
  the API serving through this - you are turning the whole cluster off. Just do
  cp3, cp2, cp1 without long gaps.
- Longhorn replicas live across all three nodes. Stopping nodes cleanly lets
  Longhorn detach volumes gracefully; a hard power-yank does not.

### 3. Shut down each node

For a clean full-cluster power-off, `shutdown -h now` per node is sufficient -
kubelet's graceful-shutdown (`shutdownGracePeriod: 120s`) stops pods in order and
Longhorn detaches volumes as the kubelet drains. You do **not** need to cordon or
drain for a full power-off (drain is for keeping the *rest* of the cluster serving
while one node leaves; that is not the goal here).

> **Optional, gentler:** if you want pods evicted before the node stops (e.g. to
> watch volumes detach one node at a time), cordon+drain first. This is slower and
> unnecessary for a full shutdown, but harmless:
> ```bash
> kubectl-admin cordon k8s-cp3
> kubectl-admin drain k8s-cp3 --ignore-daemonsets --delete-emptydir-data --timeout=180s
> ```
> Skip this for a straightforward "power everything off" - go straight to
> `shutdown` below.

Run these **one at a time, in order**, waiting for each node to fully power off
before the next:

```bash
# 1. cp3 first
ssh wawashi@10.10.30.13 'sudo shutdown -h now'

# 2. then cp2 (wait until cp3 has powered off)
ssh wawashi@10.10.30.12 'sudo shutdown -h now'

# 3. cp1 LAST (UPS host)
ssh wawashi@10.10.30.11 'sudo shutdown -h now'
```

The SSH session drops as each node halts - that is normal. Confirm each node is
actually off before pulling power (LED/fan check on the M80q, or ping):

```bash
ping -c2 10.10.30.13     # should be unreachable once it's down
```

### 4. Confirm before you cut power

- All three nodes unreachable to `ping`.
- If you have console/monitor access, each M80q shows powered off (not just at a
  boot prompt).

Now it is safe to switch off the PDU / UPS / mains for your maintenance.

---

## STARTUP / COLD-START

### 5. Power-on order

Bring nodes up **cp1 first** (UPS host + NUT server), then cp2, then cp3. Power
them on with a short stagger (~30s between presses) so they do not all hammer the
NIC/DNS/etcd election at the exact same instant - see the "all 3 at once" note in
§8.

```
cp1 (10.10.30.11, first)  ->  cp2 (10.10.30.12)  ->  cp3 (10.10.30.13)
```

> **M80q BIOS POST takes 5-7 minutes.** A node that just got power will look dead
> for several minutes before it even starts booting Linux. Do not assume hardware
> failure early. Only start worrying past ~8-10 min with no ping.

### 6. Wait for etcd quorum to form

The cluster is not usable until at least 2 of 3 nodes are up and their static
control-plane pods (etcd, kube-apiserver, kube-vip) are running.

Watch from WSL:

```bash
ping -c2 10.10.30.10                         # API VIP answers once kube-vip is up
kubectl-homelab get nodes -o wide             # wait for 2+ nodes Ready
```

If the VIP/API is slow to answer, check etcd directly on the nodes that are up:

```bash
ssh wawashi@10.10.30.11 'sudo crictl ps | grep -E "etcd|kube-apiserver|kube-vip"'
```

Once 2 nodes are `Ready`, etcd has quorum and the API is writable. The third
joining later just restores full redundancy.

### 7. Let the dependency chain self-heal (do NOT force it)

After quorum forms, the cluster brings itself back in a fixed order. This is the
**"Bootstrap Order After Full Cluster Loss"** documented in
[../rebuild/v0.29.0-vault-eso.md](../rebuild/v0.29.0-vault-eso.md#bootstrap-order-after-full-cluster-loss)
(and summarized in [../operations/restore.md](../operations/restore.md)).
Everything below is automatic - your job is mostly to watch:

```
1. Control plane + etcd           -> automatic (kubeadm static pods)
2. Longhorn + volume attach       -> automatic (CSI re-attaches PVCs)
3. vault-0 pod starts             -> automatic (StatefulSet)
4. vault-unsealer unseals vault-0 -> automatic (~30s after vault-0 is Ready)
5. ESO reconnects to vault-backend ClusterSecretStore -> automatic
6. ExternalSecrets re-sync        -> automatic
7. Workloads start with secrets   -> automatic (ArgoCD reconciles the rest)
```

Watch it converge:

```bash
kubectl-homelab get pods -n longhorn-system -o wide         # CSI + instance-managers up
kubectl-homelab get volumes.longhorn.io -n longhorn-system  # volumes going attached/healthy
kubectl-homelab get pods -n vault                           # vault-0 + vault-unsealer Running
kubectl-homelab get externalsecret -A | grep -v SecretSynced   # should empty out over time
kubectl-homelab get pods -A | grep -vE 'Running|Completed'     # shrinks as things start
```

Give it **10-20 minutes** before intervening. Longhorn re-attaching dozens of
volumes, Vault unsealing, ESO re-minting secrets, then apps restarting is a chain
- yanking on any one link (deleting pods, force-syncing ArgoCD) just slows it down.

### 8. Cold-start rejoin failures (the three you actually hit)

If a node does NOT come back Ready, it is almost always one of these:

#### 8a. kubelet stuck on the protectKernelDefaults sysctl loop (most common)

After a reboot a node can sit `Ready=Unknown` forever because kubelet's
`protectKernelDefaults: true` demands three sysctls that revert to kernel defaults
on boot. This is documented fully in
[../runbooks/00-EMERGENCY.md](../runbooks/00-EMERGENCY.md#7-the-kubernetes-api-is-unreachable)
§7 step 3. Diagnose and fix:

```bash
ssh wawashi@10.10.30.13 'sudo journalctl -u kubelet -n 30 --no-pager | grep "invalid kernel flag"'
# If that matches, set them live (they persist via /etc/sysctl.d/90-kubelet.conf):
ssh wawashi@10.10.30.13 'sudo sysctl -w vm.overcommit_memory=1 kernel.panic=10 kernel.panic_on_oops=1 && sudo systemctl restart kubelet'
```

> All three nodes were pre-seeded with `/etc/sysctl.d/90-kubelet.conf` in Phase
> 5.9.7, so this *should* no longer bite on reboot - but check it first if any
> node is `Ready=Unknown` for more than a few minutes past POST.

#### 8b. M80q slow POST mistaken for a dead node

BIOS POST is 5-7 minutes. A node can be genuinely fine and just not on the network
yet. Wait past 8-10 minutes before treating it as failed. See
[../runbooks/00-EMERGENCY.md](../runbooks/00-EMERGENCY.md#8-a-node-is-down-or-notready) §8.

#### 8c. All 3 nodes booting at once

If you powered everything simultaneously (e.g. mains just came back), expect a
messy first couple of minutes: etcd leader election, kube-vip lease contention on
`plndr-cp-lock`, Cilium L2 leases re-electing, and a brief DNS gap while AdGuard's
pod and its L2 lease settle. This usually resolves itself within a few minutes.
Two known follow-ups:

- **Cross-VLAN SSH to a just-rebooted node hangs:** OPNsense keeps stale firewall
  states. Clear the states for that node's IP in OPNsense
  `Firewall > Diagnostics > States`. (§8 of the emergency guide.)
- **AdGuard reachable in-cluster but LAN clients can't resolve** after the pod
  landed on a different node than the L2 lease holder: this is the L2-lease-mismatch
  bug. Fix per [../runbooks/00-EMERGENCY.md](../runbooks/00-EMERGENCY.md#32-mode-a-l2-lease-mismatch-most-common-lan-only-outage) §3.2.
  Quick check:
  ```bash
  kubectl-homelab get lease -n kube-system cilium-l2announce-home-adguard-dns \
    -o jsonpath='{.spec.holderIdentity}{"\n"}'
  kubectl-homelab get pods -n home -l app=adguard-home -o wide   # same node as lease holder?
  ```

### 9. Vault: auto-unseal is the norm, manual unseal is the fallback

**Vault comes up sealed after any power-off, and normally re-unseals itself.** The
`vault-unsealer` pod polls every ~30s and unseals `vault-0` from the in-cluster
`vault-unseal-keys` Secret. So the default expectation on cold-start is: wait ~30s
after `vault-0` is Ready and it unseals on its own. Verify:

```bash
kubectl-homelab get pods -n vault                        # vault-unsealer Running?
kubectl-admin exec -n vault vault-0 -- vault status      # exit 0 = unsealed, 2 = sealed, 1 = error
```

**Only if Vault stays sealed** (unsealer down, or `vault-unseal-keys` Secret
missing) do you unseal by hand. That manual path is
[../runbooks/00-EMERGENCY.md](../runbooks/00-EMERGENCY.md#10-vault-sealed--secrets-missing)
§10 - it is a **fallback, not the routine cold-start step**. The keys are in the
1Password item **"Vault Unseal Keys"**; this terminal has no `op` access, so open
1Password yourself and run the unseal from a safe terminal:

```bash
# FALLBACK ONLY - normal cold-start does this automatically. Repeat per required key:
kubectl-admin exec -n vault vault-0 -- vault operator unseal <key>
```

Once Vault is unsealed, ESO resumes minting secrets automatically -
`kubectl-homelab get externalsecret -A | grep -v SecretSynced` should drain to
empty. See [../runbooks/vault.md](../runbooks/vault.md).

### 10. Final health sweep

When the dust settles, run the standard alert-storm health sweep from
[../runbooks/00-EMERGENCY.md](../runbooks/00-EMERGENCY.md#11-everything-is-broken-alert-storm)
§11 - the first "no" is usually the thing still broken:

```bash
kubectl-homelab get nodes                                   # 1. all 3 Ready?
ping -c2 10.10.30.10                                        # 2. API VIP alive?
dig @10.10.30.53 google.com +short                         # 3. DNS working (from a LAN client)?
kubectl-homelab get pods -n kube-system | grep -iE 'cilium|coredns'  # 4. CNI/DNS pods up?
kubectl-admin exec -n vault vault-0 -- vault status        # 5. Vault unsealed?
kubectl-homelab get pods -A | grep -vE 'Running|Completed' # 6. what's still not up?
```

Then confirm the platform layer:

```bash
kubectl-homelab get externalsecret -A | grep -v SecretSynced          # secrets synced?
kubectl-homelab get volumes.longhorn.io -n longhorn-system | grep -v healthy   # all attached/healthy?
kubectl-admin get applications -n argocd | grep -vE 'Synced.*Healthy'  # matches your §1a baseline?
```

> Compare the ArgoCD result against what you wrote down in §1a. Anything that was
> already off before shutdown is not your reboot's fault. `gitlab` is manual-sync -
> if it needs a nudge:
> `kubectl-admin exec -n argocd statefulset/argocd-application-controller -- argocd app sync gitlab --core`.

Give cascaded alerts a few minutes to self-clear once the root pieces (nodes, API,
DNS, Vault) are healthy.

---

## Quick reference

**Shutdown:** snapshot criticals + verify backups -> `shutdown -h now` on
**cp3 -> cp2 -> cp1 (last)** -> confirm all off.

**Startup:** power **cp1 first -> cp2 -> cp3** (5-7 min POST each) -> wait for
2/3 quorum + API VIP -> let Longhorn/Vault/ESO/ArgoCD self-heal (10-20 min) ->
run the §10 sweep.

**Do not:** delete a PVC to fix a mount error; force-sync ArgoCD or delete pods
during the self-heal window; manually unseal Vault before checking the unsealer.

