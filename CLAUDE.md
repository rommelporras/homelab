# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Kubernetes homelab learning project for CKA certification prep. 3-node HA cluster using Lenovo M80q machines (i5-10400T, 16GB RAM, 512GB NVMe each) running Ubuntu 24.04 LTS with kubeadm.

**Current Status:** 3-node HA Kubernetes cluster running (v1.35.0 with Cilium CNI).

## Single Source of Truth

**docs/context/Cluster.md** contains all canonical values (IPs, MACs, hostnames, hardware specs). Other docs reference it, don't duplicate values.

## Repository Structure

```
homelab/
├── CLAUDE.md                      # This file (Claude Code context)
├── LICENSE                        # MIT License
├── README.md                      # GitHub landing page
├── VERSIONS.md                    # Component version tracking
│
├── ansible/                       # Cluster automation
│   ├── inventory/homelab.yml      # Node inventory
│   ├── group_vars/all.yml         # Shared variables
│   └── playbooks/                 # Bootstrap playbooks (00-07)
│
├── helm/                          # Helm values files (one dir per chart)
│   ├── alloy/                     # Grafana Alloy (log collector)
│   ├── blackbox-exporter/         # Blackbox exporter (probes)
│   ├── cilium/                    # Cilium CNI
│   ├── gitlab/                    # GitLab CE
│   ├── gitlab-runner/             # GitLab Runner
│   ├── loki/                      # Loki (log storage)
│   ├── longhorn/                  # Longhorn storage
│   ├── metrics-server/            # Metrics Server
│   ├── prometheus/                # kube-prometheus-stack
│   └── tailscale-operator/        # Tailscale Operator
│
├── manifests/                     # Raw K8s manifests (non-Helm resources)
│   ├── ai/                        # Ollama LLM inference server
│   ├── browser/                   # Firefox browser (KasmVNC)
│   ├── cert-manager/              # ClusterIssuer
│   ├── cilium/                    # IP pool, L2 announcements
│   ├── cloudflare/                # Cloudflare Tunnel + network policies
│   ├── gateway/                   # Gateway + HTTPRoutes (routes/ subdir)
│   ├── ghost-dev/                 # Ghost blog dev environment
│   ├── ghost-prod/                # Ghost blog prod environment
│   ├── gitlab/                    # GitLab SSH LoadBalancer
│   ├── home/                      # AdGuard, Homepage, MySpeed
│   ├── invoicetron/               # Invoicetron app + PostgreSQL + backup
│   ├── karakeep/                  # Karakeep bookmark manager
│   ├── monitoring/                # Grafana, probes, alerts, dashboards
│   ├── network-policies/          # Namespace network policies
│   ├── portfolio/                 # Portfolio deployment + RBAC
│   ├── storage/                   # Longhorn HTTPRoute, NFS PVs
│   ├── tailscale/                 # Tailscale Operator + Connector
│   └── uptime-kuma/               # Uptime Kuma StatefulSet
│
├── scripts/                       # Operational scripts
│
└── docs/
    ├── context/                   # Knowledge base (11 topic files)
    │   ├── Cluster.md             # Source of truth (nodes, IPs, hardware)
    │   ├── Gateway.md             # HTTPRoutes, TLS, cert-manager
    │   ├── Networking.md          # VIPs, DNS, VLANs
    │   └── ...                    # Architecture, Monitoring, Storage, etc.
    ├── rebuild/                   # Step-by-step rebuild guides (v0.1.0–v0.22.0)
    ├── todo/                      # Active and completed phase plans
    ├── K8S_v135_NOTES.md          # Kubernetes v1.35 release notes
    └── reference/                 # Historical reference docs
        ├── CHANGELOG.md           # Decision history
        └── PROXMOX_OPNSENSE_GUIDE.md
```

## Cluster Quick Reference

| Item | Value |
|------|-------|
| k8s-cp1 | 10.10.30.11 |
| k8s-cp2 | 10.10.30.12 |
| k8s-cp3 | 10.10.30.13 |
| VIP | 10.10.30.10 |
| NAS | 10.10.30.4 |
| SSH | wawashi@cp{1,2,3}.k8s.rommelporras.com |

## Architecture Decisions

- **3 nodes** - etcd quorum requires 3 minimum
- **Longhorn on NVMe** - 2x replication, no extra hardware
- **kube-vip (ARP)** - VIP without OPNsense changes
- **Cilium CNI** - NetworkPolicy for CKA
- **kubeadm** - CKA exam alignment

## Documentation Guide

