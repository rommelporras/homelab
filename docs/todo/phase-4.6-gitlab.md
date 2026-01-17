# Phase 4.6: GitLab CI/CD Platform

> **Status:** ⬜ Planned (PRIORITY)
> **Target:** v0.8.0
> **DevOps Topics:** Helm charts, StatefulSets, CI/CD pipelines, Container registries
> **CKA Topics:** Complex Helm deployments, multi-component applications

> **Purpose:** Self-hosted CI/CD for private repos, container registry, DevOps learning
> **Why GitLab:** Free CI/CD for private repos, built-in registry, Kubernetes-native

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    gitlab namespace                          │
├─────────────────────────────────────────────────────────────┤
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐ │
│  │ PostgreSQL  │  │    Redis    │  │       Gitaly        │ │
│  │ StatefulSet │  │ StatefulSet │  │    StatefulSet      │ │
│  │   (15Gi)    │  │    (5Gi)    │  │ (50Gi - Git repos)  │ │
│  └─────────────┘  └─────────────┘  └─────────────────────┘ │
│         │                │                    │             │
│         └────────────────┼────────────────────┘             │
│                          ▼                                  │
│  ┌───────────────────────────────────────────────────────┐ │
│  │              GitLab Webservice (Deployment)           │ │
│  │         gitlab.k8s.home.rommelporras.com              │ │
│  └───────────────────────────────────────────────────────┘ │
│                          │                                  │
│         ┌────────────────┼────────────────┐                │
│         ▼                ▼                ▼                │
│  ┌───────────┐   ┌────────────┐   ┌─────────────┐         │
│  │  Sidekiq  │   │  Registry  │   │ GitLab Shell│         │
│  │ (bg jobs) │   │ (images)   │   │   (SSH)     │         │
│  └───────────┘   └────────────┘   └─────────────┘         │
└─────────────────────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────┐
│                 gitlab-runner namespace                      │
│  ┌───────────────────────────────────────────────────────┐ │
│  │  GitLab Runner (Deployment)                           │ │
│  │  - Kubernetes executor (spawns pods for CI jobs)      │ │
│  │  - Builds containers, runs tests, deploys to K8s      │ │
│  └───────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

## Resource Requirements

| Component | CPU | Memory | Storage |
|-----------|-----|--------|---------|
| PostgreSQL | 500m | 1Gi | 15Gi |
| Redis | 250m | 512Mi | 5Gi |
| Gitaly | 500m | 1Gi | 50Gi |
| Webservice | 1000m | 2Gi | - |
| Sidekiq | 500m | 1Gi | - |
| Registry | 250m | 512Mi | 20Gi |
| **Total** | ~3 CPU | ~6Gi | ~90Gi |

---

## 4.6.1 Prerequisites

- [ ] 4.6.1.1 Verify cluster resources
  ```bash
  kubectl-homelab top nodes
  # Need ~6GB free RAM, ~90GB storage
  ```

- [ ] 4.6.1.2 Add GitLab Helm repo
  ```bash
  helm-homelab repo add gitlab https://charts.gitlab.io
  helm-homelab repo update
  ```

- [ ] 4.6.1.3 Create gitlab namespace
  ```bash
  kubectl-homelab create namespace gitlab
  kubectl-homelab label namespace gitlab pod-security.kubernetes.io/enforce=privileged
  ```

---

## 4.6.2 Create Secrets

- [ ] 4.6.2.1 Add GitLab credentials to 1Password
  ```
  # Create items in Kubernetes vault:
  # - GitLab/root-password (initial root password)
  # - GitLab/postgresql-password
  # - GitLab/redis-password
  # - GitLab/runner-registration-token
  ```

- [ ] 4.6.2.2 Create K8s secrets
  ```bash
  # Root password
  kubectl-homelab create secret generic gitlab-root-password \
    --from-literal=password="$(op read 'op://Kubernetes/GitLab/root-password')" \
    -n gitlab

  # PostgreSQL
  kubectl-homelab create secret generic gitlab-postgresql-password \
    --from-literal=postgresql-password="$(op read 'op://Kubernetes/GitLab/postgresql-password')" \
    -n gitlab

  # Runner token (generate after GitLab install)
  ```

