---
tags: [homelab, kubernetes, cluster, nodes]
updated: 2026-02-18
---

# Cluster

Current state of the 3-node HA Kubernetes cluster.

## Nodes

| Node | Hostname | IP | MAC | Role |
|------|----------|-----|-----|------|
| 1 | k8s-cp1 | 10.10.30.11 | 88:a4:c2:9d:87:d6 | Control Plane |
| 2 | k8s-cp2 | 10.10.30.12 | 88:a4:c2:6b:1c:44 | Control Plane |
| 3 | k8s-cp3 | 10.10.30.13 | 88:a4:c2:64:2d:81 | Control Plane |

## Hardware (per node)

| Spec | Value |
|------|-------|
| Model | Lenovo ThinkCentre M80q |
| CPU | Intel Core i5-10400T (6c/12t) |
| RAM | 16GB DDR4 |
| Storage | 512GB NVMe |
| NIC | Intel I219-LM (1GbE) |
| iGPU | Intel UHD Graphics 630 (Comet Lake) |
| GPU Driver | intel-media-va-driver-non-free (iHD 24.1.0) |
| GPU Device | /dev/dri/renderD128 |
| HuC Firmware | enable_guc=2 (kbl_huc_4.0.0.bin) |
| Interface | eno1 |

## DNS Names

| DNS | IP |
|-----|-----|
| cp1.k8s.rommelporras.com | 10.10.30.11 |
| cp2.k8s.rommelporras.com | 10.10.30.12 |
| cp3.k8s.rommelporras.com | 10.10.30.13 |
| api.k8s.rommelporras.com | 10.10.30.10 (VIP) |

## SSH Access

```bash
# Username
wawashi

# By hostname
ssh wawashi@cp1.k8s.rommelporras.com
ssh wawashi@cp2.k8s.rommelporras.com
ssh wawashi@cp3.k8s.rommelporras.com
```

## Namespaces

| Namespace | Purpose |
|-----------|---------|
| kube-system | Control plane, Cilium, metrics-server |
| longhorn-system | Longhorn storage |
| monitoring | Prometheus, Grafana, Loki, Alloy |
| cert-manager | TLS certificate management |
| cloudflare | Cloudflare Tunnel (cloudflared) |
| cilium-secrets | Cilium TLS secrets |
| home | Home services (AdGuard, Homepage, MySpeed) |
| gitlab | GitLab CE (web, gitaly, registry, sidekiq) |
| gitlab-runner | GitLab Runner (CI/CD pipelines) |
| portfolio-dev | Portfolio dev environment |
| portfolio-staging | Portfolio staging environment |
| portfolio-prod | Portfolio production environment |
| ghost-dev | Ghost blog dev environment |
| ghost-prod | Ghost blog production environment |
| invoicetron-dev | Invoicetron dev environment |
| invoicetron-prod | Invoicetron production environment |
| uptime-kuma | Uptime Kuma endpoint monitoring |
| browser | Containerized Firefox browser (KasmVNC) |
| ai | Ollama LLM inference server |
| karakeep | Karakeep bookmark manager (web, Chrome, Meilisearch) |
| tailscale | Tailscale Operator (subnet router, DNS) |
| arr-stack | ARR media stack (Prowlarr, Sonarr, Radarr, qBittorrent, Jellyfin, Bazarr, Seerr, Configarr, Unpackerr, Scraparr, Tdarr, Recommendarr, Byparr) |
| node-feature-discovery | NFD (auto-labels GPU nodes) |
| intel-device-plugins | Intel GPU Plugin Operator + GPU Plugin DaemonSet |

## Hardware Inventory & Cost

All prices in Philippine Pesos (₱) with USD approximate at ₱58 ≈ $1 (Feb 2026).

### Kubernetes Nodes

| Item | Qty | ₱ Each | ₱ Total | $ Total |
|------|-----|--------|---------|---------|
| Lenovo M80q (i5-10400T, 16GB, 512GB NVMe) | 3 | 6,000 | 18,000 | ~$310 |

All nodes are stock — no upgrades.

### Supporting Infrastructure

| Item | Specs | ₱ | $ |
|------|-------|---|---|
| Dell OptiPlex 3090 (base) | i5-10500T, 16GB stock | 6,000 | ~$103 |
| + 16GB DDR4 RAM stick | Total 32GB | 1,500 | ~$26 |
| + 1TB Enterprise SSD | Boot drive | 2,000 | ~$34 |
| + WD_BLACK SN850x 2TB NVMe | NAS storage | 7,000 | ~$121 |
| + 2.5GbE NIC | Network upgrade | 1,000 | ~$17 |
| **Dell 3090 subtotal** | | **17,500** | **~$302** |
| Topton N100 | 16GB RAM, Proxmox + OPNsense | 9,500 | ~$164 |
| CyberPower UPS | CP1600EPFCLCD, 1600VA/1000W | 8,669 | ~$149 |
| LIANGUO LG-SG5T1 switch | 5x 2.5GbE + 10G SFP+ | 1,369 | ~$24 |
| TP-Link Archer A6 | OpenWRT, VLAN WiFi (purchased ~2017) | 2,000 | ~$34 |
| TP-Link Archer AX1500 | Backup WiFi (purchased ~2020) | 2,590 | ~$45 |

### Total Investment

| | ₱ | $ |
|---|---|---|
| **Total Hardware** | **₱59,628** | **~$1,028** |

### Monthly Operating Cost

| Item | ₱/mo | $/mo |
|------|------|------|
| Electricity (~100W avg, all devices) | ~₱1,000 | ~$17 |
| Cloudflare (free tier) | ₱0 | $0 |
| Tailscale (free personal plan) | ₱0 | $0 |
| Domain (rommelporras.com) | ~₱58 | ~$1 |
| **Total** | **~₱1,058** | **~$18** |

The ~100W electricity covers all devices: 3 K8s nodes, Dell 3090, Topton firewall, UPS, managed switch, 2 WiFi APs, and 2 ISP modems.

## System

| Setting | Value |
|---------|-------|
| OS | Ubuntu 24.04.3 LTS |
| Kernel | 6.8.0-90-generic |
| Container Runtime | containerd 1.7.x |
| IP Assignment | DHCP with OPNsense reservations |

## Related

- [[Networking]] - VIPs, VLANs
- [[Versions]] - Component versions
- [[Conventions]] - SSH and kubectl usage
