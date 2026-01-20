---
tags: [homelab, kubernetes, index]
updated: 2026-01-20
---

# Homelab Kubernetes Context

> Personal knowledge base for 3-node HA Kubernetes homelab cluster.
> Owner: Rommel Porras | Goal: CKA by September 2026

## Quick Links

| Need | Go To |
|------|-------|
| Node IPs, hostnames | [[Cluster]] |
| Component versions | [VERSIONS.md](../../VERSIONS.md) |
| Commands, rules, patterns | [[Conventions]] |
| Why decisions were made | [[Architecture]] |
| 1Password paths | [[Secrets]] |
| VIPs, DNS, VLANs | [[Networking]] |
| HTTPRoutes, TLS, cert-manager | [[Gateway]] |
| Prometheus, Grafana, Alerting | [[Monitoring]] |
| Longhorn, NFS | [[Storage]] |
| NUT, graceful shutdown | [[UPS]] |

## Current State

| Item | Value |
|------|-------|
| Kubernetes | v1.35.0 |
| Nodes | 3 control planes (k8s-cp1, cp2, cp3) |
| CNI | Cilium 1.18.6 |
| Storage | Longhorn 1.10.1 |
| Status | Observability complete (Phase 3.9) |

## Notes

- [[Cluster]] - Hardware, nodes, IPs, namespaces
- [VERSIONS.md](../../VERSIONS.md) - Kubernetes, Helm charts, components
- [[Conventions]] - kubectl-homelab, 1Password, commit rules
- [[Architecture]] - Why 3 nodes, why Cilium, why Longhorn
- [[Secrets]] - All 1Password item paths
- [[Networking]] - API VIP, Gateway VIP, DNS records
- [[Gateway]] - HTTPRoutes, TLS certificates, adding services
- [[Monitoring]] - Prometheus stack, Loki, Alertmanager
- [[Storage]] - Longhorn settings, NFS integration
- [[UPS]] - NUT server/clients, shutdown timers

## Source

Canonical source: `homelab/docs/context/`
Maintained by: Claude Code
