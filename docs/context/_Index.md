---
tags: [homelab, kubernetes, index]
updated: 2026-02-18
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
| GA4, GTM, Cloudflare, Tailscale, SMTP | [[ExternalServices]] |

## Current State

| Item | Value |
|------|-------|
| Kubernetes | v1.35.0 |
| Nodes | 3 control planes (k8s-cp1, cp2, cp3) |
| CNI | Cilium 1.18.6 |
| Storage | Longhorn 1.10.1 |
| Status | Phase 4.26 complete (v0.25.2 released) |

## Source

Canonical source: `homelab/docs/context/`
