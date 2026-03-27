# ArgoCD Runbook

Covers: ArgoCD sync health, application status, component availability

## ArgocdAppOutOfSync

**Severity:** warning

An ArgoCD Application has been OutOfSync for more than 30 minutes. This means the live cluster state differs from the desired state in Git. Could be a failed sync, manual drift, or a new commit that hasn't been synced yet.

### Triage Steps

1. Check which app: `kubectl-admin get applications -n argocd -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status`
2. Check ArgoCD UI at https://argocd.k8s.rommelporras.com for diff details
3. If manual sync mode: sync via UI or `kubectl-admin annotate application <name> -n argocd argocd.argoproj.io/refresh=hard --overwrite`
4. If sync was attempted and failed: check ArgocdSyncFailed alert and repo-server logs

## ArgocdAppUnhealthy

**Severity:** warning

An ArgoCD Application has a non-Healthy status (Degraded, Missing, Unknown) for more than 15 minutes. This indicates the application's resources are not in a good state even if sync succeeded.

### Triage Steps

1. Check app health: `kubectl-admin get applications -n argocd -o custom-columns=NAME:.metadata.name,HEALTH:.status.health.status`
2. Check ArgoCD UI for the specific unhealthy resources (pods, deployments)
3. Check the target namespace for pod issues: `kubectl-homelab get pods -n <app-namespace>`
4. Common causes: CrashLoopBackOff pods, pending PVCs, resource quota exceeded

## ArgocdSyncFailed

**Severity:** critical

An ArgoCD sync operation failed in the last hour. The application's desired state could not be applied to the cluster. May indicate invalid manifests, RBAC issues, or resource conflicts.

### Triage Steps

1. Check sync history in ArgoCD UI for error message
2. Check repo-server logs: `kubectl-admin logs -n argocd deployment/argocd-repo-server --tail=50`
3. Check controller logs: `kubectl-admin logs -n argocd statefulset/argocd-application-controller --tail=50`
4. Common causes: invalid YAML, missing CRDs, AppProject restrictions, Helm template errors
5. For Helm apps: verify chart version exists and values file is valid

## ArgocdRepoServerDown

**Severity:** critical

The ArgoCD repo-server has been unreachable for 5 minutes. No syncs can proceed - repo-server handles git clone, Helm template rendering, and manifest generation.

### Triage Steps

1. Check pod status: `kubectl-homelab get pods -n argocd -l app.kubernetes.io/component=repo-server`
2. Check logs: `kubectl-admin logs -n argocd deployment/argocd-repo-server --tail=50`
3. Check CiliumNetworkPolicy: repo-server needs DNS + GitHub HTTPS egress (toFQDNs rules)
4. Check ResourceQuota: `kubectl-homelab describe resourcequota argocd-quota -n argocd`
5. Restart if stuck: `kubectl-admin rollout restart deployment/argocd-repo-server -n argocd`

## ArgocdControllerDown

**Severity:** critical

The ArgoCD application-controller has been unreachable for 5 minutes. Reconciliation is stopped - no applications will be synced or health-checked until the controller recovers.

### Triage Steps

1. Check pod status: `kubectl-homelab get pods -n argocd -l app.kubernetes.io/component=application-controller`
2. Check logs: `kubectl-admin logs -n argocd statefulset/argocd-application-controller --tail=50`
3. Check kube-apiserver connectivity: controller needs egress to port 6443
4. Check ResourceQuota: `kubectl-homelab describe resourcequota argocd-quota -n argocd`
5. Restart if stuck: `kubectl-admin rollout restart statefulset/argocd-application-controller -n argocd`
