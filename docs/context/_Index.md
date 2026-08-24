---
tags: [homelab, kubernetes, index]
updated: 2026-07-10
---

# Homelab Kubernetes Context

> Personal knowledge base for 3-node HA Kubernetes homelab cluster.
> Owner: Rommel Porras | Goal: CKA by September 2026

## Quick Links

| Need | Go To |
|------|-------|
| 🔴 Something is broken (start here - usable with no AI) | [docs/runbooks/00-EMERGENCY.md](../runbooks/00-EMERGENCY.md) |
| 🟢 How to do routine tasks (deploy, add a service, secrets, ArgoCD) | [docs/operations/](../operations/) |
| 🗺️ Full documentation map | [docs/README.md](../README.md) |
| Node IPs, hostnames | [[Cluster]] |
| Physical layout, power tree, console access | [Hardware](Hardware.md) |
| GPU / Intel device plugin / NFD | [GPU-and-Device-Plugins](GPU-and-Device-Plugins.md) |
| Component versions | [VERSIONS.md](../../VERSIONS.md) |
| Commands, rules, patterns | [[Conventions]] |
| Why decisions were made | [[Architecture]] |
| 1Password paths | [[Secrets]] |
| VIPs, DNS, VLANs | [[Networking]] |
| HTTPRoutes, TLS, cert-manager | [[Gateway]] |
| Prometheus, Grafana, Alerting | [[Monitoring]] |
| Longhorn, NFS | [[Storage]] |
| NUT, graceful shutdown | [[UPS]] |
| Upgrade/rollback procedures | [[Upgrades]] |
| PSS, ESO hardening, SA tokens | [[Security]] |
| GA4, GTM, Cloudflare, Tailscale, SMTP | [[ExternalServices]] |
| Alert triage, NVMe reseat, Argo Workflows runbook | [docs/runbooks/](../runbooks/) |

## Current State

| Item | Value |
|------|-------|
| Kubernetes | v1.35.0 |
| Nodes | 3 control planes (k8s-cp1, cp2, cp3) |
| CNI | Cilium 1.19.2 |
| Storage | Longhorn 1.11.1 |
| Status | v0.39.2 (Argo Events CI/CD) released; next target v1.0.0 (CKA-ready) |

## Source

Canonical source: `homelab/docs/context/`