| When you need... | Read... |
|------------------|---------|
| Current values (IPs, MACs) | docs/context/Cluster.md |
| Component versions | VERSIONS.md |
| Why a decision was made | docs/context/Architecture.md |
| How to bootstrap cluster | docs/rebuild/v0.2.0-bootstrap.md |
| Network/switch setup | docs/context/Networking.md |
| Storage setup | docs/context/Storage.md |
| Gateway, HTTPRoutes, TLS | docs/context/Gateway.md |
| GA4, GTM, Cloudflare, SMTP | docs/context/ExternalServices.md |
| 1Password items | docs/context/Secrets.md |
| Phase plans | docs/todo/ (active) or docs/todo/completed/ (done) |
| Decision history | docs/reference/CHANGELOG.md |
| Rebuild from scratch | docs/rebuild/ (one guide per release) |

## Project Conventions

- **Phase files:** 1 service = 1 phase file in `docs/todo/`. Completed phases move to `docs/todo/completed/`.
- **Infra + docs = 2 commits:** Infrastructure commit first (`/audit-security` → `/commit`), then documentation commit (`/audit-docs` → `/commit`).
- **Observability for every new service:** PrometheusRule alerts, Grafana dashboard ConfigMap, optional Blackbox probe. Files go in `manifests/monitoring/`.
- **Timezone:** `Asia/Manila` — never use America/Chicago or UTC for user-facing configs.

## Common Commands

**IMPORTANT:** Use `kubectl-homelab` and `helm-homelab` for this cluster. Plain `kubectl`/`helm` use your work AWS EKS config.

```bash
# SSH to nodes
ssh wawashi@cp1.k8s.rommelporras.com

# Homelab Kubernetes (uses ~/.kube/homelab.yaml)
kubectl-homelab get nodes
kubectl-homelab -n longhorn-system get pods
kubectl-homelab get componentstatuses

# Homelab Helm (uses ~/.kube/homelab.yaml)
helm-homelab list -A
helm-homelab -n longhorn-system get values longhorn

# Homelab GitLab (self-hosted, glab v1.85.2)
glab api projects/0xwsh%2Fportfolio --hostname gitlab.k8s.rommelporras.com
glab auth status

# Run Ansible playbooks
cd ansible && ansible-playbook -i inventory/homelab.yml playbooks/00-preflight.yml
```

## Secrets Management

**Use 1Password CLI (`op`) for all credentials. Never hardcode secrets.**

### Vault Structure

| Vault | Purpose |
|-------|---------|
| `Kubernetes` | K8s cluster credentials (Grafana, NUT, PostgreSQL, etc.) |
| `Proxmox` | Legacy Proxmox/Dell 3090 services (do not modify) |

### Secret Reference Format

```
op://Kubernetes/<item>/<field>
```

### Usage Patterns

```bash
# Read a secret
op read "op://Kubernetes/Grafana/password"

# Use in Helm install (inject at runtime)
helm-homelab install prometheus prometheus-community/kube-prometheus-stack \
  --set grafana.adminPassword="$(op read 'op://Kubernetes/Grafana/password')"

# Create K8s secret from 1Password
kubectl-homelab create secret generic my-secret \
  --from-literal=password="$(op read 'op://Kubernetes/MyItem/password')"
```

### Existing Credentials

See **docs/context/Secrets.md** for the complete 1Password item inventory (20+ items).

### Security Rules

- **Never hardcode passwords** in values.yaml or manifests
- **Never commit secrets** to git (use `op read` at runtime)
- **Kubernetes vault only** - don't modify Proxmox vault items
- **Sign in first** - run `eval $(op signin)` if session expired

## Rules

- **Use `kubectl-homelab` and `helm-homelab` for this cluster** - Never use plain `kubectl`/`helm` as they connect to work AWS EKS. Both aliases are defined in ~/.zshrc and use ~/.kube/homelab.yaml.
- **NO AI attribution** in commits - Do not include "Generated with Claude Code", "Co-Authored-By: Claude", or any AI-related attribution in commit messages, PR descriptions, or code comments.
- **NO automatic git commits or pushes** - Do not run `git commit` or `git push` unless explicitly requested by the user or invoked via `/commit` or `/release` commands.
- **Security review before every commit** - This is a PUBLIC repository. Before committing, audit ALL changed and new files for accidentally exposed secrets (passwords, tokens, API keys, webhook URLs, email credentials, SSH keys). Use `op://` references only, never hardcoded values. Once pushed, secrets cannot be revoked by deleting the repo — they are permanently exposed.
