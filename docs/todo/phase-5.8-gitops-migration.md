# Phase 5.8: GitOps Migration

> **Status:** Planned
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

- [ ] 5.8.0.1 Verify all Phase 5.6 gaps are resolved
  ```
  Gap 1: Invoicetron CI/CD image tag pattern - MUST be resolved before migration
  Gap 2: NFD values file - must exist at helm/nfd/values.yaml
  Gap 3: Namespace-less multi-target manifests - split into per-env directories
  Gap 4: Prometheus upgrade script runtime secrets - convert to existingSecret
  Gap 5: vault-unseal-keys - annotated for ArgoCD exclusion
  Gap 6: Intel GPU operator values file - must exist at helm/intel-device-plugins-operator/
  Gap 7: All 18 Helm releases have values files in helm/
  ```

- [ ] 5.8.0.2 Update ArgoCD CiliumNP for Helm chart repo egress
  ```bash
  # Phase 5.7 CNP only allows github.com + *.github.io + discord.com egress.
  # Wave 3/4 Helm Applications need repo-server to fetch charts from these domains:
  #   charts.longhorn.io, helm.cilium.io, charts.jetstack.io,
  #   charts.gitlab.io, charts.external-secrets.io,
  #   helm.releases.hashicorp.com, pkgs.tailscale.com
  # OCI registries (ArgoCD uses HTTPS, same port 443):
  #   quay.io, ghcr.io, registry.k8s.io
  # Already covered by *.github.io wildcard:
  #   prometheus-community, grafana, kubernetes-sigs, intel, vmware-tanzu, argoproj
  #
  # Add all non-*.github.io domains to argocd-egress CiliumNP toFQDNs rules.
  # IMPORTANT: DNS inspection rule (rules.dns.matchPattern: "*") must be in the
  # same policy as toFQDNs rules, otherwise FQDN-to-IP cache never populates.
  ```

- [ ] 5.8.0.3 Ensure Git state matches cluster state (drift check)
  ```bash
  # This is the most critical pre-migration step. ArgoCD shows OutOfSync for ANY
  # difference between Git and cluster state. Fix drift BEFORE creating Applications.

  # Check for kubectl edits (fields not in manifests):
  for ns in ai browser uptime-kuma atuin cloudflare arr-stack home ghost-dev ghost-prod karakeep; do
    echo "=== $ns ===" && kubectl-admin diff -f manifests/$ns/ 2>&1 | head -20
  done

  # Check for Helm values drift (--set overrides not in values files):
  for release in $(helm-homelab list -A --no-headers | awk '{print $1}'); do
    echo "=== $release ===" && helm-homelab get values $release -n $(helm-homelab list -A --no-headers | grep "^$release " | awk '{print $2}') 2>&1 | head -10
  done

  # Known drift sources to check:
  # - Invoicetron image tags (CI/CD patches via kubectl set image)
  # - Portfolio image tags (same CI/CD pattern)
  # - Any resources created by operators (Longhorn volumes, cert-manager certs)
  # - Helm --set overrides at install time not captured in values files
  ```

