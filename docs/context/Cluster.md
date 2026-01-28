---
tags: [homelab, kubernetes, cluster, nodes]
updated: 2026-01-28
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
| Interface | eno1 |

## DNS Names

| DNS | IP |
|-----|-----|
| k8s-cp1.home.rommelporras.com | 10.10.30.11 |
| k8s-cp2.home.rommelporras.com | 10.10.30.12 |
| k8s-cp3.home.rommelporras.com | 10.10.30.13 |
| k8s-api.home.rommelporras.com | 10.10.30.10 (VIP) |

## SSH Access

```bash
# Username
wawashi

# By hostname
ssh wawashi@k8s-cp1.home.rommelporras.com
ssh wawashi@k8s-cp2.home.rommelporras.com
ssh wawashi@k8s-cp3.home.rommelporras.com
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
| home | Home services (AdGuard, Homepage) |
| gitlab | GitLab CE (web, gitaly, registry, sidekiq) |
| gitlab-runner | GitLab Runner (CI/CD pipelines) |
| portfolio-dev | Portfolio dev environment |
| portfolio-staging | Portfolio staging environment |
| portfolio-prod | Portfolio production environment |

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
