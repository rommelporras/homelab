# Existing Proxmox Infrastructure

> **Status:** Production
> **Purpose:** Context for Kubernetes migration

This documents the existing Proxmox-based homelab that predates the Kubernetes cluster. Containerized workloads will migrate to K8s for HA; infrastructure services remain on Proxmox.

---

## Architecture Overview

```
Internet (Dual WAN) → OPNsense Firewall → VLAN Segmentation
                                              │
                      ┌───────────────────────┼───────────────────────┐
                      │                       │                       │
               ┌──────┴──────┐         ┌──────┴──────┐         ┌──────┴──────┐
               │  Firewall   │         │  PVE Node   │         │  OpenWRT    │
               │    Node     │         │   (Dell)    │         │     AP      │
               │  (Topton)   │         │             │         │             │
               └─────────────┘         └─────────────┘         └─────────────┘
```

---

## Hardware

| Component | Model | Role |
|-----------|-------|------|
| Firewall Host | Topton N100 (6-port) | Proxmox + OPNsense VM |
| Application Server | Dell OptiPlex 5090 | Main Proxmox host, NAS |
| Access Point | TP-Link Archer A6 | OpenWRT with VLAN tagging |
| UPS | APC (via PeaNUT) | Battery backup with monitoring |

---

## Proxmox Nodes

### Firewall Node (Topton N100)
- **VMs:** OPNsense (firewall/router)
- **LXC:** AdGuard Home (DNS filtering)
- **Purpose:** Network edge, dual-WAN failover

### PVE Node (Dell 5090)
- **VMs:** 4 running
- **LXC:** 6 running
- **Purpose:** Application hosting, NAS

---

## Running Services

### Infrastructure
| Service | Type | Purpose |
|---------|------|---------|
| OPNsense | VM | Firewall, routing, dual-WAN |
| OpenMediaVault | VM | NAS, NFS/SMB shares |
| AdGuard Home (x2) | LXC | DNS ad-blocking (redundant) |

### Applications
| Service | Type | Purpose |
|---------|------|---------|
| Immich | Docker | Photo/video management (~22k photos, 343 GiB) |
| Nginx Proxy Manager | LXC | Reverse proxy (11 hosts) |
| Karakeep | Docker | Bookmark management |
| Homepage | LXC | Dashboard |

### Monitoring
| Service | Purpose |
|---------|---------|
| PeaNUT | UPS monitoring |
| MySpeed | Internet speed testing |
| Tailscale | Remote access mesh VPN |

---

## Network Design

### Security Features
- VLAN segmentation (Management, Servers, DMZ, IoT, Guest, WiFi)
- Dual-WAN with automatic failover
- Split-brain DNS for internal services
- Network-wide ad blocking via AdGuard Home

### Performance
- ~940 Mbit/s download, ~860 Mbit/s upload
- Sub-2ms DNS latency (local)
- 600k+ ads blocked (PVE AdGuard)

---

## Migration to Kubernetes

### Moving to K8s (for HA)
- Immich → Multi-replica deployment
- Karakeep → Stateless workload
- Homepage → Simple deployment

### Staying on Proxmox
- OPNsense (network infrastructure)
- OpenMediaVault (NFS backend for K8s)
- AdGuard Home (DNS infrastructure)

### Integration Points
- NFS shares from OMV → Kubernetes PVCs
- DNS resolution via OPNsense/AdGuard
- Reverse proxy migration to Ingress controller (later)

---

## Lessons Learned

1. **VLAN isolation works** - IoT devices properly sandboxed
2. **Dual AdGuard is overkill** - Will consolidate post-K8s
3. **NFS is reliable** - Good foundation for K8s storage
4. **Proxmox is solid** - But manual HA; K8s automates this

---

*For detailed setup steps, see personal Obsidian vault.*
