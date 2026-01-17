# Storage Setup Guide: Longhorn on NVMe

> **Last Updated:** January 11, 2026
> **Purpose:** Configure distributed HA storage using single NVMe drives per node
> **Node details:** See [CLUSTER_STATUS.md](CLUSTER_STATUS.md)

---

## Overview

This guide configures **Longhorn** distributed storage using the existing 512GB NVMe drive on each node. No additional hardware required!

### What You'll Achieve

| Feature | Status |
|---------|--------|
| Distributed storage | âœ… Across 3 nodes |
| Data replication | âœ… 2x replicas |
| Pod failover | âœ… Data survives node failure |
| Dynamic provisioning | âœ… PVCs auto-create volumes |
| Usable capacity | ~400-500GB |

---

## Prerequisites

Before installing Longhorn, ensure:

- [ ] 3-node kubeadm cluster is running
- [ ] Cilium CNI is installed
- [ ] kubectl configured on your workstation
- [x] All nodes have `open-iscsi` installed (done in PRE_INSTALLATION_CHECKLIST)

### Verify Prerequisites

```bash
# All nodes Ready
kubectl-homelab get nodes
# NAME      STATUS   ROLES           AGE   VERSION
# k8s-cp1   Ready    control-plane   10m   v1.35.0
# k8s-cp2   Ready    control-plane   8m    v1.35.0
# k8s-cp3   Ready    control-plane   6m    v1.35.0

# Check open-iscsi on all nodes
for node in k8s-cp1 k8s-cp2 k8s-cp3; do
    echo "=== $node ==="
    ssh $node "systemctl is-active iscsid"
done
# Should show "active" for all nodes
```

---

## Step 1: Prepare Storage Directory

On **each node**, create the Longhorn data directory:

```bash
# SSH to each node and run:
sudo mkdir -p /var/lib/longhorn
sudo chmod 700 /var/lib/longhorn

# Verify disk space available
df -h /var/lib/longhorn
# Should show ~400GB free on the NVMe
```

Or run from your workstation:

```bash
for node in k8s-cp1 k8s-cp2 k8s-cp3; do
    echo "=== Preparing $node ==="
    ssh $node "sudo mkdir -p /var/lib/longhorn && sudo chmod 700 /var/lib/longhorn"
    ssh $node "df -h /var/lib/longhorn"
done
```

---

## Step 2: Install Longhorn

### Option A: Using Helm (Recommended)

```bash
# Add Longhorn Helm repo
helm-homelab repo add longhorn https://charts.longhorn.io
helm-homelab repo update

# Install Longhorn with custom values
helm-homelab install longhorn longhorn/longhorn \
    --namespace longhorn-system \
    --create-namespace \
    --set defaultSettings.defaultDataPath=/var/lib/longhorn \
    --set defaultSettings.defaultReplicaCount=2 \
    --set defaultSettings.storageMinimalAvailablePercentage=10 \
    --set defaultSettings.storageOverProvisioningPercentage=100 \
    --set persistence.defaultClassReplicaCount=2

# Wait for Longhorn to be ready
kubectl-homelab -n longhorn-system rollout status deploy/longhorn-driver-deployer
```

### Option B: Using kubectl (Alternative)

```bash
# Apply Longhorn manifest
kubectl-homelab apply -f https://raw.githubusercontent.com/longhorn/longhorn/v1.7.0/deploy/longhorn.yaml

# Wait for pods to be ready
kubectl-homelab -n longhorn-system get pods -w
```

Then configure settings:

```bash
# Patch default settings
kubectl-homelab -n longhorn-system patch settings.longhorn.io default-data-path \
    -p '{"value": "/var/lib/longhorn"}' --type=merge

kubectl-homelab -n longhorn-system patch settings.longhorn.io default-replica-count \
    -p '{"value": "2"}' --type=merge
```

---

## Step 3: Verify Installation

### Check Pods

```bash
kubectl-homelab -n longhorn-system get pods
```

Expected output (all Running):
```
NAME                                           READY   STATUS    RESTARTS   AGE
longhorn-driver-deployer-xxxx                  1/1     Running   0          2m
longhorn-manager-xxxxx                         1/1     Running   0          2m
longhorn-manager-xxxxx                         1/1     Running   0          2m
longhorn-manager-xxxxx                         1/1     Running   0          2m
longhorn-ui-xxxx                               1/1     Running   0          2m
instance-manager-xxxx                          1/1     Running   0          2m
instance-manager-xxxx                          1/1     Running   0          2m
instance-manager-xxxx                          1/1     Running   0          2m
engine-image-ei-xxxx                           1/1     Running   0          2m
csi-attacher-xxxx                              1/1     Running   0          2m
csi-provisioner-xxxx                           1/1     Running   0          2m
csi-resizer-xxxx                               1/1     Running   0          2m
csi-snapshotter-xxxx                           1/1     Running   0          2m
```

