# Code Reviewer Agent Memory -- homelab

## Project Type
Kubernetes homelab infrastructure repo (public). 3-node HA cluster (kubeadm, Cilium CNI, Longhorn storage).

## Critical Review Checks
- **No secrets in code** — repo is PUBLIC. Scan for IPs (10.10.30.x are fine), passwords, tokens, API keys
- **Use `kubectl-homelab` / `helm-homelab`** — plain `kubectl`/`helm` connects to work AWS EKS
  - `kubectl-homelab` → restricted kubeconfig (read-only, no secret `get`) — Phase 5.2
  - `kubectl-admin` → full admin kubeconfig — valid alias, not a violation
  - Scripts needing admin: `kubectl --kubeconfig ~/.kube/homelab.yaml` is correct
- **NFS paths must use NFSv4 format** — `/Kubernetes/...` not `/export/Kubernetes/...` (OMV pseudo-root has fsid=0)
- **Timezone must be `Asia/Manila`** — never UTC or America/Chicago for user-facing configs
- **Image versions must be pinned** — no `latest` tags in manifests or Helm values
- **`op://` references only** — never hardcode secret values, use 1Password URI format

## Manifest Conventions
- One namespace per service (not shared)
- Deployments use `Recreate` strategy for RWO PVC workloads
- All containers need `securityContext` (runAsNonRoot, drop ALL capabilities, readOnlyRootFilesystem where possible)
- `automountServiceAccountToken: false` unless the pod needs API access
- NFS PVs: `persistentVolumeReclaimPolicy: Retain`, `storageClassName: nfs`, `nfsvers=4.1`
- Longhorn PVCs: `storageClassName: longhorn` (default, 2x replica)

## Helm Values Conventions
- Values files live in `helm/<chart-name>/values.yaml`
- Chart version pinned in header comment AND in install/upgrade commands
- Resource requests and limits on every workload
- Helm does NOT resize existing PVCs — must `kubectl patch pvc` manually

## Observability Convention (every new service)
- PrometheusRule alerts in `manifests/monitoring/alerts/`
- Grafana dashboard ConfigMap in `manifests/monitoring/dashboards/`
- Blackbox probe in `manifests/monitoring/probes/` (optional)
- Dashboard layout: Pod Status row, Network row, Resource Usage row
- Panel + row descriptions on every element

## Documentation Convention
- `docs/context/Cluster.md` is single source of truth for IPs, MACs, specs
- CHANGELOG entries need: Summary, Fixes table, Key Design Decisions table, Gotchas list
- Phase files: 1 service = 1 file in `docs/todo/`, completed phases move to `docs/todo/completed/`
- `VERSIONS.md` tracks all component versions and PVC sizes

## Commit Convention
- Conventional commits: `feat:`, `fix:`, `docs:`, `infra:`, `refactor:`, `chore:`
- Infra + docs = 2 separate commits per project convention
- No AI attribution in commits or code

## Common Gotchas to Watch
- Longhorn RWO PVC + rolling update = new pod can't attach volume (scale down old RS first)
- DinD builds share one cgroup — total memory (app + docker daemon) must fit within pod limit
- PostgreSQL PGDATA must use a subdirectory (top-level mount fails on non-empty dir)
- CronJob NFS volumes need matching UID ownership on NAS directory
- Cilium Gateway HTTPRoute may need operator restart to reconcile
