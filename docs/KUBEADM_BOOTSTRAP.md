# kubeadm Cluster Bootstrap Guide

> **Last Updated:** January 20, 2026
> **Status:** Complete — Cluster running
> **Kubernetes Version:** v1.35.x
> **Target OS:** Ubuntu Server 24.04.3 LTS
> **Node details:** See [CLUSTER_STATUS.md](CLUSTER_STATUS.md)
> **Official Reference:** [kubernetes.io/docs/setup/production-environment/tools/kubeadm/](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/)

This guide contains the **project-specific commands** to bootstrap your 3-node HA cluster, validated against official Kubernetes v1.35 documentation.

---

## Quick Reference

| Item | Value |
|------|-------|
| **First control plane** | k8s-cp1 (10.10.30.11) |
| **Additional control planes** | k8s-cp2 (.12), k8s-cp3 (.13) |
| **VIP** | 10.10.30.10 (api.k8s.rommelporras.com) |
| **CNI** | Cilium |
| **Pod CIDR** | 10.244.0.0/16 |
| **Service CIDR** | 10.96.0.0/12 |

---

## Phase 0: Pre-flight Checks (All Nodes)

Run these checks on **all 3 nodes** before starting.

### 0.1 Verify cgroup v2

Kubernetes v1.35 requires cgroup v2. Ubuntu 24.04 uses it by default.

```bash
stat -fc %T /sys/fs/cgroup/
# Expected output: cgroup2fs
# If you see "tmpfs", you're on cgroup v1 - DO NOT PROCEED
```

### 0.2 Verify Network Interface

Find your primary network interface name:

```bash
ip link | grep -E "^[0-9]:" | awk -F: '{print $2}' | tr -d ' '
# M80q with Intel I219-LM should show: eno1
# Note this for kube-vip setup later
```

### 0.3 Verify DNS Resolution

```bash
# VIP hostname must resolve
nslookup api.k8s.rommelporras.com
# Should return: 10.10.30.10

# All nodes must be resolvable
ping -c 1 k8s-cp1.home.rommelporras.com
ping -c 1 k8s-cp2.home.rommelporras.com
ping -c 1 k8s-cp3.home.rommelporras.com
```

### 0.4 Verify Connectivity Between Nodes

```bash
# From each node, verify you can reach the others
ping -c 1 10.10.30.11  # k8s-cp1
ping -c 1 10.10.30.12  # k8s-cp2
ping -c 1 10.10.30.13  # k8s-cp3
```

---

## Required Ports Reference

Ensure these ports are open between nodes (OPNsense firewall rules):

| Port | Protocol | Purpose | Used By |
|------|----------|---------|---------|
| 6443 | TCP | Kubernetes API | All |
| 2379-2380 | TCP | etcd client/peer | Control plane |
| 10250 | TCP | Kubelet API | All |
| 10259 | TCP | kube-scheduler | Control plane |
| 10257 | TCP | kube-controller-manager | Control plane |

---

## Phase 1: Prerequisites (All Nodes)

Run these on **all 3 nodes** (k8s-cp1, k8s-cp2, k8s-cp3).

### 1.1 System Updates

```bash
sudo apt update && sudo apt upgrade -y
```

### 1.2 Disable Swap

```bash
# Disable immediately
sudo swapoff -a

# Disable permanently
sudo sed -i '/ swap / s/^/#/' /etc/fstab

# Verify
free -h | grep Swap  # Should show 0
```

### 1.3 Load Kernel Modules

```bash
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

# Verify
lsmod | grep -E "overlay|br_netfilter"
```

### 1.4 Configure sysctl

```bash
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system

# Verify
sysctl net.ipv4.ip_forward  # Should show 1
```

### 1.5 Install containerd

```bash
# Install containerd
sudo apt install -y containerd

# Check installed version
containerd --version
# Note: Ubuntu 24.04 ships containerd 1.7.x
# K8s v1.35 supports 1.7.x but recommends 2.0+ for future versions

# Generate default config
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null

# Enable systemd cgroup driver (CRITICAL for cgroup v2!)
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# Restart and enable
sudo systemctl restart containerd
sudo systemctl enable containerd

# VERIFY - All three checks must pass:
echo "=== Verification ==="

# 1. Service running
sudo systemctl is-active containerd
# Expected: active

# 2. SystemdCgroup enabled
grep -i "SystemdCgroup = true" /etc/containerd/config.toml && echo "SystemdCgroup: OK"
# Expected: SystemdCgroup = true

# 3. Socket exists
ls -la /run/containerd/containerd.sock
# Expected: socket file exists
```

> **Note:** If you see containerd 2.x in the future, the config path for SystemdCgroup changes.
> Check `/etc/containerd/config.toml` structure matches your version.

### 1.6 Install kubeadm, kubelet, kubectl

