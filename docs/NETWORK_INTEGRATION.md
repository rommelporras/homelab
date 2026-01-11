# Network Integration Guide

> **Last Updated:** January 11, 2026
> **Status:** Configured and Verified
> **Node/IP details:** See [CLUSTER_STATUS.md](CLUSTER_STATUS.md)

---

## Network Topology

```
┌─────────────┐      ┌─────────────────────────┐
│  OPNsense   │      │    LIANGUO Switch       │
│  Firewall   │      │      LG-SG5T1           │
│  Port 4     │──────│ Port 5 (Trunk)          │
│ (enp4s0)    │      ├─────────────────────────┤
└─────────────┘      │ Port 1 → k8s-cp1        │
                     │ Port 2 → k8s-cp2        │
                     │ Port 3 → k8s-cp3        │
                     │ Port 4 → Dell PVE       │
                     └─────────────────────────┘
```

---

## Physical Cabling

| Cable | From | To |
|-------|------|-----|
| 1 | OPNsense Port 4 | Switch Port 5 |
| 2 | Switch Port 1 | k8s-cp1 |
| 3 | Switch Port 2 | k8s-cp2 |
| 4 | Switch Port 3 | k8s-cp3 |
| 5 | Switch Port 4 | Dell PVE |

---

## VLAN Configuration

| VLAN ID | Name | Network | Purpose |
|---------|------|---------|---------|
| 30 | SERVERS | 10.10.30.0/24 | K8s nodes, services |
| 50 | DMZ | 10.10.50.0/24 | Future public-facing |
| 69 | MGMT | 10.10.69.0/24 | Infrastructure management |

---

## Switch Port Configuration

> **Note:** Full IP/MAC details in [CLUSTER_STATUS.md](CLUSTER_STATUS.md)

**Switch Model:** LIANGUO LG-SG5T1 (5x 2.5GbE + 1x 10G SFP+)
**Management:** http://10.10.69.3 (Chrome recommended)

| Port | Device | Native VLAN | Trunk VLAN | Speed |
|------|--------|-------------|------------|-------|
| 1 | k8s-cp1 | 30 | **30,50** | 1GbE |
| 2 | k8s-cp2 | 30 | **30,50** | 1GbE |
| 3 | k8s-cp3 | 30 | **30,50** | 1GbE |
| 4 | Dell PVE | 1 | 30,50,69 | 2.5GbE |
| 5 | OPNsense | 1 | 30,50,69 | 2.5GbE |

### Critical Lesson Learned

**VLAN must be in Trunk VLAN list even if set as Native VLAN.**

**Symptom:** Nodes could not reach gateway. "Destination Host Unreachable."

**Solution:** Add VLAN 30 to Trunk VLAN list (not just Native VLAN).

---

## DNS Configuration

### AdGuard Home DNS Rewrites

| Domain | Answer | Purpose |
|--------|--------|---------|
| *.home.rommelporras.com | 10.10.30.80 | NPM wildcard |
| k8s-cp1.home.rommelporras.com | 10.10.30.11 | Direct override |
| k8s-cp2.home.rommelporras.com | 10.10.30.12 | Direct override |
| k8s-cp3.home.rommelporras.com | 10.10.30.13 | Direct override |
| k8s-api.home.rommelporras.com | 10.10.30.10 | VIP override |

### DNS Resolution Flow

```
Web Services (grafana, longhorn, etc.):
  User → DNS → NPM (*.wildcard) → K8s Ingress

Infrastructure (SSH, K8s API):
  User → DNS → Direct IP (specific overrides)
```

---

## kube-vip Setup (Pending)

kube-vip provides a Virtual IP (VIP) for the Kubernetes API server.

### VIP Details

| Setting | Value |
|---------|-------|
| VIP | 10.10.30.10 |
| DNS | k8s-api.home.rommelporras.com |
| Mode | ARP (Layer 2) |
| Interface | eno1 |

### Setup Steps (Before kubeadm init)

On **k8s-cp1** only:

```bash
# Set environment variables
export VIP=10.10.30.10
export INTERFACE=eno1

# Pull kube-vip image
sudo ctr image pull ghcr.io/kube-vip/kube-vip:v0.8.0

# Create manifest directory
sudo mkdir -p /etc/kubernetes/manifests

# Generate kube-vip manifest
sudo ctr run --rm --net-host ghcr.io/kube-vip/kube-vip:v0.8.0 vip \
    /kube-vip manifest pod \
    --interface $INTERFACE \
    --address $VIP \
    --controlplane \
    --arp \
    --leaderElection | sudo tee /etc/kubernetes/manifests/kube-vip.yaml
```

### After kubeadm init

```bash
# Test VIP is responding
ping 10.10.30.10

# Test API server via VIP
curl -k https://10.10.30.10:6443/healthz
```

---

## Verification Commands

### Check Node Network

```bash
# Interface status
ip addr show eno1

# Routing table
ip route

# DNS resolution
resolvectl status
```

### Test Connectivity

```bash
# Gateway
ping -c 2 10.10.30.1

# Other nodes (from any node)
ping -c 2 10.10.30.11
ping -c 2 10.10.30.12
ping -c 2 10.10.30.13

# DNS
ping -c 2 k8s-cp1.home.rommelporras.com

# Internet
ping -c 2 google.com
```

### Check from Workstation

```bash
# Ping all nodes
for i in 11 12 13; do ping -c 1 10.10.30.$i && echo "✓"; done

# SSH test
ssh wawashi@k8s-cp1.home.rommelporras.com "hostname"
```

---

## Troubleshooting

### Node Can't Get IP

1. Check cable connection
2. Verify switch port is in correct VLAN
3. Check OPNsense DHCP is running for VLAN 30
4. Verify DHCP reservation exists

### Nodes Can't Ping Each Other

1. Verify all nodes are on same VLAN
2. Check Trunk VLAN includes VLAN 30 (lesson learned!)
3. Verify no firewall rules blocking

### VIP Not Responding

1. Check kube-vip pod: `sudo crictl ps | grep kube-vip`
2. Check logs: `sudo crictl logs $(sudo crictl ps -q --name kube-vip)`
3. Verify interface name matches in manifest

### Cannot Access Switch Management

1. Verify you're on VLAN 69 (10.10.69.x/24)
2. Check gateway is 10.10.69.1
3. Use Chrome (Arc has UI issues)
4. Factory reset via pinhole if locked out (restores to 192.168.2.1)

---

## Related Documents

- [CLUSTER_STATUS.md](CLUSTER_STATUS.md) — Node IPs, MACs, switch port mapping
- [ARCHITECTURE.md](ARCHITECTURE.md) — Why kube-vip over HAProxy
- [KUBEADM_BOOTSTRAP.md](KUBEADM_BOOTSTRAP.md) — Cluster initialization