### Check Nodes

```bash
kubectl-homelab -n longhorn-system get nodes.longhorn.io
```

Expected output:
```
NAME      READY   ALLOWSCHEDULING   SCHEDULABLE   AGE
k8s-cp1   True    true              True          2m
k8s-cp2   True    true              True          2m
k8s-cp3   True    true              True          2m
```

### Check Storage Class

```bash
kubectl-homelab get storageclass
```

Expected output:
```
NAME                 PROVISIONER          RECLAIMPOLICY   VOLUMEBINDINGMODE   ALLOWVOLUMEEXPANSION   AGE
longhorn (default)   driver.longhorn.io   Delete          Immediate           true                   2m
```

---

## Step 4: Configure Storage Class

Create an optimized StorageClass for your homelab:

```yaml
# longhorn-storageclass.yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: longhorn
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: driver.longhorn.io
allowVolumeExpansion: true
reclaimPolicy: Delete
volumeBindingMode: Immediate
parameters:
  numberOfReplicas: "2"
  staleReplicaTimeout: "2880"
  fromBackup: ""
  fsType: "ext4"
  dataLocality: "best-effort"
```

Apply it:

```bash
# Delete existing default StorageClass if exists
kubectl-homelab delete storageclass longhorn --ignore-not-found

# Apply new StorageClass
kubectl-homelab apply -f longhorn-storageclass.yaml

# Verify it's default
kubectl-homelab get storageclass
```

---

## Step 5: Access Longhorn UI

### Option A: Port Forward (Quick Test)

```bash
kubectl-homelab -n longhorn-system port-forward svc/longhorn-frontend 8080:80
# Then open http://localhost:8080
```

### Option B: Create Ingress (Permanent Access)

```yaml
# longhorn-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: longhorn-ui
  namespace: longhorn-system
  annotations:
    nginx.ingress.kubernetes.io/auth-type: basic
    nginx.ingress.kubernetes.io/auth-secret: longhorn-basic-auth
    nginx.ingress.kubernetes.io/auth-realm: "Authentication Required"
spec:
  ingressClassName: nginx
  rules:
  - host: longhorn.home.rommelporras.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: longhorn-frontend
            port:
              number: 80
```

Create basic auth secret:

```bash
# Create password file
htpasswd -c auth admin

# Create secret
kubectl-homelab -n longhorn-system create secret generic longhorn-basic-auth --from-file=auth

# Apply ingress
kubectl-homelab apply -f longhorn-ingress.yaml
```

---

## Step 6: Test Storage

### Create Test PVC

```yaml
# test-pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
  namespace: default
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 1Gi
```

### Create Test Pod

```yaml
# test-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: test-pod
  namespace: default
spec:
  containers:
  - name: test
    image: busybox
    command: ["sh", "-c", "echo 'Hello Longhorn!' > /data/test.txt && sleep 3600"]
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: test-pvc
```

Apply and verify:

```bash
kubectl-homelab apply -f test-pvc.yaml
kubectl-homelab apply -f test-pod.yaml

# Check PVC is Bound
kubectl-homelab get pvc test-pvc
# NAME       STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
# test-pvc   Bound    pvc-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx   1Gi        RWO            longhorn       30s

# Check pod is Running
kubectl-homelab get pod test-pod
# NAME       READY   STATUS    RESTARTS   AGE
# test-pod   1/1     Running   0          30s

# Verify data written
kubectl-homelab exec test-pod -- cat /data/test.txt
# Hello Longhorn!
```

### Verify Replication

