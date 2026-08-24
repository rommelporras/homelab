# 00 - EMERGENCY TROUBLESHOOTING GUIDE

> **Read this first when something is broken and no AI assistant is available.**
>
> This is a **symptom-first** guide: you find your problem by what you *see*
> ("the internet is down", "a website won't load"), not by the Prometheus alert
> name. The 16 other runbooks in this folder are alert-name indexed and assume
> Grafana is up - use them once you know the alert. This guide assumes nothing.
>
> Everything here is **copy-paste ready**. Commands that only *read* use
> `kubectl-homelab` (safe, read-only). Commands that *change* things use
> `kubectl-admin` (full cluster-admin) - those are the ones that fix the problem.
>
> Most facts here were checked against the live cluster on 2026-07-08, but treat
> this as a guide, not a guarantee - the cluster drifts. Before betting an outage
> on a specific command, sanity-check the live state (the commands to do so are
> inline). If a step looks wrong, trust the cluster over the doc.

---

## 0. Before you touch anything - read this

### Can you even read this right now?

This guide lives in Git (GitHub, external) and on your workstation at
`~/personal/homelab/docs/runbooks/`. If the *cluster* is down GitHub still works,
but if your *home internet* is down (the DNS case below), you may not reach
GitHub. **Keep an offline copy**: this repo is already cloned locally, so open the
file directly from disk. Consider printing §1-§3 or saving a PDF to your phone -
those are the sections you need exactly when nothing else works.

### Can you talk to the cluster?

Everything in this guide needs either `kubectl` or SSH. Verify access first:

```bash
kubectl-homelab get nodes        # if this works, you're good - go to §2
ssh wawashi@10.10.30.11 uptime   # if kubectl is dead but SSH works, see §7
```

**If `kubectl-homelab` isn't found or the kubeconfig is missing/broken:**

- The kubeconfigs live at `~/.kube/homelab.yaml` (admin) and
  `~/.kube/homelab-claude.yaml` (restricted). The wrappers are shell aliases/
  functions - if they're gone, use `kubectl --kubeconfig ~/.kube/homelab.yaml`
  directly (this is the admin config; full access).
- If both kubeconfigs are lost, regenerate the admin one from any control-plane
  node: `ssh wawashi@10.10.30.11 'sudo cat /etc/kubernetes/admin.conf'` and save
  it to `~/.kube/homelab.yaml`. **Its `server:` is `https://api.k8s.rommelporras.com:6443`
  (a hostname), which only resolves via AdGuard DNS.** If DNS/AdGuard is down (the
  §3 scenario), kubectl using this config can't resolve the hostname - fix it one
  of two ways: add `10.10.30.10 api.k8s.rommelporras.com` to `/etc/hosts`, or edit
  the kubeconfig's `server:` line to `https://10.10.30.10:6443` (the API cert
  includes the VIP as a SAN, so this works).

### Golden rules when you are on your own

1. **Do not delete a PVC to fix a mount error.** Ever. It destroys the Longhorn
   volume and every replica permanently. Mount failures are almost always
   node-level, not volume-level. See [storage.md](storage.md).
2. **Do not `helm uninstall` anything.** It deletes live resources and causes
   outages. The only Helm-managed release is `cilium`.
3. **Do not read secret values** (`kubectl get secret -o yaml`, `describe secret`).
   Not a safety issue for you personally, but it is repo policy.
4. **Prefer the smallest change that could fix it.** Delete a pod before deleting a
   lease. Delete a lease before restarting a DaemonSet. Restart before rebooting.
5. **Change one thing, then re-check.** Do not stack three fixes at once - you will
   not know which one worked, or which one broke something new.
6. **Write down what you did.** When you get the AI back, tell it exactly what you
   changed so it can verify and clean up.

---

## 1. Quick reference card

### Nodes (all 3 are control-plane; etcd needs 2 of 3 alive for quorum)

| Node | IP | MAC | SSH |
|------|-----|-----|-----|
| k8s-cp1 | 10.10.30.11 | 88:a4:c2:9d:87:d6 | `ssh wawashi@10.10.30.11` |
| k8s-cp2 | 10.10.30.12 | 88:a4:c2:6b:1c:44 | `ssh wawashi@10.10.30.12` |
| k8s-cp3 | 10.10.30.13 | 88:a4:c2:64:2d:81 | `ssh wawashi@10.10.30.13` |

SSH user is **`wawashi`** (sudo works). You can SSH to nodes directly from WSL.
You **cannot** SSH from WSL straight to the NAS - hop through a node first.

### Virtual IPs (VIPs)

| What | IP | How it's announced |
|------|-----|--------------------|
| Kubernetes API | 10.10.30.10 | kube-vip (ARP), lease `plndr-cp-lock` |
| Cilium Gateway (all `*.k8s` web apps) | 10.10.30.20 | Cilium L2 |
| GitLab SSH | 10.10.30.21 | Cilium L2 |
| OTel Collector | 10.10.30.22 | Cilium L2 |
| **AdGuard DNS (LAN primary DNS)** | **10.10.30.53** | Cilium L2, `externalTrafficPolicy: Local` |
| NAS (OMV) | 10.10.30.4 | static |
| LAN gateway (OPNsense) | 10.10.30.1 | - |

