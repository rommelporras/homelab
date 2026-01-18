# Versions

> Component versions for the homelab infrastructure.
> **Last Updated:** January 18, 2026

---

## Core Infrastructure (Stable)

| Component | Version | Role |
|-----------|---------|------|
| Proxmox VE | 9.1.4 | Hypervisor (2 nodes) |
| OPNsense | 25.7.5 | Firewall / Router |
| OpenMediaVault | 7.6.0-1 | NAS / NFS Storage |

---

## Kubernetes Cluster

| Component | Version | Status |
|-----------|---------|--------|
| Ubuntu Server | 24.04.3 LTS | Installed |
| Kernel | 6.8.0-71-generic | Installed |
| Kubernetes | v1.35.0 | Running (3 nodes) |
| containerd | 1.7.x | Installed |
| Cilium | 1.18.6 | Installed |
| Cilium CLI | v0.19.0 | Installed |
| Longhorn | 1.10.1 | Installed |
| kube-vip | v1.0.3 | Installed |

---

## Helm Charts

> **Why version pin?** Helm charts update independently of the apps they install.
> Running `helm install` without `--version` gives you "latest" which may break things.

| Chart | Version | App Version | Status | Namespace |
|-------|---------|-------------|--------|-----------|
| longhorn/longhorn | 1.10.1 | v1.10.1 | Installed | longhorn-system |
| cilium/cilium | 1.18.6 | v1.18.6 | Installed | kube-system |
| oci://quay.io/jetstack/charts/cert-manager | 1.19.2 | v1.19.2 | Installed | cert-manager |
| prometheus-community/kube-prometheus-stack | 81.0.0 | v0.82.0 | Planned | monitoring |
| grafana/loki | 6.49.0 | v3.6.3 | Planned | monitoring |
| grafana/alloy | 1.5.2 | v1.12.x | Planned | monitoring |
| gitlab/gitlab | 8.7.0 | v17.7.0 | Planned | gitlab |
| gitlab/gitlab-runner | 0.71.0 | v17.7.0 | Planned | gitlab-runner |

> **Note:** `grafana/loki-stack` is deprecated (Promtail EOL March 2026).
> Use `grafana/loki` + `grafana/alloy` instead.
>
> **Note:** cert-manager uses OCI registry (recommended by upstream).
> No `helm repo add` needed - install directly from `oci://quay.io/jetstack/charts/cert-manager`.

**Helm Repos:**
```bash
helm-homelab repo add longhorn https://charts.longhorn.io
helm-homelab repo add cilium https://helm.cilium.io/
helm-homelab repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm-homelab repo add grafana https://grafana.github.io/helm-charts
helm-homelab repo add gitlab https://charts.gitlab.io
helm-homelab repo update
# Note: cert-manager uses OCI - no repo add needed
```

---

## Gateway API

> **Why Gateway API?** Ingress is deprecated (NGINX Ingress EOL March 2026).
> Cilium has native Gateway API support - no need for Traefik or NGINX.

| Component | Version | Status |
|-----------|---------|--------|
| Gateway API CRDs | v1.4.1 | Installed |
| Cilium gatewayAPI.enabled | true | Installed |
| Cilium kubeProxyReplacement | true | Installed |
| Cilium L2 Announcements | true | Installed |
| Homelab Gateway | 10.10.30.20 | Installed |
| kube-proxy | N/A | Removed (Cilium eBPF replaces) |

---

## Cluster Nodes

| Node | Role | IP | Hardware |
|------|------|-----|----------|
| k8s-cp1 | Control Plane | 10.10.30.11 | M80q i5-10400T |
| k8s-cp2 | Control Plane | 10.10.30.12 | M80q i5-10400T |
| k8s-cp3 | Control Plane | 10.10.30.13 | M80q i5-10400T |

**VIP:** 10.10.30.10 (k8s-api.home.rommelporras.com)

---

## Version History

| Date | Change |
|------|--------|
| 2026-01-18 | Removed: kube-proxy (Cilium eBPF kube-proxy replacement now handles all services) |
| 2026-01-18 | Installed: Gateway API CRDs v1.4.1, Cilium Gateway, cert-manager v1.19.2 (OCI) |
| 2026-01-18 | Installed: Homelab Gateway (10.10.30.20) with Let's Encrypt wildcard TLS |
| 2026-01-18 | Enabled: Cilium L2 announcements, kubeProxyReplacement |
| 2026-01-18 | Updated: Gateway API v1.2.0→v1.4.1, Loki 6.24.0→6.49.0, Alloy 0.12.0→1.5.2 |
| 2026-01-18 | Added: GitLab, GitLab Runner Helm charts for CI/CD platform |
| 2026-01-17 | Added: Gateway API section, cert-manager, Loki, Alloy charts |
| 2026-01-17 | Removed: loki-stack (deprecated, Promtail EOL March 2026) |
| 2026-01-17 | Updated: kube-prometheus-stack 72.6.2→81.0.0 (current stable) |
| 2026-01-17 | Installed: Longhorn 1.10.1 distributed storage |
| 2026-01-16 | Added: Helm Charts section with version pinning |
| 2026-01-16 | Updated: kube-vip 0.8.x→v1.0.3, Cilium 1.16.x→1.18.6, containerd 2.0.x→1.7.x |
| 2026-01-11 | Initial version tracking |
