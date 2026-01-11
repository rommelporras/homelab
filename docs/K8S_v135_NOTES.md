# Kubernetes v1.35 Features & Breaking Changes

> **Last Updated:** January 11, 2026
> **Release Name:** "Timbernetes" (December 17, 2025)
> **Source:** Extracted from official v1.35 release documentation

This document covers v1.35-specific features and breaking changes relevant to your homelab cluster.

---

## Breaking Changes (Action Required)

| Change | Impact | Action |
|--------|--------|--------|
| **cgroup v1 removal (Beta)** | Nodes using cgroup v1 will fail | Verify: `stat -fc %T /sys/fs/cgroup/` should show `cgroup2fs` |
| **containerd 1.x EOL** | v1.35 is LAST release supporting containerd 1.7 | Upgrade to containerd 2.0+ before v1.36 |
| **IPVS mode deprecated** | kube-proxy IPVS mode is deprecated | Use `nftables` mode instead |
| **WebSocket exec requires CREATE** | `kubectl exec/attach/port-forward` requires CREATE permission | Update RBAC: add `create` verb on `pods/exec`, `pods/attach` |

### Verify Your Nodes

```bash
# Check cgroup version (MUST be cgroup2fs)
stat -fc %T /sys/fs/cgroup/
# Expected: cgroup2fs

# Check containerd version
containerd --version
# v1.35 supports 1.7, upgrade to 2.0+ recommended

# If using IPVS, check kube-proxy mode
kubectl get configmap kube-proxy -n kube-system -o yaml | grep mode
# Consider: mode: nftables
```

---

## GA Features (Production Ready)

### 1. In-Place Pod Vertical Scaling (KEP-1287)

Adjust CPU and memory resources on running pods **without restarting containers**.

**Why it matters for your homelab:**
- Scale Prometheus/Loki during high-load periods without downtime
- Give pods extra CPU at startup, then shrink after initialization
- Dynamically adjust resources based on actual usage

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
kubectl patch pod resizable-app --subresource=resize --patch '{
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
kubectl get pod resizable-app -o jsonpath='{.status.resize}'
# Values: Proposed, InProgress, Deferred, Infeasible, (empty = completed)

# View allocated vs requested resources
kubectl get pod resizable-app -o jsonpath='{.status.containerStatuses[0].allocatedResources}'
```

**v1.35 Improvements:**
- Memory limit **decreases** now allowed (was prohibited before)
- Better handling of deferred resizes when node resources are constrained
- New events emitted for resize status changes

---

### 2. PreferSameNode Traffic Distribution (KEP-3015)

Route Service traffic to pods on the same node first, reducing latency.

**Why it matters for your homelab:**
- Reduce network hops for Longhorn storage access
- Improve latency for database connections
- Keep related workloads communicating efficiently

```yaml
# Service with same-node preference
apiVersion: v1
kind: Service
metadata:
  name: postgres
spec:
  selector:
    app: postgres
  ports:
  - port: 5432
  trafficDistribution: PreferSameNode  # NEW in v1.35 GA
---
# Cache service benefiting from local traffic
apiVersion: v1
kind: Service
metadata:
  name: redis-cache
spec:
  selector:
    app: redis
  ports:
  - port: 6379
  trafficDistribution: PreferSameNode  # Latency-sensitive!
```

**Use cases for your cluster:**
- Longhorn volume access (reduce cross-node traffic)
- Application -> Database connections
- Prometheus -> Node Exporter scraping

---

### 3. Image Volumes (Stable)

Mount OCI images directly as read-only volumes without init containers.

```yaml
# Mount ML model from OCI registry
apiVersion: v1
kind: Pod
metadata:
  name: ml-inference
spec:
  containers:
  - name: inference
    image: my-inference-app:latest
    volumeMounts:
    - name: model
      mountPath: /models
  volumes:
  - name: model
    image:
      reference: registry.example.com/models/llama:v2
      pullPolicy: IfNotPresent
```

**Requirement:** containerd 2.1+ (not 2.0)

---

## Beta Features

### Pod Certificates (KEP-4317)

Native certificate issuance for pods without external tools like cert-manager.

```yaml
volumes:
- name: pod-cert
  projected:
    sources:
    - podCertificate:
        signerName: example.com/my-signer
        expirationSeconds: 3600
```

---

## Alpha Features

### Gang Scheduling (KEP-5565)

Schedule groups of pods together (all-or-nothing) - useful for distributed AI/ML training.

```yaml
# Requires feature gate
apiVersion: scheduling/v1alpha1
kind: Workload
metadata:
  name: distributed-training
spec:
  podGroups:
  - name: "workers"
    policy:
      gang:
        minCount: 8  # All 8 pods must be schedulable, or none
```

---

## Upgrade Checklist (v1.34 to v1.35)

```bash
# 1. Verify cgroup v2 on ALL nodes
for node in k8s-cp1 k8s-cp2 k8s-cp3; do
    ssh wawashi@$node.home.rommelporras.com "stat -fc %T /sys/fs/cgroup/"
done

# 2. Check containerd version
for node in k8s-cp1 k8s-cp2 k8s-cp3; do
    ssh wawashi@$node.home.rommelporras.com "containerd --version"
done

# 3. Update RBAC if using kubectl exec/attach automation
# Add 'create' verb to pods/exec, pods/attach subresources

# 4. If using IPVS, plan migration to nftables
kubectl get configmap kube-proxy -n kube-system -o yaml | grep -A2 "mode:"
```

---

## Quick Reference Commands

```bash
# Verify cgroup v2 (REQUIRED)
stat -fc %T /sys/fs/cgroup/
# Expected: cgroup2fs

# In-Place Pod Resize
kubectl patch pod <name> --subresource=resize --patch '{...}'
kubectl get pod <name> -o jsonpath='{.status.resize}'
kubectl get pod <name> -o jsonpath='{.status.containerStatuses[0].allocatedResources}'

# Check kube-proxy mode
kubectl get configmap kube-proxy -n kube-system -o yaml | grep -A2 "mode:"

# Monitor containerd deprecation warnings
kubectl get --raw /metrics | grep kubelet_cri_losing_support
```

---

## References

- [Kubernetes v1.35 Release Announcement](https://kubernetes.io/blog/2025/12/17/kubernetes-v1-35-release/)
- [In-Place Pod Resize GA Blog](https://kubernetes.io/blog/2025/12/19/kubernetes-v1-35-in-place-pod-resize-ga/)
- [KEP-1287: In-Place Pod Vertical Scaling](https://github.com/kubernetes/enhancements/issues/1287)
- [KEP-3015: PreferSameNode Traffic Distribution](https://github.com/kubernetes/enhancements/issues/3015)
