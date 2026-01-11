# Pre-Installation Checklist

> **Last Updated:** January 11, 2026
> **Status:** COMPLETED

---

## Overview

This checklist documents the completed setup from hardware arrival to Ubuntu installation.

**Completed:** January 11, 2026

---

## Phase 1: Hardware Verification

### Unboxing Checklist

- [x] **3x Lenovo M80q** units received
- [x] **1x LIANGUO LG-SG5T1** managed switch received
- [x] **Cat6 LAN cables** received
- [x] All items match order
- [x] No visible physical damage

### Hardware Verification (via dmidecode)

| Node | Model | Product ID | CPU |
|------|-------|------------|-----|
| k8s-cp1 | ThinkCentre M80q | 11DN0054PC | i5-10400T |
| k8s-cp2 | ThinkCentre M80q | 11DN0054PC | i5-10400T |
| k8s-cp3 | ThinkCentre M80q | 11DN0054PC | i5-10400T |

### Recorded MAC Addresses

| Node | MAC Address | IP (DHCP Reserved) |
|------|-------------|-------------------|
| k8s-cp1 | 88:a4:c2:9d:87:d6 | 10.10.30.11 |
| k8s-cp2 | 88:a4:c2:6b:1c:44 | 10.10.30.12 |
| k8s-cp3 | 88:a4:c2:64:2d:81 | 10.10.30.13 |

---

## Phase 2: BIOS Configuration

### Settings Applied (Each Node)

| Setting | Location | Value |
|---------|----------|-------|
| Virtualization | Security > Virtualization | **Enabled** |
| VT-d | Security > Virtualization | **Enabled** |
| Secure Boot | Security > Secure Boot | **Disabled** |
| Boot Mode | Startup > Boot Mode | **UEFI Only** |
| After Power Loss | Power > After Power Loss | **Power On** |

- [x] k8s-cp1 BIOS configured
- [x] k8s-cp2 BIOS configured
- [x] k8s-cp3 BIOS configured

---

## Phase 3: Switch Configuration

### VLAN Setup

| VLAN ID | Name | Network |
|---------|------|---------|
| 30 | SERVERS | 10.10.30.0/24 |
| 50 | DMZ | 10.10.50.0/24 |
| 69 | MGMT | 10.10.69.0/24 |

### Port Configuration

| Port | Device | Mode | Native VLAN | Trunk VLAN |
|------|--------|------|-------------|------------|
| 1 | k8s-cp1 | Trunk | 30 | **30,50** |
| 2 | k8s-cp2 | Trunk | 30 | **30,50** |
| 3 | k8s-cp3 | Trunk | 30 | **30,50** |
| 4 | Dell PVE | Trunk | 1 | 30,50,69 |
| 5 | OPNsense | Trunk | 1 | 30,50,69 |

**Lesson Learned:** VLAN 30 must be in Trunk VLAN list even if set as Native VLAN.

- [x] VLAN 30 created
- [x] Ports 1-3 configured for K8s nodes
- [x] Configuration saved and verified

---

## Phase 4: OPNsense Configuration

### DHCP Reservations

**Services > ISC DHCPv4 > VLAN30**

| MAC | IP | Hostname |
|-----|-----|----------|
| 88:a4:c2:9d:87:d6 | 10.10.30.11 | k8s-cp1 |
| 88:a4:c2:6b:1c:44 | 10.10.30.12 | k8s-cp2 |
| 88:a4:c2:64:2d:81 | 10.10.30.13 | k8s-cp3 |

- [x] DHCP reservations created
- [x] Reservations tested and working

---

## Phase 5: Ubuntu Installation

### Installation Settings

| Setting | k8s-cp1 | k8s-cp2 | k8s-cp3 |
|---------|--------|--------|--------|
| **Version** | 24.04.3 LTS | 24.04.3 LTS | 24.04.3 LTS |
| **Kernel** | 6.8.0 (GA) | 6.8.0 (GA) | 6.8.0 (GA) |
| **Type** | Ubuntu Server (full) | Ubuntu Server (full) | Ubuntu Server (full) |
| **Network** | DHCP (eno1) | DHCP (eno1) | DHCP (eno1) |
| **Storage** | Entire disk + LVM | Entire disk + LVM | Entire disk + LVM |
| **Filesystem** | ext4 | ext4 | ext4 |
| **Hostname** | k8s-cp1 | k8s-cp2 | k8s-cp3 |
| **Username** | wawashi | wawashi | wawashi |
| **SSH** | Installed | Installed | Installed |
| **Snaps** | None | None | None |

### Storage Layout (Each Node)

| Mount | Size | Type |
|-------|------|------|
| / | ~476GB | ext4 (LVM) |
| /boot | 2GB | ext4 |
| /boot/efi | 1GB | FAT32 |

**Fixed:** Default LVM only allocated 100GB. Manually expanded to use full disk.

- [x] k8s-cp1 Ubuntu installed
- [x] k8s-cp2 Ubuntu installed
- [x] k8s-cp3 Ubuntu installed
- [x] All nodes reboot successfully

---

## Phase 6: DNS Configuration

### AdGuard Home DNS Rewrites

| Domain | IP |
|--------|-----|
| *.home.rommelporras.com | 10.10.30.80 (NPM) |
| k8s-cp1.home.rommelporras.com | 10.10.30.11 |
| k8s-cp2.home.rommelporras.com | 10.10.30.12 |
| k8s-cp3.home.rommelporras.com | 10.10.30.13 |
| k8s-api.home.rommelporras.com | 10.10.30.10 |

- [x] DNS entries created
- [x] Resolution verified

---

## Phase 7: SSH Access

### SSH Keys Deployed

```bash
ssh-copy-id wawashi@10.10.30.11
ssh-copy-id wawashi@10.10.30.12
ssh-copy-id wawashi@10.10.30.13
```

### Verified Access

```bash
ssh wawashi@k8s-cp1.home.rommelporras.com "hostname"  # k8s-cp1
ssh wawashi@k8s-cp2.home.rommelporras.com "hostname"  # k8s-cp2
ssh wawashi@k8s-cp3.home.rommelporras.com "hostname"  # k8s-cp3
```

- [x] SSH keys copied to all nodes
- [x] Passwordless SSH working

---

## Final Verification

### Connectivity Test

```bash
# All nodes reachable
ping -c 1 10.10.30.11 && echo "cp1 ok"
ping -c 1 10.10.30.12 && echo "cp2 ok"
ping -c 1 10.10.30.13 && echo "cp3 ok"
```

### Node Status

| Check | k8s-cp1 | k8s-cp2 | k8s-cp3 |
|-------|--------|--------|--------|
| Ping gateway | OK | OK | OK |
| Ping DNS | OK | OK | OK |
| Ping internet | OK | OK | OK |
| SSH access | OK | OK | OK |
| Hostname correct | OK | OK | OK |
| IP correct | OK | OK | OK |

---

## Lessons Learned

| Issue | Cause | Solution |
|-------|-------|----------|
| DHCP not working in installer | Gateway/DNS fields not persisting | Use DHCP with OPNsense reservations |
| Nodes can't reach gateway | VLAN 30 not in Trunk VLAN list | Add VLAN to both Native AND Trunk |
| LVM only 100GB | Ubuntu installer default | Manually edit ubuntu-lv to max size |
| Interface name | Docs said enp0s31f6 | Actual is eno1 (Intel I219-LM) |
