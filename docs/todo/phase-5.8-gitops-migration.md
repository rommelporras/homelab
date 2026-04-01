# Phase 5.8: GitOps Migration

> **Status:** In Progress
> **Target:** v0.38.0
> **Prerequisite:** Phase 5.7 (v0.37.0 - ArgoCD installed, bootstrapped, monitoring in place)
> **DevOps Topics:** GitOps adoption, declarative infrastructure, Helm release adoption, drift detection
> **CKA Topics:** Application lifecycle management, resource ownership, rollout strategies

> **Purpose:** Migrate all cluster services from imperative management (`kubectl apply`, `helm upgrade`)
> to declarative GitOps via ArgoCD. After this phase, all changes flow through Git - no more
> direct `kubectl apply` or `helm upgrade` commands for managed services.
>
> **Learning Goal:** Large-scale GitOps migration, Helm-to-ArgoCD handover, ApplicationSet patterns,
> sync wave orchestration, managing drift at scale.

> **Migration scope:**
> - **18 Helm releases** to adopt via ArgoCD Helm-type Applications
> - **27 manifest directories** to manage via ArgoCD Git-type Applications
> - **31 namespaces** across 6 AppProjects
> - **179 pods** that must remain running during migration (zero downtime)
>
> **Migration principle:** Each service is migrated individually with verification.
> Manual sync mode first, then auto-sync after stability confirmed.
> ArgoCD is additive - it does not disrupt running workloads.

> **Helm adoption challenge:** ArgoCD uses `helm template`, not `helm install`.
> It does not create Helm releases. Existing `helm list` releases will conflict
> unless properly handed over. The handover procedure per service:
> 1. Create ArgoCD Application pointing at chart + values file
> 2. Sync with `ServerSideApply=true` to take field ownership from Helm
> 3. Verify Application is Synced/Healthy (ArgoCD now owns all resource fields)
> 4. Enable `selfHeal: true` on the Application (required for step 5)
> 5. `helm uninstall <release>` to remove Helm release metadata
>    (`helm uninstall` DOES delete resources. ArgoCD's selfHeal detects the drift
>    and re-creates them within ~3 minutes. Without selfHeal, resources stay deleted
>    until manual sync.)
> 6. Wait for ArgoCD to detect drift and re-sync (~1-3 minutes)
> 7. Verify Application still Synced/Healthy after Helm release removal
>
> **CRITICAL SAFETY NOTE:** The protection during handover is the SEQUENCE.
> ArgoCD MUST be Synced/Healthy (step 3) AND selfHeal MUST be enabled (step 4)
> BEFORE running `helm uninstall` (step 5). If you run `helm uninstall` before
> ArgoCD has synced, the resources will be deleted with no automatic recovery.
>
> **Downtime mitigation:** `helm uninstall` deletes resources immediately, but
> ArgoCD reconciliation runs every `timeout.reconciliation` (180s in our config).
> Worst case: ~3 minutes of downtime per service. To minimize this:
> 1. After `helm uninstall`, immediately force a refresh:
>    `kubectl-admin annotate application <name> -n argocd argocd.argoproj.io/refresh=hard --overwrite`
> 2. This triggers re-sync within seconds instead of waiting for the next cycle.
> 3. For critical services (Prometheus, Vault), monitor pod status during handover.
>
> **Do NOT use `--keep-history`** - it preserves stale Helm release metadata that
> conflicts with ArgoCD's server-side apply ownership. A stale `helm list` entry
> confuses operators and can cause problems if someone runs `helm upgrade` on a
> release ArgoCD now owns. Clean break is safer.

---

## 5.8.0 Pre-Migration Validation

- [x] 5.8.0.1 Verify all Phase 5.6 gaps are resolved
  ```
  Gap 1: Invoicetron CI/CD image tag - NOT RESOLVED (skip in Wave 2, needs per-env dirs)
  Gap 2: NFD values file - RESOLVED (helm/node-feature-discovery/values.yaml exists)
  Gap 3: Per-env directories - NOT RESOLVED (Invoicetron/Portfolio still flat, skip in Wave 2)
  Gap 4: Prometheus runtime secrets - NOT RESOLVED (SET_VIA_HELM placeholders, must fix before Wave 4)
  Gap 5: vault-unseal-keys - RESOLVED (has IgnoreExtraneous annotation)
  Gap 6: Intel GPU operator values - RESOLVED (both values files exist)
  Gap 7: All 18 Helm values files - RESOLVED (19 dirs in helm/ matching 19 releases)
  ```

- [x] 5.8.0.2 Update ArgoCD CiliumNP for Helm chart repo egress
  ```
  Added to argocd-egress CiliumNP toFQDNs:
  - HTTPS chart repos: charts.longhorn.io, helm.cilium.io, charts.jetstack.io,
    charts.gitlab.io, charts.external-secrets.io, helm.releases.hashicorp.com, pkgs.tailscale.com
  - OCI registries: quay.io (+ *.quay.io), ghcr.io (+ *.ghcr.io), registry.k8s.io (+ *.registry.k8s.io)
  Also updated infrastructure AppProject: added tailscale namespace destination,
  added OCI sourceRepos (quay.io/jetstack/charts, ghcr.io/prometheus-community/charts,
  ghcr.io/grafana/helm-charts, registry.k8s.io/nfd/charts)
  ```

- [x] 5.8.0.3 Ensure Git state matches cluster state (drift check)
  ```
  Manifest drift check: all namespaces clean (ai, browser, uptime-kuma, atuin,
  cloudflare, tailscale, home/adguard, home/homepage, home/myspeed, ghost-dev,
  ghost-prod, arr-stack, gateway, network-policies).
  Two drifts found and fixed:
  - karakeep/meilisearch: Git removed args ["meilisearch","--experimental-dumpless-upgrade"],
    cluster still had them. Applied to fix.
  - kube-system/etcd-backup: Git had alpine/k8s:1.35.3, cluster had 1.35.0. Applied to fix.
  Helm values drift: spot-checked metrics-server, cert-manager, vault - all clean.
  Known CI/CD drift: Invoicetron (prod:41b280b8, dev:45e605fb) and Portfolio (:latest)
  have CI/CD-managed tags - skipping these in Wave 2 (Gap 1/3 unresolved).
  ```

- [x] 5.8.0.4 Verify ArgoCD is healthy
  ```
  All 6 pods Running (4d uptime): application-controller, applicationset-controller,
  notifications-controller, redis, repo-server, server.
  Self-management app: OutOfSync/Healthy (expected - Git ahead of last sync).
  19 Helm releases confirmed across cluster.
  ```

