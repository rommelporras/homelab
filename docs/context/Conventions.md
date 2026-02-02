---
tags: [homelab, kubernetes, conventions, rules]
updated: 2026-02-03
---

# Conventions

Rules and patterns for working with this homelab cluster.

## kubectl and helm

**CRITICAL:** Use `kubectl-homelab` and `helm-homelab`, NOT plain `kubectl`/`helm`.

| Command | Uses | Purpose |
|---------|------|---------|
| `kubectl-homelab` | ~/.kube/homelab.yaml | Homelab cluster |
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
│   ├── prometheus/values.yaml
│   ├── loki/values.yaml
│   ├── alloy/values.yaml
│   ├── metrics-server/values.yaml
│   ├── gitlab/values.yaml
│   └── gitlab-runner/values.yaml
├── manifests/               # Raw K8s manifests
│   ├── cert-manager/
│   ├── cilium/
│   ├── cloudflare/          # Cloudflare Tunnel
│   ├── gateway/
│   ├── ghost-dev/           # Ghost blog dev environment
│   ├── ghost-prod/          # Ghost blog production environment
│   ├── gitlab/              # GitLab LoadBalancer
│   ├── home/                # Home services (AdGuard, Homepage)
│   ├── monitoring/
│   └── storage/             # Longhorn HTTPRoute
├── scripts/                 # Automation scripts
│   ├── upgrade-prometheus.sh
│   ├── sync-ghost-prod-to-dev.sh
│   └── sync-ghost-prod-to-local.sh
├── docs/
│   ├── context/             # This knowledge base
│   └── rebuild/             # Step-by-step rebuild guides
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
| 1Password items | Title Case with spaces | "Discord Webhook Incidents" |

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
