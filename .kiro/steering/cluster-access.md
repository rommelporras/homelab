# Cluster Access

## Kubeconfig table

| Config | Path | Permitted |
|--------|------|-----------|
| Restricted (default) | `~/.kube/homelab-claude.yaml` | `get`, `describe`, `top`, `events`, `explain` on most resources. No `pods/log`, no `get`/`describe` on Secrets, no write. |
| Admin | `~/.kube/homelab.yaml` | Full cluster-admin. Required for pod logs, remediation, ArgoCD app reads. |

## Command forms (bash - full paths always)

The Kiro shell runs **bash**. The zsh aliases `kubectl-homelab`, `kubectl-admin`,
and `helm-homelab` do NOT exist in this shell. Always use full forms:

```bash
# Restricted reads
kubectl --kubeconfig ~/.kube/homelab-claude.yaml get pods -A

# Pod logs (admin required)
kubectl --kubeconfig ~/.kube/homelab.yaml logs -n <ns> <pod>

# Helm reads
KUBECONFIG=~/.kube/homelab.yaml helm list -A
KUBECONFIG=~/.kube/homelab.yaml helm status <release> -n <ns>
```

**NEVER bare `kubectl` or `helm`.** Plain commands connect to the work AWS EKS
cluster, not the homelab. This is always wrong.

## WSL DNS fallback

The API endpoint `api.k8s.rommelporras.com` resolves via AdGuard DNS at
`10.10.30.53`. If that host does not resolve (AdGuard down, or WSL not using
cluster DNS), append the direct VIP:

```bash
kubectl --kubeconfig ~/.kube/homelab-claude.yaml \
  --server=https://10.10.30.10:6443 \
  get nodes
```

The VIP `10.10.30.10` is a SAN on the API server certificate, so TLS validates.

## Secret prohibition

- Never run `kubectl get secret -o ...` or `kubectl describe secret`
- Never read or log secret values through the model
- The restricted kubeconfig technically RBAC-blocks secret `get` - but this is
  also a standing policy rule regardless of which kubeconfig is in use
- To verify a Secret exists (existence check only): `kubectl ... get secret <name> -n <ns>` (no `-o`)

## Logs require admin

The restricted SA has no `pods/log` permission. Any `logs` or `logs --previous`
command requires the admin kubeconfig at `~/.kube/homelab.yaml`.
