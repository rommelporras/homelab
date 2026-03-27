# Phase 5.7: ArgoCD Installation & Bootstrap

> **Status:** Complete (v0.37.0 released 2026-03-28)
> **Target:** v0.37.0
> **Prerequisite:** Phase 5.6 (v0.36.0 - pre-GitOps validation complete, VAP in Deny mode)
> **DevOps Topics:** GitOps, declarative infrastructure, continuous delivery, app-of-apps
> **CKA Topics:** Helm chart management, RBAC, NetworkPolicy, resource management

> **Purpose:** Install ArgoCD on the cluster and configure it as the GitOps engine.
> This phase deploys ArgoCD, connects it to the self-hosted GitLab repository,
> sets up monitoring/notifications, and establishes the app-of-apps bootstrap pattern.
> No services are migrated yet - that's Phase 5.8.
>
> **Learning Goal:** GitOps workflow with ArgoCD, declarative cluster management,
> app-of-apps pattern, ArgoCD RBAC via AppProjects.

> **Why non-HA?** Cluster has 179 pods at ~60% memory (3 nodes, 16GB each).
> ArgoCD HA adds 15+ pods with ~2.5 CPU cores and ~3.5Gi memory requests.
> Non-HA adds ~5-7 pods with ~835m CPU and ~1.2Gi memory. ArgoCD downtime only
> blocks new syncs - running applications are unaffected. Upgrade to HA later
> by switching Helm values if needed.
>
> **ArgoCD version:** v3.3.5 (chart 9.4.16). v3.4.0 not GA yet - upgrade deferred
> (see docs/todo/deferred.md). v3.3.5 works on K8s 1.35 despite official matrix
> covering 1.31-1.34. Helm chart: `argo/argo-cd`.
>
> **Key ArgoCD v3 behaviors:**
> - Uses `helm template` to render charts, NOT `helm install` - no Helm releases in cluster
> - `ServerSideApply=true` mandatory for self-managed ArgoCD (CRD size exceeds client-side limits)
> - Resource tracking is annotation-based by default (not label)
> - ESO health checks built-in (ExternalSecret, SecretStore, ClusterSecretStore)
> - Cilium dynamic resources (CiliumIdentity, CiliumEndpoint) excluded by default
> - Legacy repo config in argocd-cm removed - Secret-based repo management only
> - Metrics changed: use labels on `argocd_app_info` (not separate `argocd_app_sync_status`)
>
> **Why ArgoCD over FluxCD?** Both are CNCF-graduated. ArgoCD wins for this homelab because:
> (1) built-in web UI helps visualize complex dependency chains across 30+ services,
> (2) larger community with more tutorials/examples for self-hosted setups,
> (3) ArgoCD v3.0 closed the security/RBAC gap that previously favored Flux,
> (4) ApplicationSets handle the homelab's multi-namespace structure well.
> FluxCD's native Helm lifecycle (`helm install/upgrade`) is better, but ArgoCD's `helm template`
> approach is acceptable since we already version-pin everything.
>
> **K8s 1.35 Compatibility:** ArgoCD v3.3.x officially tests K8s 1.31-1.34 only.
> K8s 1.35 Go client upgrade tracked in argoproj/argo-cd#25767, milestoned to v3.4.
> v3.4.0-rc3 released March 25, 2026 - GA estimated ~May 4, 2026.
> Installing v3.3.5 now; upgrade to v3.4.0 deferred (see docs/todo/deferred.md).

---

## 5.7.0 Pre-Installation Checklist

> **Gate:** Do not proceed until ALL Phase 5.6 verification items are checked.

- [x] 5.7.0.1 Verify Phase 5.6 is complete
  ```bash
  # VAP mode (requires kubectl-admin - claude-code RBAC can't read VAP bindings)
  kubectl-admin get validatingadmissionpolicybinding restrict-image-registries-binding \
    -o jsonpath='{.spec.validationActions}'
  # Actual: ["Warn"] - Deny mode deferred to 2026-04-02 (see deferred.md). Not a blocker.

  # kube-bench CronJob deployed
  kubectl-homelab get cronjob kube-bench-weekly -n kube-system
  # Actual: deployed, schedule 0 20 * * 0 Asia/Manila

  # All ExternalSecrets synced
  kubectl-homelab get externalsecrets -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,STATUS:.status.conditions[0].reason | grep -v SecretSynced
  # Actual: no output (all synced)
  ```

- [x] 5.7.0.2 Verify ArgoCD chart version supports K8s 1.35
  ```bash
  helm-homelab repo add argo https://argoproj.github.io/argo-helm
  helm-homelab repo update argo
  helm-homelab search repo argo/argo-cd --versions | head -10
  # Actual: v3.4.0 not GA yet. Latest: chart 9.4.16 = app v3.3.5.
  # No pre-release charts available (--devel checked).
  # Decision: proceed with v3.3.5, upgrade to v3.4.0 deferred.
  # CHART_VERSION=9.4.16 APP_VERSION=v3.3.5
  ```

- [x] 5.7.0.3 Verify VAP allows ArgoCD images (dry-run test)
  ```bash
  # ArgoCD image: quay.io - passes VAP
  kubectl-admin run test-argocd --image=quay.io/argoproj/argocd:v3.3.5 \
    --dry-run=server -n default
  # Actual: pod created (dry-run), no VAP warning

  # Redis image: chart uses ecr-public.aws.com (NOT public.ecr.aws)
  kubectl-admin run test-redis --image=ecr-public.aws.com/docker/library/redis:8.2.3-alpine \
    --dry-run=server -n default
  # Actual: pod created BUT VAP warns - ecr-public.aws.com not in allowed list.
  # VAP allows public.ecr.aws, not ecr-public.aws.com (different domain).
  # Fix: override redis image in Helm values to use public.ecr.aws registry.
  # (Warn-only now; would block when VAP switches to Deny)
  ```

---

## 5.7.1 Namespace and Secrets

### 5.7.1.1 Create argocd namespace