---

## 4.6.3 Create Helm Values

- [ ] 4.6.3.1 Create helm/gitlab/values.yaml
  ```yaml
  # helm/gitlab/values.yaml
  # GitLab Helm Chart Configuration for Homelab
  #
  # INSTALL:
  #   helm-homelab install gitlab gitlab/gitlab \
  #     --namespace gitlab \
  #     --version 8.7.0 \
  #     --values helm/gitlab/values.yaml \
  #     --timeout 10m
  #
  # UPGRADE:
  #   helm-homelab upgrade gitlab gitlab/gitlab \
  #     --namespace gitlab \
  #     --values helm/gitlab/values.yaml

  global:
    # Domain configuration
    hosts:
      domain: k8s.home.rommelporras.com
      gitlab:
        name: gitlab.k8s.home.rommelporras.com
      registry:
        name: registry.k8s.home.rommelporras.com

    # Ingress - use Cilium Gateway API
    ingress:
      enabled: false  # We'll use HTTPRoute instead
      configureCertmanager: false

    # Use existing secrets
    initialRootPassword:
      secret: gitlab-root-password
      key: password

    # PostgreSQL
    psql:
      password:
        secret: gitlab-postgresql-password
        key: postgresql-password

    # GitLab Shell (SSH)
    shell:
      port: 22

  # Disable bundled nginx (we use Cilium Gateway)
  nginx-ingress:
    enabled: false

  # Disable bundled cert-manager (we have our own)
  certmanager:
    install: false

  # Disable bundled Prometheus (we use kube-prometheus-stack)
  prometheus:
    install: false

  # PostgreSQL subchart
  postgresql:
    install: true
    persistence:
      storageClass: longhorn
      size: 15Gi

  # Redis subchart
  redis:
    install: true
    persistence:
      storageClass: longhorn
      size: 5Gi

  # Gitaly (Git storage)
  gitlab:
    gitaly:
      persistence:
        storageClass: longhorn
        size: 50Gi

    # Webservice resources (main GitLab UI)
    webservice:
      resources:
        requests:
          cpu: 500m
          memory: 1.5Gi
        limits:
          cpu: 2000m
          memory: 3Gi

    # Sidekiq resources (background jobs)
    sidekiq:
      resources:
        requests:
          cpu: 250m
          memory: 512Mi
        limits:
          cpu: 1000m
          memory: 1.5Gi

  # Container Registry
  registry:
    enabled: true
    persistence:
      storageClass: longhorn
      size: 20Gi

  # GitLab Runner (install separately for better control)
  gitlab-runner:
    install: false
  ```

---

## 4.6.4 Install GitLab

- [ ] 4.6.4.1 Install GitLab Helm chart
  ```bash
  helm-homelab install gitlab gitlab/gitlab \
    --namespace gitlab \
    --version 8.7.0 \
    --values helm/gitlab/values.yaml \
    --timeout 15m
  ```

- [ ] 4.6.4.2 Wait for all pods to be ready (can take 10-15 minutes)
  ```bash
  kubectl-homelab get pods -n gitlab -w
  # Wait for all pods to show Running/Completed
  ```

- [ ] 4.6.4.3 Verify StatefulSets
  ```bash
  kubectl-homelab get statefulsets -n gitlab
  # Should see: gitlab-postgresql, gitlab-redis, gitlab-gitaly
  ```

---

## 4.6.5 Create HTTPRoutes for Gateway API

- [ ] 4.6.5.1 Create HTTPRoute for GitLab web
  ```bash
  kubectl-homelab apply -f manifests/gateway/routes/gitlab.yaml
  ```
  ```yaml
  # manifests/gateway/routes/gitlab.yaml
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
    - "gitlab.k8s.home.rommelporras.com"
    rules:
    - matches:
      - path:
          type: PathPrefix
          value: /
      backendRefs:
      - name: gitlab-webservice-default
        port: 8181
  ```