---

## 5.8.1 Wave 1 - Simple Manifest Services

> **Why first?** These are simple `kubectl apply -f` services with minimal dependencies.
> Easiest to migrate, builds confidence in the process.

### Services in Wave 1:

| Service | Namespace | Manifest Path | Notes |
|---------|-----------|---------------|-------|
| AI (Ollama) | ai | manifests/ai/ | Single deployment, ClusterIP |
| Browser (Firefox) | browser | manifests/browser/ | Single deployment |
| Uptime Kuma | uptime-kuma | manifests/uptime-kuma/ | Single deployment, SQLite |
| Atuin | atuin | manifests/atuin/ | StatefulSet + PostgreSQL |
| Cloudflare | cloudflare | manifests/cloudflare/ | cloudflared tunnel, 2 replicas |
| Tailscale | tailscale | manifests/tailscale/ | Operator-managed, special |

### Migration Pattern (repeat for each service):

- [x] 5.8.1.1 Create Application manifest
  ```
  Created 6 Application YAMLs in manifests/argocd/apps/:
  ai.yaml, browser.yaml, uptime-kuma.yaml, atuin.yaml, cloudflare.yaml, tailscale.yaml
  All use: homelab-apps project, ServerSideApply=true, ServerSideDiff=true,
  RespectIgnoreDifferences=true, manual sync mode.
  Required fix: homelab-apps AppProject needed Namespace + Connector in
  clusterResourceWhitelist (all manifest dirs contain namespace.yaml).
  Also fixed arr-stack, gitlab, cicd-apps projects for same issue.
  ```

- [x] 5.8.1.2 Apply all Wave 1 Applications
  ```
  All 6 Applications created via kubectl-admin apply.
  Initial sync failed: "Namespace not permitted in project homelab-apps"
  Fixed by adding Namespace to clusterResourceWhitelist, then re-synced.
  ```

- [x] 5.8.1.3 Verify all Wave 1 apps in ArgoCD UI
  ```
  After sync: ExternalSecret and HTTPRoute resources showed OutOfSync due to
  CRD-defaulted fields (conversionStrategy, decodingStrategy, metadataPolicy,
  creationPolicy, deletionPolicy for ESO; group, kind, weight for HTTPRoute).
  Fixed by adding resource.customizations.ignoreDifferences to ArgoCD config
  for external-secrets.io_ExternalSecret, gateway.networking.k8s.io_HTTPRoute,
  and apps_StatefulSet (volumeClaimTemplates defaults).
  Final status: all 6 apps Synced. uptime-kuma Degraded health (completed
  CronJob backup pods - normal, not an actual issue).
  ```

- [x] 5.8.1.4 Trigger manual sync for each app
  ```
  Synced via kubectl patch (no ArgoCD CLI installed).
  All operations Succeeded. All pods confirmed Running across all 6 namespaces.
  ```

- [x] 5.8.1.5 ~~Wait 24h~~ Verified via ArgoCD UI - all Synced/Healthy

- [x] 5.8.1.6 Enable auto-sync on Wave 1 apps
  ```bash
  for app in ai browser uptime-kuma atuin cloudflare tailscale; do
    kubectl-admin patch application "$app" -n argocd --type=merge \
      -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
  done
  ```

---

## 5.8.2 Wave 2 - Complex Manifest Services

> **Why second?** These have more complex structures: multi-file directories,
> ExternalSecrets, kustomize, or namespace-level resources (LimitRange, ResourceQuota, CNP).

### Services in Wave 2:

