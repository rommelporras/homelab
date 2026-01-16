---
name: kubeadm-patterns
description: Common kubeadm patterns, troubleshooting, and best practices for cluster bootstrap and maintenance.
---

# kubeadm Patterns & Troubleshooting

## Cluster Bootstrap Patterns

### Single Control Plane Initialization

```bash
# Initialize first control plane node
sudo kubeadm init \
  --control-plane-endpoint "10.10.30.10:6443" \
  --upload-certs \
  --pod-network-cidr=10.244.0.0/16

# Save the output! Contains join commands for other nodes
```

### HA Control Plane Initialization

```bash
# First control plane with certificate upload
sudo kubeadm init \
  --control-plane-endpoint "10.10.30.10:6443" \
  --upload-certs \
  --pod-network-cidr=10.244.0.0/16

# Join additional control planes (within 2 hours of init)
sudo kubeadm join 10.10.30.10:6443 \
  --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash> \
  --control-plane \
  --certificate-key <cert-key>

# Join worker nodes
sudo kubeadm join 10.10.30.10:6443 \
  --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash>
```

### Regenerate Join Token

```bash
# If token expired (24h default)
kubeadm token create --print-join-command

# For control plane joins (regenerate cert key)
kubeadm init phase upload-certs --upload-certs
kubeadm token create --print-join-command --certificate-key <new-cert-key>
```

## Common Bootstrap Issues

### Issue: "connection refused" to API server

**Symptoms:**
```
couldn't initialize a Kubernetes cluster
error execution phase wait-control-plane
```

**Causes & Fixes:**
1. **kube-vip not running** - Check static pod manifest
   ```bash
   ls /etc/kubernetes/manifests/kube-vip.yaml
   crictl ps | grep kube-vip
   ```

2. **Firewall blocking 6443** - Open port
   ```bash
   sudo ufw allow 6443/tcp
   ```

3. **API server crash loop** - Check logs
   ```bash
   crictl logs $(crictl ps -a | grep kube-apiserver | awk '{print $1}')
   ```

### Issue: "node not found" after join

**Symptoms:**
```
Unable to register node with API server
```

**Causes & Fixes:**
1. **Hostname resolution** - Add to /etc/hosts
   ```bash
   echo "10.10.30.11 k8s-cp1" | sudo tee -a /etc/hosts
   ```

2. **kubelet not using correct hostname**
   ```bash
   # Check kubelet args
   cat /var/lib/kubelet/kubeadm-flags.env
   # Should have --hostname-override if needed
   ```

### Issue: etcd cluster unhealthy

**Symptoms:**
```
etcdserver: request timed out
```

**Diagnostic:**
```bash
# Check etcd members
sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  member list

# Check endpoint health
sudo etcdctl endpoint health --cluster
```

**Fixes:**
1. **Network partition** - Check connectivity between nodes
2. **Disk full** - etcd needs fast disk
   ```bash
   df -h /var/lib/etcd
   ```
3. **Remove failed member** (last resort)
   ```bash
   etcdctl member remove <member-id>
   ```

### Issue: CNI not ready

**Symptoms:**
```
node "k8s-cp1" not ready
network plugin is not ready: cni config uninitialized
```

**Fix:**
Install CNI before joining nodes:
```bash
# For Cilium
cilium install

# Verify
cilium status --wait
```

## Certificate Management

### Check Expiration

```bash
kubeadm certs check-expiration
```

### Renew All Certificates

```bash
# Renew all certs
sudo kubeadm certs renew all

# Restart control plane components
sudo systemctl restart kubelet

# Or restart static pods
sudo crictl rm $(crictl ps -a -q)
```

### Renew Specific Certificate

```bash
# Renew only admin.conf
sudo kubeadm certs renew admin.conf

# Copy to user
sudo cp /etc/kubernetes/admin.conf ~/.kube/config
sudo chown $(id -u):$(id -g) ~/.kube/config
```

## Upgrade Patterns

### Control Plane Upgrade

