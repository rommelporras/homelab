# Phase 5.7: ArgoCD Installation & Bootstrap

> **Status:** Planned
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
> **ArgoCD version:** v3.4.x (first version with K8s 1.35 support).
> Helm chart: `argo/argo-cd`. Verify chart version at install time:
> `helm search repo argo/argo-cd --versions | head -5`
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
> v3.4.0-rc2 released March 19, 2026 - stable expected before this phase executes.
> Use v3.4.0+ for K8s 1.35 support.

---

## 5.7.0 Pre-Installation Checklist

> **Gate:** Do not proceed until ALL Phase 5.6 verification items are checked.

- [ ] 5.7.0.1 Verify Phase 5.6 is complete
  ```bash
  # VAP in Deny mode
  kubectl-homelab get validatingadmissionpolicybinding restrict-image-registries-binding \
    -o jsonpath='{.spec.validationActions}'
  # Expected: ["Deny"]

  # kube-bench CronJob deployed
  kubectl-homelab get cronjob kube-bench-weekly -n kube-system

  # All ExternalSecrets synced
  kubectl-homelab get externalsecrets -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,STATUS:.status.conditions[0].reason | grep -v SecretSynced
  # Expected: no output (all synced)
  ```

- [ ] 5.7.0.2 Verify ArgoCD chart version supports K8s 1.35
  ```bash
  helm-homelab repo add argo https://argoproj.github.io/argo-helm
  helm-homelab repo update
  helm-homelab search repo argo/argo-cd --versions | head -10
  # Look for chart version mapping to ArgoCD v3.4.0+
  # Record: CHART_VERSION=<version> APP_VERSION=<version>
  ```

- [ ] 5.7.0.3 Verify VAP allows ArgoCD images (dry-run test)
  ```bash
  # ArgoCD images come from quay.io/argoproj/ and ecr-public.aws.com/
  kubectl-admin run test-argocd --image=quay.io/argoproj/argocd:v3.4.0 \
    --dry-run=server -n default
  # Expected: pod created (dry-run), no VAP warning

  kubectl-admin run test-redis --image=ecr-public.aws.com/docker/library/redis:7.2.8-alpine \
    --dry-run=server -n default
  # Expected: pod created (dry-run), no VAP warning
  ```

---

## 5.7.1 Namespace and Secrets

### 5.7.1.1 Create argocd namespace

- [ ] 5.7.1.1a Create namespace manifest
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

- [ ] 5.7.1.1b Apply namespace
  ```bash
  kubectl-admin apply -f manifests/argocd/namespace.yaml
  ```

### 5.7.1.2 Vault secrets preparation

> **Manual step:** Run on a terminal with `op` access (not this one).

- [ ] 5.7.1.2a Add ArgoCD secrets to 1Password
  ```
  Create 1Password item: op://Kubernetes/ArgoCD/
  Fields:
  - admin-password: bcrypt-hashed admin password (generate with: htpasswd -nbBC 10 "" <password> | tr -d ':\n' | sed 's/$2y/$2a/')
  - gitlab-deploy-token-username: deploy token username from GitLab
  - gitlab-deploy-token-password: deploy token password from GitLab
  - discord-webhook-url: webhook URL for #gitops or #apps Discord channel
  - server-secret-key: random 32-char string for JWT signing (openssl rand -hex 16)

  GitLab deploy token:
  GitLab > Settings > Repository > Deploy Tokens
  - Name: argocd-readonly
  - Scopes: read_repository
  - URL format: https://<username>:<token>@gitlab.k8s.rommelporras.com/wsh/homelab.git
  - NOTE: GitLab requires .git suffix (otherwise 301 redirect ArgoCD won't follow)
  ```