- [ ] 4.6.5.2 Create HTTPRoute for Container Registry
  ```bash
  kubectl-homelab apply -f manifests/gateway/routes/gitlab-registry.yaml
  ```

- [ ] 4.6.5.3 Configure DNS rewrites in AdGuard
  ```
  # Add to both AdGuard instances:
  gitlab.k8s.home.rommelporras.com → 10.10.30.20
  registry.k8s.home.rommelporras.com → 10.10.30.20
  ```

---

## 4.6.6 Verify GitLab Access

- [ ] 4.6.6.1 Access GitLab web UI
  ```
  https://gitlab.k8s.home.rommelporras.com
  Login: root / (password from 1Password)
  ```

- [ ] 4.6.6.2 Get initial root password if not set
  ```bash
  kubectl-homelab get secret gitlab-gitlab-initial-root-password -n gitlab \
    -o jsonpath='{.data.password}' | base64 -d
  ```

- [ ] 4.6.6.3 Change root password and configure 2FA

---

## 4.6.7 Install GitLab Runner

- [ ] 4.6.7.1 Get runner registration token from GitLab UI
  ```
  Admin Area → CI/CD → Runners → New instance runner
  Copy the registration token
  ```

- [ ] 4.6.7.2 Add token to 1Password and create secret
  ```bash
  kubectl-homelab create namespace gitlab-runner
  kubectl-homelab create secret generic gitlab-runner-token \
    --from-literal=runner-registration-token="$(op read 'op://Kubernetes/GitLab/runner-token')" \
    -n gitlab-runner
  ```

- [ ] 4.6.7.3 Create helm/gitlab-runner/values.yaml
  ```yaml
  # helm/gitlab-runner/values.yaml
  gitlabUrl: https://gitlab.k8s.home.rommelporras.com

  runners:
    secret: gitlab-runner-token
    config: |
      [[runners]]
        [runners.kubernetes]
          namespace = "gitlab-runner"
          image = "alpine:latest"
          privileged = true  # Required for Docker-in-Docker builds
          [[runners.kubernetes.volumes.empty_dir]]
            name = "docker-certs"
            mount_path = "/certs/client"
            medium = "Memory"

  rbac:
    create: true
    clusterWideAccess: true  # For deploying to other namespaces
  ```

- [ ] 4.6.7.4 Install GitLab Runner
  ```bash
  helm-homelab install gitlab-runner gitlab/gitlab-runner \
    --namespace gitlab-runner \
    --version 0.71.0 \
    --values helm/gitlab-runner/values.yaml
  ```

- [ ] 4.6.7.5 Verify runner registered
  ```bash
  kubectl-homelab get pods -n gitlab-runner
  # Check GitLab UI: Admin → CI/CD → Runners (should show online)
  ```

---

## 4.6.8 Configure Cloudflare Tunnel (Optional External Access)

- [ ] 4.6.8.1 Add GitLab route to tunnel
  ```
  # If you want external access to GitLab:
  # Cloudflare Zero Trust → Tunnels → Add public hostname
  # gitlab.yourdomain.com → http://gitlab-webservice-default.gitlab.svc.cluster.local:8181
  ```

---

## 4.6.9 Import Repositories from GitHub

- [ ] 4.6.9.1 Create GitHub personal access token (for import)
  ```
  GitHub → Settings → Developer settings → Personal access tokens
  Scopes: repo (full control)
  ```

- [ ] 4.6.9.2 Import portfolio repository
  ```
  GitLab → New Project → Import project → GitHub
  Select: portfolio
  ```

- [ ] 4.6.9.3 Import invoicetron repository
  ```
  GitLab → New Project → Import project → GitHub
  Select: invoicetron
  ```

- [ ] 4.6.9.4 Configure mirroring (optional - keep GitHub as backup)
  ```
  Project → Settings → Repository → Mirroring repositories
  Push mirror to GitHub (read-only backup)
  ```

**Rollback:** `helm-homelab uninstall gitlab -n gitlab`