- [x] 5.7.1.1a Create namespace manifest
  ```yaml
  # manifests/argocd/namespace.yaml
  apiVersion: v1
  kind: Namespace
  metadata:
    name: argocd
    labels:
      pod-security.kubernetes.io/enforce: baseline
      pod-security.kubernetes.io/enforce-version: latest
      pod-security.kubernetes.io/warn: restricted
      pod-security.kubernetes.io/warn-version: latest
      eso-enabled: "true"
  ```

- [x] 5.7.1.1b Apply namespace
  ```bash
  kubectl-admin apply -f manifests/argocd/namespace.yaml
  # Actual: namespace/argocd created
  # Note: used repo pattern (audit+warn restricted) instead of plan's enforce-version/warn-version
  ```

### 5.7.1.2 Vault secrets preparation

> **Manual step:** Run on a terminal with `op` access (not this one).

- [x] 5.7.1.2a Add ArgoCD secrets to 1Password
  ```
  1. Add gitops webhook to shared item:
     op item edit "Discord Webhooks" --vault "Kubernetes" "gitops=<webhook URL>"

  2. Create ArgoCD item: op://Kubernetes/ArgoCD/
     Fields:
     - admin-password: bcrypt hash (htpasswd -nbBC 10 "" <pw> | tr -d ':\n' | sed 's/$2y/$2a/')
     - server-secret-key: random hex (openssl rand -hex 16)

  Discord webhook uses shared item: op://Kubernetes/Discord Webhooks/gitops
  No GitLab deploy token needed - repo is public on GitHub.
  ```

- [x] 5.7.1.2b Seed Vault with ArgoCD secrets
  ```bash
  # ArgoCD section added to scripts/vault/seed-vault-from-1password.sh
  # Run from trusted terminal with op + vault access:
  #   vault kv put secret/argocd \
  #     admin-password="$(op read 'op://Kubernetes/ArgoCD/admin-password')" \
  #     discord-webhook-url="$(op read 'op://Kubernetes/Discord Webhooks/gitops')" \
  #     server-secret-key="$(op read 'op://Kubernetes/ArgoCD/server-secret-key')"
  #   vault kv get secret/argocd  # verify
  # Discord webhook reads from shared "Discord Webhooks" item, not ArgoCD item.
  ```

### 5.7.1.3 ExternalSecrets

