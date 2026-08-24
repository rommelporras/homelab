# Node lifecycle - maintenance, addition, and decommission

> How to safely take a control-plane node out for maintenance, add a replacement
> or new node, and permanently decommission a dead one. All three nodes are
> control-plane (etcd quorum needs 2 of 3 alive), so every one of these is a
> quorum-sensitive operation - only touch one node at a time.
>
> This is planned, calm work. If a node just fell over and you're firefighting,
> start at [../runbooks/00-EMERGENCY.md §8](../runbooks/00-EMERGENCY.md#8-a-node-is-down-or-notready).
> Related: [../runbooks/longhorn-hardware.md](../runbooks/longhorn-hardware.md)
> (detailed NVMe-reseat maintenance flow), [../runbooks/storage.md](../runbooks/storage.md)
> (Longhorn volume triage, stale iSCSI sessions),
> [graceful-shutdown-startup.md](graceful-shutdown-startup.md) (whole-cluster power
> down/up), [../runbooks/etcd-recovery.md](../runbooks/etcd-recovery.md) (last-resort
> etcd restore), [../context/Cluster.md](../context/Cluster.md) (canonical
> IPs/hostnames), [../context/Storage.md](../context/Storage.md),
> [day-to-day.md](day-to-day.md).

---

## Ground rules (read before any of the three)

- **Nodes:** `k8s-cp1` / `k8s-cp2` / `k8s-cp3` at `10.10.30.11` / `.12` / `.13`.
  API VIP `10.10.30.10` (`api.k8s.rommelporras.com`), kube-vip lease
  `plndr-cp-lock`. Cilium Gateway VIP `10.10.30.20` serves `*.k8s.rommelporras.com`.
- **etcd quorum = 2 of 3.** One node down is survivable. **Never take a second
  node down while one is already out** - that loses quorum and the API goes
  read-only/unavailable. Verify all other nodes are `Ready` before you cordon.
- **kubectl wrappers:** `kubectl-homelab` is read-only (`~/.kube/homelab-claude.yaml`);
  it CANNOT `exec`, `get` a named secret, read pod logs, or list ArgoCD
  Applications / Velero schedules+backups / cert-manager certificates. Use
  `kubectl-admin` (`~/.kube/homelab.yaml`) for all of those and every write.
  In a plain (non-zsh) script use `kubectl --kubeconfig ~/.kube/homelab.yaml`.
- **SSH:** `ssh wawashi@10.10.30.11` (cp1), `.12` (cp2), `.13` (cp3). No direct
  SSH from WSL to the NAS - go through a node.
- **GitOps:** everything except `cilium` is ArgoCD-managed. Do NOT `kubectl apply`
  / `helm upgrade` managed resources - selfHeal reverts them. Run `argocd` from
  the controller pod:
  `kubectl-admin exec -n argocd statefulset/argocd-application-controller -- argocd <cmd> --core`.
- **Longhorn:** NEVER delete a PVC to fix a mount error. Replicas are 2x by
  default (`default-replica-count = 2`); most volumes have exactly 2 copies, so a
  node down means the affected volumes run **degraded (1 replica)** until rebuilt.
- **M80q BIOS POST takes 5-7 minutes.** A rebooted node looks dead longer than you
  expect. Wait before assuming hardware failure.
- **Timezone is Asia/Manila** for any timestamps you record.

---

## A. Planned maintenance (drain, reboot/service, uncordon)

Use this for any physical or OS work on a healthy node: RAM, reboot, kernel
update, cover-off inspection.

> The NVMe-reseat case has a fully detailed, step-by-step version already:
> [../runbooks/longhorn-hardware.md "Reseating an NVMe"](../runbooks/longhorn-hardware.md#reseating-an-nvme).
> Follow that for a reseat. The flow below is the generic template for any
> maintenance and matches it.

Replace `<node>` with `k8s-cp1` / `k8s-cp2` / `k8s-cp3` throughout.

### A.1 Pre-drain safety checks

```bash
# 1. All OTHER nodes Ready (quorum must survive this drain).
kubectl-homelab get nodes -o wide

# 2. No Longhorn volume already degraded/faulted - every volume must have a
#    healthy replica on a node OTHER than <node> before you drain.
kubectl-homelab get volumes.longhorn.io -n longhorn-system -o json \
  | jq -r '.items[] | select(.status.robustness != "healthy") | "\(.metadata.name)\t\(.status.robustness)\t\(.status.state)"'
# Expect empty output. If anything prints, fix that volume FIRST
# (see ../runbooks/storage.md). Draining now would risk the only healthy copy.
```

### A.2 Snapshot / backup critical volumes (defense in depth)

A clean drain + reboot should not lose data, but physical work can. Snapshot or
back up volumes whose data you cannot lose before touching hardware.

- Longhorn UI (`https://longhorn.k8s.rommelporras.com`) -> Volume -> **Create
  Backup** (or **Take Snapshot** for a faster local point-in-time). Wait for
  `Completed` before proceeding.
- Not every volume is backed up automatically - only those labelled
  `recurring-job-group.longhorn.io/critical` or `important`. Check before
  assuming a volume is recoverable. See [../context/Backups.md](../context/Backups.md).

### A.3 Cordon and drain

```bash
kubectl-admin cordon <node>
kubectl-admin drain <node> --ignore-daemonsets --delete-emptydir-data --force
```

- Longhorn's `instance-manager-*` and `csi-plugin` DaemonSet pods stay (they run
  everywhere by design; their PDBs allow 0 disruptions). That's expected -
  `--ignore-daemonsets` skips them. Drain takes 2-5 min.
- **PDB awareness (DB-backed / stateful pods):** several apps declare
  PodDisruptionBudgets that block a drain until the pod can move safely -
  `vault` (`vault-pdb`), `home/adguard-home-pdb`, `monitoring/{grafana-pdb,prometheus-pdb}`,
  `cloudflare/cloudflared`, all `gitlab-*` PDBs, and the `portfolio-pdb` in each
  portfolio namespace. If drain hangs on `Cannot evict pod ... would violate the
  disruption budget`, the pod's replacement isn't Ready yet on another node - do
  NOT force-delete it; wait, or check why it can't reschedule
  (`kubectl-admin describe pod <pod> -n <ns>`). AdGuard is single-replica with
  `externalTrafficPolicy: Local`, so draining its node moves it - see A.6.

### A.4 Do the work

- OS/reboot only: `ssh wawashi@<node-ip> "sudo reboot"` (or `sudo shutdown -h now`
  for cover-off physical work, then power back on).
- Physical (NVMe reseat, RAM): follow
  [../runbooks/longhorn-hardware.md](../runbooks/longhorn-hardware.md#reseating-an-nvme).
- **After power-on, wait out the 5-7 min M80q POST** before expecting a ping.

### A.5 Verify the node comes back healthy - BEFORE uncordon

```bash
# 1. Node reachable and up.
ping -c2 <node-ip>            # e.g. 10.10.30.13
ssh wawashi@<node-ip> "uptime"

# 2. kubelet actually started. Known trap: protectKernelDefaults=true needs
#    three sysctls; if they revert, kubelet loops and node sits Ready=Unknown.
ssh wawashi@<node-ip> "sudo journalctl -u kubelet -n 30 --no-pager | grep 'invalid kernel flag'"
# Expect NO output. Persistence lives at /etc/sysctl.d/90-kubelet.conf on all
# three nodes. If it fired, apply the fix in
# ../runbooks/00-EMERGENCY.md §7 step 3.

# 3. Node registered Ready again.
kubectl-homelab get nodes

# 4. Cilium agent + control-plane static pods are back on this node.
kubectl-homelab get pods -n kube-system -o wide | grep <node>
#   Look for: cilium-<...> Running, etcd-<node> 1/1, kube-apiserver-<node> 1/1,
#   kube-vip-<node> (static pod). Static pods restart in ~30-45s; etcd may
#   briefly show 0/1 right after kubelet restart (transient).
```

### A.6 WAIT for Longhorn to finish rebuilding, THEN uncordon

The node was down, so any volume with a replica on it dropped to a single copy
and Longhorn will rebuild once the node is schedulable again. Do **not** uncordon
into more work while volumes are still degraded on other nodes.

```bash
# Watch replicas on this node come back to running:
kubectl-admin get replicas.longhorn.io -n longhorn-system \
  --field-selector spec.nodeID=<node> -o wide -w
# All should reach status.currentState=running.

# Confirm no volume is degraded anymore before uncordon:
kubectl-homelab get volumes.longhorn.io -n longhorn-system -o json \
  | jq -r '.items[] | select(.status.robustness != "healthy") | .metadata.name'
# Expect empty.
```

```bash
kubectl-admin uncordon <node>
```

- Rebuild time depends on volume sizes; 5-20 min is typical.
- **AdGuard / other `externalTrafficPolicy: Local` LB services:** if the pod
  migrated to another node during the drain, the Cilium L2 announce lease can pin
  to the wrong node and LAN clients lose DNS even though in-cluster works. After
  uncordon, verify: `kubectl-admin get lease -n kube-system | grep cilium-l2announce-`
  and confirm each `HOLDER` matches the node actually running that service's pod.
  Full fix in [../runbooks/00-EMERGENCY.md §3.2](../runbooks/00-EMERGENCY.md#32-mode-a-l2-lease-mismatch-most-common-lan-only-outage).

### A.7 Post-maintenance checks

```bash
kubectl-homelab get nodes                              # all Ready
kubectl-admin exec -n argocd statefulset/argocd-application-controller -- \
  argocd app list --core | grep -vE 'Synced.*Healthy'  # nothing unexpected drifting
```

Confirm no alerts are still firing in Grafana / Alertmanager for the node.

---

## B. Add a node (replacement hardware or scale-out)

Use this to bring a rebuilt/replacement box back in, or to add a node. All
existing nodes are control-plane; the Ansible automation only knows how to join
**control-plane** nodes.

> **Worker nodes are undocumented territory.** There is no worker inventory group
> in `ansible/inventory/homelab.yml` (only `control_plane`, `control_plane_init`,
> `control_plane_join`) and no worker join playbook. Adding a worker means a
> manual `kubeadm join` (no `--control-plane`) plus new automation - out of scope
> here. The steps below join a **control-plane** node.

### B.0 Prep the host

The new box must have completed the same prerequisites as the others (containerd,
kubeadm/kubelet at the cluster version, multipathd blacklist, kubelet sysctls,
iSCSI for Longhorn). The Ansible playbooks that do this live in
`ansible/playbooks/` (`00-preflight`, `01-prerequisites`, `06-storage-prereqs`).
For a from-scratch build see [../rebuild/](../rebuild/). Confirm the target
version matches:

```bash
kubectl-homelab get nodes    # note the shared VERSION (currently v1.35.0)
```

### B.1 Preferred - let Ansible do the join

Ansible generates fresh credentials, joins one node at a time (`serial: 1`),
copies the kube-vip manifest, reboots cleanly, and waits for Ready. This is the
tested path (`ansible/playbooks/05-join-cluster.yml`).

```bash
# From /home/wsl/personal/homelab/ansible (add the new host to the
# control_plane_join group in inventory/homelab.yml first if it isn't cp2/cp3):
ansible-playbook playbooks/05-join-cluster.yml
```

If Ansible ran, skip to B.4 (verify). Do B.2-B.3 only when joining by hand.

### B.2 Manual join - generate fresh join credentials on cp1

Run these on the first control plane. `kubeadm-certs` and the token are
**short-lived** - do the join immediately after generating them.

```bash
ssh wawashi@10.10.30.11

# Upload a fresh set of control-plane certs; prints a certificate-key.
# WARNING: this cert-key is a control-plane bootstrap credential and EXPIRES IN
# 2 HOURS. Do not paste it into chat/logs; delete any note of it after joining.
sudo kubeadm init phase upload-certs --upload-certs

# Print a ready-to-run join command (embeds a bootstrap token that EXPIRES IN
# 24 HOURS and the CA cert hash).
sudo kubeadm token create --print-join-command
```

### B.3 Manual join - run the join, deploy kube-vip, reboot

On the **new node**, combine the two outputs from B.2:

```bash
ssh wawashi@<new-node-ip>
sudo <printed kubeadm join command> \
  --control-plane --certificate-key <certificate-key-from-upload-certs>
```

- `--control-plane` makes it an etcd + apiserver member (omit it for a worker).
- This adds the node to etcd, so quorum requirements change afterwards
  (3 -> 4 members needs 3 alive for quorum; 5 members needs 3). Keep the member
  count odd where you can.

Then replicate what Ansible does - copy the kube-vip static manifest and reboot
(joining a control plane can leave Cilium/kube-vip in a backoff loop; a clean
reboot clears it):

```bash
# On cp1, read /etc/kubernetes/manifests/kube-vip.yaml; recreate it byte-for-byte
# on the new node at the same path (there are no SSH keys between nodes - copy the
# contents via your workstation). Then:
ssh wawashi@<new-node-ip> "sudo reboot"
# Wait 5-7 min (M80q POST).
```

### B.4 Verify the node joined cleanly

```bash
# Node Ready:
kubectl-homelab get nodes -o wide

# Cilium agent came up on the new node:
kubectl-homelab get pods -n kube-system -l k8s-app=cilium -o wide | grep <new-node>
# (Ready). If HTTPRoutes/gateway act up after a join:
#   kubectl-admin rollout restart deployment/cilium-operator -n kube-system

# kube-vip + control-plane static pods present on the new node:
kubectl-homelab get pods -n kube-system -o wide | grep <new-node>
#   expect etcd-<node>, kube-apiserver-<node>, kube-controller-manager-<node>,
#   kube-scheduler-<node>, and kube-vip-<node>.

# etcd membership now includes the new node (exec needs kubectl-admin; run from a
# SURVIVING node's etcd pod - pick one that is Running):
kubectl-admin -n kube-system exec etcd-k8s-cp1 -- \
  etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  member list -w table
```

### B.5 Register the node's disk in Longhorn

Longhorn auto-discovers a new node and creates a `default-disk-*` for it. Confirm
it's picked up and schedulable:

```bash
kubectl-homelab get nodes.longhorn.io -n longhorn-system -o wide
#   New node should show READY=True, ALLOWSCHEDULING=true, SCHEDULABLE=True.
```

In the Longhorn UI (`https://longhorn.k8s.rommelporras.com` -> Node): verify the
disk is present, `Schedulable`, and has capacity. **Disk tagging is optional and
this cluster currently uses NO tags** (all three nodes and disks are untagged) -
do not add a tag unless you are deliberately steering specific volumes to specific
nodes. Once the disk is schedulable, Longhorn will start placing/rebuilding
replicas onto it automatically. See [../context/Storage.md](../context/Storage.md).

### B.6 Post-join checks

```bash
kubectl-homelab get nodes                              # all Ready, same VERSION
kubectl-admin exec -n argocd statefulset/argocd-application-controller -- \
  argocd app list --core | grep -vE 'Synced.*Healthy'  # cluster still converged
```

---

## C. Decommission a dead node (permanent removal)

Use this only when a node is being **permanently retired** (dead mainboard,
replaced hardware getting a fresh identity). This removes it from etcd, Kubernetes,
Longhorn, and kube-vip. Going from 3 -> 2 nodes means **the remaining 2 are your
entire quorum - a single further failure loses the cluster.** Prefer replacing the
box (procedure B) over running long-term on 2 nodes.

> **This procedure has several destructive, irreversible steps.** Read the whole
> section first. Do NOT run it against a node you intend to bring back.
>
> If you have ALREADY lost quorum (two control planes down at once), this is the
> wrong doc - a decommission cannot restore a cluster that has no quorum. Get a
> node back first; if etcd itself is corrupted, see
> [../runbooks/etcd-recovery.md](../runbooks/etcd-recovery.md).

### C.1 Move Longhorn data off the dead node FIRST (data safety)

Before removing anything, make sure no volume depends on a replica that only
lives on the dead node.

```bash
# 1. What replicas live on the dead node, and are any volumes degraded because
#    of it?
kubectl-admin get replicas.longhorn.io -n longhorn-system \
  --field-selector spec.nodeID=<dead-node> -o wide

kubectl-homelab get volumes.longhorn.io -n longhorn-system -o json \
  | jq -r '.items[] | select(.status.robustness != "healthy") | "\(.metadata.name)\t\(.status.robustness)"'
```

- With 2x replication and one node dead, affected volumes are **degraded (1
  healthy replica remaining on a live node)**. That surviving replica is your
  only copy - protect it.
- **Rebuild the redundancy onto a live node BEFORE removing the dead node.** In
  the Longhorn UI: disable scheduling on the dead node (Node -> Edit ->
  `Scheduling: Disable`) or, if it's already gone, request a replica rebuild by
  ensuring the volume's `numberOfReplicas` can be satisfied by the remaining
  live nodes. Wait until every previously-degraded volume returns to `healthy`.
- **WARNING:** do not proceed to C.4 (node delete) while any volume is still
  degraded with its only replica implicated on the dead node - deleting the
  Longhorn node evicts/detaches its replicas and you can lose the last copy.
  If the volume has a backup (C.1 check + [../context/Backups.md](../context/Backups.md)),
  that is your fallback; if it does not, do NOT delete until rebuilt.

### C.2 kubeadm reset on the node - only if it is reachable

Skip this entirely if the box is truly dead/unreachable; go to C.3.

```bash
# WARNING: DESTRUCTIVE on the target node. Wipes its cluster membership,
# kubelet config, static-pod manifests, and etcd data dir. Only run ON the node
# being retired - never on a node you're keeping.
ssh wawashi@<dead-node-ip>
sudo kubeadm reset -f
sudo rm -rf /etc/cni/net.d ~/.kube
# (kubeadm reset attempts to remove this etcd member automatically only if the
#  local etcd is healthy; verify with C.3 regardless.)
```

### C.3 Remove the dead node's etcd member

The dead node is still an etcd member; leaving it in degrades quorum math. Remove
it from a **surviving** node's etcd pod. (`exec` requires `kubectl-admin`.)

```bash
# STEP 1 - list members and identify the dead node's member ID.
# Run against a LIVE etcd pod (etcd-k8s-cp1 or -cp2, whichever is up):
kubectl-admin -n kube-system exec etcd-k8s-cp1 -- \
  etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  member list -w table
# Output columns: ID | STATUS | NAME | PEER ADDRS | CLIENT ADDRS | IS LEARNER
# Match NAME (e.g. k8s-cp3) / PEER ADDRS (its 10.10.30.x:2380) to the dead node
# and copy its hex ID from the first column.
```

```bash
# STEP 2 - remove it. WARNING: IRREVERSIBLE. Double-check you copied the DEAD
# node's ID, not a live one. Removing a live member drops you toward losing
# quorum. Replace <MEMBER_ID_HEX> with the exact ID from STEP 1.
kubectl-admin -n kube-system exec etcd-k8s-cp1 -- \
  etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  member remove <MEMBER_ID_HEX>

# Re-run `member list` to confirm only the surviving members remain.
```

### C.4 Delete the node object from Kubernetes

```bash
# WARNING: DESTRUCTIVE. Removes the node and forces reschedule of anything still
# assigned to it. Confirm the node is truly gone and etcd member removed (C.3)
# before running.
kubectl-admin delete node <dead-node>
```

Longhorn will also drop the node object once it's gone from Kubernetes; verify:

```bash
kubectl-homelab get nodes                                # dead node absent
kubectl-homelab get nodes.longhorn.io -n longhorn-system # dead node absent
```

If the Longhorn node lingers, remove it from the Longhorn UI (Node -> the dead
entry -> delete) - only after C.1 confirmed no data depended on it.

### C.5 Clean up kube-vip and Cilium L2 leases

If the dead node held the API VIP lease or any Cilium L2 announce lease, external
traffic for those VIPs may be stuck pointing at a MAC that no longer answers.

```bash
# API VIP lease holder:
kubectl-homelab get lease plndr-cp-lock -n kube-system -o yaml | grep -i holder
# If the holder is the dead node, delete the lease to force re-election:
kubectl-admin delete lease plndr-cp-lock -n kube-system

# Cilium L2 announce leases (Gateway VIP 10.10.30.20, AdGuard DNS, GitLab shell,
# otel-collector). Check each HOLDER against the surviving nodes:
kubectl-admin get lease -n kube-system | grep cilium-l2announce-
# If any HOLDER is the dead node, release it by deleting the cilium-agent pod on a
# LIVE node so Cilium re-elects (1.19+ prefers a node with a ready backend). Same
# fix as the L2 mismatch runbook:
#   ../runbooks/00-EMERGENCY.md §3.2
```

### C.6 Clean up stale alerts and finish

- Silence/expire any node-down, `KubeNodeNotReady`, or exporter-down alerts for
  the removed node in Alertmanager (`https://alertmanager.k8s.rommelporras.com`)
  so they don't fire forever against a node that no longer exists.
- Check for anything pinned to the dead node by `nodeAffinity`/`nodeSelector`
  (e.g. `nut-exporter` is pinned OFF cp1 with a `NotIn [k8s-cp1]` affinity because
  the UPS is USB-attached to cp1 - see [../context/UPS.md](../context/UPS.md)). If
  the dead node hosted such a workload, its manifest needs updating in Git
  (ArgoCD-managed - change it in the repo, don't `kubectl edit`).
- Record the decommission in [../reference/CHANGELOG.md](../reference/CHANGELOG.md)
  and update [../context/Cluster.md](../context/Cluster.md) node table if the
  cluster is now smaller or the node was replaced with new hardware (new MAC/IP).

### C.7 Post-decommission checks

```bash
kubectl-homelab get nodes                              # only surviving nodes
kubectl-admin -n kube-system exec etcd-k8s-cp1 -- \
  etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint health --cluster           # all remaining endpoints healthy
kubectl-homelab get volumes.longhorn.io -n longhorn-system -o json \
  | jq -r '.items[] | select(.status.robustness != "healthy") | .metadata.name'
# Expect empty - no volume left degraded by the removal.
```

If you're now on 2 nodes, treat it as a temporary state: bring a replacement in
via procedure B as soon as hardware allows. Two-of-two is not fault tolerant.

