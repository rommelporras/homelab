# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Kubernetes homelab learning project for CKA certification prep. 3-node HA cluster using Lenovo M80q machines (i5-10400T, 16GB RAM, 512GB NVMe each) running Ubuntu 24.04 LTS with kubeadm.

**Current Status:** 3-node HA Kubernetes cluster running (v1.35.0 with Cilium CNI).

## Single Source of Truth

**docs/CLUSTER_STATUS.md** contains all canonical values (IPs, MACs, hostnames, hardware specs). Other docs reference it, don't duplicate values.

## Repository Structure

```
homelab/
├── CLAUDE.md                      # This file (Claude Code context)
├── LICENSE                        # MIT License
├── README.md                      # GitHub landing page
├── TODO.md                        # Bootstrap progress tracker
├── VERSIONS.md                    # Component version tracking
│
├── ansible/                       # Cluster automation
│   ├── inventory/homelab.yml      # Node inventory
│   ├── group_vars/all.yml         # Shared variables
│   └── playbooks/                 # Bootstrap playbooks (00-07)
│
├── helm/                          # Helm values files (GitOps-friendly)
│   └── longhorn/values.yaml       # Longhorn distributed storage
│
├── manifests/                     # Raw K8s manifests (non-Helm resources)
│   └── storage/                   # PV/PVC for NFS, etc.
│
└── docs/
    ├── 00_PROJECT_CONTEXT.md      # Project orientation / quick reference
    ├── ARCHITECTURE.md            # Design decisions (why)
    ├── CLUSTER_STATUS.md          # Source of truth (nodes, IPs, hardware)
    ├── EXISTING_INFRA.md          # Dell 3090 NAS integration
    ├── K8S_LEARNING_GUIDE.md      # CKA study material
    ├── K8S_v135_NOTES.md          # Kubernetes v1.35 features
    ├── KUBEADM_BOOTSTRAP.md       # Cluster bootstrap commands
    ├── NETWORK_INTEGRATION.md     # Network, switch, VLANs, kube-vip
    ├── ROADMAP.md                 # Timeline, CKA schedule
    ├── STORAGE_SETUP.md           # Longhorn installation
    │
    └── reference/                 # Historical reference docs
        ├── CHANGELOG.md           # Decision history
        ├── PRE_INSTALLATION_CHECKLIST.md
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
| Current values (IPs, MACs) | docs/CLUSTER_STATUS.md |
| Component versions | VERSIONS.md |
| Why a decision was made | docs/ARCHITECTURE.md |
| How to bootstrap cluster | docs/KUBEADM_BOOTSTRAP.md |
| Network/switch setup | docs/NETWORK_INTEGRATION.md |
| Storage setup | docs/STORAGE_SETUP.md |
| Project timeline | docs/ROADMAP.md |

## Common Commands

**IMPORTANT:** Use `kubectl-homelab` and `helm-homelab` for this cluster. Plain `kubectl`/`helm` use work AWS EKS config.

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

| Item | Vault | Used By |
|------|-------|---------|
| `Grafana` | Kubernetes | Phase 3.5 monitoring |

### Rules

- **Never hardcode passwords** in values.yaml or manifests
- **Never commit secrets** to git (use `op read` at runtime)
- **Kubernetes vault only** - don't modify Proxmox vault items
- **Sign in first** - run `eval $(op signin)` if session expired

## Rules

- **Use `kubectl-homelab` and `helm-homelab` for this cluster** - Never use plain `kubectl`/`helm` as they connect to work AWS EKS. Both aliases are defined in ~/.zshrc and use ~/.kube/homelab.yaml.
- **NO AI attribution** in commits - Do not include "Generated with Claude Code", "Co-Authored-By: Claude", or any AI-related attribution in commit messages, PR descriptions, or code comments.
- **NO automatic git commits or pushes** - Do not run `git commit` or `git push` unless explicitly requested by the user or invoked via `/commit` or `/release` commands.
