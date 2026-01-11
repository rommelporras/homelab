# Cluster Status

Quick overview of Kubernetes cluster health and status.

## Instructions

Run these commands to get a comprehensive cluster status:

1. **Check Nodes**
   ```bash
   kubectl get nodes -o wide
   ```
   - Verify all nodes are Ready
   - Check Kubernetes version consistency
   - Note node roles (control-plane, worker)

2. **Check System Pods**
   ```bash
   kubectl get pods -n kube-system
   ```
   - All pods should be Running
   - Check for restarts (indicates issues)
   - Verify CNI pods (cilium) are healthy

3. **Check All Namespaces**
   ```bash
   kubectl get pods -A | grep -v Running | grep -v Completed
   ```
   - Shows only problematic pods
   - Empty output = healthy cluster

4. **Cluster Info**
   ```bash
   kubectl cluster-info
   ```
   - Verify API server endpoint
   - Check CoreDNS availability

5. **Recent Events**
   ```bash
   kubectl get events -A --sort-by='.lastTimestamp' | tail -10
   ```
   - Check for warnings or errors
   - Identify recent issues

6. **Resource Usage** (if metrics-server installed)
   ```bash
   kubectl top nodes
   kubectl top pods -A --sort-by=memory | head -10
   ```

## Status Report Format

```
Kubernetes Cluster Status
=========================

Nodes:
  k8s-cp-1 (10.10.60.11)  Ready    control-plane   v1.35.0
  k8s-cp-2 (10.10.60.12)  Ready    control-plane   v1.35.0
  k8s-cp-3 (10.10.60.13)  Ready    control-plane   v1.35.0

Control Plane:
  API Server:    Healthy
  etcd:          Healthy (3 members)
  Scheduler:     Healthy
  Controller:    Healthy

Networking:
  CNI:           Cilium (Running)
  CoreDNS:       Running (2 replicas)
  kube-vip:      Active (VIP: 10.10.60.10)

System Pods: 15/15 Running

Problem Pods: None

Recent Events: No warnings in last 10 minutes

Status: ALL SYSTEMS OPERATIONAL
```

## Quick Health Check

For a fast yes/no health check:

```bash
# One-liner health check
kubectl get nodes | grep -q NotReady && echo "UNHEALTHY: Node(s) NotReady" || echo "HEALTHY: All nodes Ready"
```

## Troubleshooting

If issues found:

**Node NotReady:**
```bash
kubectl describe node <node-name>
ssh <node> "systemctl status kubelet"
ssh <node> "journalctl -u kubelet --since '5 minutes ago'"
```

**Pod Issues:**
```bash
kubectl describe pod <pod-name> -n <namespace>
kubectl logs <pod-name> -n <namespace>
```

**etcd Issues:**
```bash
kubectl -n kube-system logs -l component=etcd --tail=20
```

## Use Cases

- Morning check before work
- After node maintenance
- Before deploying workloads
- Investigating issues
- Verifying cluster recovery