- [ ] 5.7.1.2b Seed Vault with ArgoCD secrets
  ```bash
  # Run from trusted terminal with op access:
  # Add to scripts/vault/seed-vault-from-1password.sh:
  #   vault kv put secret/argocd \
  #     admin-password="$(op read 'op://Kubernetes/ArgoCD/admin-password')" \
  #     gitlab-deploy-token-username="$(op read 'op://Kubernetes/ArgoCD/gitlab-deploy-token-username')" \
  #     gitlab-deploy-token-password="$(op read 'op://Kubernetes/ArgoCD/gitlab-deploy-token-password')" \
  #     discord-webhook-url="$(op read 'op://Kubernetes/ArgoCD/discord-webhook-url')" \
  #     server-secret-key="$(op read 'op://Kubernetes/ArgoCD/server-secret-key')"
  ```

### 5.7.1.3 ExternalSecrets

- [ ] 5.7.1.3a Create ExternalSecret for ArgoCD
  ```yaml
  # manifests/argocd/externalsecret.yaml
  apiVersion: external-secrets.io/v1beta1
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

- [ ] 5.7.1.3b Apply ExternalSecrets
  ```bash
  kubectl-admin apply -f manifests/argocd/externalsecret.yaml
  # Wait for sync
  kubectl-homelab get externalsecrets -n argocd
  # All should show SecretSynced
  ```

---

## 5.7.2 Helm Installation

- [ ] 5.7.2.1 Create Helm values file
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

- [ ] 5.7.2.2 Install ArgoCD via Helm
  ```bash
  # IMPORTANT: --server-side --force-conflicts required for CRD size
  CHART_VERSION="<version from 5.7.0.2>"

  helm-homelab install argocd argo/argo-cd \
    --namespace argocd \
    --version "$CHART_VERSION" \
    --values helm/argocd/values.yaml \
    --set configs.params.server.insecure=true

  # Wait for all pods to be ready
  kubectl-homelab get pods -n argocd -w
  # Expected: 5 pods (controller, server, repo-server, applicationset, redis)
  # notifications-controller is a 6th pod
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

- [ ] 5.7.2.3 Verify installation
  ```bash
  kubectl-homelab get pods -n argocd
  # All pods Running and Ready

  kubectl-homelab get svc -n argocd
  # argocd-server ClusterIP on port 8080

  # Check ArgoCD version
  kubectl-homelab exec -n argocd deployment/argocd-server -- argocd version --short
  ```

---

## 5.7.3 Networking

### 5.7.3.1 HTTPRoute

- [ ] 5.7.3.1a Create HTTPRoute for ArgoCD UI
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
            port: 8080
  ```

- [ ] 5.7.3.1b Add DNS entry in AdGuard
  ```
  argocd.k8s.rommelporras.com -> 10.10.30.20
  (Already covered by *.k8s.rommelporras.com wildcard if configured)
  Verify: nslookup argocd.k8s.rommelporras.com 10.10.30.53
  ```

- [ ] 5.7.3.1c Apply and verify
  ```bash
  kubectl-admin apply -f manifests/argocd/httproute.yaml
  # Test HTTPS access
  curl -sk https://argocd.k8s.rommelporras.com | head -5
  # Expected: ArgoCD HTML response
  ```

### 5.7.3.2 CiliumNetworkPolicy

- [ ] 5.7.3.2a Create CiliumNetworkPolicy for argocd namespace
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
      # Allow GitLab access (repo-server clones from GitLab)
      - toCIDR:
          - 10.10.30.20/32
        toPorts:
          - ports:
              - port: "443"
                protocol: TCP
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
  > not directly to GitLab pods. The CIDR rule for 10.10.30.20 covers this.
  > The `remote-node` entity is needed for cross-node API server traffic in Cilium
  > tunnel mode (same pattern as cert-manager and ESO webhook policies from Phase 5.3).

- [ ] 5.7.3.2b Apply and test
  ```bash
  kubectl-admin apply -f manifests/argocd/networkpolicy.yaml
  # Verify ArgoCD can still reach GitLab and kube-apiserver
  kubectl-homelab logs -n argocd deployment/argocd-server --tail=20
  # No connection refused errors
  ```

---

## 5.7.4 Discord Notifications

- [ ] 5.7.4.1 Create notifications ConfigMap
  ```yaml
  # Add to helm/argocd/values.yaml under configs.notifications:
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

- [ ] 5.7.5.1 Create AppProject manifests
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

