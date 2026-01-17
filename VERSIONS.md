# Versions

> Component versions for the homelab infrastructure.
> **Last Updated:** January 17, 2026

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
| prometheus-community/kube-prometheus-stack | 72.6.2 | v0.81.0 | Planned | monitoring |
| grafana/loki-stack | 2.10.3 | v3.4.3 | Planned | monitoring |

**Helm Repos:**
```bash
helm-homelab repo add longhorn https://charts.longhorn.io
helm-homelab repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm-homelab repo add grafana https://grafana.github.io/helm-charts
helm-homelab repo update
```

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
| 2026-01-17 | Installed: Longhorn 1.10.1 distributed storage |
| 2026-01-16 | Added: Helm Charts section with version pinning |
| 2026-01-16 | Updated: kube-vip 0.8.x→v1.0.3, Cilium 1.16.x→1.18.6, containerd 2.0.x→1.7.x |
| 2026-01-11 | Initial version tracking |
