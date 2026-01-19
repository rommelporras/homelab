# Versions

> Component versions for the homelab infrastructure.
> **Last Updated:** January 20, 2026

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
| oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack | 81.0.0 | v0.88.0 | Installed | monitoring |
| oci://ghcr.io/grafana/helm-charts/loki | 6.49.0 | v3.6.3 | Installed | monitoring |
| grafana/alloy | 1.5.2 | v1.12.2 | Installed | monitoring |
| gitlab/gitlab | 8.7.0 | v17.7.0 | Planned | gitlab |
| gitlab/gitlab-runner | 0.71.0 | v17.7.0 | Planned | gitlab-runner |

> **Note:** `grafana/loki-stack` is deprecated (Promtail EOL March 2026).
> Use `grafana/loki` + `grafana/alloy` instead.
>
> **Note:** cert-manager, kube-prometheus-stack, and Loki use OCI registry (recommended by upstream).
> No `helm repo add` needed - install directly from OCI URLs.
>
> **Note:** Grafana Alloy doesn't support OCI yet. Uses traditional Helm repo (`grafana`).

**Helm Repos:**
```bash
helm-homelab repo add longhorn https://charts.longhorn.io
helm-homelab repo add cilium https://helm.cilium.io/
helm-homelab repo add grafana https://grafana.github.io/helm-charts
helm-homelab repo add gitlab https://charts.gitlab.io
helm-homelab repo update
# Note: cert-manager and kube-prometheus-stack use OCI - no repo add needed
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

## UPS Monitoring (NUT)

> **Why NUT over PeaNUT?** PeaNUT has no data persistence (resets on refresh).
> NUT + Prometheus + Grafana provides 90-day history, alerting, and correlation with cluster metrics.

| Component | Version | Status | Location |
|-----------|---------|--------|----------|
| NUT (Network UPS Tools) | 2.8.1 | Installed | k8s-cp1 (server), cp2/cp3 (clients) |
| nut-exporter (DRuggeri) | 3.1.1 | Installed | monitoring namespace |
| CyberPower UPS | CP1600EPFCLCD | Connected | USB to k8s-cp1 |
| UPS Dashboard | custom | Installed | ConfigMap auto-provisioned |

**Staggered Shutdown Timers:**
| Node | Timer | Trigger |
|------|-------|---------|
| k8s-cp3 | 10 min | First to shutdown (reduce load) |
| k8s-cp2 | 20 min | Second to shutdown |
| k8s-cp1 | Low Battery | Last (sends UPS power-off) |

**Kubelet Graceful Shutdown:**
- `shutdownGracePeriod: 120s`
- `shutdownGracePeriodCriticalPods: 30s`

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
| 2026-01-20 | Added: docs/rebuild/ - split rebuild guides by release tag (v0.1.0 to v0.4.0) |
| 2026-01-20 | Added: Custom UPS Grafana dashboard with ConfigMap auto-provisioning |
| 2026-01-20 | Fixed: ServiceMonitor relabeling adds `ups=cyberpower` label to all NUT metrics |
| 2026-01-20 | Installed: NUT 2.8.1 for UPS monitoring (k8s-cp1 server, cp2/cp3 clients) |
| 2026-01-20 | Installed: nut-exporter 3.1.1 (DRuggeri) for Prometheus UPS metrics |
| 2026-01-20 | Added: PrometheusRule with 8 UPS alerts (battery, load, status) |
| 2026-01-20 | Configured: Staggered shutdown timers (cp3: 10m, cp2: 20m, cp1: LB) |
| 2026-01-20 | Configured: Kubelet graceful shutdown (120s grace, 30s critical) |
| 2026-01-20 | Added: 1Password items for NUT credentials (NUT Admin, NUT Monitor) |
| 2026-01-19 | Added: ServiceMonitors for Loki and Alloy (Prometheus now scrapes logging stack) |
| 2026-01-19 | Added: PrometheusRule with 7 alerts for logging pipeline health |
| 2026-01-19 | Added: K8s events collection to Alloy (query with `{source="kubernetes_events"}`) |
| 2026-01-19 | Updated: Alloy memory limit 128Mi→256Mi for events collection |
| 2026-01-19 | Installed: Loki v3.6.3 (SingleBinary mode, 90-day retention, Longhorn storage) |
| 2026-01-19 | Installed: Grafana Alloy v1.12.2 (DaemonSet, K8s API log collection) |
| 2026-01-18 | Installed: kube-prometheus-stack v81.0.0 (Prometheus, Grafana, Alertmanager, node-exporter) |
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
