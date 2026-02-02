# Phase 4.6: GitLab CI/CD Platform

> **Status:** Planned (PRIORITY)
> **Target:** v0.8.0
> **Prerequisite:** Phase 4.5 complete (Cloudflare Tunnel for external access)
> **DevOps Topics:** Helm charts, StatefulSets, CI/CD pipelines, Container registries
> **CKA Topics:** Complex Helm deployments, multi-component applications, RBAC

> **Purpose:** Self-hosted CI/CD for private repos, container registry, DevOps learning
> **Why GitLab:** Free CI/CD for private repos, built-in registry, Kubernetes-native

> **Security:** INTERNAL ACCESS ONLY - No Cloudflare Tunnel route
> Access via: `gitlab.k8s.rommelporras.com` (home network / Tailscale only)
> CiliumNetworkPolicy blocks cloudflared from reaching GitLab namespace

---

## Important: Deployment Context

> **⚠️ This is a LEARNING/POC deployment, NOT production-ready.**
>
> The GitLab Helm chart's default configuration deploys all components (PostgreSQL, Redis,
> Gitaly) inside the cluster. This is explicitly [NOT supported for production](https://docs.gitlab.com/charts/installation/).
>
> **For Production:** PostgreSQL, Redis, and Gitaly must run OUTSIDE the cluster on VMs
> or managed services (RDS, Cloud SQL, etc.). See [Cloud Native Hybrid architecture](https://docs.gitlab.com/ee/administration/reference_architectures/).
>
> **For this homelab:** In-cluster deployment is acceptable for learning Kubernetes concepts,
> CI/CD workflows, and Helm chart management. Just be aware of the limitations.

### Bitnami Image Advisory

The bundled PostgreSQL and Redis charts use Bitnami images. As of 2025, Bitnami is
transitioning to a paid subscription model:

| Date | Change |
|------|--------|
| Aug 28, 2025 | Public catalog moves to limited subset |
| Sept 29, 2025 | Legacy images archived (no updates) |

**Impact for us:** The GitLab chart will use `bitnamilegacy` images as a temporary solution.
For a homelab, this is acceptable. Monitor [GitLab issue #6152](https://gitlab.com/gitlab-org/charts/gitlab/-/issues/6152)
for long-term direction.

---

## Version Information

| Component | Chart Version | App Version | Notes |
|-----------|---------------|-------------|-------|
| GitLab | 9.8.2 | v18.8.2 | [Version mappings](https://docs.gitlab.com/charts/installation/version_mappings/) |
| GitLab Runner | 0.85.0 | 18.8.0 | Uses authentication tokens (not registration tokens) |

> **Version Selection:** Always check `helm-homelab search repo gitlab/gitlab --versions`
> before installing. Chart versions don't match GitLab versions (e.g., chart 9.8.2 = GitLab 18.8.2).

---

## GitLab CI/CD Concepts (Learning Guide)

Before implementing, understand how GitLab CI/CD works:

### What is GitLab CI/CD?

```
┌─────────────────────────────────────────────────────────────────────┐
│                         GitLab CI/CD Flow                           │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│   Developer                  GitLab                    Kubernetes   │
│   ─────────                  ──────                    ──────────   │
│                                                                     │
│   git push ──────────────►  .gitlab-ci.yml                         │
│                              (pipeline definition)                  │
│                                    │                                │
│                                    ▼                                │
│                              GitLab Server                          │
│                              (parses pipeline)                      │
│                                    │                                │
│                                    ▼                                │
│                              GitLab Runner  ◄──── Registered runner │
│                              (executes jobs)                        │
│                                    │                                │
│                                    ▼                                │
│                              Kubernetes Executor                    │
│                              (spawns pods for each job)             │
│                                    │                                │
│                           ┌───────┴───────┐                        │
│                           ▼               ▼                        │
│                      Build Pod       Deploy Pod                    │
│                      (docker build)  (kubectl apply)               │
│                           │               │                        │
│                           ▼               ▼                        │
│                      Container       Updated                       │
│                      Registry        Deployment                    │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### Key Components

| Component | What It Does | Where It Runs |
|-----------|--------------|---------------|
| **GitLab Server** | Hosts repos, manages pipelines, stores artifacts | K8s (gitlab namespace) |
| **GitLab Runner** | Picks up jobs from GitLab and executes them | K8s (gitlab-runner namespace) |
| **Kubernetes Executor** | Spawns pods in K8s for each CI/CD job | K8s (dynamic pods) |
| **Container Registry** | Stores Docker images built by CI/CD | K8s (part of GitLab) |

### .gitlab-ci.yml Basics

```yaml
# Every pipeline needs stages (order of execution)
stages:
  - build      # First: build the app
  - test       # Second: run tests
  - deploy     # Third: deploy to K8s

# Jobs run in parallel within a stage
build-app:
  stage: build
  script:
    - docker build -t myapp .
    - docker push registry/myapp

deploy-app:
  stage: deploy
  script:
    - kubectl set image deployment/myapp myapp=registry/myapp:latest
```

### Why GitLab Runner with Kubernetes Executor?

| Executor | How Jobs Run | Best For |
|----------|--------------|----------|
| Shell | On the runner machine directly | Simple scripts |
| Docker | In Docker containers on runner | Most use cases |
| **Kubernetes** | As pods in your K8s cluster | K8s-native CI/CD |

**We use Kubernetes executor because:**
- Jobs run as pods → isolated, reproducible
- Scale automatically → no dedicated build servers
- Native K8s access → deploy directly to cluster

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    gitlab namespace                              │
├─────────────────────────────────────────────────────────────────┤
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐     │
│  │ PostgreSQL  │  │    Redis    │  │       Gitaly        │     │
│  │ StatefulSet │  │ StatefulSet │  │    StatefulSet      │     │
│  │   (15Gi)    │  │    (5Gi)    │  │ (50Gi - Git repos)  │     │
│  └─────────────┘  └─────────────┘  └─────────────────────┘     │
│         │                │                    │                 │
│         └────────────────┼────────────────────┘                 │
│                          ▼                                      │
│  ┌───────────────────────────────────────────────────────────┐ │
│  │              GitLab Webservice (Deployment)               │ │
│  │         gitlab.k8s.rommelporras.com                  │ │
│  └───────────────────────────────────────────────────────────┘ │
│                          │                                      │
│         ┌────────────────┼────────────────┐                    │
│         ▼                ▼                ▼                    │
│  ┌───────────┐   ┌────────────┐   ┌─────────────┐             │
│  │  Sidekiq  │   │  Registry  │   │ GitLab Shell│             │
│  │ (bg jobs) │   │ (images)   │   │   (SSH)     │             │
│  └───────────┘   └────────────┘   └─────────────┘             │
└─────────────────────────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│                 gitlab-runner namespace                          │
│  ┌───────────────────────────────────────────────────────────┐ │
│  │  GitLab Runner (Deployment)                               │ │
│  │  - Kubernetes executor (spawns pods for CI jobs)          │ │
│  │  - Builds containers, runs tests, deploys to K8s          │ │
│  └───────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

## Resource Requirements

| Component | CPU Request | Memory Request | Storage |
|-----------|-------------|----------------|---------|
| PostgreSQL | 500m | 1Gi | 15Gi |
| Redis | 250m | 512Mi | 5Gi |
| Gitaly | 500m | 1Gi | 50Gi |
| Webservice | 500m | 1.5Gi | - |
| Sidekiq | 250m | 512Mi | - |
| Registry | 250m | 512Mi | 20Gi |
| **Total** | ~2.25 CPU | ~5Gi requests | ~90Gi |

> **Note:** Actual memory usage will be higher. Plan for **8-10GB RAM** available across
> the cluster for comfortable operation. Your 3x16GB nodes have plenty of headroom.

---

## 4.6.1 Prerequisites

- [ ] 4.6.1.1 Verify cluster resources
  ```bash
  kubectl-homelab top nodes
  # Need ~8-10GB free RAM across cluster
  # Need ~100GB available storage in Longhorn (90Gi + buffer)

  # Check Longhorn capacity
  kubectl-homelab -n longhorn-system get nodes.longhorn.io \
    -o custom-columns=NAME:.metadata.name,AVAIL:.status.diskStatus.default-disk.storageAvailable
  ```

- [ ] 4.6.1.2 Verify Helm version
  ```bash
  helm-homelab version --short
  # Should be 3.8+ (OCI support) or 4.x
  # Current: v3.19.5 ✓
  ```

- [ ] 4.6.1.3 Add GitLab Helm repo
  ```bash
  helm-homelab repo add gitlab https://charts.gitlab.io --force-update
  helm-homelab repo update gitlab
  ```

- [ ] 4.6.1.4 Check available GitLab chart versions
  ```bash
  helm-homelab search repo gitlab/gitlab --versions | head -10
  # Current latest: 9.8.2 (GitLab v18.8.2)

  helm-homelab search repo gitlab/gitlab-runner --versions | head -5
  # Current latest: 0.85.0 (Runner 18.8.0)
  ```

- [ ] 4.6.1.5 Create gitlab namespace
  ```bash
  kubectl-homelab create namespace gitlab
  kubectl-homelab label namespace gitlab pod-security.kubernetes.io/enforce=privileged
  # privileged required: GitLab components need various capabilities
  ```

- [ ] 4.6.1.6 Verify namespace created
  ```bash
  kubectl-homelab get namespace gitlab -o jsonpath='{.metadata.labels}' | jq .
  # Should show pod-security.kubernetes.io/enforce: privileged
  ```

---

## 4.6.2 Create Secrets

- [ ] 4.6.2.1 Generate passwords and add to 1Password
  ```bash
  # Generate secure passwords
  ROOT_PASS=$(openssl rand -base64 24)
  PG_PASS=$(openssl rand -base64 24)

  echo "Root password: $ROOT_PASS"
  echo "PostgreSQL password: $PG_PASS"

  # Create items in 1Password Kubernetes vault:
  #
  # Item: GitLab
  # Fields:
  #   - root-password: (generated above)
  #   - postgresql-password: (generated above)
  #   - runner-token: (will add after GitLab install - this is the glrt-xxx token)
  #
  # Verify:
  op read "op://Kubernetes/GitLab/root-password" >/dev/null && echo "Root OK"
  op read "op://Kubernetes/GitLab/postgresql-password" >/dev/null && echo "PG OK"
  ```

- [ ] 4.6.2.2 Create K8s secrets from 1Password
  ```bash
  # Root password secret
  kubectl-homelab create secret generic gitlab-root-password \
    --from-literal=password="$(op read 'op://Kubernetes/GitLab/root-password')" \
    -n gitlab

  # PostgreSQL password secret
  kubectl-homelab create secret generic gitlab-postgresql-password \
    --from-literal=postgresql-password="$(op read 'op://Kubernetes/GitLab/postgresql-password')" \
    -n gitlab
  ```

- [ ] 4.6.2.3 Verify secrets created
  ```bash
  kubectl-homelab get secrets -n gitlab
  # Should see: gitlab-root-password, gitlab-postgresql-password

  # Verify secret contents (don't print, just check key exists)
  kubectl-homelab get secret gitlab-root-password -n gitlab -o jsonpath='{.data}' | jq 'keys'
  # Should show: ["password"]
  ```

---

## 4.6.3 Create Helm Values

- [ ] 4.6.3.1 Create helm/gitlab directory
  ```bash
  mkdir -p helm/gitlab
  ```

- [ ] 4.6.3.2 Create helm/gitlab/values.yaml
  ```yaml
  # helm/gitlab/values.yaml
  # GitLab Helm Chart Configuration for Homelab (Learning/PoC)
  #
  # Chart version: 9.8.2 (GitLab v18.8.2)
  # Docs: https://docs.gitlab.com/charts/
  #
  # WARNING: This configuration runs all components in-cluster.
  # This is NOT production-ready. For production, use Cloud Native Hybrid
  # architecture with external PostgreSQL, Redis, and Gitaly.
  #
  # INSTALL:
  #   helm-homelab install gitlab gitlab/gitlab \
  #     --namespace gitlab \
  #     --version 9.8.2 \
  #     --values helm/gitlab/values.yaml \
  #     --timeout 15m
  #
  # UPGRADE:
  #   helm-homelab upgrade gitlab gitlab/gitlab \
  #     --namespace gitlab \
  #     --version 9.8.2 \
  #     --values helm/gitlab/values.yaml \
  #     --timeout 15m

  global:
    # Edition: Community Edition (free, open source)
    edition: ce

    # Domain configuration
    hosts:
      domain: k8s.rommelporras.com
      gitlab:
        name: gitlab.k8s.rommelporras.com
        https: true
      registry:
        name: registry.k8s.rommelporras.com
        https: true
      # Disable external IP assignment (we use Gateway API)
      externalIP: null

    # Ingress - DISABLED (we use Cilium Gateway API with HTTPRoute)
    ingress:
      enabled: false
      configureCertmanager: false

    # Use existing secrets for initial root password
    initialRootPassword:
      secret: gitlab-root-password
      key: password

    # PostgreSQL password from secret
    psql:
      password:
        secret: gitlab-postgresql-password
        key: postgresql-password

    # GitLab Shell (SSH) - for git+ssh access
    shell:
      port: 22

    # Time zone
    time_zone: America/Los_Angeles

  # ─────────────────────────────────────────────────────────────────
  # DISABLED BUNDLED COMPONENTS (we have our own or don't need)
  # ─────────────────────────────────────────────────────────────────

  # Disable bundled nginx (we use Cilium Gateway API)
  nginx-ingress:
    enabled: false

  # Disable bundled cert-manager (we have our own cluster-wide)
  certmanager:
    install: false

  # Disable bundled Prometheus (we use kube-prometheus-stack)
  prometheus:
    install: false

  # Disable GitLab Runner (install separately for better control)
  gitlab-runner:
    install: false

  # ─────────────────────────────────────────────────────────────────
  # STATEFUL COMPONENTS (in-cluster for learning, NOT for production)
  # ─────────────────────────────────────────────────────────────────

  # PostgreSQL subchart (Bitnami)
  postgresql:
    install: true
    persistence:
      storageClass: longhorn
      size: 15Gi
    # Resource limits for homelab
    primary:
      resources:
        requests:
          cpu: 250m
          memory: 512Mi
        limits:
          cpu: 1000m
          memory: 1Gi

  # Redis subchart (Bitnami)
  redis:
    install: true
    persistence:
      storageClass: longhorn
      size: 5Gi
    master:
      resources:
        requests:
          cpu: 100m
          memory: 256Mi
        limits:
          cpu: 500m
          memory: 512Mi

  # ─────────────────────────────────────────────────────────────────
  # GITLAB CORE COMPONENTS
  # ─────────────────────────────────────────────────────────────────

  gitlab:
    # Gitaly (Git storage backend)
    gitaly:
      persistence:
        storageClass: longhorn
        size: 50Gi
      resources:
        requests:
          cpu: 250m
          memory: 512Mi
        limits:
          cpu: 1000m
          memory: 1.5Gi

    # Webservice (main GitLab UI/API)
    webservice:
      # Single replica for homelab
      minReplicas: 1
      maxReplicas: 2
      resources:
        requests:
          cpu: 500m
          memory: 1.5Gi
        limits:
          cpu: 2000m
          memory: 3Gi
      # Workhorse (handles Git HTTP and large file uploads)
      workhorse:
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 500m
            memory: 256Mi

    # Sidekiq (background job processor)
    sidekiq:
      minReplicas: 1
      maxReplicas: 2
      resources:
        requests:
          cpu: 250m
          memory: 512Mi
        limits:
          cpu: 1000m
          memory: 1.5Gi

    # GitLab Shell (SSH access to repos)
    gitlab-shell:
      minReplicas: 1
      maxReplicas: 2

    # Toolbox (for rails console, rake tasks, backups)
    toolbox:
      enabled: true

    # Migrations (database migrations on install/upgrade)
    migrations:
      enabled: true

  # ─────────────────────────────────────────────────────────────────
  # CONTAINER REGISTRY
  # ─────────────────────────────────────────────────────────────────

  registry:
    enabled: true
    storage:
      secret: null  # Use filesystem storage
    persistence:
      enabled: true
      storageClass: longhorn
      size: 20Gi
    resources:
      requests:
        cpu: 100m
        memory: 256Mi
      limits:
        cpu: 500m
        memory: 512Mi
  ```

---

## 4.6.4 Install GitLab

- [ ] 4.6.4.1 Install GitLab Helm chart
  ```bash
  helm-homelab install gitlab gitlab/gitlab \
    --namespace gitlab \
    --version 9.8.2 \
    --values helm/gitlab/values.yaml \
    --timeout 15m
  ```

  > **Note:** The `--timeout` applies per-resource, not total. Full installation
  > typically takes 10-20 minutes as components start sequentially.

- [ ] 4.6.4.2 Monitor installation progress
  ```bash
  # Watch pods come up (Ctrl+C to exit)
  kubectl-homelab get pods -n gitlab -w

  # In another terminal, watch events for issues
  kubectl-homelab get events -n gitlab --sort-by='.lastTimestamp' -w
  ```

- [ ] 4.6.4.3 Wait for critical components (explicit verification)
  ```bash
  # Wait for PostgreSQL
  kubectl-homelab wait --for=condition=ready pod -l app.kubernetes.io/name=postgresql \
    -n gitlab --timeout=300s
  echo "✓ PostgreSQL ready"

  # Wait for Redis
  kubectl-homelab wait --for=condition=ready pod -l app.kubernetes.io/name=redis \
    -n gitlab --timeout=300s
  echo "✓ Redis ready"

  # Wait for Gitaly
  kubectl-homelab wait --for=condition=ready pod -l app=gitaly \
    -n gitlab --timeout=300s
  echo "✓ Gitaly ready"

  # Wait for Webservice (main UI)
  kubectl-homelab wait --for=condition=ready pod -l app=webservice \
    -n gitlab --timeout=600s
  echo "✓ Webservice ready"
  ```

- [ ] 4.6.4.4 Verify StatefulSets
  ```bash
  kubectl-homelab get statefulsets -n gitlab
  # Should see all with READY matching REPLICAS:
  # - gitlab-gitaly
  # - gitlab-postgresql
  # - gitlab-redis-master
  ```

- [ ] 4.6.4.5 Verify all pods running
  ```bash
  kubectl-homelab get pods -n gitlab
  # All should be Running or Completed (migrations/jobs)

  # Check for any issues
  kubectl-homelab get pods -n gitlab | grep -v "Running\|Completed"
  # Should return nothing
  ```

- [ ] 4.6.4.6 Discover service names for HTTPRoute
  ```bash
  # Find the webservice Service name and port
  kubectl-homelab get svc -n gitlab | grep webservice
  # Note the service name (usually gitlab-webservice-default) and port

  # Find the registry Service name and port
  kubectl-homelab get svc -n gitlab | grep registry
  # Note the service name and port
  ```

---

## 4.6.5 Create Network Policy (Internal Access Only)

Before exposing GitLab via Gateway, create a CiliumNetworkPolicy to ensure
cloudflared cannot reach the GitLab namespace (internal access only).

- [ ] 4.6.5.1 Create manifests/network-policies/gitlab-internal-only.yaml
  ```yaml
  # manifests/network-policies/gitlab-internal-only.yaml
  # Blocks Cloudflare Tunnel (cloudflared) from accessing GitLab
  # GitLab remains accessible via:
  #   - Home network (10.10.0.0/16)
  #   - Tailscale (100.64.0.0/10)
  #   - Cluster internal traffic
  apiVersion: cilium.io/v2
  kind: CiliumNetworkPolicy
  metadata:
    name: gitlab-deny-cloudflared
    namespace: gitlab
  spec:
    description: "Deny traffic from cloudflared to GitLab (internal access only)"
    endpointSelector: {}  # Applies to all pods in gitlab namespace
    ingressDeny:
      - fromEndpoints:
          - matchLabels:
              # Match cloudflared pods by their labels
              app.kubernetes.io/name: cloudflared
        toPorts:
          - ports:
              - port: "8181"   # Webservice
                protocol: TCP
              - port: "5000"   # Registry
                protocol: TCP
              - port: "22"     # SSH
                protocol: TCP
  ```

- [ ] 4.6.5.2 Apply network policy
  ```bash
  kubectl-homelab apply -f manifests/network-policies/gitlab-internal-only.yaml
  ```

- [ ] 4.6.5.3 Verify network policy
  ```bash
  kubectl-homelab get ciliumnetworkpolicy -n gitlab
  # Should see: gitlab-deny-cloudflared
  ```

---

## 4.6.6 Create HTTPRoutes for Gateway API

- [ ] 4.6.6.1 Create HTTPRoute for GitLab web
  ```bash
  mkdir -p manifests/gateway/routes
  ```

  Create manifests/gateway/routes/gitlab.yaml:
  ```yaml
  # manifests/gateway/routes/gitlab.yaml
  # HTTPRoute for GitLab web UI via Cilium Gateway API
  #
  # Verify service name first:
  #   kubectl-homelab get svc -n gitlab | grep webservice
  apiVersion: gateway.networking.k8s.io/v1
  kind: HTTPRoute
  metadata:
    name: gitlab
    namespace: gitlab
  spec:
    parentRefs:
      - name: homelab-gateway
        namespace: default
    hostnames:
      - "gitlab.k8s.rommelporras.com"
    rules:
      - matches:
          - path:
              type: PathPrefix
              value: /
        backendRefs:
          - name: gitlab-webservice-default
            port: 8181
  ```

- [ ] 4.6.6.2 Create HTTPRoute for Container Registry

  Create manifests/gateway/routes/gitlab-registry.yaml:
  ```yaml
  # manifests/gateway/routes/gitlab-registry.yaml
  # HTTPRoute for GitLab Container Registry via Cilium Gateway API
  #
  # Verify service name first:
  #   kubectl-homelab get svc -n gitlab | grep registry
  apiVersion: gateway.networking.k8s.io/v1
  kind: HTTPRoute
  metadata:
    name: gitlab-registry
    namespace: gitlab
  spec:
    parentRefs:
      - name: homelab-gateway
        namespace: default
    hostnames:
      - "registry.k8s.rommelporras.com"
    rules:
      - matches:
          - path:
              type: PathPrefix
              value: /
        backendRefs:
          - name: gitlab-registry
            port: 5000
  ```

- [ ] 4.6.6.3 Apply HTTPRoutes
  ```bash
  kubectl-homelab apply -f manifests/gateway/routes/gitlab.yaml
  kubectl-homelab apply -f manifests/gateway/routes/gitlab-registry.yaml
  ```

- [ ] 4.6.6.4 Verify HTTPRoutes accepted
  ```bash
  kubectl-homelab get httproute -n gitlab
  # Both should show ACCEPTED=True

  # Check detailed status
  kubectl-homelab describe httproute gitlab -n gitlab | grep -A5 "Status:"
  ```

- [ ] 4.6.6.5 Configure DNS rewrites in AdGuard
  ```
  # Add to both AdGuard instances (primary and secondary):
  # Settings → DNS rewrites → Add

  gitlab.k8s.rommelporras.com → 10.10.30.20
  registry.k8s.rommelporras.com → 10.10.30.20
  ```

---

## 4.6.7 Verify GitLab Access

- [ ] 4.6.7.1 Test DNS resolution
  ```bash
  nslookup gitlab.k8s.rommelporras.com
  # Should resolve to 10.10.30.20
  ```

- [ ] 4.6.7.2 Test HTTP connectivity
  ```bash
  curl -I https://gitlab.k8s.rommelporras.com
  # Should return 200 OK or 302 redirect
  ```

- [ ] 4.6.7.3 Access GitLab web UI
  ```
  https://gitlab.k8s.rommelporras.com
  Login: root / (password from 1Password: op://Kubernetes/GitLab/root-password)
  ```

- [ ] 4.6.7.4 Get initial root password (if 1Password secret wasn't used)
  ```bash
  # Only needed if you didn't set up the root password secret
  kubectl-homelab get secret gitlab-gitlab-initial-root-password -n gitlab \
    -o jsonpath='{.data.password}' | base64 -d && echo
  ```

- [ ] 4.6.7.5 First login tasks
  - Change root password (Profile → Edit Profile → Password)
  - Enable 2FA (Profile → Edit Profile → Two-factor Authentication)
  - Set email in Admin Area → Settings → General

---

## 4.6.8 Install GitLab Runner

> **Important: New Runner Registration Workflow**
>
> GitLab 17.0+ uses **authentication tokens** (prefixed with `glrt-`) instead of the
> deprecated registration tokens. Runner configuration (tags, run untagged, etc.) is
> now done in the GitLab UI when creating the runner, NOT in values.yaml.
>
> See: https://docs.gitlab.com/ee/ci/runners/new_creation_workflow.html

- [ ] 4.6.8.1 Create runner in GitLab UI and get authentication token
  ```
  1. Go to: Admin Area → CI/CD → Runners
  2. Click "New instance runner"
  3. Configure runner settings:
     - Tags: kubernetes, homelab (or as needed)
     - Run untagged jobs: ✓ (check if you want)
     - Protected: ✗ (uncheck for flexibility)
  4. Click "Create runner"
  5. Copy the authentication token (starts with glrt-)
  ```

- [ ] 4.6.8.2 Add runner token to 1Password
  ```bash
  # Add the glrt-xxx token to 1Password:
  # Item: GitLab
  # Field: runner-token
  # Value: glrt-xxxxxxxxxxxxxxxx (the token from GitLab UI)

  # Verify:
  op read "op://Kubernetes/GitLab/runner-token" | head -c 5
  # Should show: glrt-
  ```

- [ ] 4.6.8.3 Create gitlab-runner namespace and secret
  ```bash
  kubectl-homelab create namespace gitlab-runner
  kubectl-homelab label namespace gitlab-runner pod-security.kubernetes.io/enforce=privileged

  # Create secret with runnerToken key (NOT runner-registration-token)
  kubectl-homelab create secret generic gitlab-runner-token \
    --from-literal=runner-token="$(op read 'op://Kubernetes/GitLab/runner-token')" \
    -n gitlab-runner
  ```

- [ ] 4.6.8.4 Verify secret
  ```bash
  kubectl-homelab get secret gitlab-runner-token -n gitlab-runner -o jsonpath='{.data}' | jq 'keys'
  # Should show: ["runner-token"]
  ```

- [ ] 4.6.8.5 Create helm/gitlab-runner directory
  ```bash
  mkdir -p helm/gitlab-runner
  ```

- [ ] 4.6.8.6 Create helm/gitlab-runner/values.yaml
  ```yaml
  # helm/gitlab-runner/values.yaml
  # GitLab Runner with Kubernetes Executor
  #
  # Chart version: 0.85.0 (Runner 18.8.0)
  # Docs: https://docs.gitlab.com/runner/install/kubernetes/
  #
  # IMPORTANT: Uses new authentication token workflow (GitLab 17.0+)
  # Runner configuration (tags, run untagged, etc.) is done in GitLab UI,
  # NOT in this file.
  #
  # INSTALL:
  #   helm-homelab install gitlab-runner gitlab/gitlab-runner \
  #     --namespace gitlab-runner \
  #     --version 0.85.0 \
  #     --values helm/gitlab-runner/values.yaml
  #
  # UPGRADE:
  #   helm-homelab upgrade gitlab-runner gitlab/gitlab-runner \
  #     --namespace gitlab-runner \
  #     --version 0.85.0 \
  #     --values helm/gitlab-runner/values.yaml

  # GitLab instance URL
  gitlabUrl: https://gitlab.k8s.rommelporras.com

  # Runner authentication token (from secret)
  # The secret must have a key named 'runner-token' containing the glrt-xxx token
  runners:
    secret: gitlab-runner-token

    # Kubernetes executor configuration
    config: |
      [[runners]]
        [runners.kubernetes]
          namespace = "gitlab-runner"
          image = "alpine:latest"

          # Resource limits for CI job pods
          cpu_limit = "2"
          cpu_request = "500m"
          memory_limit = "2Gi"
          memory_request = "512Mi"

          # Helper container resources
          helper_cpu_limit = "500m"
          helper_cpu_request = "100m"
          helper_memory_limit = "256Mi"
          helper_memory_request = "128Mi"

          # Pull policy
          pull_policy = ["if-not-present"]

          # Pod labels for identification
          [runners.kubernetes.pod_labels]
            "gitlab-runner" = "true"

  # RBAC - required for creating job pods
  rbac:
    create: true
    # clusterWideAccess allows deploying to namespaces other than gitlab-runner
    # Set to true if your CI jobs need to deploy to other namespaces
    clusterWideAccess: true

  # Runner pod resources
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      cpu: 500m
      memory: 256Mi
  ```

- [ ] 4.6.8.7 Install GitLab Runner
  ```bash
  helm-homelab install gitlab-runner gitlab/gitlab-runner \
    --namespace gitlab-runner \
    --version 0.85.0 \
    --values helm/gitlab-runner/values.yaml
  ```

- [ ] 4.6.8.8 Verify runner pod is running
  ```bash
  kubectl-homelab get pods -n gitlab-runner
  # Should show gitlab-runner-xxx in Running state

  # Check logs for successful registration
  kubectl-homelab logs -n gitlab-runner -l app=gitlab-runner --tail=50
  # Look for: "Configuration loaded" and connection success
  ```

- [ ] 4.6.8.9 Verify runner registered in GitLab UI
  ```
  Admin Area → CI/CD → Runners
  Should show runner with green "online" status
  ```

---

## 4.6.9 Test CI/CD Pipeline

- [ ] 4.6.9.1 Create a test project
  ```
  GitLab → New Project → Create blank project
  Name: ci-test
  Visibility: Private
  Initialize with README: ✓
  ```

- [ ] 4.6.9.2 Add .gitlab-ci.yml
  ```yaml
  # .gitlab-ci.yml - Simple test pipeline
  stages:
    - test

  test-job:
    stage: test
    image: alpine:latest
    script:
      - echo "Hello from GitLab CI!"
      - echo "Runner is working correctly"
      - cat /etc/os-release
    tags: []  # Remove if you want to match specific tags
  ```

- [ ] 4.6.9.3 Commit and verify pipeline runs
  ```
  1. Commit the .gitlab-ci.yml file
  2. Go to: CI/CD → Pipelines
  3. Watch the pipeline execute
  4. Verify job completes successfully
  ```

- [ ] 4.6.9.4 Verify job pod was created
  ```bash
  # While job is running, check for job pod
  kubectl-homelab get pods -n gitlab-runner -l gitlab-runner=true

  # After job completes, pod should be cleaned up automatically
  ```

---

## 4.6.10 Import Repositories from GitHub (Optional)

- [ ] 4.6.10.1 Create GitHub personal access token (for import)
  ```
  GitHub → Settings → Developer settings → Personal access tokens → Fine-grained tokens
  Generate new token with:
  - Repository access: Select repositories to import
  - Permissions: Contents (read), Metadata (read)
  ```

- [ ] 4.6.10.2 Import repository
  ```
  GitLab → New Project → Import project → GitHub
  Authenticate with token
  Select repository to import
  ```

- [ ] 4.6.10.3 Configure mirroring (optional - keep GitHub as backup)
  ```
  Project → Settings → Repository → Mirroring repositories
  Add mirror direction: Push (GitLab → GitHub) or Pull (GitHub → GitLab)
  ```

---

## 4.6.11 Configure CI/CD for Next.js Projects

This section covers setting up CI/CD pipelines for your Next.js projects (invoicetron, portfolio)
using GitLab's built-in Container Registry.

### Container Registry Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                     CI/CD Pipeline Flow                             │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  1. git push          2. GitLab CI              3. Container        │
│     to main              builds image              Registry         │
│        │                     │                        │             │
│        ▼                     ▼                        ▼             │
│  ┌──────────┐         ┌──────────────┐      ┌─────────────────┐    │
│  │ GitLab   │────────►│ Runner Pod   │─────►│ registry.k8s.   │    │
│  │ Repo     │         │ (docker build)│      │ home...com      │    │
│  └──────────┘         └──────────────┘      │ (20Gi Longhorn) │    │
│                                              └────────┬────────┘    │
│                                                       │             │
│  4. Deploy to K8s                                     │             │
│        │                                              │             │
│        ▼                                              ▼             │
│  ┌──────────────┐                           ┌─────────────────┐    │
│  │ invoicetron  │◄──────────────────────────│  docker pull    │    │
│  │ Deployment   │     (imagePullSecrets)    │                 │    │
│  └──────────────┘                           └─────────────────┘    │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### Registry URLs

| Project | Registry URL |
|---------|-------------|
| invoicetron | `registry.k8s.rommelporras.com/invoicetron/invoicetron` |
| portfolio | `registry.k8s.rommelporras.com/portfolio/portfolio` |

> **Note:** GitLab auto-provides `$CI_REGISTRY_IMAGE` variable containing the full registry path.

### 4.6.11.1 Create Dockerfile for Next.js

Create this multi-stage Dockerfile in your Next.js project root:

```dockerfile
# Dockerfile for Next.js with standalone output
# Optimized for small image size (~150MB vs ~1GB)

# ─────────────────────────────────────────────────────────────────
# Stage 1: Dependencies
# ─────────────────────────────────────────────────────────────────
FROM node:20-alpine AS deps
WORKDIR /app

# Install dependencies based on the preferred package manager
COPY package.json package-lock.json* ./
RUN npm ci --only=production

# ─────────────────────────────────────────────────────────────────
# Stage 2: Builder
# ─────────────────────────────────────────────────────────────────
FROM node:20-alpine AS builder
WORKDIR /app

COPY package.json package-lock.json* ./
RUN npm ci

COPY . .

# Next.js collects anonymous telemetry - disable it
ENV NEXT_TELEMETRY_DISABLED=1

# Build the application
RUN npm run build

# ─────────────────────────────────────────────────────────────────
# Stage 3: Runner (production image)
# ─────────────────────────────────────────────────────────────────
FROM node:20-alpine AS runner
WORKDIR /app

ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1

# Create non-root user for security
RUN addgroup --system --gid 1001 nodejs && \
    adduser --system --uid 1001 nextjs

# Copy built assets from builder
COPY --from=builder /app/public ./public
COPY --from=builder --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=builder --chown=nextjs:nodejs /app/.next/static ./.next/static

USER nextjs

EXPOSE 3000

ENV PORT=3000
ENV HOSTNAME="0.0.0.0"

CMD ["node", "server.js"]
```

**Required:** Add to `next.config.js`:
```javascript
// next.config.js
module.exports = {
  output: 'standalone',  // Required for Docker optimization
  // ... other config
}
```

### 4.6.11.2 Create .gitlab-ci.yml

Create `.gitlab-ci.yml` in your project root:

```yaml
# .gitlab-ci.yml for Next.js projects
# Builds Docker image and pushes to GitLab Container Registry

stages:
  - build
  - deploy

variables:
  # Use Docker-in-Docker
  DOCKER_HOST: tcp://docker:2376
  DOCKER_TLS_CERTDIR: "/certs"
  DOCKER_TLS_VERIFY: 1
  DOCKER_CERT_PATH: "$DOCKER_TLS_CERTDIR/client"
  # Image tag: registry.k8s.home.../project:commit-sha
  IMAGE_TAG: ${CI_REGISTRY_IMAGE}:${CI_COMMIT_SHORT_SHA}
  IMAGE_LATEST: ${CI_REGISTRY_IMAGE}:latest

# ─────────────────────────────────────────────────────────────────
# Build Stage
# ─────────────────────────────────────────────────────────────────
build:
  stage: build
  image: docker:24
  services:
    - docker:24-dind
  before_script:
    # Login to GitLab Container Registry (credentials auto-injected)
    - docker login -u $CI_REGISTRY_USER -p $CI_REGISTRY_PASSWORD $CI_REGISTRY
  script:
    # Build with commit SHA tag
    - docker build -t $IMAGE_TAG -t $IMAGE_LATEST .
    # Push both tags
    - docker push $IMAGE_TAG
    - docker push $IMAGE_LATEST
  rules:
    - if: $CI_COMMIT_BRANCH == "main"
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"

# ─────────────────────────────────────────────────────────────────
# Deploy Stage (to Kubernetes)
# ─────────────────────────────────────────────────────────────────
deploy:
  stage: deploy
  image: bitnami/kubectl:latest
  script:
    # Update deployment with new image
    - kubectl set image deployment/${CI_PROJECT_NAME} app=$IMAGE_TAG -n ${CI_PROJECT_NAME}
    # Wait for rollout
    - kubectl rollout status deployment/${CI_PROJECT_NAME} -n ${CI_PROJECT_NAME} --timeout=300s
  environment:
    name: production
    url: https://${CI_PROJECT_NAME}.k8s.rommelporras.com
  rules:
    - if: $CI_COMMIT_BRANCH == "main"
  # Requires: KUBECONFIG variable or ServiceAccount with RBAC
  # See 4.6.11.5 for RBAC setup
```

### 4.6.11.3 Update Runner for Docker-in-Docker

The runner needs `privileged: true` for Docker-in-Docker builds. This is already configured
in `helm/gitlab-runner/values.yaml`, but verify:

```yaml
# helm/gitlab-runner/values.yaml (already configured)
runners:
  config: |
    [[runners]]
      [runners.kubernetes]
        namespace = "gitlab-runner"
        image = "alpine:latest"
        privileged = true  # Required for DinD
```

> **Security Note:** `privileged: true` gives containers full host access. This is acceptable
> for a homelab but would need isolation (separate runner pool) in production.

### 4.6.11.4 Configure Image Pull Secrets

For Kubernetes to pull images from your private registry, create an image pull secret:

```bash
# Create registry credentials secret in your app namespace
kubectl-homelab create secret docker-registry gitlab-registry \
  --docker-server=registry.k8s.rommelporras.com \
  --docker-username=<gitlab-username> \
  --docker-password=<gitlab-personal-access-token> \
  --docker-email=<your-email> \
  -n invoicetron

# Reference in deployment
# spec:
#   template:
#     spec:
#       imagePullSecrets:
#         - name: gitlab-registry
```

**Alternative:** Use GitLab Deploy Tokens (recommended):
```
Project → Settings → Repository → Deploy tokens
- Name: kubernetes-pull
- Scopes: read_registry
```

### 4.6.11.5 RBAC for CI/CD Deployments

Create a ServiceAccount for GitLab Runner to deploy to app namespaces:

```yaml
# manifests/gitlab/runner-deploy-rbac.yaml
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: gitlab-deployer
  namespace: gitlab-runner
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: gitlab-deployer
rules:
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "list", "patch", "update"]
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: gitlab-deployer
subjects:
  - kind: ServiceAccount
    name: gitlab-deployer
    namespace: gitlab-runner
roleRef:
  kind: ClusterRole
  name: gitlab-deployer
  apiGroup: rbac.authorization.k8s.io
```

Then update runner values to use this ServiceAccount:
```yaml
# helm/gitlab-runner/values.yaml
runners:
  config: |
    [[runners]]
      [runners.kubernetes]
        service_account = "gitlab-deployer"
```

### 4.6.11.6 Registry Storage Sizing

| Project | Image Size (optimized) | Versions to Keep | Storage |
|---------|----------------------|------------------|---------|
| invoicetron | ~150MB | 10 | ~1.5Gi |
| portfolio | ~150MB | 10 | ~1.5Gi |
| Future projects | ~200MB | 10 | ~2Gi |
| **Buffer** | - | - | ~15Gi |
| **Total Allocated** | - | - | **20Gi** ✓ |

### 4.6.11.7 Registry Garbage Collection (Optional)

To clean up old images and reclaim storage:

```bash
# Run garbage collection (GitLab 13.0+)
kubectl-homelab exec -n gitlab -it $(kubectl-homelab get pods -n gitlab -l app=registry -o name) \
  -- /bin/registry garbage-collect /etc/docker/registry/config.yml

# Or configure automatic cleanup in GitLab:
# Admin → Settings → CI/CD → Container Registry
# - Enable expiration policies
# - Keep: 10 tags per image
# - Remove tags older than: 90 days
```

### 4.6.11.8 Test Registry Access

After GitLab is installed, verify registry works:

```bash
# From your local machine (with Docker installed)
docker login registry.k8s.rommelporras.com
# Username: root (or your GitLab username)
# Password: (your GitLab password or access token)

# Test push
docker pull alpine:latest
docker tag alpine:latest registry.k8s.rommelporras.com/test/alpine:latest
docker push registry.k8s.rommelporras.com/test/alpine:latest

# Test pull
docker rmi registry.k8s.rommelporras.com/test/alpine:latest
docker pull registry.k8s.rommelporras.com/test/alpine:latest

# Clean up test image
# GitLab → Admin → Packages & Registries → Container Registry → Delete test project
```

---

## 4.6.12 Documentation Updates

- [ ] 4.6.12.1 Update VERSIONS.md
  ```markdown
  # Add to Applications section:
  | GitLab | 18.8.x | Self-hosted Git + CI/CD |
  | GitLab Runner | 18.8.x | Kubernetes executor |

  # Add to Version History:
  | YYYY-MM-DD | Phase 4.6: GitLab CI/CD platform |
  ```

- [ ] 4.6.12.2 Update docs/context/Secrets.md
  ```markdown
  # Add 1Password items:
  | GitLab | root-password | GitLab root user |
  | GitLab | postgresql-password | Internal database |
  | GitLab | runner-token | Runner authentication (glrt-xxx) |
  ```

- [ ] 4.6.12.3 Update docs/reference/CHANGELOG.md
  - Add Phase 4.6 section with milestone, decisions, lessons learned

---

## Verification Checklist

- [ ] Namespace `gitlab` exists with privileged PSS
- [ ] Namespace `gitlab-runner` exists with privileged PSS
- [ ] All GitLab pods running: `kubectl-homelab get pods -n gitlab`
- [ ] StatefulSets healthy: postgresql, redis, gitaly
- [ ] PVCs bound: `kubectl-homelab get pvc -n gitlab`
- [ ] CiliumNetworkPolicy applied: `kubectl-homelab get cnp -n gitlab`
- [ ] HTTPRoutes accepted: `kubectl-homelab get httproute -n gitlab`
- [ ] DNS resolves: `nslookup gitlab.k8s.rommelporras.com`
- [ ] GitLab web UI accessible at https://gitlab.k8s.rommelporras.com
- [ ] Can login as root with 1Password password
- [ ] 2FA configured for root account
- [ ] Container registry accessible at https://registry.k8s.rommelporras.com
- [ ] Docker login to registry works: `docker login registry.k8s.rommelporras.com`
- [ ] GitLab Runner registered and showing "online" in Admin → CI/CD → Runners
- [ ] Test pipeline runs successfully (simple alpine echo test)
- [ ] Docker build pipeline works (builds and pushes image to registry)
- [ ] 1Password items created (root-password, postgresql-password, runner-token)

---

## Rollback

If GitLab installation fails:

```bash
# 1. Check which component is failing
kubectl-homelab get pods -n gitlab
kubectl-homelab describe pod <failing-pod> -n gitlab

# 2. Check logs
kubectl-homelab logs -n gitlab <pod-name> --tail=100

# 3. Check events
kubectl-homelab get events -n gitlab --sort-by='.lastTimestamp' | tail -20

# 4. If storage issues, check PVCs
kubectl-homelab get pvc -n gitlab
kubectl-homelab describe pvc <pending-pvc> -n gitlab

# 5. Partial cleanup (keeps PVCs for debugging)
helm-homelab uninstall gitlab -n gitlab

# 6. Complete uninstall (WARNING: deletes all data)
helm-homelab uninstall gitlab -n gitlab
kubectl-homelab delete pvc --all -n gitlab
kubectl-homelab delete namespace gitlab

# 7. Clean up runner if installed
helm-homelab uninstall gitlab-runner -n gitlab-runner
kubectl-homelab delete namespace gitlab-runner

# 8. Start fresh from 4.6.1
```

---

## Troubleshooting

### GitLab pods stuck in Pending

```bash
# Check if PVCs are bound
kubectl-homelab get pvc -n gitlab

# If PVC Pending, check Longhorn
kubectl-homelab -n longhorn-system get volumes
kubectl-homelab -n longhorn-system get nodes.longhorn.io

# Common issues:
# - Not enough storage → check Longhorn available space
# - Node affinity issues → check Longhorn node status
# - StorageClass missing → verify 'longhorn' storageclass exists
```

### GitLab web UI returns 502

```bash
# Check webservice pod
kubectl-homelab logs -n gitlab -l app=webservice --tail=100

# Check if all dependencies are ready
kubectl-homelab get pods -n gitlab | grep -E "postgres|redis|gitaly"

# GitLab takes 10-15 minutes to fully initialize after pods are "Ready"
# The webservice needs to run migrations and warm up

# Check webservice readiness probe
kubectl-homelab describe pod -n gitlab -l app=webservice | grep -A10 "Readiness"
```

### Runner not registering (410 Gone error)

```bash
# This error means you're using the OLD registration token workflow
# You need to use the NEW authentication token workflow (glrt-xxx tokens)

# Check runner logs
kubectl-homelab logs -n gitlab-runner -l app=gitlab-runner --tail=100

# Verify secret has correct key
kubectl-homelab get secret gitlab-runner-token -n gitlab-runner -o yaml
# Should have key: runner-token (NOT runner-registration-token)

# Verify token format
kubectl-homelab get secret gitlab-runner-token -n gitlab-runner \
  -o jsonpath='{.data.runner-token}' | base64 -d | head -c 5
# Should show: glrt-
```

### Runner can't reach GitLab

```bash
# Test connectivity from runner namespace
kubectl-homelab run test --rm -it --image=curlimages/curl -n gitlab-runner -- \
  curl -v https://gitlab.k8s.rommelporras.com/api/v4/runners

# Check if network policy is blocking
kubectl-homelab get ciliumnetworkpolicy -A

# Common issues:
# - Wrong gitlabUrl in values.yaml
# - TLS certificate issues (try with -k for insecure)
# - DNS resolution failure
```

### CI/CD jobs fail to start pods

```bash
# Check runner configuration
kubectl-homelab get configmap -n gitlab-runner -o yaml

# Check RBAC permissions
kubectl-homelab auth can-i create pods -n gitlab-runner \
  --as=system:serviceaccount:gitlab-runner:gitlab-runner-gitlab-runner

# Check if privileged pods allowed (check PSS label)
kubectl-homelab get namespace gitlab-runner -o jsonpath='{.metadata.labels}'

# Check job pod events
kubectl-homelab get events -n gitlab-runner --sort-by='.lastTimestamp'
```

### Registry push/pull fails

```bash
# Test registry connectivity
curl -v https://registry.k8s.rommelporras.com/v2/

# Check registry pod
kubectl-homelab logs -n gitlab -l app=registry --tail=50

# Common issues:
# - TLS certificate mismatch
# - Registry not configured in Docker daemon (for insecure registries)
# - Authentication issues
```

---

## Backup Strategy (Recommended)

For a homelab, consider these backup approaches:

### Option 1: Longhorn Snapshots
```bash
# Create snapshot of GitLab PVCs
# Do this before upgrades or major changes
kubectl-homelab -n longhorn-system get volumes | grep gitlab
# Use Longhorn UI to create snapshots
```

### Option 2: GitLab Backup Task
```bash
# Run backup using GitLab toolbox
kubectl-homelab exec -n gitlab -it $(kubectl-homelab get pods -n gitlab -l app=toolbox -o name) \
  -- backup-utility --skip registry
# Backups stored in toolbox pod, copy to external storage
```

---

## Final: Commit and Release

- [ ] Commit changes
  ```bash
  /commit
  ```

- [ ] Release v0.8.0
  ```bash
  /release v0.8.0
  ```

- [ ] Move this file to completed folder
  ```bash
  mv docs/todo/phase-4.6-gitlab.md docs/todo/completed/
  ```