```bash
# Remove any conflicting snap packages (Ubuntu may have these)
sudo snap remove kubectl kubeadm kubelet 2>/dev/null || true

# Install prerequisites
sudo apt install -y apt-transport-https ca-certificates curl gpg

# Create keyrings directory (may not exist)
sudo mkdir -p -m 755 /etc/apt/keyrings

# Download Kubernetes signing key
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.35/deb/Release.key | \
    sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

# Add Kubernetes apt repository
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.35/deb/ /' | \
    sudo tee /etc/apt/sources.list.d/kubernetes.list

# Install Kubernetes components
sudo apt update
sudo apt install -y kubelet kubeadm kubectl

# Hold versions to prevent accidental upgrades
sudo apt-mark hold kubelet kubeadm kubectl

# Enable kubelet (it will crashloop until kubeadm init, that's normal)
sudo systemctl enable kubelet

# Verify installation
echo "=== Verification ==="
kubeadm version
kubectl version --client
kubelet --version
```

### 1.7 Install open-iscsi (Longhorn Prereq)

```bash
sudo apt install -y open-iscsi
sudo systemctl enable --now iscsid
```

---

## Phase 2: Set Up kube-vip (k8s-cp1 Only)

Run on **k8s-cp1** only, **before** kubeadm init.

```bash
# Verify your network interface (should be eno1 for M80q Intel NIC)
ip -br link | grep -v lo
# Look for interface with state UP

# Set variables
export VIP=10.10.30.10
export INTERFACE=eno1  # Adjust if your interface differs
export KVVERSION=v1.0.3  # Check latest: https://github.com/kube-vip/kube-vip/releases

echo "Using VIP: $VIP on interface: $INTERFACE with kube-vip: $KVVERSION"

# Pull kube-vip image
sudo ctr image pull ghcr.io/kube-vip/kube-vip:${KVVERSION}

# Create manifest directory
sudo mkdir -p /etc/kubernetes/manifests

# Generate kube-vip manifest
sudo ctr run --rm --net-host ghcr.io/kube-vip/kube-vip:${KVVERSION} vip \
    /kube-vip manifest pod \
    --interface $INTERFACE \
    --address $VIP \
    --controlplane \
    --arp \
    --leaderElection | sudo tee /etc/kubernetes/manifests/kube-vip.yaml

# Verify manifest was created
cat /etc/kubernetes/manifests/kube-vip.yaml | head -20

# K8s 1.29+ workaround: Use super-admin.conf during bootstrap
# IMPORTANT: Only change hostPath.path, NOT volumeMount.mountPath!
# kube-vip v1.0.3 expects kubeconfig at /etc/kubernetes/admin.conf inside container
sudo sed -i 's|path: /etc/kubernetes/admin.conf|path: /etc/kubernetes/super-admin.conf|' \
    /etc/kubernetes/manifests/kube-vip.yaml

# Verify workaround applied (hostPath should show super-admin.conf)
grep -A1 "hostPath:" /etc/kubernetes/manifests/kube-vip.yaml
# Verify mountPath still shows admin.conf (where kube-vip expects it)
grep "mountPath:" /etc/kubernetes/manifests/kube-vip.yaml
```

> **Note:** kube-vip won't start until kubeadm init creates the required certificates.
> After kubeadm init succeeds, revert to admin.conf (see Phase 3.3).

---

## Phase 3: Initialize First Control Plane (k8s-cp1)

### 3.1 Create kubeadm Config

```bash
cat <<EOF | sudo tee /etc/kubernetes/kubeadm-config.yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: "10.10.30.11"
  bindPort: 6443
nodeRegistration:
  name: k8s-cp1
  criSocket: unix:///var/run/containerd/containerd.sock
  # No taints - workloads run on control plane nodes
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: "v1.35.0"
controlPlaneEndpoint: "api.k8s.rommelporras.com:6443"
networking:
  podSubnet: "10.244.0.0/16"
  serviceSubnet: "10.96.0.0/12"
apiServer:
  certSANs:
    - "api.k8s.rommelporras.com"
    - "10.10.30.10"
    - "10.10.30.11"
    - "10.10.30.12"
    - "10.10.30.13"
    - "k8s-cp1"
    - "k8s-cp2"
    - "k8s-cp3"
etcd:
  local:
    dataDir: /var/lib/etcd
EOF
```

### 3.2 Initialize Cluster

```bash
sudo kubeadm init --config=/etc/kubernetes/kubeadm-config.yaml --upload-certs
```

**Save the output!** It contains:
- Certificate key (for joining control planes)
- Join command (for joining nodes)

### 3.3 Revert kube-vip to admin.conf

After kubeadm init succeeds, revert the K8s 1.29+ workaround (hostPath only):

```bash
# Revert hostPath from super-admin.conf to admin.conf
sudo sed -i 's|path: /etc/kubernetes/super-admin.conf|path: /etc/kubernetes/admin.conf|' \
    /etc/kubernetes/manifests/kube-vip.yaml

# Verify hostPath now uses admin.conf
grep -A1 "hostPath:" /etc/kubernetes/manifests/kube-vip.yaml
# Should show: path: /etc/kubernetes/admin.conf
```

