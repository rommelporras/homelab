---
tags: [homelab, kubernetes, networking, dns, vlan]
updated: 2026-02-16
---

# Networking

Network configuration for the homelab cluster.

## VIPs

| VIP | IP | DNS | Implementation |
|-----|-----|-----|----------------|
| K8s API | 10.10.30.10 | api.k8s.rommelporras.com | kube-vip (ARP) |
| Gateway | 10.10.30.20 | *.k8s.rommelporras.com | Cilium L2 |
| GitLab SSH | 10.10.30.21 | ssh.gitlab.k8s.rommelporras.com | Cilium L2 |
| OTel Collector | 10.10.30.22 | — | Cilium L2 |
| AdGuard DNS | 10.10.30.53 | adguard.k8s.rommelporras.com | Cilium L2 |

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
| DNS Primary | 10.10.30.53 | adguard.k8s.rommelporras.com (K8s) |
| DNS Secondary | 10.10.30.54 | fw-agh.home.rommelporras.com (FW LXC failover) |
| NAS | 10.10.30.4 | omv.home.rommelporras.com |
| NPM | 10.10.30.80 | *.home.rommelporras.com |

## DNS Records (AdGuard)

| Record | Type | Value |
|--------|------|-------|
| api.k8s.rommelporras.com | A | 10.10.30.10 |
| cp1.k8s.rommelporras.com | A | 10.10.30.11 |
| cp2.k8s.rommelporras.com | A | 10.10.30.12 |
| cp3.k8s.rommelporras.com | A | 10.10.30.13 |
| *.k8s.rommelporras.com | A | 10.10.30.20 |
| *.dev.k8s.rommelporras.com | A | 10.10.30.20 |
| *.stg.k8s.rommelporras.com | A | 10.10.30.20 |

## Service URLs

| Service | URL | Tier |
|---------|-----|------|
| Grafana | https://grafana.k8s.rommelporras.com | base |
| Longhorn | https://longhorn.k8s.rommelporras.com | base |
| AdGuard | https://adguard.k8s.rommelporras.com | base |
| Homepage | https://portal.k8s.rommelporras.com | base |
| GitLab | https://gitlab.k8s.rommelporras.com | base |
| GitLab Registry | https://registry.k8s.rommelporras.com | base |
| GitLab SSH | ssh://git@ssh.gitlab.k8s.rommelporras.com | base |
| Portfolio Dev | https://portfolio.dev.k8s.rommelporras.com | dev |
| Portfolio Staging | https://portfolio.stg.k8s.rommelporras.com | stg |
| Portfolio Prod | https://portfolio.k8s.rommelporras.com | base |
| Ghost Dev | https://blog.dev.k8s.rommelporras.com | dev |
| Ghost Prod (internal) | https://blog.k8s.rommelporras.com | base |
| Ghost Prod (public) | https://blog.rommelporras.com | — |
| Invoicetron Dev | https://invoicetron.dev.k8s.rommelporras.com | dev |
| Invoicetron Prod (internal) | https://invoicetron.k8s.rommelporras.com | base |
| Invoicetron Prod (public) | https://invoicetron.rommelporras.com | — |
| Uptime Kuma (internal) | https://uptime.k8s.rommelporras.com | base |
| Uptime Kuma (public) | https://status.rommelporras.com | — |
| MySpeed | https://myspeed.k8s.rommelporras.com | base |
| Firefox Browser | https://browser.k8s.rommelporras.com | base |
| Karakeep | https://karakeep.k8s.rommelporras.com | base |
| Prowlarr | https://prowlarr.k8s.rommelporras.com | base |
| Sonarr | https://sonarr.k8s.rommelporras.com | base |
| Radarr | https://radarr.k8s.rommelporras.com | base |
| qBittorrent | https://qbit.k8s.rommelporras.com | base |
| Jellyfin | https://jellyfin.k8s.rommelporras.com | base |
| Bazarr | https://bazarr.k8s.rommelporras.com | base |

## Tailscale (Remote Access)

| Setting | Value |
|---------|-------|
| Tailnet | `capybara-interval.ts.net` |
| MagicDNS | Enabled |
| Global Nameserver | `10.10.30.53` (K8s AdGuard via subnet route) |
| Override DNS | ON |
| Connector | `homelab-subnet` (100.109.196.53) |
| Subnet Route | `10.10.30.0/24` (auto-approved via ACL) |
| Operator | `tailscale-operator` (100.69.243.39) |
| DERP Relay | DERP-20 hkg (~31ms from Philippines) |

**Traffic flow (remote device):**
```
Phone → WireGuard tunnel → Connector Pod → AdGuard DNS (10.10.30.53)
  → Cilium Gateway (10.10.30.20) → Backend Service
```

**Key:** No per-service manifests needed. All existing HTTPRoutes work through the subnet route.

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
| Base wildcard | *.k8s.rommelporras.com |
| Dev wildcard | *.dev.k8s.rommelporras.com |
| Stg wildcard | *.stg.k8s.rommelporras.com |
| Cert secrets | wildcard-k8s-tls, wildcard-dev-k8s-tls, wildcard-stg-k8s-tls |

## Related

- [[Cluster]] - Node details
- [[Architecture]] - Why kube-vip, why Gateway API
- [[Secrets]] - Cloudflare API token