- [ ] 5.8.0.4 Verify ArgoCD is healthy
  ```bash
  kubectl-homelab get pods -n argocd
  # All pods Running
  kubectl-homelab get application -n argocd
  # argocd self-management app should be Synced/Healthy
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

- [ ] 5.8.1.1 Create Application manifest
  ```yaml
  # Example for ai/ollama:
  # manifests/argocd/apps/ai.yaml
  apiVersion: argoproj.io/v1alpha1
  kind: Application
  metadata:
    name: ai
    namespace: argocd
    annotations:
      notifications.argoproj.io/subscribe.on-sync-succeeded.discord: ""
      notifications.argoproj.io/subscribe.on-sync-failed.discord: ""
  spec:
    project: homelab-apps
    source:
      repoURL: https://github.com/rommelporras/homelab.git
      path: manifests/ai
      targetRevision: main
    destination:
      server: https://kubernetes.default.svc
      namespace: ai
    syncPolicy:
      syncOptions:
        - ServerSideApply=true
        - CreateNamespace=false
        - PrunePropagationPolicy=foreground
      # Manual sync first - enable auto after verification
      # automated:
      #   prune: true
      #   selfHeal: true
  ```

- [ ] 5.8.1.2 Apply all Wave 1 Applications
  ```bash
  kubectl-admin apply -f manifests/argocd/apps/ai.yaml
  kubectl-admin apply -f manifests/argocd/apps/browser.yaml
  kubectl-admin apply -f manifests/argocd/apps/uptime-kuma.yaml
  kubectl-admin apply -f manifests/argocd/apps/atuin.yaml
  kubectl-admin apply -f manifests/argocd/apps/cloudflare.yaml
  kubectl-admin apply -f manifests/argocd/apps/tailscale.yaml
  ```

- [ ] 5.8.1.3 Verify all Wave 1 apps in ArgoCD UI
  ```
  Each Application should show:
  - Sync Status: Synced (or OutOfSync if drift exists)
  - Health: Healthy
  - If OutOfSync: investigate and fix drift in Git BEFORE syncing
  ```

- [ ] 5.8.1.4 Trigger manual sync for each app
  ```bash
  # Via ArgoCD UI: click Sync for each app
  # Or via CLI (if installed):
  # argocd app sync ai --server argocd.k8s.rommelporras.com --grpc-web
  ```

- [ ] 5.8.1.5 Wait 24h, verify no drift detected

- [ ] 5.8.1.6 Enable auto-sync on Wave 1 apps
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

- [ ] 5.8.2.1 Create all Wave 2 Application manifests
- [ ] 5.8.2.2 Apply Wave 2 Applications
- [ ] 5.8.2.3 Fix any drift before syncing
- [ ] 5.8.2.4 Manual sync and verify
- [ ] 5.8.2.5 Wait 24h, verify stability
- [ ] 5.8.2.6 Enable auto-sync on Wave 2 apps

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

- [ ] 5.8.3.1 Start with metrics-server (lowest risk)
  ```yaml
  # manifests/argocd/apps/metrics-server.yaml
  apiVersion: argoproj.io/v1alpha1
  kind: Application
  metadata:
    name: metrics-server
    namespace: argocd
    annotations:
      notifications.argoproj.io/subscribe.on-sync-succeeded.discord: ""
      notifications.argoproj.io/subscribe.on-sync-failed.discord: ""
  spec:
    project: infrastructure
    # Multi-source: chart from Helm repo + values from GitHub repo
    sources:
      - repoURL: https://kubernetes-sigs.github.io/metrics-server/
        chart: metrics-server
        targetRevision: "3.13.0"
        helm:
          valueFiles:
            - $values/helm/metrics-server/values.yaml
      - repoURL: https://github.com/rommelporras/homelab.git
        targetRevision: main
        ref: values
    destination:
      server: https://kubernetes.default.svc
      namespace: kube-system
    syncPolicy:
      syncOptions:
        - ServerSideApply=true
        - CreateNamespace=false
  ```

- [ ] 5.8.3.2 Execute handover for metrics-server
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

- [ ] 5.8.3.3 Repeat handover for remaining Wave 3 services
  ```
  Order (increasing risk):
  1. metrics-server (done above)
  2. node-feature-discovery
  3. intel-device-plugins-operator
  4. intel-device-plugins-gpu
  5. tailscale-operator
  6. cert-manager
  7. external-secrets
  8. vault
  9. velero
  10. longhorn (HIGH RISK - manual sync only)
  11. cilium (HIGH RISK - manual sync only)
  ```

  > **After each handover:** verify the service still works correctly.
  > Wait at least 1 hour between high-risk services.

- [ ] 5.8.3.4 Verify all Wave 3 apps Synced/Healthy
- [ ] 5.8.3.5 `helm list -A` should show no releases for migrated services
- [ ] 5.8.3.6 Enable auto-sync on low-risk Wave 3 apps (NOT Cilium, NOT Longhorn)

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

- [ ] 5.8.4.1 Resolve Prometheus runtime secret dependency (Gap 4)
  ```
  Before: upgrade-prometheus.sh reads from K8s Secrets at runtime
  After: values.yaml references existingSecret fields directly
  Test: helm template with new values, verify Alertmanager config renders correctly
  ```

- [ ] 5.8.4.2 Create all Wave 4 Application manifests
- [ ] 5.8.4.3 Execute handover procedure for each (blackbox-exporter first, prometheus last)
- [ ] 5.8.4.4 Verify Prometheus targets still scraped, Grafana dashboards working
- [ ] 5.8.4.5 Verify Loki receiving logs, Alloy running
- [ ] 5.8.4.6 Deprecate `scripts/monitoring/upgrade-prometheus.sh`
- [ ] 5.8.4.7 Enable auto-sync on Wave 4 apps

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

- [ ] 5.8.5.1 Create GitLab Application manifest (manual sync initially)
- [ ] 5.8.5.2 Dry-run sync, verify no unexpected changes
- [ ] 5.8.5.3 Execute handover procedure
- [ ] 5.8.5.4 Verify GitLab accessible, CI/CD pipelines working
- [ ] 5.8.5.5 Enable auto-sync after 48h stability confirmed

---

## 5.8.6 App-of-Apps Root Application

> **After all waves complete:** Create the root Application that manages all other
> Applications. This is the "app-of-apps" pattern - a single Application that
> points at the `manifests/argocd/apps/` directory.

- [ ] 5.8.6.1 Create app-of-apps manifest
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

- [ ] 5.8.6.2 Apply root Application
- [ ] 5.8.6.3 Verify root app manages all individual Applications
- [ ] 5.8.6.4 Test: add a dummy Application YAML, push, verify ArgoCD creates it

---

## 5.8.7 Post-Migration Cleanup

- [ ] 5.8.7.1 Complete ArgoCD self-management Helm handover
  ```bash
  # ArgoCD was installed via `helm install` in Phase 5.7. The self-management
  # Application uses `helm template`. The Helm release still exists:
  helm --kubeconfig ~/.kube/homelab.yaml list -n argocd
  # Expected: argocd release present

  # This is the most dangerous handover - if it fails, ArgoCD can't fix itself.
  # Prerequisites: self-management Application MUST be Synced/Healthy first.
  # The Application was created in Phase 5.7.7 and should be stable by now.

  # 1. Verify self-management app is Synced/Healthy
  kubectl-admin get application argocd -n argocd
  # 2. Enable selfHeal on the self-management app
  kubectl-admin patch application argocd -n argocd --type=merge \
    -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":true,"prune":false}}}}'
  # 3. Uninstall the Helm release
  helm-homelab uninstall argocd -n argocd
  # 4. Immediately force refresh
  kubectl-admin annotate application argocd -n argocd argocd.argoproj.io/refresh=hard --overwrite
  # 5. Watch ArgoCD self-heal (pods will be briefly deleted then recreated)
  kubectl-admin get pods -n argocd -w
  # 6. Verify all pods Running and Application Synced/Healthy
  ```

- [ ] 5.8.7.2 Verify `helm list -A` shows NO releases
  ```bash
  helm --kubeconfig ~/.kube/homelab.yaml list -A
  # Expected: empty (all releases handed over to ArgoCD)
  ```

- [ ] 5.8.7.3 Archive deprecated scripts
  ```bash
  # These scripts are replaced by GitOps:
  # scripts/monitoring/upgrade-prometheus.sh -> DEPRECATED (ArgoCD syncs Helm values)
  # Any manual kubectl apply workflows -> DEPRECATED
  # Keep scripts/vault/seed-vault-from-1password.sh (manual by design)
  # Keep scripts/backup/homelab-backup.sh (off-site backup, not cluster-managed)
  # Keep scripts/ghost/ (data sync scripts, not deployment)
  ```

- [ ] 5.8.7.4 Update CLAUDE.md with GitOps workflow
  ```
  Add to CLAUDE.md:
  - Changes go through Git, not kubectl apply
  - ArgoCD syncs from main branch (GitHub, public repo)
  - Manual sync required for: Cilium, Longhorn (high-risk infrastructure)
  - To add a new service: manifest + ArgoCD Application YAML + push
  - Helm values changes: edit helm/<chart>/values.yaml + push
  ```

- [ ] 5.8.7.5 Update docs/context/ files
  ```
  - Architecture.md: add GitOps section
  - Conventions.md: update deployment workflow
  - Add docs/context/GitOps.md with ArgoCD architecture, AppProject map, sync policies
  ```

---

## 5.8.8 Final Verification

- [ ] 5.8.8.1 Full Application health check
  ```bash
  kubectl-homelab get applications -n argocd -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,PROJECT:.spec.project
  # All should be Synced/Healthy
  ```

- [ ] 5.8.8.2 Drift test
  ```bash
  # Make a manual change and verify ArgoCD detects it
  kubectl-admin annotate deployment homepage -n home test-drift=true
  # ArgoCD should show 'home' Application as OutOfSync within 3 minutes
  # If auto-sync: ArgoCD should self-heal (remove the annotation)
  # Clean up if manual sync: sync the app
  ```

- [ ] 5.8.8.3 Git-driven change test
  ```bash
  # Make a change in Git and verify ArgoCD applies it
  # Edit a resource replica count in manifests/
  # Push to main
  # ArgoCD should detect and sync within 3 minutes
  ```

---

## Verification Checklist

**Wave 1 - Simple Manifests:**
- [ ] All 6 simple manifest services managed by ArgoCD
- [ ] All showing Synced/Healthy
- [ ] Auto-sync enabled

**Wave 2 - Complex Manifests:**
- [ ] Homepage (Kustomize) managed by ArgoCD
- [ ] ARR stack (recursive directory) managed by ArgoCD
- [ ] Ghost dev/prod (per-env) managed by ArgoCD
- [ ] Invoicetron/Portfolio (per-env, after Gap 3 fix) managed by ArgoCD
- [ ] Gateway, NetworkPolicies, kube-system extras managed
- [ ] Auto-sync enabled

**Wave 3 - Infrastructure Helm:**
- [ ] All 11 infrastructure Helm releases adopted by ArgoCD
- [ ] `helm list -A` shows no infrastructure releases
- [ ] Cilium and Longhorn on manual sync only
- [ ] Auto-sync enabled on low-risk infrastructure services

**Wave 4 - Monitoring Helm:**
- [ ] All 5 monitoring Helm releases adopted by ArgoCD
- [ ] `upgrade-prometheus.sh` deprecated
- [ ] Prometheus targets still scraped, dashboards working
- [ ] Auto-sync enabled

**Wave 5 - GitLab Helm:**
- [ ] GitLab and GitLab Runner adopted by ArgoCD
- [ ] Auto-sync enabled after 48h stability (no chicken-and-egg - ArgoCD reads from GitHub)
- [ ] CI/CD pipelines still working

**App-of-Apps:**
- [ ] Root Application managing all individual Applications
- [ ] Adding new Application YAML to Git auto-creates ArgoCD Application
- [ ] Self-management Application (ArgoCD managing itself) stable

**Post-Migration:**
- [ ] ArgoCD self-management Helm handover complete
- [ ] `helm list -A` shows NO releases (all handed to ArgoCD)
- [ ] Deprecated scripts archived
- [ ] CLAUDE.md updated with GitOps workflow
- [ ] Drift detection verified (manual change -> auto-heal)
- [ ] Git-driven change verified (push -> auto-sync)

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

- [ ] `/audit-security` then `/commit`
- [ ] `/audit-docs` then `/commit`
- [ ] `/release v0.38.0 "GitOps Migration"`
- [ ] `mv docs/todo/phase-5.8-gitops-migration.md docs/todo/completed/`
- [ ] Celebrate - the cluster is now GitOps-managed