In Longhorn UI (http://localhost:8080):

1. Go to **Volume** tab
2. Find `pvc-xxxx` volume
3. Verify **Replicas: 2** on different nodes

Or via kubectl:

```bash
kubectl-homelab -n longhorn-system get replicas.longhorn.io
# Should show 2 replicas on different nodes
```

### Cleanup Test Resources

```bash
kubectl-homelab delete pod test-pod
kubectl-homelab delete pvc test-pvc
```

---

## Step 7: Test Failover (Optional but Recommended)

### Simulate Node Failure

```bash
# Find which node has the test pod
kubectl-homelab get pod test-pod -o wide
# Note the NODE column

# Cordon the node (prevent new pods)
kubectl-homelab cordon k8s-cp1

# Delete the pod (or drain the node)
kubectl-homelab delete pod test-pod

# Watch pod reschedule to another node
kubectl-homelab get pod test-pod -o wide -w
```

### Verify Data Survives

```bash
# Once pod is running on new node
kubectl-homelab exec test-pod -- cat /data/test.txt
# Should still show: Hello Longhorn!
```

### Restore Node

```bash
kubectl-homelab uncordon k8s-cp1
```

---

## Storage Configuration Reference

### Recommended Settings

| Setting | Value | Reason |
|---------|-------|--------|
| `defaultReplicaCount` | 2 | Balance between HA and space |
| `defaultDataPath` | `/var/lib/longhorn` | Use NVMe root filesystem |
| `storageMinimalAvailablePercentage` | 10 | Keep 10% free for OS |
| `storageOverProvisioningPercentage` | 100 | Allow thin provisioning |
| `dataLocality` | best-effort | Try to schedule pod near data |

### Capacity Calculation

```
Per Node:
  NVMe Total:           512GB
  OS + etcd + images:   ~100GB
  Available for LH:     ~400GB

Cluster Total (3 nodes):
  Raw capacity:         ~1200GB
  With 2x replication:  ~600GB usable
  With 3x replication:  ~400GB usable
```

---

## NFS Storage for Media

For large media files (photos, videos), use NFS from Dell 5090:

```yaml
# nfs-pv.yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: immich-photos-nfs
spec:
  capacity:
    storage: 1Ti
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  storageClassName: nfs
  nfs:
    server: 10.10.30.4
    path: /export/photos
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: immich-photos
  namespace: media
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: nfs
  resources:
    requests:
      storage: 1Ti
  volumeName: immich-photos-nfs
```

---

## Troubleshooting

### PVC Stuck in Pending

```bash
# Check events
kubectl-homelab describe pvc <pvc-name>

# Common causes:
# - StorageClass doesn't exist
# - No schedulable nodes
# - Insufficient disk space
```

### Volume Not Attaching

```bash
# Check Longhorn manager logs
kubectl-homelab -n longhorn-system logs -l app=longhorn-manager

# Check volume status
kubectl-homelab -n longhorn-system get volumes.longhorn.io
```

### Replica Rebuild Slow

At 1GbE, rebuilding a 100GB replica takes ~15-20 minutes. This is normal.

```bash
# Monitor rebuild progress in UI
# Or check replica status
kubectl-homelab -n longhorn-system get replicas.longhorn.io
```

### Node Shows "Unschedulable"

```bash
# Check if path exists and has space
ssh k8s-cp1 "df -h /var/lib/longhorn"

# Check node conditions
kubectl-homelab -n longhorn-system describe node.longhorn.io k8s-cp1
```

---

## Backup Strategy

### To NFS (Recommended)

```bash
# Configure backup target in Longhorn UI:
# Settings â†’ Backup Target
# NFS: nfs://10.10.30.4:/export/longhorn-backups

# Or via kubectl:
kubectl-homelab -n longhorn-system patch settings.longhorn.io backup-target \
    -p '{"value": "nfs://10.10.30.4:/export/longhorn-backups"}' --type=merge
```

### Create Scheduled Backup

In Longhorn UI:
1. Go to **Volume** â†’ Select volume
2. Click **Create Recurring Job**
3. Set schedule (e.g., daily at 3 AM)
4. Set retention count (e.g., keep 7 backups)

---

## Next Steps

After Longhorn is running:

1. **Deploy stateful workloads** â€” PostgreSQL, Prometheus, etc.
2. **Configure backup schedules** â€” Protect your data
3. **Monitor disk usage** â€” Set up alerts in Grafana
4. **Test failover periodically** â€” Ensure HA works as expected

---

## Quick Reference

```bash
# Check Longhorn status
kubectl-homelab -n longhorn-system get pods

# List volumes
kubectl-homelab -n longhorn-system get volumes.longhorn.io

# List replicas
kubectl-homelab -n longhorn-system get replicas.longhorn.io

# Access UI
kubectl-homelab -n longhorn-system port-forward svc/longhorn-frontend 8080:80

# Check disk usage per node
kubectl-homelab -n longhorn-system get nodes.longhorn.io -o wide
```