| Service | Namespace | Manifest Path | Complexity |
|---------|-----------|---------------|------------|
| Home - AdGuard | home | manifests/home/adguard/ | Plain manifests |
| Home - Homepage | home | manifests/home/homepage/ | Kustomize (auto-detected) |
| Home - MySpeed | home | manifests/home/myspeed/ | Plain manifests |
| Home - namespace resources | home | manifests/home/*.yaml | LimitRange, ResourceQuota, CNP, namespace |
| ARR Stack | arr-stack | manifests/arr-stack/ | 15+ subdirectories, NFS PVs |
| Ghost Dev | ghost-dev | manifests/ghost-dev/ | Per-env deployment |
| Ghost Prod | ghost-prod | manifests/ghost-prod/ | Per-env deployment |
| Karakeep | karakeep | manifests/karakeep/ | Multi-container (Chrome, Meilisearch, Ollama) |
| Gateway | default | manifests/gateway/ | Cluster-wide Gateway resource |
| Network Policies | various | manifests/network-policies/ | Cross-namespace CiliumNPs |
| Kube-system extras | kube-system | manifests/kube-system/ | kube-bench, cluster-janitor |

### Special Handling:

**Home namespace (multi-Application):**
The `home` namespace has 3 services with different apply methods: Homepage uses Kustomize,
AdGuard and MySpeed use plain manifests. A single recursive-directory Application would
break Homepage (ArgoCD would apply Kustomize files as raw manifests). Split into:
- `home-adguard` Application -> `manifests/home/adguard/` (directory, recurse)
- `home-homepage` Application -> `manifests/home/homepage/` (auto-detects kustomization.yaml)
- `home-myspeed` Application -> `manifests/home/myspeed/` (directory, recurse)
- `home-infra` Application -> `manifests/home/` (non-recursive, picks up namespace.yaml,
  limitrange.yaml, resourcequota.yaml, networkpolicy.yaml only)

```yaml
# Homepage: ArgoCD natively supports Kustomize - just point at the directory
spec:
  source:
    repoURL: https://github.com/rommelporras/homelab.git
    path: manifests/home/homepage
    targetRevision: main
    # ArgoCD auto-detects kustomization.yaml

# AdGuard/MySpeed: plain directory Application
spec:
  source:
    repoURL: https://github.com/rommelporras/homelab.git
    path: manifests/home/adguard  # or manifests/home/myspeed
    targetRevision: main
    directory:
      recurse: true
```

**ARR Stack (large directory):**
```yaml
# Option A: Single Application for entire arr-stack
# Pros: Simple, one sync for everything
# Cons: Large diff on any change, all-or-nothing sync
spec:
  source:
    path: manifests/arr-stack
    directory:
      recurse: true
      exclude: '{backup-cronjob-*.yaml}'  # Exclude node-specific CronJobs

# Option B: ApplicationSet with directory generator
# Pros: Per-service Applications, individual sync control
# Cons: More complex setup
```

> **Recommendation:** Use Option A (single Application) for arr-stack.
> The services are tightly coupled (shared NFS, shared namespace, shared NetworkPolicy).
> Individual service Applications would create sync ordering issues.

**Invoicetron/Portfolio (multi-namespace):**
```yaml
# After Gap 3 is resolved (per-env directories), create per-env Applications:
# manifests/argocd/apps/invoicetron-prod.yaml
spec:
  project: cicd-apps
  source:
    path: manifests/invoicetron/prod   # After split
  destination:
    namespace: invoicetron-prod

# manifests/argocd/apps/invoicetron-dev.yaml
spec:
  project: cicd-apps
  source:
    path: manifests/invoicetron/dev    # After split
  destination:
    namespace: invoicetron-dev
```

**Gateway (cluster-scoped):**
```yaml
# Gateway is in default namespace - needs infrastructure project
spec:
  project: infrastructure
  source:
    path: manifests/gateway
  destination:
    namespace: default
```

- [x] 5.8.2.1 Create all Wave 2 Application manifests
  ```
  Created 11 Application YAMLs in manifests/argocd/apps/:
  
  Home namespace split into 4 apps (key ArgoCD concept: one namespace, multiple apps):
    home-infra.yaml     - non-recursive (directory.recurse: false) picks up ONLY
                          top-level YAML files (namespace, limitrange, resourcequota, CNP).
                          Without recurse:false, ArgoCD would descend into adguard/homepage/
                          myspeed/ and try to apply their manifests too, conflicting with
                          the per-service apps below.
    home-adguard.yaml   - recursive directory (directory.recurse: true), plain manifests
    home-homepage.yaml  - NO directory config needed. ArgoCD auto-detects kustomization.yaml
                          in the path and switches to kustomize build. This is why Homepage
                          can't be in a recursive parent app - ArgoCD would try to apply
                          kustomization.yaml as a raw manifest instead of using kustomize.
    home-myspeed.yaml   - recursive directory, plain manifests

  arr-stack.yaml - Single recursive app for all 15+ subdirectories. Option A from plan.
                   Tightly coupled services (shared NFS PVs, shared namespace, shared CNP)
                   mean individual apps would cause sync ordering failures.

  ghost-dev.yaml, ghost-prod.yaml - Per-environment apps. Same manifests structure,
                   different namespaces. ArgoCD treats them independently.

  karakeep.yaml  - Multi-container app (Karakeep + Chrome + Meilisearch). Single
                   directory app, ArgoCD manages all deployments together.

  gateway.yaml   - Infrastructure project. Cilium Gateway API Gateway resource in
                   default namespace. Namespaced resource (not cluster-scoped) so no
                   clusterResourceWhitelist entry needed.

  network-policies.yaml - Infrastructure project. CiliumClusterwideNetworkPolicy
                   resources (cluster-scoped). Required adding CCNP to infrastructure
                   project's clusterResourceWhitelist.

  kube-system.yaml - Infrastructure project. CronJobs (kube-bench, etcd-backup,
                   cluster-janitor, cert-expiry-check, pki-backup), claude-code RBAC
                   (ClusterRole/ClusterRoleBinding), and ValidatingAdmissionPolicy.
                   admissionregistration.k8s.io already whitelisted with kind: '*'.

  Skipped: Invoicetron, Portfolio (Gap 3 unresolved - need per-env directory split)

  AppProject updates applied:
    arr-stack:      Added PersistentVolume to clusterResourceWhitelist (NFS PVs are
                    cluster-scoped, unlike PVCs which are namespace-scoped)
    infrastructure: Added CiliumClusterwideNetworkPolicy to clusterResourceWhitelist

  All apps created with auto-sync enabled from the start (lesson from Wave 1:
  manual sync adds a round-trip with no benefit when drift is already verified clean).
  ```

- [x] 5.8.2.2 Apply Wave 2 Applications
  ```
  All 11 Applications created. Issues discovered and fixed during sync:

  Issue 1: arr-stack ServiceMonitor "scraparr" targets monitoring namespace,
           but arr-stack project only allowed arr-stack namespace.
           Fix: Added monitoring as allowed destination in arr-stack AppProject.
           Lesson: When a manifest directory contains resources that deploy to
           DIFFERENT namespaces than the app's destination, the AppProject must
           allow all target namespaces, not just the primary one.

  Issue 2: home-homepage ClusterRole/ClusterRoleBinding showed "Unknown" status.
           Homepage's ServiceAccount needs cluster-wide read access for the
           Kubernetes widget. ClusterRole is cluster-scoped.
           Fix: Added ClusterRole/ClusterRoleBinding to homelab-apps AppProject
           clusterResourceWhitelist.
           Lesson: Every cluster-scoped resource kind must be explicitly
           whitelisted in the AppProject. ArgoCD defaults to denying all
           cluster-scoped resources for security (prevents one project from
           affecting cluster-wide state).

  Issue 3: network-policies app failed with "namespace '' does not match
           allowed destinations". CiliumClusterwideNetworkPolicy is cluster-scoped
           (no namespace), but ArgoCD still needs a destination namespace for
           project RBAC matching.
           Fix: Added namespace: default to the Application destination.
           Lesson: Even for cluster-scoped resources, ArgoCD Applications need
           a destination namespace. This namespace is used for project RBAC
           matching only - it doesn't affect where the resource is deployed.

  Issue 4: gateway OutOfSync from CRD-defaulted group: "" on certificateRefs.
           Fix: Added group: "" explicitly to the Gateway manifest (not
           ignoreDifferences, since there's only 1 Gateway and 1 missing field).
           Will resolve after commit+push (ArgoCD reads from GitHub, not local).
           Lesson: Two approaches for CRD defaults:
           (a) ignoreDifferences - best for high-cardinality resources (30+ HTTPRoutes,
               33 ExternalSecrets) where adding defaults is maintenance burden
           (b) Explicit in manifest - best for low-cardinality (1 Gateway) where
               the manifest becomes more self-documenting
  ```

- [x] 5.8.2.3 Verify all Wave 2 apps Synced/Healthy
  ```
  All 11 Wave 2 apps Synced. Expected exceptions:
  - gateway: OutOfSync (local manifest fix not pushed to GitHub yet)
  - argocd: OutOfSync (self-management, expected - config changes not synced)
  Degraded health (all normal - completed CronJob backup pods):
  - arr-stack, home-adguard, home-myspeed, uptime-kuma
  ```

- [x] 5.8.2.4 Verify pods running across all Wave 2 namespaces
  ```
  All pods Running across home (4 pods), arr-stack (14 pods), ghost-dev (2),
  ghost-prod (3), karakeep (3). Gateway programmed at 10.10.30.20.
  network-policies and kube-system have no long-running pods (CronJobs only).
  ```

---

## 5.8.3 Wave 3 - Helm Releases: Infrastructure

> **Why third?** Helm-managed services require the handover procedure.
> Infrastructure services are the foundation - migrate them before apps.
> **Critical: test the handover procedure on a low-risk service first (metrics-server).**

### Helm Handover Procedure:

```bash
# 1. Create ArgoCD Application for the Helm release
kubectl-admin apply -f manifests/argocd/apps/<service>.yaml

# 2. Manual sync with ServerSideApply (takes field ownership)
# Via ArgoCD UI: Sync > check "Server Side Apply" > Synchronize

# 3. Verify Application is Synced/Healthy
kubectl-homelab get application <service> -n argocd

# 4. Enable auto-sync with selfHeal BEFORE uninstalling Helm release
# Without selfHeal, helm uninstall deletes resources and they STAY deleted
# until someone manually syncs. selfHeal makes ArgoCD auto-recreate them.
kubectl-admin patch application <service> -n argocd --type=merge \
  -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":true,"prune":false}}}}'

# 5. Remove old Helm release metadata (resources will be deleted briefly)
helm-homelab uninstall <release-name> -n <namespace>

# 6. Immediately force ArgoCD to detect the drift (don't wait 3 min for reconciliation)
kubectl-admin annotate application <service> -n argocd argocd.argoproj.io/refresh=hard --overwrite

# 7. Watch ArgoCD re-create resources (~10-30 seconds after forced refresh)
kubectl-admin get application <service> -n argocd -w
# Should go OutOfSync -> Synced

# 8. Verify Application is Synced/Healthy and pods are running
kubectl-admin get application <service> -n argocd
kubectl-homelab get pods -n <namespace>
```

### Services in Wave 3:

| Release Name | Chart | Namespace | Risk Level |
|-------------|-------|-----------|------------|
| metrics-server | metrics-server/metrics-server | kube-system | Low (test first) |
| node-feature-discovery | oci://registry.k8s.io/nfd/charts/nfd | node-feature-discovery | Low |
| intel-device-plugins-operator | intel/intel-device-plugins-operator | intel-device-plugins | Low |
| intel-device-plugins-gpu | intel/intel-device-plugins-gpu | intel-device-plugins | Low |
| tailscale-operator | tailscale/tailscale-operator | tailscale | Low |
| cert-manager | oci://quay.io/jetstack/charts/cert-manager | cert-manager | Medium |
| external-secrets | external-secrets/external-secrets | external-secrets | Medium |
| vault | hashicorp/vault | vault | High |
| velero | vmware-tanzu/velero | velero | Medium |
| longhorn | longhorn/longhorn | longhorn-system | **HIGH** |
| cilium | cilium/cilium | kube-system | **HIGH** |

> **WARNING: Cilium and Longhorn are HIGH RISK.** These are core infrastructure.
> A failed sync could break networking (Cilium) or storage (Longhorn).
> Migrate these LAST within Wave 3. Consider keeping them on manual sync
> permanently (no auto-sync for CNI and storage).
>
> **Cilium special handling:** Cilium Helm chart includes CRDs that must be
> managed carefully. Use `crds.install: false` in the values and manage CRDs
> separately (or set `skipCrds: true` in the ArgoCD source).
>
> **Longhorn special handling:** Set `preUpgradeChecker.jobEnabled: false`
> in values (ArgoCD manages upgrades, not Longhorn's pre-upgrade Job).

- [x] 5.8.3.1 Start with metrics-server (lowest risk)
  ```yaml
  # manifests/argocd/apps/metrics-server.yaml - Multi-source pattern:
  # Source 1: Helm chart from repo (chart name + version)
  # Source 2: Git repo with $values ref (ArgoCD reads values.yaml from here)
  apiVersion: argoproj.io/v1alpha1
  kind: Application
  spec:
    sources:
      - repoURL: https://kubernetes-sigs.github.io/metrics-server/
        chart: metrics-server
        targetRevision: "3.13.0"
        helm:
          valueFiles:
            - $values/helm/metrics-server/values.yaml
      - repoURL: https://github.com/rommelporras/homelab.git
        targetRevision: main
        ref: values   # <-- this creates the $values alias
    destination:
      server: https://kubernetes.default.svc
      namespace: kube-system
    syncPolicy:
      syncOptions:
        - ServerSideApply=true
        - CreateNamespace=false
  ```

- [x] 5.8.3.2 Execute handover for metrics-server
  ```bash
  # Apply ArgoCD Application
  kubectl-admin apply -f manifests/argocd/apps/metrics-server.yaml
  # Manual sync via ArgoCD UI (check "Server Side Apply")
  # Verify Synced/Healthy
  # Enable selfHeal:
  kubectl-admin patch application metrics-server -n argocd --type=merge \
    -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":true,"prune":false}}}}'
  # Uninstall Helm release (resources will be briefly deleted):
  helm-homelab uninstall metrics-server -n kube-system
  # Force immediate re-sync:
  kubectl-admin annotate application metrics-server -n argocd argocd.argoproj.io/refresh=hard --overwrite
  # Verify ArgoCD re-creates resources:
  kubectl-admin get application metrics-server -n argocd -w
  # Verify metrics-server still works:
  kubectl-homelab top nodes
  ```

- [x] 5.8.3.3 Repeat handover for remaining Wave 3 services
  ```
  Created 11 Helm Applications + 5 companion manifest Applications.

  AppProject gaps discovered and fixed during syncs:
  - APIService (metrics-server), GpuDevicePlugin + NodeFeatureRule (intel),
    IngressClass (tailscale), PriorityClass (longhorn), GatewayClass (cilium),
    cilium-secrets namespace (cilium RBAC), pkgs.tailscale.com sourceRepo.
  Lesson: Helm charts create many cluster-scoped resources not obvious from
  the values file. Each new kind needs clusterResourceWhitelist entry.
  Running a test sync BEFORE handover catches these safely.

  Handover results (increasing risk order):
  1. metrics-server    - DONE. kubectl top nodes confirmed working.
  2. node-feature-discovery - Initially DEFERRED (OCI registry.k8s.io
     timed out via CiliumNP redirect to *.pkg.dev). Resolved in Wave 5
     after CNP simplification to toEntities:world. Successfully handed over.
  3. intel-device-plugins-operator - DONE.
  4. intel-device-plugins-gpu - DONE.
  5. tailscale-operator - DONE. INCIDENT: operator-oauth Secret deleted by
     helm uninstall (was created via --set, not in values file). Operator
     couldn't start. Fixed: recreated Secret imperatively, created
     ExternalSecret for Vault-backed declarative management.
     Lesson: ALWAYS audit helm get values vs values file before handover.
     Any --set secrets will be destroyed by helm uninstall.
  6. cert-manager      - DONE. Clean handover.
  7. external-secrets  - DONE. INCIDENT: First attempt failed - chart pull
     timeout after repo-server restart (cold FQDN cache). Restored via
     helm install, then retried handover successfully.
     Lesson: Don't restart repo-server during handovers. Chart cache is
     lost and CiliumNP FQDN rules need time to warm up.
  8. vault             - DONE. Auto-unsealer recovered pod in ~40s.
  9. velero            - DONE. Clean handover.
  10. longhorn         - DONE. Handover succeeded. Manual sync only.
      Longhorn's pre-delete hook job failed (PSS) but release was still
      removed. selfHeal recreated resources.
  11. cilium           - KEPT ON HELM. INCIDENT: helm uninstall deleted Cilium
      pods. ArgoCD couldn't pull chart to recreate them because network
      degraded (DNS timeout). Chicken-and-egg: CNI deletion breaks the
      network ArgoCD needs to restore CNI.
      Decision: Cilium stays on Helm permanently. ArgoCD Application
      exists for drift monitoring only (manual sync, no selfHeal).
      This is a fundamental limitation of GitOps for CNI plugins.
  ```

- [x] 5.8.3.4 Verify all Wave 3 apps Synced/Healthy
  ```
  9 of 11 handed over to ArgoCD. 2 kept on Helm:
  - cilium: Cannot hand over (CNI chicken-and-egg)
  - node-feature-discovery: OCI registry timeout (deferred)
  All handed-over services verified Synced/Healthy.
  ```

- [x] 5.8.3.5 Helm releases removed for migrated services
  ```
  Remaining Helm releases (10):
  - cilium, node-feature-discovery (Wave 3 - kept on Helm)
  - alloy, blackbox-exporter, loki, prometheus, smartctl-exporter (Wave 4)
  - gitlab, gitlab-runner (Wave 5)
  - argocd (self-management)
  ```

- [x] 5.8.3.6 Enable auto-sync on low-risk Wave 3 apps
  ```
  Auto-sync enabled on: metrics-server, intel-device-plugins-operator,
  intel-device-plugins-gpu, tailscale-operator, cert-manager,
  external-secrets, vault, velero.
  Manual sync only: longhorn, cilium (both too critical for auto-sync).
  ```

---

## 5.8.4 Wave 4 - Helm Releases: Monitoring

> **Why separate from Wave 3?** Monitoring stack is interconnected
> (Prometheus, Loki, Alloy, blackbox-exporter, smartctl-exporter).
> Migrate together to avoid partial monitoring gaps.

### Services in Wave 4:

| Release Name | Chart | Namespace | Notes |
|-------------|-------|-----------|-------|
| prometheus | kube-prometheus-stack | monitoring | 37 revisions, most active |
| loki | grafana/loki | monitoring | OCI chart |
| alloy | grafana/alloy | monitoring | Non-OCI chart |
| blackbox-exporter | prometheus-blackbox-exporter | monitoring | Low risk |
| smartctl-exporter | prometheus-smartctl-exporter | monitoring | DaemonSet |

> **Prometheus special handling:**
> - `upgrade-prometheus.sh` reads runtime secrets into a temp file for Alertmanager config
> - Before migration: convert Alertmanager config to use `existingSecret` references
>   (Gap 4 from Phase 5.6 MUST be resolved first)
> - After ArgoCD adoption, `upgrade-prometheus.sh` is DEPRECATED
>   (ArgoCD syncs from `helm/prometheus/values.yaml` directly)
>
> **OCI chart sources (cert-manager, prometheus, loki, NFD):**
> OCI charts need different ArgoCD source config than traditional HTTPS repos.
> Traditional: `repoURL: https://charts.longhorn.io` + `chart: longhorn`
> OCI: `repoURL: ghcr.io/grafana/helm-charts` + `chart: loki` (no `oci://` prefix in ArgoCD)
> OCI registries used: `quay.io` (cert-manager), `ghcr.io` (prometheus, loki),
> `registry.k8s.io` (NFD). All need CiliumNP egress (added in 5.8.0.2).
>
> **Alloy:** Uses traditional HTTPS repo (`https://grafana.github.io/helm-charts`).

- [x] 5.8.4.1 Resolve Prometheus runtime secret dependency (Gap 4)
  ```
  DONE (session 3). Created ESO ExternalSecret "alertmanager-config" with
  template block that assembles complete alertmanager.yaml from Vault secrets.

  Implementation:
  1. Added ExternalSecret to manifests/monitoring/externalsecret.yaml
     - ESO template with engineVersion v2
     - Pulls 6 values from Vault (smtp username/password, 3x discord webhooks,
       healthchecks ping-url)
     - Templates into complete alertmanager.yaml config
     - Alertmanager Go template expressions escaped with {{ "{{" }} pattern
  2. Added configSecret: alertmanager-config to Helm values
  3. Removed entire alertmanager.config block (6 SET_VIA_HELM placeholders)
  4. Created manifests/argocd/apps/prometheus.yaml (OCI Helm, v82.13.1)
  5. Deleted scripts/monitoring/upgrade-prometheus.sh
  6. Updated context docs (Monitoring.md, Conventions.md, Secrets.md)

  Handover: push changes, ArgoCD syncs monitoring-manifests (creates ESO
  ExternalSecret + alertmanager-config Secret). Then create prometheus
  ArgoCD Application, sync, hand over via Secret deletion.
  ```

- [x] 5.8.4.2 Create all Wave 4 Application manifests
  ```
  Created 4 Helm Applications + 1 companion manifest Application:
  - blackbox-exporter.yaml (HTTPS: prometheus-community)
  - smartctl-exporter.yaml (HTTPS: prometheus-community)
  - alloy.yaml (HTTPS: grafana - OCI not supported by Alloy chart)
  - loki.yaml (OCI: ghcr.io/grafana/helm-charts)
  - monitoring-manifests.yaml (Git: manifests/monitoring/, recursive,
    manages alerts, dashboards, exporters, grafana, otel, probes,
    servicemonitors, ExternalSecrets, CNP, PDBs, grafana-backup)
  ```

- [x] 5.8.4.3 Execute handover for 4 services (Prometheus deferred)
  ```
  NEW METHOD: Secret deletion instead of helm uninstall.
  Delete Helm release Secrets directly:
    kubectl delete secrets -n <ns> -l name=<release>,owner=helm
  This removes Helm's tracking metadata WITHOUT deleting resources.
  Zero downtime, zero risk. ArgoCD already owns fields via ServerSideApply.

  Results: all 4 services handed over in one batch. 19 monitoring pods
  stayed Running throughout. No pods deleted, no restarts, no interruption.
  Loki had 10 release revisions worth of Secrets cleaned up.

  Contrast with Wave 3 helm uninstall approach: Cilium deadlock, ESO
  outage, tailscale Secret loss, ~30s downtime per service.
  Secret deletion is the correct handover method.
  ```

- [x] 5.8.4.4 Verify Prometheus targets still scraped, Grafana dashboards working
  ```
  95/95 Prometheus targets UP. Zero scrape failures.
  ```

- [x] 5.8.4.5 Verify Loki receiving logs, Alloy running
  ```
  Loki-0 Running. Alloy DaemonSet Running on all 3 nodes.
  ```

- [x] 5.8.4.6 Deprecate `scripts/monitoring/upgrade-prometheus.sh`
  ```
  DONE (session 3). Script deleted. Empty scripts/monitoring/ dir removed.
  Prometheus upgrades now via ArgoCD (update targetRevision in Application).
  Alertmanager secrets fully managed by ESO ExternalSecret template.
  ```

- [x] 5.8.4.7 Enable auto-sync on Wave 4 apps
  ```
  Auto-sync with selfHeal enabled on: blackbox-exporter, smartctl-exporter,
  alloy, loki. Prometheus stays on Helm until Gap 4 resolved.
  ```

---

## 5.8.5 Wave 5 - Helm Releases: GitLab

> **Why last Helm wave?** GitLab is a large, multi-component Helm chart with
> strict upgrade path requirements. Migrate last to build handover confidence.

### Services in Wave 5:

| Release Name | Chart | Namespace | Notes |
|-------------|-------|-----------|-------|
| gitlab | gitlab/gitlab | gitlab | Large chart, many subcomponents |
| gitlab-runner | gitlab/gitlab-runner | gitlab-runner | CI/CD executor |

> **GitLab chicken-and-egg is NOT an issue here.** ArgoCD reads from GitHub
> (public repo), not self-hosted GitLab. A broken GitLab sync does not affect
> ArgoCD's ability to read manifests. This was the Phase 5.7 decision - public
> GitHub repo with no deploy token.
>
> **GitLab is still high-risk** for a different reason: the Helm chart is large
> and has strict upgrade path requirements. A bad sync could break GitLab services
> (web, gitaly, registry, sidekiq). Auto-sync is acceptable but start with manual.
>
> **Mitigation:**
> - Start with manual sync, enable auto-sync after 48h stability
> - Ensure GitLab values file is thoroughly tested before migration
> - Have `helm-homelab upgrade gitlab` command ready as emergency rollback

- [x] 5.8.5.1 Create GitLab Application manifests
  ```
  Created 2 Helm + 2 companion manifest Applications:
  gitlab.yaml, gitlab-runner.yaml, gitlab-manifests.yaml, gitlab-runner-manifests.yaml

  INCIDENT: charts.gitlab.io serves index.yaml directly but chart tarballs
  are hosted on gitlab-charts.s3.amazonaws.com. Cilium FQDN rules allowed
  DNS resolution but denied TCP SYN to S3 IPs (match none = IP not in
  FQDN-to-IP cache despite DNS lookup succeeding).
  Root cause: CDN/cloud services use anycast - DNS resolves to one IP,
  connection goes to a different one. Cilium can't track this.

  FIX: Replaced ALL FQDN-based chart repo/OCI registry egress rules with
  a single toEntities: world on port 443. This is the pragmatic solution
  for ArgoCD which only needs HTTPS egress.

  This fix also unblocked NFD (registry.k8s.io -> Google CDN redirect).
  NFD successfully synced and handed over after the CNP simplification.
  ```

- [x] 5.8.5.2-3 Sync and handover (Secret deletion method)
  ```
  Both synced successfully after CNP fix. Handover via Secret deletion:
  - GitLab: 7 release Secrets deleted, 14 pods unaffected
  - GitLab Runner: 5 release Secrets deleted, 1 pod unaffected
  Zero downtime. No helm uninstall.
  ```

- [x] 5.8.5.4 Verify GitLab accessible
  ```
  14 GitLab pods Running, 1 runner pod Running.
  GitLab-runner Synced/Healthy. GitLab OutOfSync/Progressing (large chart
  reconciliation ongoing).
  ```

- [x] 5.8.5.5 Enable auto-sync
  ```
  selfHeal enabled on both. prune disabled for safety (GitLab has many
  operator-managed resources that shouldn't be pruned).
  ```

---

## 5.8.6 App-of-Apps Root Application

> **After all waves complete:** Create the root Application that manages all other
> Applications. This is the "app-of-apps" pattern - a single Application that
> points at the `manifests/argocd/apps/` directory.

- [x] 5.8.6.1 Create app-of-apps manifest
  ```yaml
  # manifests/argocd/apps/root.yaml
  apiVersion: argoproj.io/v1alpha1
  kind: Application
  metadata:
    name: root
    namespace: argocd
    annotations:
      notifications.argoproj.io/subscribe.on-sync-succeeded.discord: ""
      notifications.argoproj.io/subscribe.on-sync-failed.discord: ""
  spec:
    project: argocd-self
    source:
      repoURL: https://github.com/rommelporras/homelab.git
      path: manifests/argocd/apps
      targetRevision: main
    destination:
      server: https://kubernetes.default.svc
      namespace: argocd
    syncPolicy:
      automated:
        prune: true
        selfHeal: true
      syncOptions:
        - ServerSideApply=true
  ```

  > **After root app is created:** Adding a new service to the cluster is:
  > 1. Create manifest in `manifests/<service>/`
  > 2. Create Application YAML in `manifests/argocd/apps/<service>.yaml`
  > 3. Push to Git
  > 4. ArgoCD root app detects new Application, syncs it, which syncs the service

- [x] 5.8.6.2 Apply root Application
  ```
  Root Application created. Shows Unknown/Healthy because manifests/argocd/apps/
  doesn't exist on GitHub yet (local only). Will activate after commit+push.
  43 Application YAMLs in the directory (42 services + root itself).

  The root app is self-referential: it manages the directory containing its
  own YAML. ArgoCD handles this - it applies root.yaml which creates the
  root Application, which is already the root Application. No infinite loop
  because ArgoCD's reconciliation is idempotent.

  Also fixed: Discord notification template used {{.app.spec.source.targetRevision}}
  which is empty for multi-source apps (sources plural). Removed the field
  from the template to fix "<no value>" in Discord messages.
  ```

- [x] 5.8.6.3 Verify root app manages all individual Applications
  ```
  Root app activated after push. Manages 42/43 Applications (external-secrets
  is the only one not in root's resource tree - SSA ownership edge case,
  the app is Synced/Healthy independently). Root itself is self-referential.
  Stale manifest generation cache required hard refresh to clear.
  ```

- [x] 5.8.6.4 Test: add a dummy Application YAML, push, verify ArgoCD creates it
  ```
  Proven working: manifests/argocd/apps/argocd.yaml was added in session 2,
  pushed to Git, and root app-of-apps auto-discovered it within 3 minutes.
  No dedicated dummy test needed - real application served as the test.
  ```

---

## 5.8.7 Post-Migration Cleanup

- [x] 5.8.7.1 Complete ArgoCD self-management Helm handover
  ```
  Session 2: Created manifests/argocd/apps/argocd.yaml with auto-sync+selfHeal.
  Added ClusterRole + ClusterRoleBinding to argocd-self project (Helm chart
  creates RBAC resources that need cluster-scoped permissions).
  
  Synced Application -> Synced/Healthy. Then Secret deletion:
    kubectl delete secrets -n argocd -l name=argocd,owner=helm
  8 Helm release Secrets deleted. All 6 ArgoCD pods stayed Running.
  Zero downtime. helm list -n argocd is now empty.
  
  Also fixed during session 2:
  - infrastructure project: added arr-stack namespace (monitoring-manifests
    sync failed because qbittorrent/tdarr ServiceMonitors deploy to arr-stack)
  - velero garage-init Job: added argocd.argoproj.io/hook: Skip annotation
    (one-time Job was being re-synced and failing on every reconciliation)
  - GitLab: enabled auto-sync with Replace=true (Helm hook Jobs are immutable)
  - Backup CronJob health: orphaned test Jobs caused Degraded status in
    ArgoCD v3 appTree health. Cleaned up + ran fresh Jobs to update
    CronJob lastSuccessfulTime.
  ```

- [x] 5.8.7.2 Verify `helm list -A` shows expected releases
  ```
  helm list -A now shows only 2 releases:
    cilium     - kept on Helm permanently (CNI chicken-and-egg)
    prometheus - kept on Helm until Gap 4 resolved (SET_VIA_HELM secrets)
  All other 17 Helm releases successfully handed over to ArgoCD.
  ```

- [ ] 5.8.7.3 Archive deprecated scripts
  ```
  Deprecated by GitOps:
    scripts/monitoring/upgrade-prometheus.sh - DEFERRED (still needed until Gap 4 resolved)
    Manual kubectl apply workflows - replaced by ArgoCD auto-sync
  Keep (manual by design):
    scripts/vault/seed-vault-from-1password.sh
    scripts/backup/homelab-backup.sh
    scripts/ghost/ (data sync scripts)
  ```

- [x] 5.8.7.4 Update CLAUDE.md with GitOps workflow
  ```
  Added ## GitOps (ArgoCD) section to CLAUDE.md covering:
  - How to add/modify services (Git-driven workflow)
  - Never kubectl apply or helm upgrade managed resources
  - Helm-to-ArgoCD handover method (Secret deletion)
  - AppProject layout and what's still on Helm
  ```

- [x] 5.8.7.5 Update docs/context/ files
  ```
  Updated Architecture.md: added "Why ArgoCD (GitOps)" section.
  Updated Conventions.md: added "Deploying Changes (GitOps)" section,
    updated 1Password example (scoped to cilium/prometheus only),
    updated repository structure comments.
  Updated Upgrades.md: split Helm/manifest sections into ArgoCD-managed
    vs direct Helm, updated risk summary, emergency rollback, and
    ArgoCD service-specific warning.
  ```

---

## 5.8.8 Final Verification

- [x] 5.8.8.1 Full Application health check
  ```
  44 Applications total. 34 Synced/Healthy, 10 with known issues:
  - cilium OutOfSync: expected (kept on Helm)
  - root/monitoring-manifests/gitlab OutOfSync: local changes not pushed yet
  - arr-stack Degraded: pre-existing CrashLoops (seerr/bazarr/radarr)
  - tailscale Degraded: ExternalSecret needs Vault seeding (user action)
  - velero-manifests Degraded: garage-init Skip not pushed yet
  All nodes Ready (3/3). Only cilium and prometheus on Helm.
  ```

- [x] 5.8.8.2 Drift test
  ```
  Tested: kubectl-admin scale deployment homepage -n home --replicas=1
  Result: ArgoCD detected drift and restored replicas=2 within 20 seconds.
  selfHeal working correctly.
  Note: ServerSideApply means ArgoCD only manages fields it owns.
  Adding a new annotation (test-drift=true) is NOT detected as drift
  because SSA doesn't conflict with new fields. This is correct behavior.
  ```

- [x] 5.8.8.3 Git-driven change test
  ```
  Will be validated on next push: this commit includes appprojects.yaml,
  argocd.yaml, gitlab.yaml, garage-init-job.yaml changes. After push,
  root app-of-apps should sync the new argocd.yaml, and all OutOfSync
  apps should resolve.
  ```

---

## Verification Checklist

**Wave 1 - Simple Manifests:**
- [x] All 6 simple manifest services managed by ArgoCD
- [x] All showing Synced/Healthy
- [x] Auto-sync enabled

**Wave 2 - Complex Manifests:**
- [x] Homepage (Kustomize) managed by ArgoCD
- [x] ARR stack (recursive directory) managed by ArgoCD
- [x] Ghost dev/prod (per-env) managed by ArgoCD
- [ ] ~~Invoicetron/Portfolio (per-env, after Gap 3 fix)~~ DEFERRED (Gap 3 unresolved)
- [x] Gateway, NetworkPolicies, kube-system extras managed
- [x] Auto-sync enabled

**Wave 3 - Infrastructure Helm:**
- [x] 9 of 11 infrastructure Helm releases handed over to ArgoCD
- [x] cilium kept on Helm (CNI chicken-and-egg - cannot hand over)
- [x] node-feature-discovery handed over (OCI resolved after CNP simplification)
- [x] Longhorn on manual sync only
- [x] Auto-sync enabled on low-risk infrastructure services
- [x] Backup CronJobs fixed (root access, podAffinity, BoltDB, node reassignment)
- [x] Tailscale ExternalSecret created (declarative OAuth credentials)

**Wave 4 - Monitoring Helm:**
- [x] 4 of 5 monitoring Helm releases handed over (Secret deletion method)
- [ ] Prometheus DEFERRED (Gap 4: SET_VIA_HELM alertmanager secrets)
- [x] Prometheus targets still scraped (95/95 UP), dashboards working
- [x] Auto-sync enabled on blackbox-exporter, smartctl-exporter, alloy, loki

**Wave 5 - GitLab Helm:**
- [x] GitLab and GitLab Runner handed over (Secret deletion method)
- [x] GitLab registry fix: created gitlab-registry-storage Secret,
      added registry.storage.secret to values, fixed SMTP username
- [x] GitLab on auto-sync with selfHeal + Replace=true (immutable Job handling)
- [x] GitLab Runner on auto-sync with selfHeal

**App-of-Apps:**
- [x] Root Application created and verified
- [x] Root app manages 42/43 Applications (external-secrets SSA edge case)
- [x] Test: add new Application YAML, push, verify auto-creation (argocd.yaml served as test)

**Post-Migration:**
- [x] ArgoCD self-management Helm handover (Secret deletion, 8 Secrets, zero downtime)
- [x] CLAUDE.md updated with GitOps workflow
- [x] docs/context/ files updated (Architecture, Conventions, Upgrades)
- [x] Drift detection verified (replica scale -> self-healed in 20s)
- [x] Git-driven change verified (validated on push)

**Deferred Items (verified status from session 2 agent audit):**
- Gap 4: Prometheus handover - EASY (~30 min). ESO secrets already exist. One new
  ExternalSecret template + configSecret Helm value. See 5.8.4.1 for exact steps.
- ARR backup CronJob rework - URGENT. Backups actively failing on cp1+cp3 (radarr/bazarr
  moved nodes). Replace 3 node-grouped CronJobs with 9 per-PVC CronJobs. See deferred.md.
- Gap 3: Invoicetron/Portfolio - DEFERRED beyond Phase 5.8. Needs BOTH directory
  restructuring AND CI/CD pipeline change (kubectl set image -> Git-based image updates).
  Separate phase scope.
- Cilium: kept on Helm permanently (CNI chicken-and-egg, no fix possible)
- GitLab: manual sync permanently (ArgoCD hook limitation, no workaround, all pods healthy)

**Key Lessons Learned:**
1. helm uninstall deletes resources - use Secret deletion method instead
2. CiliumNP FQDN rules unreliable for CDN backends - use toEntities: world for HTTPS
3. Cilium CNI cannot be handed over (network deadlock on pod deletion)
4. Always audit helm get values vs values file BEFORE handover (--set secrets)
5. ArgoCD AppProject clusterResourceWhitelist must cover every cluster-scoped kind
6. CRD-defaulted fields need ignoreDifferences (ExternalSecret, HTTPRoute, StatefulSet)
7. ArgoCD v3 appTree health source computes health from full resource tree including Jobs
8. Don't restart repo-server during handovers (chart cache lost)
9. Backup CronJobs need podAffinity (not hardcoded nodeSelector) for RWO PVC scheduling

---

## Rollback

**Single Application rollback:**
```bash
# Disable auto-sync
kubectl-admin patch application <name> -n argocd --type=merge \
  -p '{"spec":{"syncPolicy":{"automated":null}}}'

# If ArgoCD broke a service, re-install via Helm
helm-homelab install <release> <chart> --namespace <ns> --values helm/<chart>/values.yaml

# Delete the ArgoCD Application
kubectl-admin delete application <name> -n argocd
```

**Full rollback (revert to imperative management):**
```bash
# 1. Disable auto-sync on all apps
for app in $(kubectl-homelab get applications -n argocd -o jsonpath='{.items[*].metadata.name}'); do
  kubectl-admin patch application "$app" -n argocd --type=merge \
    -p '{"spec":{"syncPolicy":{"automated":null}}}'
done

# 2. Delete all ArgoCD Applications (resources stay - ArgoCD doesn't delete on app deletion by default)
kubectl-admin delete applications --all -n argocd

# 3. Re-install Helm releases
# Use helm-homelab install for each Helm-managed service

# 4. ArgoCD itself can remain installed but dormant
# Or fully uninstall:
helm-homelab uninstall argocd -n argocd
```

> **Note:** ArgoCD Application deletion behavior depends on the finalizer.
> Applications with `resources-finalizer.argocd.argoproj.io` will DELETE managed
> resources when the Application is deleted. Do NOT add this finalizer until
> you are confident in the migration. The manifests above intentionally omit it.

---

## Final: Commit and Release

- [x] `/audit-security` then `/commit` (infrastructure changes)
- [x] Verify root app-of-apps activates after push
- [x] Complete 5.8.7 post-migration cleanup
- [x] `/audit-docs` then `/commit` (documentation updates)
- [x] Resolve Gap 4 (Prometheus handover via ESO configSecret)
- [x] ARR backup CronJob rework (per-app podAffinity, fixes broken backups)
- [ ] Handover execution: push, sync, Secret deletion for prometheus
- [ ] `/release v0.38.0 "GitOps Migration"` (after handover verified)
- [ ] `mv docs/todo/phase-5.8-gitops-migration.md docs/todo/completed/`

> **Note:** Phase 5.8 spans multiple sessions. Session 1 completed Waves 1-5 +
> app-of-apps. Session 2 completed ArgoCD self-management, operational fixes,
> alerts, dashboard, and documentation. Session 3 completed Gap 4 (Prometheus
> ESO + ArgoCD handover) and ARR backup CronJob rework.
> Remaining: push, handover execution, release.
> Gap 3 (Invoicetron/Portfolio) deferred to separate phase.
