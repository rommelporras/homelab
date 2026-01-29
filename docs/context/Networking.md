---
tags: [homelab, kubernetes, networking, dns, vlan]
updated: 2026-01-25
---

# Networking

Network configuration for the homelab cluster.

## VIPs

| VIP | IP | DNS | Implementation |
|-----|-----|-----|----------------|
| K8s API | 10.10.30.10 | k8s-api.home.rommelporras.com | kube-vip (ARP) |
| Gateway | 10.10.30.20 | *.k8s.home.rommelporras.com | Cilium L2 |
| GitLab SSH | 10.10.30.21 | ssh.gitlab.k8s.home.rommelporras.com | Cilium L2 |
| AdGuard DNS | 10.10.30.53 | adguard.k8s.home.rommelporras.com | Cilium L2 |

## Node IPs

| Node | IP | MAC |
|------|-----|-----|
| k8s-cp1 | 10.10.30.11 | 88:a4:c2:9d:87:d6 |
| k8s-cp2 | 10.10.30.12 | 88:a4:c2:6b:1c:44 |
| k8s-cp3 | 10.10.30.13 | 88:a4:c2:64:2d:81 |

## Infrastructure IPs

| Resource | IP | DNS |
|----------|-----|-----|
| Gateway | 10.10.30.1 | — |
| DNS Primary | 10.10.30.53 | adguard.k8s.home.rommelporras.com (K8s) |
| DNS Secondary | 10.10.30.54 | fw-agh.home.rommelporras.com (FW LXC failover) |
| NAS | 10.10.30.4 | omv.home.rommelporras.com |
| NPM | 10.10.30.80 | *.home.rommelporras.com |

## DNS Records (AdGuard)

| Record | Type | Value |
|--------|------|-------|
| k8s-api.home.rommelporras.com | A | 10.10.30.10 |
| k8s-cp1.home.rommelporras.com | A | 10.10.30.11 |
| k8s-cp2.home.rommelporras.com | A | 10.10.30.12 |
| k8s-cp3.home.rommelporras.com | A | 10.10.30.13 |
| *.k8s.home.rommelporras.com | A | 10.10.30.20 |

## Service URLs

| Service | URL |
|---------|-----|
| Grafana | https://grafana.k8s.home.rommelporras.com |
| Longhorn | https://longhorn.k8s.home.rommelporras.com |
| AdGuard | https://adguard.k8s.home.rommelporras.com |
| Homepage | https://portal.k8s.home.rommelporras.com |
| GitLab | https://gitlab.k8s.home.rommelporras.com |
| GitLab Registry | https://registry.k8s.home.rommelporras.com |
| GitLab SSH | ssh://git@ssh.gitlab.k8s.home.rommelporras.com |
| Portfolio Dev | https://portfolio-dev.k8s.home.rommelporras.com |
| Portfolio Staging | https://portfolio-staging.k8s.home.rommelporras.com |
| Portfolio Prod | https://portfolio-prod.k8s.home.rommelporras.com |

## VLAN Configuration

| VLAN ID | Name | Network | Purpose |
|---------|------|---------|---------|
| 10 | LAN | 10.10.10.0/24 | Default network |
| 20 | TRUSTED | 10.10.20.0/24 | Workstations |
| 30 | SERVERS | 10.10.30.0/24 | K8s nodes, services |
| 40 | IOT | 10.10.40.0/24 | Smart devices (internet-only) |
| 50 | DMZ | 10.10.50.0/24 | Legacy public-facing services |
| 60 | GUEST | 10.10.60.0/24 | Visitor WiFi (isolated) |
| 69 | MGMT | 10.10.69.0/24 | Infrastructure management |
| 70 | AP_TRUNK | — | WiFi AP trunking (all WiFi VLANs) |

## Switch

| Setting | Value |
|---------|-------|
| Model | LIANGUO LG-SG5T1 |
| Ports | 5x 2.5GbE + 1x 10G SFP+ |
| Management IP | 10.10.69.3 |

| Port | Device | Native VLAN | Trunk VLANs |
|------|--------|-------------|-------------|
| 1 | k8s-cp1 | 30 | 30, 50 |
| 2 | k8s-cp2 | 30 | 30, 50 |
| 3 | k8s-cp3 | 30 | 30, 50 |
| 4 | Dell PVE | 1 | 30, 50, 69 |
| 5 | OPNsense | 1 | 30, 50, 69 |

**Lesson:** VLAN must be in Trunk list even if set as Native VLAN.

## Cilium Configuration

| Setting | Value |
|---------|-------|
| kubeProxyReplacement | true |
| gatewayAPI.enabled | true |
| l2announcements.enabled | true |
| IP Pool | 10.10.30.20-99 (Gateway at .20, AdGuard at .53) |

## TLS

| Setting | Value |
|---------|-------|
| Issuer | Let's Encrypt (production) |
| Challenge | DNS-01 via Cloudflare |
| Wildcard | *.k8s.home.rommelporras.com |

## Related

- [[Cluster]] - Node details
- [[Architecture]] - Why kube-vip, why Gateway API
- [[Secrets]] - Cloudflare API token
