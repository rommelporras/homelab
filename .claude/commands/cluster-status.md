# Cluster Status

Quick overview of Kubernetes cluster health and status.

**Important:** Use `kubectl-homelab` for this cluster (not generic `kubectl`).

## Instructions

Run these commands to get a comprehensive cluster status:

1. **Check Nodes**
   ```bash
   kubectl-homelab get nodes -o wide
   ```
   - Verify all nodes are Ready
   - Check Kubernetes version consistency
   - Note node roles (control-plane, worker)

2. **Check System Pods**
   ```bash
   kubectl-homelab get pods -n kube-system
   ```
   - All pods should be Running
   - Check for restarts (indicates issues)
   - Verify CNI pods (cilium) are healthy

3. **Check All Namespaces**
   ```bash
   kubectl-homelab get pods -A | grep -v Running | grep -v Completed
   ```
   - Shows only problematic pods
   - Empty output = healthy cluster

4. **Cluster Info**
   ```bash
   kubectl-homelab cluster-info
   ```
   - Verify API server endpoint
   - Check CoreDNS availability

5. **Recent Events**
   ```bash
   kubectl-homelab get events -A --sort-by='.lastTimestamp' | tail -10
   ```
   - Check for warnings or errors
   - Identify recent issues

6. **Resource Usage** (if metrics-server installed)
   ```bash
   kubectl-homelab top nodes
   kubectl-homelab top pods -A --sort-by=memory | head -10
   ```

## Status Report Format

```
Kubernetes Cluster Status
=========================

Nodes:
  k8s-cp1 (10.10.30.11)  Ready    control-plane   v1.35.0
  k8s-cp2 (10.10.30.12)  Ready    control-plane   v1.35.0
  k8s-cp3 (10.10.30.13)  Ready    control-plane   v1.35.0

Control Plane:
  API Server:    Healthy
  etcd:          Healthy (3 members)
  Scheduler:     Healthy
  Controller:    Healthy

Networking:
  CNI:           Cilium (Running)
  CoreDNS:       Running (2 replicas)
  kube-vip:      Active (VIP: 10.10.30.10)

System Pods: 15/15 Running

Problem Pods: None

Recent Events: No warnings in last 10 minutes

Status: ALL SYSTEMS OPERATIONAL
```

## Quick Health Check

For a fast yes/no health check:

```bash
# One-liner health check
kubectl-homelab get nodes | grep -q NotReady && echo "UNHEALTHY: Node(s) NotReady" || echo "HEALTHY: All nodes Ready"
```

## Troubleshooting

If issues found:

**Node NotReady:**
```bash
kubectl-homelab describe node <node-name>
ssh wawashi@<node>.k8s.rommelporras.com "systemctl status kubelet"
ssh wawashi@<node>.k8s.rommelporras.com "journalctl -u kubelet --since '5 minutes ago'"
```

**Pod Issues:**
```bash
kubectl-homelab describe pod <pod-name> -n <namespace>
kubectl-homelab logs <pod-name> -n <namespace>
```

**etcd Issues:**
```bash
kubectl-homelab -n kube-system logs -l component=etcd --tail=20
```

## Use Cases

- Morning check before work
- After node maintenance
- Before deploying workloads
- Investigating issues
- Verifying cluster recovery