- [ ] 5.7.5.2 Apply AppProjects
  ```bash
  kubectl-admin apply -f manifests/argocd/appprojects.yaml
  kubectl-homelab get appprojects -n argocd
  ```

---

## 5.7.6 GitLab Repository Connection

- [ ] 5.7.6.1 Verify repo credentials work
  ```bash
  # ESO should have created the argocd-repo-gitlab Secret
  kubectl-homelab get secret argocd-repo-gitlab -n argocd
  # Verify the label
  kubectl-homelab get secret argocd-repo-gitlab -n argocd -o jsonpath='{.metadata.labels}'
  # Should contain: argocd.argoproj.io/secret-type: repo-creds

  # ArgoCD should auto-discover the credential template
  # Check ArgoCD server logs for repo connection
  kubectl-homelab logs -n argocd deployment/argocd-server --tail=20 | grep -i repo
  ```

- [ ] 5.7.6.2 Add the homelab repository
  ```yaml
  # manifests/argocd/repository.yaml
  apiVersion: v1
  kind: Secret
  metadata:
    name: homelab-repo
    namespace: argocd
    labels:
      argocd.argoproj.io/secret-type: repository
  stringData:
    type: git
    url: https://gitlab.k8s.rommelporras.com/wsh/homelab.git
    # Credentials inherited from repo-creds template (argocd-repo-gitlab)
  ```

  > **Note:** The `url` must end with `.git` for GitLab. Without it, GitLab returns
  > a 301 redirect that ArgoCD won't follow, causing "repository not found" errors.

- [ ] 5.7.6.3 Apply and verify
  ```bash
  kubectl-admin apply -f manifests/argocd/repository.yaml
  # Access ArgoCD UI and check Settings > Repositories
  # Should show the homelab repo as "Successful"
  ```

---

## 5.7.7 ArgoCD Self-Management Application

> **Why self-manage?** After bootstrap, ArgoCD's own Helm values should be in Git.
> Changes to ArgoCD config are made by editing `helm/argocd/values.yaml` and pushing
> to Git. ArgoCD detects the drift and syncs itself.

- [ ] 5.7.7.1 Create self-management Application
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

- [ ] 5.7.7.2 Apply self-management Application
  ```bash
  kubectl-admin apply -f manifests/argocd/self-management.yaml
  # Check Application status in ArgoCD UI
  kubectl-homelab get application argocd -n argocd
  ```

---

## 5.7.8 Monitoring

### 5.7.8.1 PrometheusRules

- [ ] 5.7.8.1a Create ArgoCD alert rules
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

- [ ] 5.7.8.2a Create ArgoCD Grafana dashboard
  ```
  Follow homelab convention:
  - Row 1: Pod Status (all ArgoCD component pods)
  - Row 2: Network Traffic (server, repo-server, controller)
  - Row 3: Resource Usage (CPU/Memory with request/limit lines)
  - Row 4: ArgoCD-specific (sync status, app health, reconciliation time)
  - Descriptions on every panel and row
  - ConfigMap with grafana_dashboard: "1" label, grafana_folder: "Homelab" annotation
  ```

### 5.7.8.3 Blackbox Probe

- [ ] 5.7.8.3a Create ArgoCD blackbox probe
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

- [ ] 5.7.8.4 Apply monitoring resources
  ```bash
  kubectl-admin apply -f manifests/monitoring/alerts/argocd-alerts.yaml
  kubectl-admin apply -f manifests/monitoring/probes/argocd-probe.yaml
  # Dashboard ConfigMap created separately
  ```

---

## 5.7.9 LimitRange and ResourceQuota

- [ ] 5.7.9.1 Create LimitRange
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

- [ ] 5.7.9.2 Create ResourceQuota
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

- [ ] 5.7.9.3 Apply
  ```bash
  kubectl-admin apply -f manifests/argocd/limitrange.yaml
  kubectl-admin apply -f manifests/argocd/resourcequota.yaml
  ```

---

## 5.7.10 Initial Verification