```bash
# 1. Upgrade kubeadm
sudo apt-mark unhold kubeadm
sudo apt-get update
sudo apt-get install -y kubeadm=1.35.0-*
sudo apt-mark hold kubeadm

# 2. Verify upgrade plan
sudo kubeadm upgrade plan

# 3. Apply upgrade (first control plane only)
sudo kubeadm upgrade apply v1.35.0

# 4. Upgrade kubelet and kubectl
sudo apt-mark unhold kubelet kubectl
sudo apt-get install -y kubelet=1.35.0-* kubectl=1.35.0-*
sudo apt-mark hold kubelet kubectl

# 5. Restart kubelet
sudo systemctl daemon-reload
sudo systemctl restart kubelet
```

### Additional Control Planes

```bash
# Use 'node' instead of 'apply'
sudo kubeadm upgrade node
```

### Worker Node Upgrade

```bash
# 1. Drain node
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data

# 2. Upgrade packages (on node)
sudo apt-get update
sudo apt-get install -y kubeadm=1.35.0-* kubelet=1.35.0-* kubectl=1.35.0-*

# 3. Upgrade node config
sudo kubeadm upgrade node

# 4. Restart kubelet
sudo systemctl daemon-reload
sudo systemctl restart kubelet

# 5. Uncordon node
kubectl uncordon <node-name>
```

## Backup & Recovery

### etcd Backup

```bash
# Create snapshot
sudo ETCDCTL_API=3 etcdctl snapshot save /backup/etcd-$(date +%Y%m%d).db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key

# Verify snapshot
sudo etcdctl snapshot status /backup/etcd-*.db --write-out=table
```

### etcd Restore

```bash
# Stop kubelet
sudo systemctl stop kubelet

# Move current etcd data
sudo mv /var/lib/etcd /var/lib/etcd.bak

# Restore
sudo ETCDCTL_API=3 etcdctl snapshot restore /backup/etcd-snapshot.db \
  --data-dir=/var/lib/etcd \
  --name=<node-name> \
  --initial-cluster=<node-name>=https://<node-ip>:2380 \
  --initial-advertise-peer-urls=https://<node-ip>:2380

# Fix permissions
sudo chown -R etcd:etcd /var/lib/etcd

# Start kubelet
sudo systemctl start kubelet
```

### Backup Certificates

```bash
# Backup PKI
sudo tar -czvf /backup/kubernetes-pki-$(date +%Y%m%d).tar.gz /etc/kubernetes/pki/

# Backup kubeconfig files
sudo tar -czvf /backup/kubernetes-configs-$(date +%Y%m%d).tar.gz \
  /etc/kubernetes/*.conf
```

## Reset & Cleanup

### Full Node Reset

```bash
# Reset kubeadm
sudo kubeadm reset -f

# Clean up networking
sudo rm -rf /etc/cni/net.d
sudo rm -rf /var/lib/cni/

# Clean up iptables
sudo iptables -F && sudo iptables -t nat -F && sudo iptables -t mangle -F
sudo iptables -X && sudo iptables -t nat -X && sudo iptables -t mangle -X

# Remove etcd data
sudo rm -rf /var/lib/etcd

# Remove kubelet data
sudo rm -rf /var/lib/kubelet

# Clean up config
rm -rf ~/.kube/config
```

## Pre-flight Checklist

Before running `kubeadm init`:

- [ ] Unique hostname set
- [ ] MAC address unique
- [ ] product_uuid unique (`cat /sys/class/dmi/id/product_uuid`)
- [ ] Swap disabled (`swapoff -a`)
- [ ] Required ports open (6443, 2379-2380, 10250-10252)
- [ ] Container runtime installed (containerd)
- [ ] br_netfilter module loaded
- [ ] net.bridge.bridge-nf-call-iptables = 1
- [ ] net.ipv4.ip_forward = 1
- [ ] kubelet, kubeadm, kubectl installed
- [ ] Time synchronized (chrony/systemd-timesyncd)

## Quick Reference

| Operation | Command |
|-----------|---------|
| Get join command | `kubeadm token create --print-join-command` |
| Check certs | `kubeadm certs check-expiration` |
| Renew certs | `kubeadm certs renew all` |
| Upgrade plan | `kubeadm upgrade plan` |
| Apply upgrade | `kubeadm upgrade apply v1.x.x` |
| Reset node | `kubeadm reset -f` |
| Upload certs | `kubeadm init phase upload-certs --upload-certs` |
