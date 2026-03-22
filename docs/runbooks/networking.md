# Networking Runbook

Covers: AdGuard DNS, network interfaces, Cloudflare tunnels, Tailscale, kube-vip

---

## AdGuardDNSDown

**Severity:** critical

External DNS probe to 10.10.30.53 has failed. The most common root cause is an L2 lease misalignment: the AdGuard pod is running and healthy, but `externalTrafficPolicy: Local` drops all traffic because the Cilium L2 lease is held by a different node than the one running the pod.

### Triage Steps

```
1. Check pod node:
   kubectl-homelab get pods -n home -l app=adguard-home -o wide

2. Check L2 lease holder:
   kubectl-homelab get leases -n kube-system cilium-l2announce-home-adguard-dns -o jsonpath='{.spec.holderIdentity}'

3. If pod node != lease holder, delete lease to force re-election:
   kubectl-homelab delete lease -n kube-system cilium-l2announce-home-adguard-dns

4. Verify DNS resolution restored:
   dig @10.10.30.53 google.com
```

---

## NetworkInterfaceSaturated

**Severity:** warning

NIC utilization has been above 80% on a node for 10+ minutes. At 1GbE (125 MB/s max), this threshold indicates sustained high throughput that may degrade downloads, streaming, and NFS performance. A 2.5GbE NIC upgrade may be justified if this fires regularly.

### Triage Steps

```
1. Check Network Throughput dashboard in Grafana

2. Identify which pods are generating traffic:
   kubectl-homelab top pod -A --sort-by=cpu

3. If NFS-related, check qBittorrent download activity

4. If sustained during off-hours, this is likely Tdarr transcoding
```

---

## NetworkInterfaceCritical

**Severity:** critical

NIC utilization has been above 95% on a node for 5+ minutes. The network is an active bottleneck - downloads, streaming, and NFS I/O will be visibly degraded.

### Triage Steps

```
1. Check if Tdarr is running a large batch transcode:
   https://tdarr.k8s.rommelporras.com

2. If yes, pause Tdarr queue to restore bandwidth

3. Check qBittorrent for many simultaneous downloads:
   https://qbittorrent.k8s.rommelporras.com

4. Consider 2.5GbE NIC upgrade if this is frequent
```

---

## CloudflareTunnelDegraded

**Severity:** warning

Only one of two `cloudflared` pods is healthy. The tunnel is running on reduced redundancy - a second failure will cause a full outage for all Cloudflare-exposed services (Ghost, Invoicetron). Pods run with anti-affinity so each is on a different node; a single pod being down often means one node is unhealthy.

### Triage Steps

```
1. Check cloudflared pod status:
   kubectl-homelab get pods -n cloudflare -l app=cloudflared -o wide

2. Check pod logs:
   kubectl-homelab logs -n cloudflare -l app=cloudflared --tail=50

3. Check if a node is down (anti-affinity means 1 pod per node):
   kubectl-homelab get nodes

4. Check Cloudflare dashboard for tunnel health:
   https://dash.cloudflare.com → Zero Trust → Tunnels
```

---

## CloudflareTunnelDown

**Severity:** critical

All `cloudflared` pods have been unhealthy for 2+ minutes. All services exposed via Cloudflare Tunnel are unreachable from the internet.

### Triage Steps

```
1. Check cloudflared pod status immediately:
   kubectl-homelab get pods -n cloudflare -l app=cloudflared -o wide

2. Check pod logs:
   kubectl-homelab logs -n cloudflare -l app=cloudflared --tail=100

3. Check node health (if all nodes down, tunnel will fail):
   kubectl-homelab get nodes

4. Check Cloudflare dashboard:
   https://dash.cloudflare.com → Zero Trust → Tunnels

5. Restart deployment if pods are stuck:
   kubectl-homelab rollout restart deploy/cloudflared -n cloudflare
```

---

## TailscaleConnectorDown

**Severity:** warning

The Tailscale Connector proxy pod has been unavailable for 5+ minutes. This breaks tailnet DNS (global nameserver 10.10.30.53) and all remote access to the homelab from outside the network.

### Triage Steps

```
1. Check pod status:
   kubectl-homelab get pods -n tailscale

2. Check connector logs:
   kubectl-homelab logs -n tailscale -l tailscale.com/parent-resource-type=connector --tail=50

3. Check Connector CRD:
   kubectl-homelab get connector homelab-network -o yaml

4. Check events:
   kubectl-homelab get events -n tailscale --sort-by=.lastTimestamp
```

---

## TailscaleOperatorDown

**Severity:** warning

The Tailscale Operator pod has been unavailable for 5+ minutes. The operator manages connector and proxy pod lifecycle. Existing Tailscale connections may still work, but recovery from failures is impaired until the operator is restored.

### Triage Steps

