---
tags: [homelab, kubernetes, conventions, rules]
updated: 2026-03-28
---

# Conventions

Rules and patterns for working with this homelab cluster.

## kubectl and helm

**CRITICAL:** Use `kubectl-homelab` and `helm-homelab`, NOT plain `kubectl`/`helm`.

| Command | Uses | Purpose |
|---------|------|---------|
| `kubectl-homelab` | ~/.kube/homelab-claude.yaml | Homelab cluster (restricted: read-only, no secret get) |
| `kubectl` | ~/.kube/config | Work AWS EKS (DO NOT USE) |
| `helm-homelab` | ~/.kube/homelab.yaml | Homelab Helm |
| `helm` | ~/.kube/config | Work AWS EKS (DO NOT USE) |

```bash
# Correct
kubectl-homelab get nodes
helm-homelab list -A

# WRONG - hits work cluster
kubectl get nodes
helm list -A
```

## 1Password CLI

All secrets stored in 1Password. Never hardcode.

```bash
# Sign in first
eval $(op signin)

# Read a secret
op read "op://Kubernetes/Grafana/password"

# Use in Helm
helm-homelab upgrade prometheus ... \
  --set grafana.adminPassword="$(op read 'op://Kubernetes/Grafana/password')"
```

See [[Secrets]] for all 1Password paths.

## Git Commits

- **NO AI attribution** - Never include "Generated with Claude", "Co-Authored-By: Claude" in commits
- **NO automatic commits** - Only commit when explicitly requested
- Use conventional commits: `feat:`, `fix:`, `docs:`, `infra:`

## Repository Structure

```
homelab/
├── helm/                    # Helm values files
│   ├── alloy/values.yaml
│   ├── blackbox-exporter/values.yaml
│   ├── cilium/values.yaml
│   ├── gitlab/values.yaml
│   ├── gitlab-runner/values.yaml
│   ├── loki/values.yaml
│   ├── longhorn/values.yaml
│   ├── metrics-server/values.yaml
│   ├── prometheus/values.yaml
│   ├── intel-device-plugins-gpu/values.yaml
│   ├── intel-device-plugins-operator/values.yaml
│   ├── node-feature-discovery/values.yaml
│   ├── smartctl-exporter/values.yaml
│   ├── tailscale-operator/values.yaml
│   ├── vault/values.yaml
│   ├── velero/values.yaml
│   └── external-secrets/values.yaml
├── manifests/               # Raw K8s manifests
│   ├── ai/                  # Ollama LLM inference server
│   ├── argocd/              # ArgoCD installation + networking + monitoring
│   ├── arr-stack/           # ARR media stack (core + companions: 13 apps)
│   ├── atuin/               # Atuin self-hosted shell history sync
│   ├── browser/             # Firefox browser (KasmVNC)
│   ├── cert-manager/        # ClusterIssuer
│   ├── cilium/              # IP pool, L2 announcements
│   ├── cloudflare/          # Cloudflare Tunnel + network policy
│   ├── external-secrets/    # ESO CiliumNetworkPolicy
│   ├── gateway/             # Gateway + HTTPRoutes (routes/ subdir)
│   ├── ghost-dev/           # Ghost blog dev environment
│   ├── ghost-prod/          # Ghost blog production environment
│   ├── gitlab/              # GitLab SSH LoadBalancer
│   ├── gitlab-runner/       # GitLab Runner ExternalSecret
│   ├── home/                # Home services (AdGuard, Homepage, MySpeed)
│   ├── invoicetron/         # Invoicetron app + PostgreSQL + backup
│   ├── karakeep/            # Karakeep bookmark manager (AIO, Chrome, Meilisearch)
│   ├── kube-system/         # System CronJobs, RBAC (claude-code SA), cert utilities
│   ├── monitoring/          # Observability (alerts/, dashboards/, probes/, exporters/, servicemonitors/)
│   ├── network-policies/    # CiliumClusterwideNetworkPolicy (gateway ingress)
│   ├── portfolio/           # Portfolio deployment + RBAC
│   ├── storage/             # Longhorn HTTPRoute, NFS PVs
│   ├── tailscale/           # Tailscale Operator + Connector (subnet router)
│   ├── uptime-kuma/         # Uptime Kuma StatefulSet
│   ├── vault/               # Vault + auto-unsealer + snapshot CronJob
│   └── velero/              # Velero + Garage S3 backend (namespace, StatefulSet, Schedule, CiliumNP)
├── scripts/                 # Automation scripts
│   ├── backup/              # Off-site backup scripts
│   │   ├── homelab-backup.sh       # Main backup script (restic to OneDrive)
│   │   ├── config.example          # Template for local config
│   │   └── config                  # Local config (gitignored)
│   ├── vault/
│   │   ├── configure-vault.sh      # One-time Vault setup (KV v2, K8s auth, ESO policy)
│   │   └── seed-vault-from-1password.sh  # Seed Vault KV from 1Password (safe terminal only)
│   ├── ghost/
│   │   ├── sync-ghost-prod-to-dev.sh
│   │   └── sync-ghost-prod-to-local.sh
│   ├── monitoring/
│   │   └── upgrade-prometheus.sh
│   └── test/
│       ├── test-cloudflare-networkpolicy.sh
│       └── verify-migration.sh    # Post-migration health check (ESO sync, Vault status)
├── docs/
│   ├── context/             # This knowledge base (RAG source)
│   ├── rebuild/             # Step-by-step rebuild guides (v0.1.0-v0.29.0)
│   ├── todo/                # Active and completed phase plans
│   └── reference/           # CHANGELOG, historical docs
└── ansible/                 # Bootstrap automation
```

## Naming Patterns

| Resource | Pattern | Example |
|----------|---------|---------|
| Namespace | lowercase | `monitoring`, `cert-manager` |
| Helm release | lowercase | `prometheus`, `loki` |
| DNS (base) | *.k8s.rommelporras.com | grafana.k8s.rommelporras.com |
| DNS (dev) | *.dev.k8s.rommelporras.com | portfolio.dev.k8s.rommelporras.com |
| DNS (stg) | *.stg.k8s.rommelporras.com | portfolio.stg.k8s.rommelporras.com |
| 1Password items | Title Case with spaces | "Discord Webhooks" |

## Common Commands

```bash
# Check cluster status
kubectl-homelab get nodes
kubectl-homelab get pods -A | grep -v Running

# Check a namespace
kubectl-homelab -n monitoring get pods

# Helm releases
helm-homelab list -A

# Logs
kubectl-homelab -n monitoring logs -l app.kubernetes.io/name=prometheus

# Port forward
kubectl-homelab -n monitoring port-forward svc/prometheus-grafana 3000:80
```

## Related

- [[Secrets]] - 1Password paths
- [[Cluster]] - Node details
- [[Versions]] - Component versions
