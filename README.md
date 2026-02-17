# Kubernetes Homelab

![License](https://img.shields.io/badge/license-MIT-blue)
![Status](https://img.shields.io/badge/status-Cluster%20Running-brightgreen)
![Kubernetes](https://img.shields.io/badge/kubernetes-v1.35-326CE5?logo=kubernetes&logoColor=white)
![Cilium](https://img.shields.io/badge/cilium-1.18.6-F8C517?logo=cilium&logoColor=white)
![Ubuntu](https://img.shields.io/badge/ubuntu-24.04-E95420?logo=ubuntu&logoColor=white)
![Alertmanager](https://healthchecks.io/badge/e8a6a1d7-c42b-428a-901e-5f28d9/EOi8irKL.svg)

3-node HA Kubernetes cluster on bare-metal Lenovo M80q machines, built from scratch with kubeadm for CKA certification prep. Zero-to-production in 6 weeks — 24 releases, each with a [complete rebuild guide](docs/rebuild/README.md).

> **Owner:** Rommel Porras  |  **CKA Target:** September 2026

---

## Architecture

```
                                    Internet
                                       |
                                  (Dual WAN)
                                       |
                      +----------------+----------------+
                      |   Firewall Node (Topton N100)   |
                      |   OPNsense VM · AdGuard LXC     |
                      +----------------+----------------+
                                       |
                              VLAN 30 · 2.5GbE
     +------------------+--------------+------+------------------+
     |                  |                     |                  |
+----+-----+       +----+-----+         +----+-----+     +------+------+
|  k8s-cp1 |       |  k8s-cp2 |         |  k8s-cp3 |     |  Dell 3090  |
|   M80q   |       |   M80q   |         |   M80q   |     |  (Proxmox)  |
|i5-10400T |       |i5-10400T |         |i5-10400T |     +-------------+
+----------+       +----------+         +----------+     | OMV NAS     |
| Control  |       | Control  |         | Control  |     | Immich VM   |
| + etcd   |       | + etcd   |         | + etcd   |     | NPM LXC     |
| + Work   |       | + Work   |         | + Work   |     | Test VMs    |
+----------+       +----------+         +----------+     +------+------+
| Longhorn |       | Longhorn |         | Longhorn |            |
| (NVMe)   |       | (NVMe)   |         | (NVMe)   |            |
+----+-----+       +----+-----+         +----+-----+            |
     |                  |                    |                  |
     +---- Sync (2x replication) -----------+                   |
                        |                                       |
                        +--------------- NFS -------------------+
```

| Device | Role | Spec |
|--------|------|------|
| 3x Lenovo M80q | Kubernetes nodes | i5-10400T (6c/12t), 16GB DDR4, 512GB NVMe |
| 1x Topton N100 | Firewall (Proxmox) | OPNsense VM + AdGuard LXC (DNS failover) |
| 1x Dell 3090 | PVE + NAS (Proxmox) | OMV (NFS), Immich, NPM, test VMs |

### Traffic Flow

```
Public       -->  Cloudflare Tunnel (HA)  -->  Gateway API  -->  Services
Remote       -->  Tailscale VPN (WireGuard)  -->  Subnet Route  -->  Services
LAN / VLANs  -->  AdGuard DNS  -->  Cilium L2 VIP  -->  Gateway API  -->  Services
```

---

## What's Running

**Platform**
- Kubernetes v1.35 (kubeadm) with Cilium CNI (eBPF, no kube-proxy)
- Longhorn distributed storage (2x replication across NVMe)
- kube-vip HA VIP (ARP mode, Prometheus monitoring)
- Gateway API + cert-manager (Let's Encrypt wildcard TLS)
- Ansible-automated bootstrap ([8 playbooks](ansible/playbooks/))

**Observability**
- Prometheus + Grafana + Loki + Alloy (full metrics, logs, dashboards)
- Alertmanager (Discord + Email, severity routing)
- Dead Man's Switch (healthchecks.io), Blackbox probes, UPS monitoring (NUT)
- Uptime Kuma (public [status page](https://status.rommelporras.com))

**Networking & Access**
- Cloudflare Tunnel (HA, 2 replicas) for public services
- Tailscale Operator (WireGuard subnet router) for private remote access
- AdGuard DNS as primary for all VLANs + Tailscale global nameserver
- CiliumNetworkPolicies per namespace

**Applications**
- GitLab CE (Runner, Container Registry, SSH) with CI/CD pipelines
- Ghost Blog (dev/prod, MySQL, Tinybird analytics, Cloudflare Tunnel)
- ARR Media Stack (Prowlarr, Sonarr, Radarr, qBittorrent, Jellyfin, Bazarr)
- Ollama (CPU-only LLM: qwen3, moondream, gemma3)
- Karakeep (bookmark manager with Ollama AI tagging + Meilisearch)
- Portfolio (Next.js, 3-env GitLab CI/CD: dev/staging/prod)
- Invoicetron (Next.js + PostgreSQL, Cloudflare Access)
- Homepage dashboard, MySpeed, Firefox browser (KasmVNC)

---

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| **Bootstrap** | kubeadm (not k3s/Talos) | CKA exam alignment |
| **CNI** | Cilium (eBPF) | Replaces kube-proxy, native Gateway API, NetworkPolicy for CKA |
| **Storage** | Longhorn on NVMe | Full HA from day one, no extra hardware |
| **VIP** | kube-vip (ARP mode) | No OPNsense changes needed |
| **Ingress** | Gateway API (not NGINX) | Ingress is deprecated, Cilium has native support |
| **Remote access** | Tailscale Connector (not per-service Ingress) | 1 pod routes entire subnet, zero per-service manifests |
| **Secrets** | 1Password CLI (`op read`) | Runtime injection, never committed to git |

---

## Lessons Learned

Things that bit us and might save you time:

- **Cilium + Tailscale incompatibility** — `socketLB.hostNamespaceOnly: true` is required when using Cilium with `kubeProxyReplacement: true` alongside Tailscale. Without it, eBPF socket-level load balancing intercepts traffic inside proxy pod namespaces, silently breaking WireGuard routing.

- **Ghost `__` env var convention** — Ghost uses double underscores for nested config (`mail__options__auth__pass`). Flat env vars like `MAIL_OPTIONS_AUTH_PASS` are silently ignored. Also, Ghost does NOT proxy `/.ghost/analytics/` — you need a separate sidecar (Caddy or TrafficAnalytics).

- **Cloudflare free SSL wildcard depth** — Free plans only cover `*.rommelporras.com`, NOT `*.blog.rommelporras.com`. We use single-level subdomains like `blog-api.rommelporras.com` for analytics endpoints to stay on the free tier.

- **Rebuild guides as a pattern** — Every release (v0.1.0 through v0.23.0) has a [complete rebuild guide](docs/rebuild/README.md). If the cluster dies, we can rebuild everything from scratch by following the guides in order. This also serves as living documentation that never goes stale.

- **CiliumNetworkPolicy vs forwarded traffic** — CiliumNetworkPolicy filters forwarded/routed packets, not just local pod traffic. This means a network policy on a Tailscale Connector pod will break subnet routing entirely. Only apply policies to the operator, not the proxy.

---

## Documentation

| Document | Purpose |
|----------|---------|
| [docs/context/Cluster.md](docs/context/Cluster.md) | **Source of truth** — nodes, IPs, hardware |
| [docs/rebuild/](docs/rebuild/README.md) | Step-by-step rebuild guides (24 releases, v0.1.0 to v0.24.0) |
| [docs/context/](docs/context/) | Knowledge base (11 topic files: Architecture, Gateway, Networking, etc.) |
| [docs/todo/](docs/todo/README.md) | Phase plans (active + [completed](docs/todo/completed/)) |
| [docs/reference/CHANGELOG.md](docs/reference/CHANGELOG.md) | Decision history and project timeline |
| [VERSIONS.md](VERSIONS.md) | Component versions, Helm charts, HTTPRoutes |

---

## Next Steps

1. **ARR Companions** — Configarr, Unpackerr, Scraparr (Phase 4.26)
2. **Version Automation** — Upgrade runbooks and automated version tracking (Phase 4.27)
3. **CKA Certification** — September 2026 target