### 3.4 Configure kubectl

```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

### 3.5 Verify VIP

```bash
# Test VIP responds
ping -c 3 10.10.30.10

# Test API via VIP
curl -k https://10.10.30.10:6443/healthz
```

---

## Phase 4: Install Cilium CNI

Without a CNI, nodes stay in `NotReady` state. Cilium provides networking + NetworkPolicy (needed for CKA).

```bash
# Install Cilium CLI (latest stable)
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
echo "Installing Cilium CLI: ${CILIUM_CLI_VERSION}"

curl -L --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-amd64.tar.gz{,.sha256sum}
sha256sum --check cilium-linux-amd64.tar.gz.sha256sum
sudo tar xzvfC cilium-linux-amd64.tar.gz /usr/local/bin
rm cilium-linux-amd64.tar.gz cilium-linux-amd64.tar.gz.sha256sum

# Verify CLI installed
cilium version --client

# Check available Cilium versions (optional)
# cilium install --list-versions

# Install Cilium (1.18.x is latest stable, works with K8s 1.35 via backward compatibility)
cilium install --version 1.18.6

# Wait for Cilium to be ready (may take 2-3 minutes)
cilium status --wait

# Verify all Cilium pods are running
kubectl get pods -n kube-system -l k8s-app=cilium

# Run connectivity test (optional but recommended)
# cilium connectivity test
```

> **Tip:** If `cilium status` shows issues, check: `kubectl -n kube-system logs -l k8s-app=cilium`

---

## Phase 5: Join Additional Control Planes

Run on **k8s-cp2** and **k8s-cp3**.

### 5.1 Get Join Command

From k8s-cp1:

```bash
# Generate new certificate key if needed
sudo kubeadm init phase upload-certs --upload-certs

# Get join command
kubeadm token create --print-join-command
```

### 5.2 Join as Control Plane

On k8s-cp2 and k8s-cp3:

```bash
# Use the join command from above, adding --control-plane and --certificate-key
sudo kubeadm join api.k8s.rommelporras.com:6443 \
    --token <token> \
    --discovery-token-ca-cert-hash sha256:<hash> \
    --control-plane \
    --certificate-key <cert-key>
```

### 5.3 Configure kubectl on Joined Nodes

```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

---

## Phase 6: Verify Cluster

```bash
# All nodes Ready
kubectl get nodes
# NAME      STATUS   ROLES           AGE   VERSION
# k8s-cp1   Ready    control-plane   10m   v1.35.0
# k8s-cp2   Ready    control-plane   5m    v1.35.0
# k8s-cp3   Ready    control-plane   3m    v1.35.0

# All pods Running
kubectl get pods -A

# etcd members (should show 3)
kubectl -n kube-system exec -it etcd-k8s-cp1 -- etcdctl \
    --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    member list -w table

# Cilium status
cilium status
```

---

## Phase 7: Copy kubeconfig to Workstation

From your workstation:

```bash
mkdir -p ~/.kube
scp wawashi@k8s-cp1.home.rommelporras.com:~/.kube/config ~/.kube/config

# Edit to use VIP instead of node IP
sed -i 's/10.10.30.11/10.10.30.10/' ~/.kube/config

# Test
kubectl get nodes
```

---

## Troubleshooting

### kubeadm init Fails

```bash
# Check containerd
sudo systemctl status containerd

# Check kubelet logs
sudo journalctl -xeu kubelet

# Reset and retry
sudo kubeadm reset -f
sudo rm -rf /etc/kubernetes /var/lib/etcd
```

### Node Won't Join

```bash
# On the joining node, check kubelet
sudo journalctl -xeu kubelet

# Verify DNS resolution
nslookup api.k8s.rommelporras.com

# Verify VIP is reachable
ping 10.10.30.10
curl -k https://10.10.30.10:6443/healthz
```

### Pods Stuck in Pending

```bash
# Check if CNI is installed
kubectl get pods -n kube-system | grep cilium

# Check node conditions
kubectl describe nodes | grep -A5 "Conditions"
```

---

## Next Steps

After cluster is running:

1. **Install Longhorn** — See [STORAGE_SETUP.md](STORAGE_SETUP.md)
2. **Configure NFS mounts** — For media from Dell 3090
3. **Deploy first workloads** — Start with simple apps

---

## Quick Commands Reference

> **Note:** From your workstation, use `kubectl-homelab` instead of `kubectl` to avoid hitting work EKS.

```bash
# Cluster info
kubectl-homelab cluster-info

# Node status
kubectl-homelab get nodes -o wide

# All pods
kubectl-homelab get pods -A

# Events
kubectl-homelab get events -A --sort-by=.lastTimestamp

# etcd health
kubectl-homelab -n kube-system exec etcd-k8s-cp1 -- etcdctl endpoint health

# Drain node for maintenance
kubectl-homelab drain k8s-cp1 --ignore-daemonsets --delete-emptydir-data

# Uncordon node
kubectl-homelab uncordon k8s-cp1
```
