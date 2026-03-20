---
tags: [homelab, kubernetes, networking, dns, vlan, network-policies]
updated: 2026-03-17
---

# Networking

Network configuration for the homelab cluster.

## VIPs

| VIP | IP | DNS | Implementation |
|-----|-----|-----|----------------|
| K8s API | 10.10.30.10 | api.k8s.rommelporras.com | kube-vip (ARP) |
| Gateway | 10.10.30.20 | *.k8s.rommelporras.com | Cilium L2 |
| GitLab SSH | 10.10.30.21 | ssh.gitlab.k8s.rommelporras.com | Cilium L2 |
| OTel Collector | 10.10.30.22 | - | Cilium L2 |
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
| Gateway | 10.10.30.1 | - |
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
| Prometheus | https://prometheus.k8s.rommelporras.com | base |
| Alertmanager | https://alertmanager.k8s.rommelporras.com | base |
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
| Ghost Prod (public) | https://blog.rommelporras.com | - |
| Invoicetron Dev | https://invoicetron.dev.k8s.rommelporras.com | dev |
| Invoicetron Prod (internal) | https://invoicetron.k8s.rommelporras.com | base |
| Invoicetron Prod (public) | https://invoicetron.rommelporras.com | - |
| Uptime Kuma (internal) | https://uptime.k8s.rommelporras.com | base |
| Uptime Kuma (public) | https://status.rommelporras.com | - |
| MySpeed | https://myspeed.k8s.rommelporras.com | base |
| Firefox Browser | https://browser.k8s.rommelporras.com | base |
| Karakeep | https://karakeep.k8s.rommelporras.com | base |
| Prowlarr | https://prowlarr.k8s.rommelporras.com | base |
| Sonarr | https://sonarr.k8s.rommelporras.com | base |
| Radarr | https://radarr.k8s.rommelporras.com | base |
| qBittorrent | https://qbit.k8s.rommelporras.com | base |
| Jellyfin | https://jellyfin.k8s.rommelporras.com | base |
| Bazarr | https://bazarr.k8s.rommelporras.com | base |
| Seerr | https://seerr.k8s.rommelporras.com | base |
| Tdarr | https://tdarr.k8s.rommelporras.com | base |
| Recommendarr | https://recommendarr.k8s.rommelporras.com | base |
| Loki | https://loki.k8s.rommelporras.com | base |
| Vault | https://vault.k8s.rommelporras.com | base |
| Atuin | https://atuin.k8s.rommelporras.com | base |

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
| 70 | AP_TRUNK | - | WiFi AP trunking (all WiFi VLANs) |

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

## CiliumNetworkPolicy Traffic Matrix (Phase 5.3)

CiliumNetworkPolicies across 24 namespaces + 1 CiliumClusterwideNetworkPolicy.
See [[Security]] for policy strategy, Cilium identity reference, and known limitations.

### Cluster-Wide

| Policy | Scope | Rule |
|--------|-------|------|
| allow-gateway-ingress-egress | CiliumClusterwideNetworkPolicy | Gateway `reserved:ingress` egress to all cluster pods |

### Infrastructure Namespaces

| Namespace | Ingress From | Egress To |
|-----------|-------------|-----------|
| external-secrets | monitoring (8080), kube-apiserver (443 webhook), host (8081) | kube-dns, kube-apiserver (6443), vault (8200) |
| vault | ESO ns (8200), monitoring (8200), Gateway (8200), home (8200), unsealer+snapshot (8200/8201) | kube-dns, kube-apiserver (6443) |
| cert-manager | monitoring (9402), kube-apiserver (10250 webhook), host (controller:9403, cainjector:9402, webhook:6080) | kube-dns, kube-apiserver (6443), FQDN: Let's Encrypt + Cloudflare API (443) |
| monitoring | intra-namespace (all), Gateway (grafana:3000, prometheus:9090, alertmanager:9093, loki:3100), OTel: world+host+remote-node+cluster (4317/4318) | intra-namespace, DNS, cluster (Prometheus scrape), kube-apiserver, remote-node (kube-vip:2112, NUT:3493), FQDN: Alertmanager SMTP/Discord/healthchecks, blackbox: internet+cluster+LAN, version-checker: internet (443) |
| kube-system | (CronJobs only) | cluster-janitor: DNS + kube-apiserver (6443) + internet HTTPS (Discord). cert-expiry-check: DNS + internet HTTPS (Discord) only |

### Application Namespaces

