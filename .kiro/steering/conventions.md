# Conventions

## Cluster layout

- **Node names:** `k8s-cp1`, `k8s-cp2`, `k8s-cp3` (bare `cp1`/`cp2`/`cp3` is wrong)
- **One namespace per service** - never share namespaces between unrelated services
- **Timezone:** `Asia/Manila` everywhere - never UTC or America/Chicago
  - Alpine images have no tzdata: use `TZ=UTC-8` (POSIX sign is inverted; means UTC+8 = Manila)

## Repo structure (write surfaces)

```
helm/          # Helm values files (ArgoCD-managed except cilium/)
manifests/     # Raw Kubernetes manifests
scripts/       # Automation scripts
docs/          # Documentation
```

- `homelab-deploy` writes to `manifests/` and `helm/` only
- `homelab-orchestrator` handles all git operations

## Secrets

- **1Password - Vault - ESO pipeline:** `op://Kubernetes/<item>/<field>` references
  flow through Vault (via `scripts/seed-vault-from-1password.sh`) to ESO ExternalSecrets
- **Never hardcode secret values** in manifests, Helm values, scripts, or docs
- **Never `op read` in automation** - the terminal has no `op` access; Family plan has no Connect
- **Never `kubectl create secret` with literal values**
- Safe automation pattern: generate scripts using `op://` references; user runs in a safe terminal

## Image tags

- **Pin all image tags** - no `latest` in manifests or Helm values
- Verify the exact tag exists in the registry before deploying

## Observability (every new service ships all three)

- PrometheusRule alerts in `manifests/monitoring/alerts/<service>-alerts.yaml`
- Grafana dashboard ConfigMap in `manifests/monitoring/dashboards/`
- Blackbox probe in `manifests/monitoring/probes/` (optional but preferred)

## Commit convention

Format: `<type>: <subject>` (lowercase subject, no trailing period, max 72 chars)

| Type | Use for |
|------|---------|
| `feat:` | new service or feature |
| `fix:` | bug fix |
| `docs:` | documentation only |
| `infra:` | infrastructure / manifest / Helm values changes |
| `refactor:` | restructuring without behavior change |
| `chore:` | maintenance, dependency bumps |

- Infra changes and docs changes = two separate commits per project convention
- **No AI attribution** - no "Generated with", "Co-Authored-By: Claude/Kiro", or any AI reference

## Style rules

- **No em dashes** - use regular hyphens (`-`) everywhere
- No AI attribution anywhere (commits, comments, docs, PRs)

## Homelab gotchas

- **NFS paths:** use `/Kubernetes/...` not `/export/Kubernetes/...` (OMV pseudo-root has fsid=0)
- **RWO PVC workloads:** Deployments must use `strategy: Recreate` - rolling update causes volume attach deadlock
- **NFS PV fields:** `persistentVolumeReclaimPolicy: Retain`, `storageClassName: nfs`, `nfsvers=4.1`
- **Cilium network policy:** `ingress: []` = deny-all; `ingress: [{}]` = allow-all - always verify the body matches intent
- **ESO `creationPolicy: Merge`** requires the target Secret to pre-exist - Helm creates it first, then ESO merges
- **ESO `engineVersion: v2`** required for Go-template expression escaping in target templates
- **ArgoCD AppProject `destinations`** must include every namespace its Applications deploy into (including `default` for Gateway)
- **OCI chart URLs** must be fully qualified: `oci://quay.io/jetstack/charts/cert-manager` not `oci://jetstack/cert-manager`
- **Grafana dashboard layout:** Pod Status row -> Network row -> Resource Usage row; descriptions required on every panel and row
- **Vault health:** check pod `Ready=True` - the `vault.hashicorp.com` annotations on vault-0 are a false-positive signal and do not reflect actual Vault health