```
1. Check pod status:
   kubectl-homelab get pods -n tailscale -l app=operator

2. Check operator logs:
   kubectl-homelab logs -n tailscale -l app=operator --tail=50

3. Check OAuth secret:
   kubectl-homelab get secret -n tailscale operator-oauth

4. Verify Helm release:
   helm-homelab -n tailscale list
```

---

## KubeVipInstanceDown

**Severity:** warning

One kube-vip instance has been unreachable for 2 minutes. VIP failover should keep the API server VIP (10.10.30.10) functional, but the affected node should be investigated.

### Triage Steps

1. Identify which node is affected from the `instance` label on the alert.

2. Check kube-vip static pod status on that node:
   ```
   kubectl-homelab get pods -n kube-system -l app=kube-vip -o wide
   ```

3. Check kube-vip logs on the affected node:
   ```
   kubectl-homelab logs -n kube-system -l app=kube-vip --field-selector spec.nodeName=<node> --tail=50
   ```

4. Check overall node health:
   ```
   kubectl-homelab get nodes
   kubectl-homelab describe node <node>
   ```

5. If the pod is not running, check kubelet status on the node via SSH and inspect `/etc/kubernetes/manifests/kube-vip.yaml` to confirm the static pod manifest is present.

---

## KubeVipAllDown

**Severity:** critical

No kube-vip instance is reachable. The API server VIP (10.10.30.10) may be unreachable, which means `kubectl` and all control plane operations could be broken.

### Triage Steps

1. Confirm VIP reachability directly:
   ```
   ping 10.10.30.10
   curl -k https://10.10.30.10:6443/livez
   ```

2. Check all kube-vip pods:
   ```
   kubectl-homelab get pods -n kube-system -l app=kube-vip -o wide
   ```
   (If kubectl itself is broken, SSH to a control plane node and use `kubectl --kubeconfig /etc/kubernetes/admin.conf`.)

3. Check all node status:
   ```
   kubectl-homelab get nodes
   ```

4. On each control plane node, verify the kube-vip static pod manifest exists and kubelet is running:
   ```
   ssh wawashi@10.10.30.11 "ls /etc/kubernetes/manifests/kube-vip.yaml && systemctl is-active kubelet"
   ```

5. Check kube-vip logs on each control plane node for crash reasons:
   ```
   kubectl-homelab logs -n kube-system -l app=kube-vip --tail=100
   ```

---

## KubeVipLeaseStale

**Severity:** critical

The `plndr-cp-lock` lease in `kube-system` has not been renewed in more than 30 seconds (sustained for 2 minutes). Leader election may be stuck, which can mean the VIP is not being actively managed. The 2-minute `for:` absorbs transient blips during Helm upgrades (~90s API server load spike).

### Triage Steps

1. Check the current lease holder and last renewal time:
   ```
   kubectl-homelab get lease plndr-cp-lock -n kube-system -o yaml
   ```

2. Check kube-vip logs on all control plane nodes for election errors:
   ```
   kubectl-homelab logs -n kube-system -l app=kube-vip --tail=100
   ```

3. Check all kube-vip pods are running:
   ```
   kubectl-homelab get pods -n kube-system -l app=kube-vip -o wide
   ```

4. Check API server health (lease renewal requires API server write access):
   ```
   kubectl-homelab get --raw /livez
   ```

5. If the lease is stuck and pods are healthy, deleting the lease forces re-election:
   ```
   kubectl-admin delete lease plndr-cp-lock -n kube-system
   ```
   Confirm the VIP responds after re-election: `ping 10.10.30.10`

---

## KubeVipHighRestarts

**Severity:** warning

A kube-vip container has restarted more than 3 times in the last hour, indicating a crash loop. Frequent restarts cause brief VIP gaps during each restart cycle.

### Triage Steps

1. Identify the affected pod from the `pod` label on the alert, then check its restart count and last exit reason:
   ```
   kubectl-homelab describe pod -n kube-system <pod-name>
   ```

2. Check kube-vip logs, including the previous terminated container:
   ```
   kubectl-homelab logs -n kube-system <pod-name> -c kube-vip --previous --tail=100
   kubectl-homelab logs -n kube-system <pod-name> -c kube-vip --tail=100
   ```

3. Common crash causes:
   - ARP conflicts: another host on the network is also using the VIP address (10.10.30.10)
   - Interface misconfiguration: check the static pod manifest on the node (`/etc/kubernetes/manifests/kube-vip.yaml`)
   - Insufficient privileges: kube-vip needs `NET_ADMIN` capability; check the manifest's `securityContext`

4. If the node is otherwise healthy and restarts stop on their own, monitor for recurrence. If crashes continue, inspect the OPNsense ARP table for conflicts:
   ```
   https://opnsense.home.rommelporras.com → Diagnostics → ARP Table
   ```
