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
- Longhorn RecurringJob backups write to a configured backup target (S3/NFS S3-gateway), NOT directly to NFS paths — specs that assume Longhorn outputs to `/Kubernetes/Backups/longhorn/` need an explicit Minio or NFS-S3 bridge
- Secret seeding always goes: 1Password → `scripts/seed-vault-from-1password.sh` → Vault. Never raw `vault kv put` in specs/docs; never `op read` in unattended/automated scripts (Family plan has no Connect)
- `restic forget --prune` on large repos (300GB+) can run 30-60 min — don't run after every backup on media repos
- `restic check` without `--with-cache` reads all pack files (slow on large repos); use `--with-cache` for routine post-backup checks
- **Node names are `k8s-cp1`, `k8s-cp2`, `k8s-cp3`** — bare `cp1`/`cp2`/`cp3` is wrong in `nodeName` fields and SSH targets
- **`helm uninstall --keep-history` does NOT protect resources** — it only keeps the Helm release secret; ArgoCD SSA field ownership is what prevents resource deletion during Helm handover
- **Cilium `ingress: [{}]` = allow-all, `ingress: []` = deny-all** — the opposite of the name "default-deny". Always verify the body matches the intent when reviewing CiliumNetworkPolicy.
- **ArgoCD `kubectl-homelab get secret -o jsonpath` will fail** — `kubectl-homelab` RBAC blocks secret `get`. Retrieve passwords from 1Password or Vault UI instead.
- **ESO `creationPolicy: Merge` requires the target Secret to pre-exist** — ArgoCD `argocd-secret` must be created by Helm first before ESO can Merge into it. Ordering: Helm install → then apply ExternalSecrets.

## ArgoCD-Specific Review Checks (Phase 5.7-5.8)
- AppProject `destinations` must include ALL namespaces used by its Applications (e.g., `default` for Gateway)
- `spec.source` and `spec.sources` are mutually exclusive in ArgoCD Applications — remove `spec.source` when using multi-source
- Wave 3 has 11 Helm releases (not 6): includes tailscale-operator, NFD, intel-device-plugins-operator, intel-device-plugins-gpu, velero in addition to the 6 in the summary table
- OCI chart URLs must be fully qualified: `oci://quay.io/jetstack/charts/cert-manager` not `oci://jetstack/cert-manager`