- [x] 5.7.1.3a Create ExternalSecret for ArgoCD
  ```yaml
  # manifests/argocd/externalsecret.yaml
  # Actual: used external-secrets.io/v1 (not v1beta1) to match repo convention
  # Actual: remoteRef.key uses "argocd" not "secret/argocd" (ClusterSecretStore has path: secret)
  apiVersion: external-secrets.io/v1
  kind: ExternalSecret
  metadata:
    name: argocd-vault-secrets
    namespace: argocd
  spec:
    refreshInterval: 1h
    secretStoreRef:
      name: vault-backend
      kind: ClusterSecretStore
    target:
      name: argocd-secret
      creationPolicy: Merge
      # Merge with the argocd-secret created by Helm (contains TLS certs, etc.)
    data:
      - secretKey: admin.password
        remoteRef:
          key: secret/argocd
          property: admin-password
      - secretKey: server.secretkey
        remoteRef:
          key: secret/argocd
          property: server-secret-key
  ---
  apiVersion: external-secrets.io/v1beta1
  kind: ExternalSecret
  metadata:
    name: argocd-repo-creds
    namespace: argocd
  spec:
    refreshInterval: 1h
    secretStoreRef:
      name: vault-backend
      kind: ClusterSecretStore
    target:
      name: argocd-repo-gitlab
      creationPolicy: Owner
      template:
        metadata:
          labels:
            argocd.argoproj.io/secret-type: repo-creds
        data:
          type: "git"
          url: "https://gitlab.k8s.rommelporras.com"
          username: "{{ .username }}"
          password: "{{ .password }}"
    data:
      - secretKey: username
        remoteRef:
          key: secret/argocd
          property: gitlab-deploy-token-username
      - secretKey: password
        remoteRef:
          key: secret/argocd
          property: gitlab-deploy-token-password
  ---
  apiVersion: external-secrets.io/v1beta1
  kind: ExternalSecret
  metadata:
    name: argocd-notifications-secret
    namespace: argocd
  spec:
    refreshInterval: 1h
    secretStoreRef:
      name: vault-backend
      kind: ClusterSecretStore
    target:
      name: argocd-notifications-secret
      creationPolicy: Owner
    data:
      - secretKey: discord-webhook-url
        remoteRef:
          key: secret/argocd
          property: discord-webhook-url
  ```

  > **Ordering note:** The `argocd-secret` ExternalSecret uses `creationPolicy: Merge` which
  > patches an existing Secret. `argocd-secret` is created by the Helm chart in step 5.7.2.2.
  > Apply ExternalSecrets BEFORE Helm install, but verify `SecretSynced` status AFTER Helm
  > install completes (the merge target doesn't exist until Helm creates it). ESO will retry
  > automatically once the target Secret appears.
  >
  > **Why `repo-creds` not `repository`?** `repo-creds` is a credential template - it matches
  > any repo URL starting with `https://gitlab.k8s.rommelporras.com`. This avoids creating
  > a separate Secret for each repo. When ArgoCD sees a repo URL matching the template prefix,
  > it automatically uses these credentials.

- [x] 5.7.1.3b Apply ExternalSecrets
  ```bash
  kubectl-admin apply -f manifests/argocd/externalsecret.yaml
  # Actual: all 3 created. Status: SecretSyncedError (expected - Vault secret/argocd
  # not seeded yet). ESO will auto-retry once user seeds Vault (step 5.7.1.2b).
  # argocd-vault-secrets (Merge) will also wait for Helm to create argocd-secret.
  ```

---

## 5.7.2 Helm Installation

- [x] 5.7.2.1 Create Helm values file
  ```yaml
  # helm/argocd/values.yaml
  global:
    domain: argocd.k8s.rommelporras.com

  configs:
    params:
      # TLS terminated at Cilium Gateway - ArgoCD serves plain HTTP
      server.insecure: true
      # gRPC-web for CLI access through Gateway (no separate GRPCRoute needed)
      server.enable.gzip: true

    cm:
      # Increase status processing to handle 30+ apps
      timeout.reconciliation: 180s
      # Resource exclusions for dynamic resources ArgoCD should ignore.
      # NOTE: ArgoCD v3 defaults already exclude CiliumIdentity, CiliumEndpoint,
      # CertificateRequest, Endpoints, EndpointSlice, and Lease.
      # We add Longhorn and Velero dynamic resources which are NOT in defaults.
      resource.exclusions: |
        - apiGroups: ["longhorn.io"]
          kinds: ["Volume", "Replica", "Snapshot", "Backup", "BackupVolume",
                  "InstanceManager", "Engine", "ShareManager", "Node",
                  "BackupBackingImage"]
          clusters: ["*"]
        - apiGroups: ["velero.io"]
          kinds: ["Backup", "Restore", "PodVolumeBackup", "PodVolumeRestore",
                  "BackupStorageLocation", "VolumeSnapshotLocation"]
          clusters: ["*"]

    rbac:
      policy.default: role:readonly
      policy.csv: |
        # Admin access for the admin user
        p, role:admin, applications, *, */*, allow
        p, role:admin, clusters, get, *, allow
        p, role:admin, repositories, *, *, allow
        p, role:admin, logs, get, *, allow
        p, role:admin, exec, create, */*, allow
        g, admin, role:admin

    notifications:
      enabled: true

  # Non-HA: single replica for all components
  controller:
    replicas: 1
    resources:
      requests:
        cpu: 250m
        memory: 512Mi
      limits:
        memory: 1Gi
    metrics:
      enabled: true
      serviceMonitor:
        enabled: true
        additionalLabels:
          release: prometheus

  server:
    replicas: 1
    resources:
      requests:
        cpu: 50m
        memory: 128Mi
      limits:
        memory: 256Mi
    metrics:
      enabled: true
      serviceMonitor:
        enabled: true
        additionalLabels:
          release: prometheus

  repoServer:
    replicas: 1
    resources:
      requests:
        cpu: 100m
        memory: 256Mi
      limits:
        memory: 512Mi
    metrics:
      enabled: true
      serviceMonitor:
        enabled: true
        additionalLabels:
          release: prometheus

  applicationSet:
    replicas: 1
    resources:
      requests:
        cpu: 50m
        memory: 64Mi
      limits:
        memory: 128Mi
    metrics:
      enabled: true
      serviceMonitor:
        enabled: true
        additionalLabels:
          release: prometheus

  notifications:
    resources:
      requests:
        cpu: 50m
        memory: 64Mi
      limits:
        memory: 128Mi
    metrics:
      enabled: true
      serviceMonitor:
        enabled: true
        additionalLabels:
          release: prometheus

  redis:
    resources:
      requests:
        cpu: 50m
        memory: 64Mi
      limits:
        memory: 128Mi

  dex:
    # Disable Dex (SSO) - homelab uses local admin account
    # Enable later if SSO is needed
    enabled: false
  ```

  > **Resource estimates (non-HA total):**
  > | Component | CPU Request | Memory Request |
  > |-----------|-------------|----------------|
  > | application-controller | 250m | 512Mi |
  > | server | 50m | 128Mi |
  > | repo-server | 100m | 256Mi |
  > | applicationset-controller | 50m | 64Mi |
  > | notifications-controller | 50m | 64Mi |
  > | redis | 50m | 64Mi |
  > | **Total** | **550m** | **1088Mi** |
  >
  > ~1Gi memory on a cluster at ~60% (9.6GB/16GB per node). Comfortable fit.

- [x] 5.7.2.2 Install ArgoCD via Helm
  ```bash
  helm-homelab install argocd argo/argo-cd \
    --namespace argocd \
    --version 9.4.16 \
    --values helm/argocd/values.yaml
  # Note: server.insecure already in values.yaml, no need for --set override
  # Note: --server-side --force-conflicts not needed for helm install (only for kubectl apply of CRDs)

  # Actual: 6 pods all Running/Ready (+ 1 completed redis-secret-init Job):
  #   argocd-application-controller-0 (StatefulSet)
  #   argocd-applicationset-controller (Deployment)
  #   argocd-notifications-controller (Deployment)
  #   argocd-redis (Deployment)
  #   argocd-repo-server (Deployment)
  #   argocd-server (Deployment)
  # Redis image override to public.ecr.aws worked (no VAP warnings)
  ```

  > **Gotcha:** If CRD installation fails with "metadata annotations too long",
  > use `--set crds.install=false` and apply CRDs separately:
  > ```bash
  > kubectl-admin apply --server-side --force-conflicts \
  >   -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.4.0/manifests/crds/application-crd.yaml
  > kubectl-admin apply --server-side --force-conflicts \
  >   -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.4.0/manifests/crds/applicationset-crd.yaml
  > kubectl-admin apply --server-side --force-conflicts \
  >   -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.4.0/manifests/crds/appproject-crd.yaml
  > ```

- [x] 5.7.2.3 Verify installation
  ```bash
  kubectl-homelab get pods -n argocd
  # Actual: 6/6 Running, 1/1 Ready each

  kubectl-homelab get svc -n argocd
  # Actual: argocd-server ClusterIP on ports 80 (http->8080) and 443 (https->8443)
  # Note: service port is 80, not 8080 - HTTPRoute must target port 80

  # ArgoCD version
  # Actual: quay.io/argoproj/argocd:v3.3.5
  ```

---

## 5.7.3 Networking

### 5.7.3.1 HTTPRoute

- [x] 5.7.3.1a Create HTTPRoute for ArgoCD UI
  ```yaml
  # manifests/argocd/httproute.yaml
  apiVersion: gateway.networking.k8s.io/v1
  kind: HTTPRoute
  metadata:
    name: argocd
    namespace: argocd
  spec:
    parentRefs:
      - name: homelab-gateway
        namespace: default
        sectionName: https
    hostnames:
      - argocd.k8s.rommelporras.com
    rules:
      - matches:
          - path:
              type: PathPrefix
              value: /
        backendRefs:
          - name: argocd-server
            port: 80
            # Note: plan had port 8080 (container port) but service port is 80
  ```

- [x] 5.7.3.1b Add DNS entry in AdGuard
  ```
  argocd.k8s.rommelporras.com -> 10.10.30.20
  # Actual: covered by *.k8s.rommelporras.com wildcard. No AdGuard change needed.
  # nslookup from WSL resolves via 10.255.255.254 (WSL DNS) -> 10.10.30.20
  # Note: 10.10.30.53 (AdGuard direct) unreachable from WSL
  ```

- [x] 5.7.3.1c Apply and verify
  ```bash
  kubectl-admin apply -f manifests/argocd/httproute.yaml
  # Actual: httproute.gateway.networking.k8s.io/argocd created
  curl -sk https://argocd.k8s.rommelporras.com | head -5
  # Actual: ArgoCD HTML response (Argo CD title, main.js loaded)
  ```

### 5.7.3.2 CiliumNetworkPolicy

- [x] 5.7.3.2a Create CiliumNetworkPolicy for argocd namespace
  ```yaml
  # manifests/argocd/networkpolicy.yaml
  # Single policy: endpointSelector: {} = all pods in namespace.
  # Cilium default-deny: ingress/egress sections define ONLY what's allowed.
  # Any traffic not listed is denied (Cilium deny-by-default when policy exists).
  # NOTE: ingress: [{}] = allow-all, ingress: [] = deny-all in Cilium.
  # We use neither - we list specific allow rules only.
  apiVersion: cilium.io/v2
  kind: CiliumNetworkPolicy
  metadata:
    name: argocd
    namespace: argocd
  spec:
    endpointSelector: {}
    ingress:
      # Allow intra-namespace traffic between ArgoCD components
      - fromEndpoints:
          - matchLabels:
              app.kubernetes.io/part-of: argocd
      # Allow Prometheus scraping from monitoring namespace
      - fromEndpoints:
          - matchLabels:
              app.kubernetes.io/name: prometheus
            matchExpressions:
              - key: io.kubernetes.pod.namespace
                operator: In
                values: ["monitoring"]
        toPorts:
          - ports:
              - port: "8082"  # controller metrics
                protocol: TCP
              - port: "8083"  # server metrics
                protocol: TCP
              - port: "8084"  # repo-server metrics
                protocol: TCP
              - port: "9001"  # notifications metrics
                protocol: TCP
      # Allow Gateway (Cilium) to reach argocd-server
      - fromEntities:
          - cluster
        toPorts:
          - ports:
              - port: "8080"
                protocol: TCP
    egress:
      # Allow DNS
      - toEndpoints:
          - matchLabels:
              io.kubernetes.pod.namespace: kube-system
              k8s-app: kube-dns
        toPorts:
          - ports:
              - port: "53"
                protocol: UDP
              - port: "53"
                protocol: TCP
      # Allow kube-apiserver access (controller + server)
      - toEntities:
          - kube-apiserver
          - remote-node
        toPorts:
          - ports:
              - port: "6443"
                protocol: TCP
      # Allow GitLab access (repo-server clones from GitLab via Gateway VIP)
      # Gateway LB VIP requires L4-only rule (no toPorts) - L7 envoy interferes
      # See docs/context/Networking.md "Reach Gateway LB VIP from pods"
      - toCIDR:
          - 10.10.30.20/32
      # Allow Discord webhooks (notifications-controller)
      - toFQDNs:
          - matchName: discord.com
          - matchName: discordapp.com
        toPorts:
          - ports:
              - port: "443"
                protocol: TCP
      # Allow intra-namespace (components talk to each other + redis)
      - toEndpoints:
          - matchLabels:
              app.kubernetes.io/part-of: argocd
  ```

  > **Note:** GitLab is accessed via HTTPS through the Cilium Gateway (10.10.30.20),
  > not directly to GitLab pods. The CIDR rule uses L4-only (no `toPorts`) because
  > the Gateway LB VIP has its own Cilium identity and L7 envoy interferes with
  > port-specific rules (see Networking.md gotcha table). This is the same pattern
  > used by Homepage egress.
  > The `remote-node` entity is needed for cross-node API server traffic in Cilium
  > tunnel mode (same pattern as cert-manager and ESO webhook policies from Phase 5.3).

- [x] 5.7.3.2b Apply and test
  ```bash
  kubectl-admin apply -f manifests/argocd/networkpolicy.yaml
  # Actual: argocd-ingress and argocd-egress created
  # Actual: split into 2 policies (ingress/egress) following repo pattern (not single policy)
  # Actual: used fromEntities: ingress (not cluster) for Gateway, matching vault/other NPs
  # Actual: used k8s:io.kubernetes.pod.namespace for cross-ns selectors (repo convention)
  # Actual: added applicationset-controller metrics port 8080 (missing from plan)
  # Verification:
  #   curl -sk https://argocd.k8s.rommelporras.com -> ArgoCD HTML (UI works)
  #   kubectl-admin logs: no connection refused errors, clean info-level logs
  #   Note: kubectl-homelab can't read logs in argocd ns (RBAC restriction)
  ```

---

## 5.7.4 Discord Notifications

- [x] 5.7.4.1 Create notifications ConfigMap
  ```yaml
  # Added to helm/argocd/values.yaml under top-level notifications: key
  # (NOT configs.notifications - plan had wrong path)
  # Helm upgrade applied (revision 2). Verified argocd-notifications-cm has all keys.
  notifications:
    enabled: true
    notifiers:
      service.webhook.discord: |
        url: $discord-webhook-url
        headers:
          - name: Content-Type
            value: application/json

    templates:
      template.app-sync-succeeded: |
        webhook:
          discord:
            method: POST
            body: |
              {"embeds": [{"title": "{{.app.metadata.name}}", "description": "Sync succeeded - {{.app.spec.source.targetRevision}}", "color": 65280, "fields": [{"name": "Project", "value": "{{.app.spec.project}}", "inline": true}, {"name": "Namespace", "value": "{{.app.spec.destination.namespace}}", "inline": true}]}]}

      template.app-sync-failed: |
        webhook:
          discord:
            method: POST
            body: |
              {"embeds": [{"title": "{{.app.metadata.name}}", "description": "Sync FAILED: {{.app.status.operationState.message}}", "color": 16711680, "fields": [{"name": "Project", "value": "{{.app.spec.project}}", "inline": true}, {"name": "Namespace", "value": "{{.app.spec.destination.namespace}}", "inline": true}]}]}

      template.app-health-degraded: |
        webhook:
          discord:
            method: POST
            body: |
              {"embeds": [{"title": "{{.app.metadata.name}}", "description": "Health: DEGRADED", "color": 16776960, "fields": [{"name": "Project", "value": "{{.app.spec.project}}", "inline": true}, {"name": "Status", "value": "{{.app.status.health.status}}", "inline": true}]}]}

    triggers:
      trigger.on-sync-succeeded: |
        - when: app.status.operationState.phase in ['Succeeded']
          send: [app-sync-succeeded]

      trigger.on-sync-failed: |
        - when: app.status.operationState.phase in ['Error', 'Failed']
          send: [app-sync-failed]

      trigger.on-health-degraded: |
        - when: app.status.health.status == 'Degraded'
          oncePer: app.status.operationState.syncResult.revision
          send: [app-health-degraded]
  ```

  > **Decision:** Create dedicated `#gitops` Discord channel (not reuse `#apps`).
  > GitOps sync events are high-volume during migration. Separate channel prevents
  > drowning out application alerts.

---

## 5.7.5 AppProjects

- [x] 5.7.5.1 Create AppProject manifests
  # Actual: all sourceRepos changed from gitlab.k8s.rommelporras.com to github.com/rommelporras/homelab.git
  # Actual: infrastructure sourceRepos updated to match actual helm repo list (removed OCI refs, added velero/tailscale repos)
  # Actual: removed argo-workflows/argo-rollouts destinations (don't exist yet, add when needed)
  ```yaml
  # manifests/argocd/appprojects.yaml
  apiVersion: argoproj.io/v1alpha1
  kind: AppProject
  metadata:
    name: infrastructure
    namespace: argocd
    finalizers:
      - resources-finalizer.argocd.argoproj.io
  spec:
    description: Core platform services
    sourceRepos:
      - https://gitlab.k8s.rommelporras.com/wsh/homelab.git
      - https://charts.longhorn.io
      - https://helm.cilium.io/
      - oci://quay.io/jetstack/charts/*
      - oci://ghcr.io/prometheus-community/charts/*
      - oci://ghcr.io/grafana/helm-charts/*
      - https://grafana.github.io/helm-charts
      - https://kubernetes-sigs.github.io/metrics-server/
      - https://helm.releases.hashicorp.com
      - https://charts.external-secrets.io
      - oci://registry.k8s.io/nfd/charts/*
      - https://intel.github.io/helm-charts/
      - https://prometheus-community.github.io/helm-charts
      - https://argoproj.github.io/argo-helm
    destinations:
      - namespace: default
        server: https://kubernetes.default.svc
      - namespace: cert-manager
        server: https://kubernetes.default.svc
      - namespace: external-secrets
        server: https://kubernetes.default.svc
      - namespace: monitoring
        server: https://kubernetes.default.svc
      - namespace: vault
        server: https://kubernetes.default.svc
      - namespace: longhorn-system
        server: https://kubernetes.default.svc
      - namespace: kube-system
        server: https://kubernetes.default.svc
      - namespace: node-feature-discovery
        server: https://kubernetes.default.svc
      - namespace: intel-device-plugins
        server: https://kubernetes.default.svc
      - namespace: velero
        server: https://kubernetes.default.svc
      - namespace: argo-workflows
        server: https://kubernetes.default.svc
      - namespace: argo-rollouts
        server: https://kubernetes.default.svc
    clusterResourceWhitelist:
      - group: ''
        kind: Namespace
      - group: rbac.authorization.k8s.io
        kind: ClusterRole
      - group: rbac.authorization.k8s.io
        kind: ClusterRoleBinding
      - group: admissionregistration.k8s.io
        kind: '*'
      - group: apiextensions.k8s.io
        kind: CustomResourceDefinition
      - group: storage.k8s.io
        kind: StorageClass
      - group: external-secrets.io
        kind: ClusterSecretStore
  ---
  apiVersion: argoproj.io/v1alpha1
  kind: AppProject
  metadata:
    name: homelab-apps
    namespace: argocd
    finalizers:
      - resources-finalizer.argocd.argoproj.io
  spec:
    description: General homelab services
    sourceRepos:
      - https://gitlab.k8s.rommelporras.com/wsh/homelab.git
    destinations:
      - namespace: home
        server: https://kubernetes.default.svc
      - namespace: ghost-prod
        server: https://kubernetes.default.svc
      - namespace: ghost-dev
        server: https://kubernetes.default.svc
      - namespace: browser
        server: https://kubernetes.default.svc
      - namespace: ai
        server: https://kubernetes.default.svc
      - namespace: karakeep
        server: https://kubernetes.default.svc
      - namespace: atuin
        server: https://kubernetes.default.svc
      - namespace: cloudflare
        server: https://kubernetes.default.svc
      - namespace: tailscale
        server: https://kubernetes.default.svc
      - namespace: uptime-kuma
        server: https://kubernetes.default.svc
    clusterResourceWhitelist: []
  ---
  apiVersion: argoproj.io/v1alpha1
  kind: AppProject
  metadata:
    name: arr-stack
    namespace: argocd
    finalizers:
      - resources-finalizer.argocd.argoproj.io
  spec:
    description: Media stack (isolated)
    sourceRepos:
      - https://gitlab.k8s.rommelporras.com/wsh/homelab.git
    destinations:
      - namespace: arr-stack
        server: https://kubernetes.default.svc
    clusterResourceWhitelist: []
  ---
  apiVersion: argoproj.io/v1alpha1
  kind: AppProject
  metadata:
    name: gitlab
    namespace: argocd
    finalizers:
      - resources-finalizer.argocd.argoproj.io
  spec:
    description: GitLab platform (isolated)
    sourceRepos:
      - https://gitlab.k8s.rommelporras.com/wsh/homelab.git
      - https://charts.gitlab.io
    destinations:
      - namespace: gitlab
        server: https://kubernetes.default.svc
      - namespace: gitlab-runner
        server: https://kubernetes.default.svc
    clusterResourceWhitelist: []
  ---
  apiVersion: argoproj.io/v1alpha1
  kind: AppProject
  metadata:
    name: cicd-apps
    namespace: argocd
    finalizers:
      - resources-finalizer.argocd.argoproj.io
  spec:
    description: CI/CD-deployed applications (per-environment)
    sourceRepos:
      - https://gitlab.k8s.rommelporras.com/wsh/homelab.git
    destinations:
      - namespace: invoicetron-dev
        server: https://kubernetes.default.svc
      - namespace: invoicetron-prod
        server: https://kubernetes.default.svc
      - namespace: portfolio-dev
        server: https://kubernetes.default.svc
      - namespace: portfolio-staging
        server: https://kubernetes.default.svc
      - namespace: portfolio-prod
        server: https://kubernetes.default.svc
    clusterResourceWhitelist: []
  ---
  apiVersion: argoproj.io/v1alpha1
  kind: AppProject
  metadata:
    name: argocd-self
    namespace: argocd
    finalizers:
      - resources-finalizer.argocd.argoproj.io
  spec:
    description: ArgoCD self-management
    sourceRepos:
      - https://gitlab.k8s.rommelporras.com/wsh/homelab.git
      - https://argoproj.github.io/argo-helm
    destinations:
      - namespace: argocd
        server: https://kubernetes.default.svc
    clusterResourceWhitelist:
      - group: apiextensions.k8s.io
        kind: CustomResourceDefinition
  ```

  > **Security model:** Each project restricts source repos and destination namespaces.
  > A compromised Application in `arr-stack` cannot deploy to `monitoring` or `vault`.
  > Only `infrastructure` project can create cluster-scoped resources (CRDs, ClusterRoles).

- [x] 5.7.5.2 Apply AppProjects
  ```bash
  kubectl-admin apply -f manifests/argocd/appprojects.yaml
  # Actual: 6 created. Finalizer warning is expected (ArgoCD's standard finalizer format).
  # Note: kubectl-homelab can't list appprojects (RBAC). Use kubectl-admin.
  kubectl-admin get appprojects -n argocd
  # Actual: 7 total (6 custom + default from Helm)
  ```

---

## 5.7.6 GitLab Repository Connection

- [x] 5.7.6.1 Verify repo credentials work
  ```bash
  # SKIPPED - repo is public on GitHub, no credentials needed.
  # No argocd-repo-gitlab ExternalSecret exists (removed in session 1).
  # No deploy token, no repo-creds template.
  ```

- [x] 5.7.6.2 Add the homelab repository
  ```yaml
  # manifests/argocd/repository.yaml
  # Actual: simplified - public GitHub repo, no credentials
  apiVersion: v1
  kind: Secret
  metadata:
    name: homelab-repo
    namespace: argocd
    labels:
      argocd.argoproj.io/secret-type: repository
  stringData:
    type: git
    url: https://github.com/rommelporras/homelab.git
  ```

- [x] 5.7.6.3 Apply and verify
  ```bash
  kubectl-admin apply -f manifests/argocd/repository.yaml
  # Actual: secret/homelab-repo created. No errors in repo-server logs.
  # Full connection test deferred to 5.7.10 (test Application).
  ```

---

## 5.7.7 ArgoCD Self-Management Application

> **Why self-manage?** After bootstrap, ArgoCD's own Helm values should be in Git.
> Changes to ArgoCD config are made by editing `helm/argocd/values.yaml` and pushing
> to Git. ArgoCD detects the drift and syncs itself.

- [x] 5.7.7.1 Create self-management Application
  # Actual: GitHub URL instead of GitLab, chart version 9.4.16 (not placeholder)
  ```yaml
  # manifests/argocd/self-management.yaml
  apiVersion: argoproj.io/v1alpha1
  kind: Application
  metadata:
    name: argocd
    namespace: argocd
  spec:
    project: argocd-self
    # Multi-source: chart from Helm repo + values from GitLab repo
    sources:
      - repoURL: https://argoproj.github.io/argo-helm
        chart: argo-cd
        targetRevision: "<CHART_VERSION>"
        helm:
          valueFiles:
            - $values/helm/argocd/values.yaml
      - repoURL: https://gitlab.k8s.rommelporras.com/wsh/homelab.git
        targetRevision: main
        ref: values
    destination:
      server: https://kubernetes.default.svc
      namespace: argocd
    syncPolicy:
      syncOptions:
        - ServerSideApply=true
        - CreateNamespace=false
      # Start with MANUAL sync - do not auto-sync until stable
      # automated:
      #   prune: false
      #   selfHeal: true
  ```

  > **Multi-source Application:** Uses `sources` (plural) to combine the Helm chart
  > from the argo repo with values from the homelab GitLab repo. The `$values` reference
  > points to the second source (GitLab repo) for the values file.
  >
  > **Manual sync first:** Auto-sync is commented out. Enable after verifying ArgoCD
  > is stable. A broken auto-sync on the self-management app can brick ArgoCD.

- [x] 5.7.7.2 Apply self-management Application
  ```bash
  kubectl-admin apply -f manifests/argocd/self-management.yaml
  # Actual: application.argoproj.io/argocd created
  # Status: Unknown/Healthy with ComparisonError - expected because
  # helm/argocd/values.yaml not yet pushed to GitHub. Will resolve after commit+push.
  #
  # CiliumNP gotcha: GitHub access needed DNS inspection rule (rules.dns.matchPattern: "*")
  # in same policy as toFQDNs. Without it, FQDN-to-IP cache never populates.
  # Also added *.githubusercontent.com and *.github.io for chart downloads.
  ```

---

## 5.7.8 Monitoring

### 5.7.8.1 PrometheusRules

- [x] 5.7.8.1a Create ArgoCD alert rules
  # Actual: 5 alerts. Runbook URLs use github.com pattern (repo convention).
  # Fixed job names to match actual: argocd-repo-server-metrics, argocd-application-controller-metrics
  ```yaml
  # manifests/monitoring/alerts/argocd-alerts.yaml
  apiVersion: monitoring.coreos.com/v1
  kind: PrometheusRule
  metadata:
    name: argocd-alerts
    namespace: monitoring
    labels:
      release: prometheus
  spec:
    groups:
      - name: argocd
        rules:
          - alert: ArgocdAppOutOfSync
            expr: |
              argocd_app_info{sync_status="OutOfSync"} == 1
            for: 30m
            labels:
              severity: warning
              category: apps
            annotations:
              summary: "ArgoCD app {{ $labels.name }} is out of sync"
              description: "Application {{ $labels.name }} in project {{ $labels.project }} has been OutOfSync for 30 minutes."
              runbook_url: "https://gitlab.k8s.rommelporras.com/wsh/homelab/-/blob/main/docs/runbooks/argocd-out-of-sync.md"

          - alert: ArgocdAppUnhealthy
            expr: |
              argocd_app_info{health_status!~"Healthy|Progressing"} == 1
            for: 15m
            labels:
              severity: warning
              category: apps
            annotations:
              summary: "ArgoCD app {{ $labels.name }} is unhealthy"
              description: "Application {{ $labels.name }} health status is {{ $labels.health_status }} for 15 minutes."
              runbook_url: "https://gitlab.k8s.rommelporras.com/wsh/homelab/-/blob/main/docs/runbooks/argocd-unhealthy.md"

          - alert: ArgocdSyncFailed
            expr: |
              increase(argocd_app_sync_total{phase!="Succeeded"}[1h]) > 0
            labels:
              severity: critical
              category: infra
            annotations:
              summary: "ArgoCD sync failed for {{ $labels.name }}"
              description: "Application {{ $labels.name }} sync failed in the last hour."
              runbook_url: "https://gitlab.k8s.rommelporras.com/wsh/homelab/-/blob/main/docs/runbooks/argocd-sync-failed.md"

          - alert: ArgocdRepoServerDown
            expr: |
              up{job=~".*argocd-repo-server.*"} == 0
            for: 5m
            labels:
              severity: critical
              category: infra
            annotations:
              summary: "ArgoCD repo server is down"
              description: "ArgoCD repo-server has been unreachable for 5 minutes. No syncs can proceed."
              runbook_url: "https://gitlab.k8s.rommelporras.com/wsh/homelab/-/blob/main/docs/runbooks/argocd-component-down.md"

          - alert: ArgocdControllerDown
            expr: |
              up{job=~".*argocd-application-controller.*"} == 0
            for: 5m
            labels:
              severity: critical
              category: infra
            annotations:
              summary: "ArgoCD application controller is down"
              description: "ArgoCD application-controller has been unreachable for 5 minutes. Reconciliation is stopped."
              runbook_url: "https://gitlab.k8s.rommelporras.com/wsh/homelab/-/blob/main/docs/runbooks/argocd-component-down.md"
  ```

### 5.7.8.2 Grafana Dashboard

- [x] 5.7.8.2a Create ArgoCD Grafana dashboard
  ```
  Follow homelab convention:
  - Row 1: Pod Status (all ArgoCD component pods)
  - Row 2: Network Traffic (server, repo-server, controller)
  - Row 3: ArgoCD-specific (sync status, app health, reconciliation time)
  - Row 4: Resource Usage (CPU/Memory with request/limit lines, must be last per convention)
  - Descriptions on every panel and row
  - ConfigMap with grafana_dashboard: "1" label, grafana_folder: "Homelab" annotation
  ```

### 5.7.8.3 Blackbox Probe

- [x] 5.7.8.3a Create ArgoCD blackbox probe
  ```yaml
  # manifests/monitoring/probes/argocd-probe.yaml
  apiVersion: monitoring.coreos.com/v1
  kind: Probe
  metadata:
    name: argocd-web
    namespace: monitoring
    labels:
      release: prometheus
  spec:
    interval: 60s
    module: http_2xx
    prober:
      url: blackbox-exporter-prometheus-blackbox-exporter.monitoring.svc.cluster.local:9115
    targets:
      staticConfig:
        static:
          - https://argocd.k8s.rommelporras.com
  ```

- [x] 5.7.8.4 Apply monitoring resources
  ```bash
  kubectl-admin apply -f manifests/monitoring/alerts/argocd-alerts.yaml
  # Actual: prometheusrule.monitoring.coreos.com/argocd-alerts created
  kubectl-admin apply -f manifests/monitoring/probes/argocd-probe.yaml
  # Actual: probe.monitoring.coreos.com/argocd-web created
  kubectl-admin apply -f manifests/monitoring/dashboards/argocd-dashboard-configmap.yaml
  # Actual: configmap/argocd-dashboard created
  ```

---

## 5.7.9 LimitRange and ResourceQuota

- [x] 5.7.9.1 Create LimitRange
  ```yaml
  # manifests/argocd/limitrange.yaml
  apiVersion: v1
  kind: LimitRange
  metadata:
    name: default-limits
    namespace: argocd
  spec:
    limits:
      - default:
          cpu: 500m
          memory: 256Mi
        defaultRequest:
          cpu: 100m
          memory: 128Mi
        type: Container
  ```

- [x] 5.7.9.2 Create ResourceQuota
  ```yaml
  # manifests/argocd/resourcequota.yaml
  apiVersion: v1
  kind: ResourceQuota
  metadata:
    name: argocd-quota
    namespace: argocd
  spec:
    hard:
      requests.cpu: "2"
      requests.memory: 3Gi
      limits.cpu: "4"
      limits.memory: 4Gi
      pods: "20"
  ```

- [x] 5.7.9.3 Apply
  ```bash
  kubectl-admin apply -f manifests/argocd/limitrange.yaml
  kubectl-admin apply -f manifests/argocd/resourcequota.yaml
  # Actual: both created. Usage: 550m/2 CPU req, 1088Mi/3Gi mem req, 6/20 pods
  ```

---

## 5.7.10 Initial Verification

- [x] 5.7.10.1 Access ArgoCD UI
  ```bash
  # UI accessible: curl -sk https://argocd.k8s.rommelporras.com returns ArgoCD HTML
  # Admin password: op://Kubernetes/ArgoCD/password (plain text for login)
  # Username: admin
  ```

- [x] 5.7.10.2 Verify repository connection
  ```
  # Verified via test Application (5.7.10.3): ArgoCD cloned GitHub repo and read manifests.
  # Test app showed OutOfSync/Healthy = repo connection works, manifests parsed.
  ```

- [x] 5.7.10.3 Test with a simple Application (dry-run)
  ```bash
  # Actual: used GitHub URL (not GitLab). Created test-homepage Application.
  # Status: OutOfSync/Healthy - ArgoCD read manifests/home/homepage from GitHub main branch.
  # Cleaned up: kubectl-admin delete application test-homepage -n argocd
  ```

- [x] 5.7.10.4 Verify monitoring
  ```bash
  # Actual: 6 targets all up:
  #   argocd (blackbox probe): up
  #   argocd-application-controller-metrics: up
  #   argocd-applicationset-controller-metrics: up
  #   argocd-notifications-controller-metrics: up
  #   argocd-repo-server-metrics: up
  #   argocd-server-metrics: up
  ```

---

## Verification Checklist

**Installation:**
- [x] ArgoCD installed via Helm (non-HA, v3.3.5 - chart 9.4.16)
- [x] All 6 ArgoCD pods Running and Ready
- [x] ArgoCD version confirmed (v3.3.5 - v3.4.0 upgrade deferred, see deferred.md)
- [x] Helm values file created (`helm/argocd/values.yaml`) - not yet pushed to GitHub

**Secrets:**
- [x] ArgoCD secrets in 1Password (`op://Kubernetes/ArgoCD/` + `op://Kubernetes/Discord Webhooks/gitops`)
- [x] Vault KV path seeded (`secret/argocd`)
- [x] 2 ExternalSecrets synced (argocd-vault-secrets, argocd-notifications-secret). No repo-creds needed (public GitHub repo).

**Networking:**
- [x] HTTPRoute working (https://argocd.k8s.rommelporras.com accessible)
- [x] CiliumNetworkPolicy applied (2 policies: argocd-ingress + argocd-egress)
- [x] DNS resolving (argocd.k8s.rommelporras.com -> 10.10.30.20 via wildcard)
- [x] GitHub + Helm chart egress working (toFQDNs with DNS inspection)

**Configuration:**
- [x] 6 AppProjects created (infrastructure, homelab-apps, arr-stack, gitlab, cicd-apps, argocd-self)
- [x] GitHub repository connected (test Application read manifests successfully)
- [x] Resource exclusions configured (Longhorn, Velero in Helm values)
- [x] Discord notifications configured (webhook, 3 templates, 3 triggers in Helm values)
- [x] Self-management Application created (manual sync mode, awaiting git push for values.yaml)

**Monitoring:**
- [x] 5 ServiceMonitors created and scraped by Prometheus (all up)
- [x] 5 PrometheusRule alerts deployed (argocd-alerts.yaml)
- [x] Grafana dashboard deployed (argocd-dashboard ConfigMap, Homelab folder)
- [x] Blackbox probe for ArgoCD UI deployed (argocd-web, 60s interval)

**Security:**
- [x] LimitRange and ResourceQuota applied (550m/2 CPU, 1088Mi/3Gi mem, 6/20 pods)
- [x] Dex disabled (no SSO - local admin only)
- [x] Redis not exposed outside namespace (verified by CiliumNP)
- [x] Redis stores plaintext rendered manifests in cache - CiliumNP enforces isolation
- [x] Server running in insecure mode (TLS at Gateway, not ArgoCD)
- [x] `resource.respectRBAC: strict` considered (not enabled - default behavior sufficient for now)

---

## Rollback

**ArgoCD installation issues:**
```bash
# Full uninstall (keeps namespace for inspection)
helm-homelab uninstall argocd -n argocd

# Clean up CRDs if needed
kubectl-admin delete crd applications.argoproj.io applicationsets.argoproj.io appprojects.argoproj.io

# Remove namespace
kubectl-admin delete namespace argocd
```

**GitLab connection issues:**
```bash
# Check repo-server logs for auth errors
kubectl-homelab logs -n argocd deployment/argocd-repo-server --tail=50

# Verify deploy token is valid
# Re-create in GitLab > Settings > Repository > Deploy Tokens
```

**NetworkPolicy too restrictive:**
```bash
# Temporarily allow all traffic to debug
kubectl-admin delete ciliumnetworkpolicy argocd-default-deny argocd-internal -n argocd
# Re-apply after fixing rules
```

---

## Final: Commit and Release

- [ ] `/audit-security` then `/commit`
- [ ] `/audit-docs` then `/commit`
- [ ] `/release v0.37.0 "ArgoCD Installation & Bootstrap"`
- [ ] `mv docs/todo/phase-5.7-argocd-installation.md docs/todo/completed/`
- [ ] Proceed to Phase 5.8 (GitOps Migration, v0.38.0)
