# Phase 4.8: AdGuard Client IP Preservation

> **Status:** Complete
> **Target:** v0.10.2
> **CKA Topics:** externalTrafficPolicy, Service topology, Cilium L2 announcement

> **Purpose:** Restore client IP visibility in AdGuard logs
>
> **Problem:** With `externalTrafficPolicy: Cluster`, client IPs were hidden (showed as node IPs or CoreDNS pod IPs).
>
> **Solution:** Switch to `externalTrafficPolicy: Local` with pod and L2 announcement aligned on same node.

---

## What We Did

### Initial State
| Component | Value | Issue |
|-----------|-------|-------|
| Pod location | k8s-cp2 | - |
| L2 lease | k8s-cp1 | ✗ Mismatch |
| externalTrafficPolicy | Cluster | ✗ Hides client IPs |

### Final State
| Component | Value |
|-----------|-------|
| Pod location | k8s-cp2 |
| L2 lease | k8s-cp2 |
| externalTrafficPolicy | Local |
| Client IPs visible | Yes |

---

## Key Learnings (CKA Relevant)

### 1. externalTrafficPolicy Explained

| Policy | Behavior | Client IP | Use Case |
|--------|----------|-----------|----------|
| **Cluster** | Traffic can route to any node, then forward to pod | Hidden (SNAT to node IP) | Default, most reliable |
| **Local** | Traffic only served by nodes with local pod | Preserved | When you need real client IPs |

With `Local` policy, if traffic hits a node without a local pod, it's **dropped** (connection refused).

### 2. Cilium L2 Announcement

Cilium L2 uses **leader election** via Kubernetes Leases to decide which node announces a LoadBalancer IP via ARP.

```bash
# Check which node is announcing an IP
kubectl get leases -n kube-system | grep l2announce
```

**Important:** With `externalTrafficPolicy: Cluster`, any node can hold the L2 lease. With `Local`, only nodes with healthy endpoints should announce, but Cilium doesn't automatically enforce this - the lease holder is chosen by leader election.

### 3. The Alignment Problem

For `externalTrafficPolicy: Local` to work with Cilium L2:

```
L2 Lease Node == Pod Node
```

If they don't match, external traffic is dropped.

**Solutions:**
1. **Node pinning** (what we did) - Pin pod to specific node, delete L2 lease to force re-election
2. **DaemonSet** - Run pod on every node (more complex)
3. **Service-specific L2 policy** - Didn't work due to policy conflicts

### 4. Cilium L2 Policy Conflicts

Multiple `CiliumL2AnnouncementPolicy` resources can conflict:
- A general policy (matching all services) can override a specific policy
- The lease holder is determined by leader election across ALL matching policies
- Deleting a conflicting policy and the lease can force re-evaluation

### 5. Health Check Node Port

With `externalTrafficPolicy: Local`, Kubernetes creates a health check endpoint:

```bash
# Get health check port
kubectl get svc <name> -o jsonpath='{.spec.healthCheckNodePort}'

# Check health on a node
curl http://<node-ip>:<port>/healthz
# Returns: {"localEndpoints": N}
```

---

## Understanding Client IP Sources

After the fix, AdGuard shows different client types:

| Client Type | IP Pattern | Explanation |
|-------------|------------|-------------|
| External devices | 10.10.20.x, 10.10.40.x | Real client IPs (laptops, phones, IoT) |
| Kubernetes pods | 10.0.x.x (CoreDNS) | Pods query CoreDNS which forwards to AdGuard |
| Node DNS | 10.10.30.11-13 | Nodes querying DNS directly |

**Note:** In-cluster pod queries will always show CoreDNS IPs. This is expected - pods query CoreDNS, and CoreDNS forwards upstream.

---

## Files Changed

1. **manifests/home/adguard/service.yaml**
   - Changed `externalTrafficPolicy: Cluster` → `Local`
   - Added `app: adguard-home` label
   - Updated comments

2. **docs/todo/phase-4.8-adguard-client-ip.md** (this file)
   - Renamed from `phase-4.8-adguard-daemonset.md`
   - Documented actual solution vs original plan

---

## Verification Commands

```bash
# Check pod location
kubectl-homelab get pods -n home -l app=adguard-home -o wide

# Check L2 lease holder
kubectl-homelab get leases -n kube-system cilium-l2announce-home-adguard-dns -o jsonpath='{.spec.holderIdentity}'

# Check traffic policy
kubectl-homelab get svc adguard-dns -n home -o jsonpath='{.spec.externalTrafficPolicy}'

# Test DNS
nslookup google.com 10.10.30.53

# Check health endpoint
curl http://10.10.30.12:$(kubectl-homelab get svc adguard-dns -n home -o jsonpath='{.spec.healthCheckNodePort}')/healthz
```

---

## Rollback

If issues occur:

```bash
# Revert to Cluster policy
kubectl-homelab patch svc adguard-dns -n home -p '{"spec":{"externalTrafficPolicy":"Cluster"}}'
```

---

## Future Considerations

1. **L2 lease stability** - If Cilium agents restart, the L2 lease may move to a different node. Monitor and delete lease if mismatch occurs.

2. **Monitoring** - Consider adding an alert for when L2 lease holder doesn't match pod node.

3. **Alternative: DaemonSet** - If single-node pinning becomes unreliable, DaemonSet ensures a pod on every node (but loses UI config persistence).