### The two kubectl wrappers (this matters)

```bash
kubectl-homelab   # READ-ONLY. No secret get, no pod logs. Use for looking.
kubectl-admin     # FULL cluster-admin. Use for delete/patch/scale/logs.
```

- If a `kubectl-homelab` command returns `Forbidden`, that is expected for
  `logs`, `secrets`, and any write. Re-run it with `kubectl-admin`.
- `helm-homelab` uses the admin kubeconfig (Helm needs write access).

### First-30-seconds health sweep (safe, read-only)

```bash
kubectl-homelab get nodes -o wide                          # all 3 Ready?
kubectl-homelab get pods -A | grep -vE 'Running|Completed'  # what's broken?
kubectl-homelab get pods -A -o wide | grep -iE 'adguard|cilium|coredns'
kubectl-homelab get leases -n kube-system | grep -E 'l2announce|plndr-cp-lock'
```

---

## 2. First-response triage - "where do I even start?"

Match the biggest symptom you see, then jump to the section:

| What you observe | Go to |
|------------------|-------|
| **No internet / websites won't resolve anywhere in the house** | [§3 DNS and AdGuard](#3-dns-and-adguard-outages-most-common) |
| One `*.k8s.rommelporras.com` web app is down, DNS works | [§4 A single web app is down](#4-a-single-web-app-is-down) |
| Browser shows a **TLS/certificate error** on every web app | [§4.1 TLS certificate problems](#41-tls-certificate-problems) |
| A pod is stuck (`Pending`, `CrashLoopBackOff`, `Init`, `ContainerCreating`) | [§5 A pod won't start](#5-a-pod-wont-start) |
| A pod is stuck `ContainerCreating` with a **volume/mount** error | [§6 Storage / volume stuck](#6-storage--volume-stuck) |
| `kubectl` itself times out / API unreachable | [§7 The Kubernetes API is unreachable](#7-the-kubernetes-api-is-unreachable) |
| A whole node is `NotReady` or won't come back after reboot | [§8 A node is down or NotReady](#8-a-node-is-down-or-notready) |
| ArgoCD shows red / OutOfSync / an app won't sync | [§9 ArgoCD / GitOps stuck](#9-argocd--gitops-stuck) |
| Secrets missing / app says "unauthenticated" / ESO errors | [§10 Vault sealed / secrets missing](#10-vault-sealed--secrets-missing) |
| Everything looks broken at once (alert storm) | [§11 Everything is broken (alert storm)](#11-everything-is-broken-alert-storm) |

---

## 3. DNS and AdGuard outages (most common)

**This is the failure you have hit most.** AdGuard at `10.10.30.53` is the LAN's
primary DNS resolver **and** the cluster's external DNS upstream. It runs as a
**single replica** with `externalTrafficPolicy: Local`. When it breaks, the whole
house loses name resolution and it *feels* like the internet is down.

### 3.0 IMMEDIATE escape hatch - get internet back NOW, fix AdGuard later

If people need internet immediately and you cannot fix the root cause fast,
**bypass AdGuard** by pointing at a public resolver. This buys you time.

- **On one device (fastest):** set its DNS manually to `1.1.1.1` and `8.8.8.8`.
  It will resolve again immediately (you lose ad-blocking until AdGuard is back).
- **For the whole LAN:** in **OPNsense** (`https://10.10.30.1`), change the DHCP
  DNS server handed to clients from `10.10.30.53` to `1.1.1.1`, then have devices
  renew their lease (or reboot). Change it **back to `10.10.30.53`** once AdGuard
  is healthy, so ad-blocking and local records return.

> Note: the old secondary `10.10.30.54` (fw-agh LXC) is documented but was
> declared dead in commit `ed5211c` - **do not rely on it as a failover.**
> Treat `10.10.30.53` as a true single point of failure.

Now diagnose which of the four AdGuard failure modes you have.

### 3.1 Decide which failure mode this is

Run these first:

```bash
# Where is the pod, and is it Running?
kubectl-homelab get pods -n home -l app=adguard-home -o wide

# Who holds the L2 lease?
kubectl-homelab get lease -n kube-system cilium-l2announce-home-adguard-dns \
  -o jsonpath='{.spec.holderIdentity}{"\n"}'

# Does DNS resolve IN-CLUSTER vs from a LAN/external client? Run BOTH:
ssh wawashi@10.10.30.11 dig @10.10.30.53 google.com +short   # in-cluster path (a node)
dig @10.10.30.53 google.com +short                           # external client (WSL/phone)
```

> **Important:** WSL is a *cross-VLAN external client*, NOT in-cluster. In Mode A
> (L2 lease mismatch) the in-cluster test (from a node) SUCCEEDS while the external
> test (WSL/phone) TIMES OUT - that split is the whole diagnostic tell. A WSL
> timeout alone does not tell them apart; always compare against the node test.

Use this decision table:

| Symptom | Most likely mode | Section |
|---------|------------------|---------|
| Pod `Running`, **lease holder node ≠ pod node**, in-cluster `dig` works but LAN clients time out | **L2 lease mismatch** | [§3.2](#32-mode-a-l2-lease-mismatch-most-common-lan-only-outage) |
| Pod `Running` and healthy, but *in-cluster* pods (CoreDNS/firefox) can't resolve, cluster-wide DNS alert storm | **NetworkPolicy DNS SPOF** | [§3.3](#33-mode-b-networkpolicy-dns-spof-in-cluster-resolution-broken) |
| Intermittent "DNS down" blips (Uptime-Kuma pings you), AdGuard UI slow/dead, PVC nearly full | **PTR flood + PVC fill** | [§3.4](#34-mode-c-ptr-flood--pvc-full-intermittent-blips--dead-ui) |
| Pod restarting, `OOMKilled`, `CrashLoopBackOff` | **Out of memory** | [§3.5](#35-mode-d-oomkilled) |

### 3.2 Mode A: L2 lease mismatch (most common LAN-only outage)

**What's happening:** Cilium announces the `10.10.30.53` VIP over ARP from exactly
one node - whichever node holds the lease. Because the service is
`externalTrafficPolicy: Local`, only the node **running the AdGuard pod** can
actually serve traffic. The lease **only re-elects when the holding cilium-agent
restarts or the network partitions** - it does NOT follow the pod. So when the
AdGuard pod migrates to a different node (eviction, drain, a memory-limit bump, a
Helm upgrade), the lease can stay behind. ARP resolves the VIP to a node with no
local backend, and Cilium silently drops the packets.

**The tell:** in-cluster `dig @10.10.30.53` **works** (Cilium's overlay forwards
in-cluster traffic across nodes regardless of the Local policy), but real LAN
clients (phones, laptops via OPNsense) **time out**. Health probes and smoke
tests all pass - only real cross-VLAN client traffic notices. This exact bug hid
undetected for ~6 weeks in Phase 5.3.

**Diagnose:**

```bash
# 1. Pod's node:
kubectl-homelab get pods -n home -l app=adguard-home -o wide
# 2. Lease holder:
kubectl-homelab get lease -n kube-system cilium-l2announce-home-adguard-dns \
  -o jsonpath='{.spec.holderIdentity}{"\n"}'
# If (1) and (2) name DIFFERENT nodes -> this is Mode A.
```

Optional hard confirmation - ARP the VIP from any node and compare the MAC to the
node table in §1:

```bash
ssh wawashi@10.10.30.11 'sudo ip neigh del 10.10.30.53 dev eno1; ping -c1 10.10.30.53; ip neigh show 10.10.30.53'
```
> `eno1` is the primary NIC on these M80q nodes. If `ip neigh del` says the device
> is unknown, find the real one: `ip -o -4 addr show | grep 10.10.30.11`.

**Fix (least disruptive first):**

# This is the PROVEN fix from the actual Phase 5.3 incident (see
# docs/todo/adguard-l2-resilience.md): delete the **cilium-agent pod on the wrong
# lease-holder node**. That releases every lease that node held; with Cilium 1.19+
# local-backend preference, re-election lands on a node that has a ready endpoint
# (the pod's node). NOTE: the lease only re-elects on cilium-agent restart or
# network partition - so deleting the *lease object* alone is NOT the reliable
# lever; restart the agent.

```bash
# 1. Find the cilium-agent pod on the CURRENT (wrong) lease-holder node, e.g. k8s-cp3:
kubectl-homelab get pods -n kube-system -o wide | grep cilium | grep <lease-holder-node>
# 2. Delete it (expect a ~15-30s ARP gap on that node's VIPs, no data loss):
kubectl-admin delete pod -n kube-system <cilium-agent-pod-name>

# 3. Wait ~15-30s, then re-check that holder == pod node:
kubectl-homelab get lease -n kube-system cilium-l2announce-home-adguard-dns \
  -o jsonpath='{.spec.holderIdentity}{"\n"}'
kubectl-homelab get pods -n home -l app=adguard-home -o wide
```

In the real incident, `kubectl-admin delete pod -n kube-system cilium-<id>` (the
agent on the wrong holder cp3) forced re-election and cp2 (where the pod lived)
acquired the lease.

**Verify fixed:** from an actual LAN client (or by re-running the ARP test above),
confirm resolution works and the MAC now matches the pod's node.

```bash
dig @10.10.30.53 google.com +short
```

> **Root-cause note for later:** the permanent fix (tracked in
> `docs/todo/adguard-l2-resilience.md`) is a lease-vs-pod mismatch Prometheus
> alert (Task A) and splitting the catch-all `CiliumL2AnnouncementPolicy`
> (`manifests/cilium/l2-announcement.yaml`) into per-service policies so
> re-election only affects the one service (Task D). Neither is deployed yet.

### 3.3 Mode B: NetworkPolicy DNS SPOF (in-cluster resolution broken)

**What's happening:** AdGuard is the upstream that CoreDNS forwards the cluster's
external queries to, and the `firefox` browser pod uses it directly. When
in-cluster pods dial the `10.10.30.53` VIP, Cilium's kube-proxy-replacement DNATs
it to the backend pod, so the traffic arrives with the **source pod identity** -
not `host`/`remote-node`/`world`. If the AdGuard ingress NetworkPolicy doesn't
explicitly allow those pod identities, they get dropped and the whole cluster
loses external DNS. This caused a cluster-wide alert storm.

This is **structurally fixed** in `manifests/home/networkpolicy.yaml` (commit
`8f8f680`): a `fromEndpoints` rule allows `kube-system/kube-dns` and
`browser/firefox` on port 53. You only hit this again if that policy gets reverted
or a **new** in-cluster DNS consumer is added without an allow rule.

**Diagnose:**

```bash
# Do in-cluster pods fail to resolve while the pod is healthy?
kubectl-admin -n kube-system logs -l k8s-app=kube-dns --tail=50 | grep -i 'timeout\|SERVFAIL\|no route'
# Confirm the allow rule still exists:
kubectl-homelab get cnp -n home
grep -n 'kube-dns\|firefox\|fromEndpoints' manifests/home/networkpolicy.yaml
```

**Fix:** ensure the `fromEndpoints` rule for `kube-dns` + `firefox` on port 53 is
present in `manifests/home/networkpolicy.yaml` and synced by ArgoCD. If it was
reverted, restore it and let ArgoCD sync (see [§9](#9-argocd--gitops-stuck)).
Any **new** in-cluster service that resolves via AdGuard needs its own
`fromEndpoints` entry here.

### 3.4 Mode C: PTR flood / PVC full (intermittent blips + dead UI)

**What's happening:** two things that showed up together on 2026-06-10:

1. **PVC filling:** `querylog.json` grew to fill the 5Gi `adguard-data` volume
   because query-log retention was 90 days. When the disk is full, the AdGuard
   **UI itself dies** (it writes config to the PVC).
2. **PTR flood:** `use_private_ptr_resolvers: true` with an empty
   `local_ptr_upstreams` made AdGuard send every private reverse-DNS lookup to
   kube-dns (`10.96.0.10`), which has no RFC1918 reverse zone -> mass `i/o
   timeout` -> DNS latency blips. These blips were all <2 min so the Prometheus
   `AdGuardDNSDown` alert (`for: 2m`) never fired - you found out via Uptime-Kuma.

**Diagnose:**

```bash
# Is the PVC full?  (exec needs kubectl-admin - the read-only kubeconfig can't exec)
kubectl-admin exec -n home deploy/adguard-home -- df -h /opt/adguardhome/work
# Is the log flooded with PTR timeouts?
kubectl-admin -n home logs deploy/adguard-home --tail=50 | grep -i 'i/o timeout\|10.96.0.10'
```

**Fix - reclaim space immediately (UI is dead when disk is full, so do it via exec):**

```bash
# 1. Truncate the query log(s) to free space NOW. Lowering retention alone does
#    NOT shrink the existing file - AdGuard trims lazily. You must truncate.
#    Note the rotated file (querylog.json.1) is often the bigger space hog, so
#    truncate the whole querylog.json* set:
kubectl-admin exec -n home deploy/adguard-home -- \
  sh -c 'for f in /opt/adguardhome/work/data/querylog.json*; do truncate -s 0 "$f"; done; \
         df -h /opt/adguardhome/work'
```

**Fix - stop the PTR flood (runtime config lives on the PVC, NOT the ConfigMap):**

> The `init-config` initContainer only copies the ConfigMap on **first boot**.
> The live config is at `/opt/adguardhome/conf/AdGuardHome.yaml` on the PVC.
> Editing the ConfigMap does NOT change a running pod. The AdGuard image is
> Alpine-based, so its `sed` is busybox `sed` - **the GNU `0,/re/` range form is
> silently ignored; use `awk`** for "change first match only".

```bash
# Set use_private_ptr_resolvers to false in the live PVC config, then reload:
kubectl-admin exec -n home deploy/adguard-home -- sh -c \
  "awk '/use_private_ptr_resolvers/ && !done {sub(/true/,\"false\"); done=1} 1' \
   /opt/adguardhome/conf/AdGuardHome.yaml > /tmp/agh.yaml && \
   cp /tmp/agh.yaml /opt/adguardhome/conf/AdGuardHome.yaml"

# Reload by restarting the pod (single replica -> expect a ~30-60s LAN DNS blip;
# your own WSL kubectl may briefly lose DNS during it):
kubectl-admin rollout restart deploy/adguard-home -n home
```

**After restart:** re-verify the pod and the lease are on the **same node**
(the restart may have moved the pod - see [§3.2](#32-mode-a-l2-lease-mismatch-most-common-lan-only-outage)).
Also update the source of truth: retention and `use_private_ptr_resolvers: false`
belong in `manifests/home/adguard/configmap.yaml` so a first-boot rebuild is
correct.

### 3.5 Mode D: OOMKilled

AdGuard's memory limit is currently **1Gi** (bumped from 512Mi in `15b24a3` to
stop an OOM loop). If it's crash-looping with `OOMKilled`:

```bash
kubectl-homelab get pods -n home -l app=adguard-home
kubectl-admin get pod -n home <pod> -o json | \
  jq '.status.containerStatuses[].lastState.terminated'   # look for reason OOMKilled, exit 137
```

Short term, delete the pod to get a clean restart; if it recurs, bump
`resources.limits.memory` in `manifests/home/adguard/deployment.yaml`. See
[oomkilled.md](oomkilled.md) for the general OOM playbook.

---

## 4. A single web app is down

DNS works, but one `https://<app>.k8s.rommelporras.com` returns an error or won't
load. All web apps route through the Cilium Gateway at `10.10.30.20`.

```bash
# 1. Is the app's pod healthy?
kubectl-homelab get pods -n <namespace> -o wide

# 2. Is the HTTPRoute Accepted? (stale parents break ArgoCD health, see below)
kubectl-homelab get httproute -A
kubectl-homelab get httproute <name> -n <ns> -o jsonpath='{.status.parents}' | jq

# 3. Is the Gateway itself up?
kubectl-homelab get gateway -n default
kubectl-homelab get pods -n kube-system -l k8s-app=cilium
```

**Common causes & fixes:**

- **HTTPRoute shows `<none>` status:** restart the Cilium operator.
  `kubectl-admin rollout restart deployment/cilium-operator -n kube-system`
- **HTTPRoute has stale `status.parents`** (an old entry stuck `Accepted=False`,
  cascading to ArgoCD Degraded): the gateway-controller does NOT clean these up.
  Surgically remove the stale index:
  ```bash
  kubectl-admin patch httproute <name> -n <ns> --subresource=status --type=json \
    -p='[{"op":"remove","path":"/status/parents/<index>"}]'
  ```
- **Pod is `Running` but browser gets `upstream connect error ... connection
  timeout`:** the app's ingress CiliumNetworkPolicy is using the wrong entity.
  HTTPRoute-exposed backends take ingress from the Cilium envoy proxy with
  identity `reserved:ingress` - the CNP must use `fromEntities: [ingress]`, not
  `[host, remote-node, world]`.
- **App-specific playbooks:** see [apps.md](apps.md) (Ghost, Invoicetron,
  Portfolio, Karakeep, Ollama, Atuin, Uptime-Kuma, Homepage, MySpeed, GitLab).

**GitLab special case:** `gitlab` and `cilium` are the two ArgoCD apps with **no
`automated:` block at all** (fully manual-sync); `cilium` is manual because it IS
the CNI. `gitlab` is the one you'll actually resync by hand routinely - after any
change to `helm/gitlab/values.yaml` or its Application, sync it manually:
```bash
kubectl-admin exec -n argocd statefulset/argocd-application-controller -- \
  argocd app sync gitlab --core
```

### 4.1 TLS certificate problems

Every `*.k8s.rommelporras.com` site is served with a wildcard cert from Let's
Encrypt, issued by cert-manager via a **DNS-01 challenge through Cloudflare**. If
*every* web app suddenly shows a certificate warning (expired / not valid), the
cert failed to renew - usually because the Cloudflare API token expired or
cert-manager can't reach Cloudflare.

> **Note:** cert-manager resources are RBAC-blocked on `kubectl-homelab` - use
> `kubectl-admin` for all of these reads. The three wildcard certs
> (`wildcard-k8s-tls`, `wildcard-dev-k8s-tls`, `wildcard-stg-k8s-tls`) all live in
> the **`default`** namespace (created by the Gateway), not per-app namespaces.

```bash
# Are the wildcard certs valid / not expiring?
kubectl-admin get certificate -A
kubectl-admin get certificate wildcard-k8s-tls -n default -o wide   # READY should be True
# Recent cert-manager activity / errors:
kubectl-admin -n cert-manager logs -l app.kubernetes.io/name=cert-manager --tail=50
# Pending challenges stuck?
kubectl-admin get challenges,orders -A
```

- **`READY=False` / renewal failing:** check the cert-manager logs for a
  Cloudflare auth error. The token is in Vault (`cert-manager/cloudflare-api-token`)
  and 1Password ("Cloudflare DNS API Token"). If it expired, rotate it (see the
  secrets guide) - cert-manager retries automatically once the token is valid.
- **Force a reissue** after fixing the cause: delete the cert's backing Secret and
  cert-manager recreates it automatically -
  `kubectl-admin delete secret wildcard-k8s-tls -n default` (this is the reliable,
  no-extra-tooling path; the `cmctl`/`kubectl cert-manager` plugin is NOT installed
  on the workstation, so `cert-manager renew` would fail). See
  [certificates.md](certificates.md).
- **It's not actually expired:** if only *one* device complains, it's that
  device's clock or trust store, not the cluster.

More: [certificates.md](certificates.md).

---

## 5. A pod won't start

```bash
kubectl-homelab get pods -A -o wide | grep -vE 'Running|Completed'
kubectl-homelab describe pod <pod> -n <ns> | tail -30   # look at Events
kubectl-admin logs <pod> -n <ns> --tail=50              # admin: homelab can't read logs
kubectl-admin logs <pod> -n <ns> --previous --tail=50   # if it already crashed
```

| Pod state | Likely cause | First move |
|-----------|--------------|-----------|
| `Pending` | No schedulable node (resources, taints, affinity) | `kubectl-homelab describe` -> read the FailedScheduling event |
| `ContainerCreating` (with mount error) | Volume/CSI - go to [§6](#6-storage--volume-stuck) | do NOT delete the PVC |
| `Init:*` | initContainer blocked (waiting on a dep, config, or secret) | check initContainer logs |
| `CrashLoopBackOff` | App crashes on boot | read `logs --previous` for the real error |
| `ImagePullBackOff` | Bad tag or Docker Hub rate limit | verify the tag exists in the registry |
| `Running` but `0/1 READY` | Readiness probe failing, or OOM-in-place (see below) | check probe + `lastState.terminated` |

**Docker Hub rate limit during pulls:** unauthenticated limit is 100 pulls / 6h,
and all 3 nodes share one public IP. Workaround - re-tag a cached image on the node:
```bash
ssh wawashi@<node> 'sudo ctr -n k8s.io images tag <cached-tag> <new-tag>'
```

**OOM-in-place mount deadlock (Longhorn RWO):** a container OOMKilled *inside* a
still-`Running` pod can wedge - kubelet restarts it in place, but Longhorn rejects
the re-stage ("no Pending workload pods ... map[Running:...]"). Pod shows
`Running`, container exit 137, `FailedMount` events every few minutes, Deployment
stuck `0/1`. **Fix:** delete the pod so a fresh one is created; do NOT delete the
PVC. Then fix the underlying OOM.
```bash
kubectl-admin delete pod <stuck-pod> -n <ns>
```

More detail: [cluster.md](cluster.md), [oomkilled.md](oomkilled.md).

---

## 6. Storage / volume stuck

**FIRST, THE RULE AGAIN: never delete a PVC to fix a mount error.** It permanently
destroys the Longhorn volume and all replicas.

**Mount-failure triage order** (from CLAUDE.md, do them in order):

1. Longhorn node conditions - is `multipathd` and the node `Ready`?
2. CSI plugin pods on the affected node.
3. `dmesg` on the node for filesystem/device errors.
4. Try force-detach via the Longhorn UI.
5. Only after all of the above fail, escalate.

```bash
kubectl-homelab get pods -n longhorn-system -o wide | grep -iE 'csi|instance-manager'
kubectl-homelab get volumes.longhorn.io -n longhorn-system     # state / robustness
ssh wawashi@<node> 'dmesg | tail -40'
```

**Two specific deadlocks you have hit before:**

- **`mke2fs "apparently in use by the system"` on new mounts** = multipathd
  blacklist config was lost (e.g. after an OS upgrade). Re-add the blacklist to
  `/etc/multipath.conf` on the node and `sudo systemctl restart multipathd`. All
  3 nodes should have `blacklist { devnode "^sd[a-z0-9]+" }`.

- **Stale iSCSI session after a Longhorn instance-manager IP rotation** - engine
  stuck in a `iscsiadm ... error 32 - target likely not connected` restart loop,
  volume stuck `attaching`, pod stuck `ContainerCreating`. The kernel session
  can't be cleaned from userspace. **Fix without rebooting:** cordon the node,
  delete the pod so it reschedules elsewhere, uncordon. Full command sequence:
  [storage.md#staleiscsisession](storage.md#staleiscsisession).

More: [storage.md](storage.md), [longhorn-hardware.md](longhorn-hardware.md).

---

## 7. The Kubernetes API is unreachable

`kubectl` times out or says connection refused. The API is behind the kube-vip
VIP `10.10.30.10` (`api.k8s.rommelporras.com`).

```bash
# Which node holds the API VIP lease?
kubectl-homelab get lease plndr-cp-lock -n kube-system -o yaml 2>/dev/null | grep -i holder
# If kubectl is dead entirely, go straight to the nodes:
ssh wawashi@10.10.30.11 'sudo crictl ps | grep -E "kube-apiserver|etcd"'
ping -c2 10.10.30.10
```

**Checks:**

1. **Is the VIP answering?** `ping 10.10.30.10`. If not, the kube-vip lease may be
   stuck. Check `plndr-cp-lock`; if the holder is a dead node, delete the lease to
   force re-election: `kubectl-admin delete lease plndr-cp-lock -n kube-system`.
   (If kubectl is dead, do this from a node once you get a local kubeconfig, or
   restart kube-vip static pod - see below.)
2. **etcd quorum:** the cluster survives **one** node down (2 of 3 = quorum). If
   **two** control-plane nodes are down, the API goes read-only/unavailable until
   a second node is back. Priority: get a node back, don't try to force anything.
   **Do NOT restore etcd from a snapshot just to fix quorum** - that throws away
   real data. Snapshot restore is only for genuinely corrupted/lost etcd; it is a
   separate break-glass procedure in [etcd-recovery.md](etcd-recovery.md).
3. **kubelet won't start after a reboot** (`Ready=Unknown` forever): known issue -
   `protectKernelDefaults: true` needs three sysctls that revert on reboot.
   ```bash
   ssh wawashi@<node> 'sudo journalctl -u kubelet -n 30 --no-pager | grep "invalid kernel flag"'
   # If present, set them live and they persist via /etc/sysctl.d/90-kubelet.conf:
   ssh wawashi@<node> 'sudo sysctl -w vm.overcommit_memory=1 kernel.panic=10 kernel.panic_on_oops=1 && sudo systemctl restart kubelet'
   ```
4. **Static control-plane pods** (apiserver/etcd/kube-vip) are managed by kubelet
   from `/etc/kubernetes/manifests/` on each node. Restarting them = move the
   manifest out and back:
   ```bash
   ssh wawashi@<node> 'sudo mv /etc/kubernetes/manifests/kube-vip.yaml /tmp/ && sleep 5 && sudo mv /tmp/kube-vip.yaml /etc/kubernetes/manifests/'
   ```

More: [cluster.md](cluster.md) (KubeApiserverFrequentRestarts),
[networking.md](networking.md) (KubeVip*).

---

## 8. A node is down or NotReady

```bash
kubectl-homelab get nodes -o wide
kubectl-homelab describe node <node> | grep -A15 Conditions
ssh wawashi@<node> 'uptime; sudo systemctl status kubelet --no-pager | head'
```

- **One node down is survivable** (etcd quorum holds with 2/3). Longhorn keeps
  serving from its other replica. Don't panic-fix; get the node back cleanly.
- **After a reboot, node sits `Ready=Unknown` for ~30 min:** almost always the
  kubelet sysctl issue in [§7 step 3](#7-the-kubernetes-api-is-unreachable). Check
  the kubelet journal for `invalid kernel flag`.
- **M80q BIOS POST takes 5-7 minutes** - a rebooted node looks dead longer than
  you expect. Wait before assuming hardware failure.
- **Cross-VLAN SSH to a rebooted node hangs:** OPNsense keeps stale firewall
  states. Clear the states for that IP in OPNsense
  `Firewall > Diagnostics > States`.
- **Pod dials a host-pinned daemon on its own node and times out** (e.g.
  nut-exporter -> NUT on cp1): Cilium can't do pod->same-node-host for
  non-cluster-IP services. Keep the pod off that node with a `nodeAffinity NotIn`.

More: [cluster.md](cluster.md), [ups.md](ups.md) (graceful shutdown on power loss).

---

## 9. ArgoCD / GitOps stuck

**How this cluster works:** everything except `cilium` is ArgoCD-managed.
`kubectl apply`/`helm upgrade` on a managed resource will be **reverted by
selfHeal** - all real changes go through Git. Auto-sync is ~3 min.

```bash
kubectl-admin get applications -n argocd | grep -vE 'Synced.*Healthy'  # admin: homelab RBAC can't list Applications
```

Run any `argocd` command from inside the controller pod in `--core` mode (no login
needed):

```bash
kubectl-admin exec -n argocd statefulset/argocd-application-controller -- \
  argocd app get <app> --core
```

| Symptom | Fix |
|---------|-----|
| App `OutOfSync`, won't converge, log says "spec.source differs" | A `directory.recurse: false` block - remove the whole `directory:` block from the Application (recurse false is the default and gets stripped, causing an infinite loop) |
| Multi-source `$values` app not picking up a git change (seen on `alloy`) | `argocd app get <app> --core --refresh` then `argocd app sync <app> --core` |
| `gitlab` shows OutOfSync/Missing | It has no auto-sync by design. Sync manually: `argocd app sync gitlab --core` |
| `gitlab` `Health=Missing` but every pod healthy | Migrations container OOMKilled (needs ≥1536Mi). Check `lastState.terminated` on the migrations pod. |
| Built-in CronJob shows Degraded ("not completed last execution") | Find WHY the last run failed FIRST (janitor deletes failed jobs fast). Fix root cause, THEN clear stale status by patching `lastSuccessfulTime`. |
| Sync deadlocked, `operationState.phase: Running` with `.operation: null` | Ghost operation - clear Job finalizers, re-set `.operation`, then `argocd app terminate-op <app> --core`. Full sequence in CLAUDE.md "ArgoCD stuck sync recovery". |

More: [argocd.md](argocd.md). To confirm a sync worked: run `/verify-sync`
(when AI is back) or `argocd app get <app> --core`.

---

## 10. Vault sealed / secrets missing

Apps fail auth, or ExternalSecrets stop syncing. Vault must be **unsealed** for ESO
to mint secrets. After a full restart Vault comes up **sealed**.

**First: Vault normally auto-unseals itself.** A `vault-unsealer` pod polls every
~30s and unseals from the in-cluster `vault-unseal-keys` Secret. So before doing
anything manual, check whether the automation is alive:

```bash
kubectl-homelab get pods -n vault              # is vault-unsealer Running?
# Sealed status (exit code: 0=unsealed, 2=sealed, 1=error):
kubectl-admin exec -n vault vault-0 -- vault status
```

- If `vault-unsealer` is Running, Vault should self-unseal within ~30s - just wait.
- **If Vault stays sealed**, the real problem is the unsealer being down or the
  `vault-unseal-keys` Secret missing. Fix that, or manually unseal as a fallback.

**Manual unseal (fallback):** the unseal keys are in the 1Password item **"Vault
Unseal Keys"** (Kubernetes vault). This terminal has **no `op` access** - open
1Password yourself, then run the unseal from a safe terminal (threshold of keys):

```bash
# Run this yourself with the keys from 1Password (repeat for each required key):
kubectl-admin exec -n vault vault-0 -- vault operator unseal <key>
```

- Access Vault UI/API at `https://vault.k8s.rommelporras.com` (not port-forward).
- After unseal, ESO resumes automatically. Check with
  `kubectl-homelab get externalsecrets -A | grep -v SecretSynced`.

More: [vault.md](vault.md).

---

## 11. Everything is broken (alert storm)

When dozens of alerts fire at once, they are almost always **one** root cause
cascading. Do not chase individual alerts. Find the common root:

**Check in this order - the first "no" is usually your root cause:**

```bash
kubectl-homelab get nodes                                  # 1. all 3 Ready?
ping -c2 10.10.30.10                                        # 2. API VIP alive?
dig @10.10.30.53 google.com +short                         # 3. DNS working?
kubectl-homelab get pods -n kube-system | grep -iE 'cilium|coredns'  # 4. CNI/DNS pods up?
kubectl-admin exec -n vault vault-0 -- vault status        # 5. Vault unsealed?
kubectl-homelab get pods -A | grep -vE 'Running|Completed' # 6. what else?
```

**Classic cascades in this homelab:**

- **DNS down -> everything "down".** If step 3 fails, it's almost certainly
  AdGuard - go to [§3](#3-dns-and-adguard-outages-most-common). Most
  house-wide outages you've had are this.
- **A node down -> Longhorn degraded + pods evicted + L2 leases stranded.** Get
  the node back ([§8](#8-a-node-is-down-or-notready)); most alerts clear on their own.
- **Vault sealed -> every ESO secret stale -> auth failures everywhere.** Unseal
  ([§10](#10-vault-sealed--secrets-missing)).
- **etcd lost quorum (2 nodes down) -> API unavailable -> all of ArgoCD/monitoring
  red.** Restore a node; don't force anything.

Once the root is fixed, give it a few minutes - most cascaded alerts self-clear.

---

## 12. Full runbook index (alert-name detail)

Once you know the specific alert, these have the deep detail. All in `docs/runbooks/`:

| Runbook | Covers |
|---------|--------|
| [networking.md](networking.md) | AdGuardDNSDown, NIC saturation, Cloudflare Tunnel, Tailscale, kube-vip |
| [cluster.md](cluster.md) | Pod stuck/pending/crashloop/imagepull, CPU throttling, apiserver restarts, version-checker |
| [storage.md](storage.md) | Longhorn volume degraded/replica-failed, NVMe SMART, LonghornUI, **StaleISCSISession** |
| [longhorn-hardware.md](longhorn-hardware.md) | Longhorn hardware / NVMe crash recovery |
| [oomkilled.md](oomkilled.md) | ContainerOOMKilled + repeat, common culprits |
| [argocd.md](argocd.md) | App OutOfSync/Unhealthy, sync failed, repo/controller down |
| [vault.md](vault.md) | Vault sealed/down/latency, ESO sync errors, snapshot failing |
| [apps.md](apps.md) | Ghost, Invoicetron, Portfolio, Karakeep, Ollama, Atuin, Uptime-Kuma, Homepage, MySpeed, GitLab (web/sidekiq/postgres/redis) |
| [arr-stack.md](arr-stack.md) | Prowlarr, Sonarr, Radarr, qBittorrent, Jellyfin, Tdarr, etc. |
| [certificates.md](certificates.md) | cert-manager / Let's Encrypt DNS-01 |
| [logging.md](logging.md) | Loki, Alloy |
| [otel.md](otel.md) | OTel Collector |
| [backup.md](backup.md) | Velero, Longhorn backups, vault snapshots |
| [ups.md](ups.md) | UPS, NUT, graceful shutdown on power loss |
| [argo-workflows.md](argo-workflows.md) | Argo Workflows / CI pipelines |

**The single richest source of hard-won gotchas is `CLAUDE.md`** (repo root) -
its "Gotchas" section is effectively an incident database. When you have a weird,
specific symptom, `grep` it there first:

```bash
grep -niE '<your symptom keyword>' /home/wsl/personal/homelab/CLAUDE.md
```

---

## 13. When the AI comes back

Tell it, in order:
1. What you observed (the symptom, which section you used).
2. Every command you **changed** state with (`delete`, `patch`, `scale`, `exec ... cp`).
3. Whether it's fixed or partially fixed.

So it can (a) verify the fix held, (b) reconcile any runtime edits back into Git
(runtime `kubectl`/`exec` edits get reverted by ArgoCD selfHeal or lost on the
next pod restart - the real fix belongs in a manifest + `/commit`), and (c) update
this guide with anything new you learned.
