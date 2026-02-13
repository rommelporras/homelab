# Kubernetes v1.35 Features & Breaking Changes

> **Last Updated:** February 14, 2026
> **Release Name:** "Timbernetes" (December 17, 2025)
> **Source:** Extracted from official v1.35 release documentation

Features and breaking changes relevant to this homelab cluster (3-node, Cilium CNI, containerd 1.7).

---

## Breaking Changes (Action Required)

| Change | Impact | Action | Cluster Status |
|--------|--------|--------|----------------|
| **cgroup v1 removal (Beta)** | Nodes using cgroup v1 will fail | Verify: `stat -fc %T /sys/fs/cgroup/` = `cgroup2fs` | Already cgroup v2 (ansible preflight checks this) |
| **containerd 1.x EOL** | v1.35 is LAST release supporting containerd 1.7 | Upgrade to containerd 2.0+ before v1.36 | Running 1.7.x — **upgrade needed before v1.36** |
| **WebSocket exec requires CREATE** | `kubectl exec/attach/port-forward` requires CREATE permission | Update RBAC: add `create` verb on `pods/exec`, `pods/attach` | Review custom RBAC roles |

> **Note:** IPVS mode deprecation is not applicable — this cluster uses Cilium eBPF as kube-proxy replacement.

### Verify Nodes

```bash
# Check cgroup version (MUST be cgroup2fs)
for node in cp1 cp2 cp3; do
    echo "=== $node ==="
    ssh wawashi@$node.k8s.rommelporras.com "stat -fc %T /sys/fs/cgroup/"
done

# Check containerd version (must upgrade to 2.0+ before v1.36)
for node in cp1 cp2 cp3; do
    echo "=== $node ==="
    ssh wawashi@$node.k8s.rommelporras.com "containerd --version"
done
```

---

## GA Features (Production Ready)

### 1. In-Place Pod Vertical Scaling (KEP-1287)

Adjust CPU and memory resources on running pods **without restarting containers**.

**Useful for this cluster:**
- Scale Prometheus/Loki during high-load periods without downtime
- Give pods extra CPU at startup, then shrink after initialization

```yaml
# Pod with resize policy
apiVersion: v1
kind: Pod
metadata:
  name: resizable-app
spec:
  containers:
  - name: app
    image: nginx:latest
    resources:
      requests:
        cpu: "500m"
        memory: "256Mi"
      limits:
        cpu: "1"
        memory: "512Mi"
    resizePolicy:
    - resourceName: cpu
      restartPolicy: NotRequired   # CPU changes don't restart
    - resourceName: memory
      restartPolicy: NotRequired   # Memory changes don't restart (if possible)
```

**Resize a running pod:**

```bash
# Patch resources on running pod (no restart!)
kubectl-homelab patch pod resizable-app --subresource=resize --patch '{
  "spec": {
    "containers": [{
      "name": "app",
      "resources": {
        "requests": {"cpu": "750m", "memory": "384Mi"},
        "limits": {"cpu": "2", "memory": "1Gi"}
      }
    }]
  }
}'

# Check resize status
kubectl-homelab get pod resizable-app -o jsonpath='{.status.resize}'
# Values: Proposed, InProgress, Deferred, Infeasible, (empty = completed)

# View allocated vs requested resources
kubectl-homelab get pod resizable-app -o jsonpath='{.status.containerStatuses[0].allocatedResources}'
```

**v1.35 improvements:**
- Memory limit **decreases** now allowed (was prohibited before)
- Better handling of deferred resizes when node resources are constrained
- New events emitted for resize status changes

---

### 2. PreferSameNode Traffic Distribution (KEP-3015)

Route Service traffic to pods on the same node first, reducing latency.

**Useful for this cluster:**
- Longhorn volume access (reduce cross-node traffic)
- Application → Database connections (PostgreSQL, MySQL)

```yaml
apiVersion: v1
kind: Service
metadata:
  name: postgres
spec:
  selector:
    app: postgres
  ports:
  - port: 5432
  trafficDistribution: PreferSameNode  # Prefer local pod first
```

---

## Quick Reference

```bash
# In-Place Pod Resize
kubectl-homelab patch pod <name> --subresource=resize --patch '{...}'
kubectl-homelab get pod <name> -o jsonpath='{.status.resize}'

# Monitor containerd deprecation warnings
kubectl-homelab get --raw /metrics | grep kubelet_cri_losing_support
```

---

## References

- [Kubernetes v1.35 Release Announcement](https://kubernetes.io/blog/2025/12/17/kubernetes-v1-35-release/)
- [In-Place Pod Resize GA Blog](https://kubernetes.io/blog/2025/12/19/kubernetes-v1-35-in-place-pod-resize-ga/)
- [KEP-1287: In-Place Pod Vertical Scaling](https://github.com/kubernetes/enhancements/issues/1287)
- [KEP-3015: PreferSameNode Traffic Distribution](https://github.com/kubernetes/enhancements/issues/3015)