- [ ] 5.7.10.1 Access ArgoCD UI
  ```bash
  # Admin password is in 1Password: op://Kubernetes/ArgoCD/admin-password
  # Retrieve from 1Password (run on trusted terminal with op access):
  #   op read 'op://Kubernetes/ArgoCD/admin-password'
  # Do NOT use kubectl to read secrets (RBAC blocks it + policy violation)
  # Login at https://argocd.k8s.rommelporras.com
  # Username: admin
  ```

- [ ] 5.7.10.2 Verify repository connection
  ```
  ArgoCD UI > Settings > Repositories
  - homelab repo should show "Successful" connection status
  - If failed, check argocd-server logs for auth errors
  ```

- [ ] 5.7.10.3 Test with a simple Application (dry-run)
  ```yaml
  # Do NOT commit this - manual test only
  apiVersion: argoproj.io/v1alpha1
  kind: Application
  metadata:
    name: test-homepage
    namespace: argocd
  spec:
    project: homelab-apps
    source:
      repoURL: https://gitlab.k8s.rommelporras.com/wsh/homelab.git
      path: manifests/home/homepage
      targetRevision: main
    destination:
      server: https://kubernetes.default.svc
      namespace: home
    syncPolicy:
      syncOptions:
        - ServerSideApply=true
  ```

  ```bash
  # Apply test application (manual sync mode - won't change anything yet)
  kubectl-admin apply -f /tmp/test-app.yaml
  # Check in ArgoCD UI - should show as OutOfSync (manual sync)
  # Verify it can READ the manifests from GitLab
  # Then clean up:
  kubectl-admin delete application test-homepage -n argocd
  ```

- [ ] 5.7.10.4 Verify monitoring
  ```bash
  # Check ServiceMonitors are scraped
  # Prometheus UI > Targets - look for argocd-* targets
  curl -s "https://prometheus.k8s.rommelporras.com/api/v1/targets" | \
    jq '.data.activeTargets[] | select(.labels.job | contains("argocd")) | {job: .labels.job, health: .health}'
  ```

---

## Verification Checklist

**Installation:**
- [ ] ArgoCD installed via Helm (non-HA, v3.4.x)
- [ ] All 6 ArgoCD pods Running and Ready
- [ ] ArgoCD version confirmed (v3.4.x with K8s 1.35 support)
- [ ] Helm values file committed to repo (`helm/argocd/values.yaml`)

**Secrets:**
- [ ] ArgoCD secrets in 1Password (`op://Kubernetes/ArgoCD/`)
- [ ] Vault KV path seeded (`secret/argocd`)
- [ ] 3 ExternalSecrets synced (argocd-secret, argocd-repo-gitlab, argocd-notifications-secret)

**Networking:**
- [ ] HTTPRoute working (https://argocd.k8s.rommelporras.com accessible)
- [ ] CiliumNetworkPolicy applied (default-deny + allow-list)
- [ ] DNS resolving (argocd.k8s.rommelporras.com -> 10.10.30.20)

**Configuration:**
- [ ] 6 AppProjects created (infrastructure, homelab-apps, arr-stack, gitlab, cicd-apps, argocd-self)
- [ ] GitLab repository connected (Successful status in UI)
- [ ] Resource exclusions configured (Longhorn, Velero, Cilium dynamic)
- [ ] Discord notifications configured and tested
- [ ] Self-management Application created (manual sync mode)

**Monitoring:**
- [ ] 5 ServiceMonitors created and scraped by Prometheus
- [ ] 5 PrometheusRule alerts deployed
- [ ] Grafana dashboard deployed (Homelab folder)
- [ ] Blackbox probe for ArgoCD UI deployed

**Security:**
- [ ] LimitRange and ResourceQuota applied
- [ ] Dex disabled (no SSO - local admin only)
- [ ] Redis not exposed outside namespace (verified by CiliumNP)
- [ ] Redis stores plaintext rendered manifests in cache - CiliumNP enforces isolation
- [ ] Server running in insecure mode (TLS at Gateway, not ArgoCD)
- [ ] `resource.respectRBAC: strict` considered (auto-excludes resources ArgoCD can't read)

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
