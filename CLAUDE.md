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
├── ansible/          # Cluster automation (inventory, group_vars, playbooks 00-08)
├── helm/             # Helm values files (one dir per chart: cilium, prometheus, loki, etc.)
├── manifests/        # Raw K8s manifests (one dir per service: arr-stack, gateway, monitoring, etc.)
├── scripts/          # Operational scripts
├── docs/context/     # Knowledge base (Cluster.md = source of truth, + 10 topic files)
├── docs/rebuild/     # Step-by-step rebuild guides per release
├── docs/todo/        # Phase plans (active + completed/)
├── docs/reference/   # CHANGELOG.md, historical docs
└── VERSIONS.md       # Component version tracking
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

```bash
# Homelab Kubernetes (uses ~/.kube/homelab.yaml)
kubectl-homelab get nodes
kubectl-homelab -n longhorn-system get pods

# Homelab Helm
helm-homelab list -A
helm-homelab -n longhorn-system get values longhorn

# Homelab GitLab (self-hosted, glab v1.85.2)
glab api projects/0xwsh%2Fportfolio --hostname gitlab.k8s.rommelporras.com

# Run Ansible playbooks
cd ansible && ansible-playbook -i inventory/homelab.yml playbooks/00-preflight.yml
```

## Secrets Management

- **Vault:** `Kubernetes` only (do not modify `Proxmox` vault). Format: `op://Kubernetes/<item>/<field>`
- **Full inventory:** see `docs/context/Secrets.md` (20+ items)
- **Never run `op` or secret-bearing `kubectl` commands** — This terminal has no `op` access. Generate the commands and ask the user to run them in their safe terminal. This includes `op read`, `op item create/edit`, and any `kubectl create secret` or `kubectl apply` that embeds secret values.

## Rules

- **Use `kubectl-homelab` and `helm-homelab` for this cluster** — Never use plain `kubectl`/`helm` as they connect to work AWS EKS. Both aliases are defined in ~/.zshrc and use ~/.kube/homelab.yaml.
- **`kubectl-homelab` is zsh-only** — Scripts and non-zsh shells must use `kubectl --kubeconfig ~/.kube/homelab.yaml` directly. The alias only works interactively.
- **This is a PUBLIC repository** — the global "security review before every commit" rule applies. Once pushed, secrets cannot be revoked.