| Namespace | Ingress From | Egress To |
|-----------|-------------|-----------|
| home (AdGuard) | LAN 10.10.0.0/16 + host/remote-node/world (53 UDP/TCP), monitoring (53), Gateway (3000), host, uptime-kuma (3000) | **L4-only** (no toPorts): kube-dns, upstream DNS (0.0.0.0/0), internet (443/80) |
| home (Homepage) | Gateway (3000), uptime-kuma (3000), host | **L4-only** (no toPorts): kube-dns, kube-apiserver, cluster, host+remote-node (Gateway hairpin + node exporters), LAN (10.10.0.0/16), internet (443) |
| home (MySpeed) | Gateway (5216), host, uptime-kuma (5216) | kube-dns, internet (443/80/8080 speedtest) |
| ghost-dev | Gateway (2368), host | DNS (with FQDN inspection), MySQL (3306), FQDN: SMTP smtp.mail.me.com (587) |
| ghost-prod | Gateway (2368), cloudflare (2368), monitoring (2368), host | DNS (with FQDN inspection), MySQL (3306), ghost-analytics (3000), FQDN: SMTP (587) |
| invoicetron-dev | Gateway (3000), host | DNS, invoicetron-db (5432) |
| invoicetron-prod | Gateway (3000), cloudflare (3000), monitoring (3000), host | DNS, invoicetron-db (5432). Backup CronJob: DNS + DB (5432) |
| portfolio-dev | Gateway (80), monitoring (80), host | DNS only |
| portfolio-staging | Gateway (80), cloudflare (80), monitoring (80), host | DNS only |
| portfolio-prod | Gateway (80), cloudflare (80), monitoring (80), host | DNS only |
| browser | Gateway (3000), host | DNS, internet (world entity) |
| uptime-kuma | Gateway (3001), cloudflare (3001), monitoring (3001), host | DNS, internet (443/80), monitoring (3000), home (3000/5216), longhorn (8000), ghost-dev/prod (2368), Gateway (toServices), LAN IPs (NPM/OPNsense/NAS:443/80), NAS Glances (61208) |
| arr-stack | Gateway (9 HTTPRoutes), monitoring, host, intra-namespace | DNS, intra-namespace, internet (indexers/torrents), NAS NFS (2049), ai/ollama (11434) |
| gitlab | Gateway (webservice:8181, registry:5000), gitlab-runner (8181/8080/5000), monitoring (metrics), LAN + host/remote-node/world (SSH:2222), host, intra-namespace | DNS, intra-namespace, kube-apiserver, internet (webhooks:443/80/587) |
| gitlab-runner | monitoring (9252), host | DNS, kube-apiserver, internet (443/80), gitlab ns (8181/8080/5000) |
| ai | monitoring, karakeep, arr-stack (11434), host | DNS, internet (443 model downloads) |
| karakeep | intra-namespace, Gateway, monitoring, host | DNS, intra-namespace, ai/ollama (11434), internet (chrome web scraping:443/80) |
| atuin | intra-namespace, Gateway, monitoring, host | DNS, intra-namespace, NAS NFS (2049 backup) |
| tailscale | kube-apiserver, host | DNS, kube-apiserver, internet (Tailscale coordination) |
| cloudflare | monitoring (2000), host (2000) | DNS, Cloudflare edge (443/7844 TCP+UDP), portfolio-staging/prod (80), ghost-prod (2368/3000), invoicetron-prod (3000), uptime-kuma (3001) |
| vault (unsealer) | (no inbound services) | DNS, vault (8200), kube-apiserver |
| vault (snapshot) | (no inbound services) | DNS, vault (8200), NAS NFS (2049) |

### Key Cross-Namespace Flows

```
monitoring  --> all namespaces     (Prometheus scrape, blackbox probes)
cloudflare  --> portfolio, ghost, invoicetron, uptime-kuma  (Cloudflare Tunnel proxy)
uptime-kuma --> home, monitoring, ghost, longhorn  (health monitoring)
home        --> vault (8200)       (Homepage widget)
gitlab-runner --> gitlab (8181/5000)  (CI/CD API + registry)
arr-stack   --> ai (11434)         (Recommendarr -> Ollama)
karakeep    --> ai (11434)         (AI tagging -> Ollama)
```

### Cilium Identity Gotchas (from Phase 5.3)

**CRITICAL - LoadBalancer ingress:** All LoadBalancer ingress policies MUST include
`fromEntities: [host, remote-node, world]` alongside `fromCIDRSet`. Cilium LB rewrites
the source identity on incoming traffic. `fromCIDRSet` alone appears to work because
Cilium conntrack entries from before the policy carry existing flows through. After ~34h
when conntrack expires, new connections are silently dropped. Affected services: AdGuard
DNS (10.10.30.53), GitLab SSH (10.10.30.21), OTel Collector (10.10.30.22).

| What you want | Wrong approach | Right approach |
|---------------|---------------|----------------|
| Reach k8s nodes (NUT, node-exporter, kube-vip) | `toCIDR: 10.10.30.11/32` | `toEntities: [remote-node]` |
| Reach pods in other namespaces | `toCIDR: 10.244.0.0/16` | `toEndpoints` or `toEntities: [cluster]` |
| Reach Gateway LB VIP from pods | `toCIDR: 10.10.30.20/32` | L4-only policy (no toPorts) - L7 envoy interferes |
| Accept external LoadBalancer traffic | `fromCIDRSet` only | Add `fromEntities: [host, remote-node, world]` (conntrack masks bug for ~34h) |
| Reach external LAN IPs (NAS, NPM, router) | (works correctly) | `toCIDR: 10.10.30.4/32` etc. |
| Avoid L7 envoy proxy interference | Policy with `toPorts` | Remove `toPorts` (L4-only) for critical services |

### Deferred (no CiliumNetworkPolicy)

longhorn-system, intel-device-plugins, node-feature-discovery - high breakage risk, low attack surface.

## Related

- [[Cluster]] - Node details
- [[Architecture]] - Why kube-vip, why Gateway API
- [[Security]] - Network policy strategy, Cilium identity reference, known limitations
- [[Secrets]] - Cloudflare API token
