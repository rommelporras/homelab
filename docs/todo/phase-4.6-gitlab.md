# Phase 4.6: GitLab CI/CD Platform

> **Status:** ⬜ Planned (PRIORITY)
> **Target:** v0.8.0
> **Prerequisite:** Phase 4.5 complete (Cloudflare Tunnel for external access)
> **DevOps Topics:** Helm charts, StatefulSets, CI/CD pipelines, Container registries
> **CKA Topics:** Complex Helm deployments, multi-component applications, RBAC

> **Purpose:** Self-hosted CI/CD for private repos, container registry, DevOps learning
> **Why GitLab:** Free CI/CD for private repos, built-in registry, Kubernetes-native

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
  # Need ~6GB free RAM across cluster
  # Need ~90GB available storage in Longhorn

  # Check Longhorn capacity
  kubectl-homelab -n longhorn-system get nodes.longhorn.io -o custom-columns=NAME:.metadata.name,AVAIL:.status.diskStatus.default-disk.storageAvailable
  ```

- [ ] 4.6.1.2 Add GitLab Helm repo
  ```bash
  helm-homelab repo add gitlab https://charts.gitlab.io --force-update
  helm-homelab repo update
  ```

- [ ] 4.6.1.3 Check available GitLab chart versions
  ```bash
  helm-homelab search repo gitlab/gitlab --versions | head -10
  # Pick a recent stable version
  ```

- [ ] 4.6.1.4 Create gitlab namespace
  ```bash
  kubectl-homelab create namespace gitlab
  kubectl-homelab label namespace gitlab pod-security.kubernetes.io/enforce=privileged
  # privileged required: GitLab components need various capabilities
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
  #   - runner-token: (will add after install)
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

---

## 4.6.10 Documentation Updates

- [ ] 4.6.10.1 Update VERSIONS.md
  ```
  # Add to Applications section:
  | GitLab | 8.x.x | Self-hosted Git + CI/CD |
  | GitLab Runner | 0.71.x | Kubernetes executor |

  # Add to Version History:
  | YYYY-MM-DD | Phase 4.6: GitLab CI/CD platform |
  ```

- [ ] 4.6.10.2 Update docs/context/Secrets.md
  ```
  # Add 1Password items:
  | GitLab | root-password | GitLab root user |
  | GitLab | postgresql-password | Internal database |
  | GitLab | runner-token | Runner registration |
  ```

- [ ] 4.6.10.3 Update docs/reference/CHANGELOG.md
  - Add Phase 4.6 section with milestone, decisions, lessons learned

---

## Verification Checklist

- [ ] Namespace `gitlab` exists with privileged PSS
- [ ] All GitLab pods running (check with `kubectl-homelab get pods -n gitlab`)
- [ ] StatefulSets healthy: postgresql, redis, gitaly
- [ ] GitLab web UI accessible at https://gitlab.k8s.home.rommelporras.com
- [ ] Can login as root with 1Password password
- [ ] Container registry accessible at registry.k8s.home.rommelporras.com
- [ ] GitLab Runner registered and showing "online" in Admin → CI/CD → Runners
- [ ] Test pipeline runs successfully
- [ ] DNS rewrites configured in AdGuard
- [ ] 1Password items created (root-password, postgresql-password, runner-token)

---

## Rollback

If GitLab installation fails:

```bash
# 1. Check which component is failing
kubectl-homelab get pods -n gitlab
kubectl-homelab describe pod <failing-pod> -n gitlab

# 2. Check logs
kubectl-homelab logs -n gitlab <pod-name>

# 3. If storage issues, check PVCs
kubectl-homelab get pvc -n gitlab

# 4. Complete uninstall (WARNING: deletes all data)
helm-homelab uninstall gitlab -n gitlab
kubectl-homelab delete pvc --all -n gitlab
kubectl-homelab delete namespace gitlab

# 5. Start fresh from 4.6.1
```

---

## Troubleshooting

### GitLab pods stuck in Pending

```bash
# Check if PVCs are bound
kubectl-homelab get pvc -n gitlab

# If PVC Pending, check Longhorn
kubectl-homelab -n longhorn-system get volumes

# Common issues:
# - Not enough storage → add more NVMe or reduce PVC sizes
# - Node affinity issues → check Longhorn node status
```

### GitLab web UI returns 502

```bash
# Check webservice pod
kubectl-homelab logs -n gitlab -l app=webservice --tail=50

# Check if all dependencies are ready
kubectl-homelab get pods -n gitlab | grep -E "postgres|redis|gitaly"

# GitLab takes 10-15 minutes to fully initialize
# Wait and check again
```

### Runner not registering

```bash
# Check runner logs
kubectl-homelab logs -n gitlab-runner -l app=gitlab-runner

# Verify runner can reach GitLab
kubectl-homelab run test --rm -it --image=curlimages/curl -n gitlab-runner -- \
  curl -v https://gitlab.k8s.home.rommelporras.com/api/v4/runners

# Common issues:
# - Wrong gitlabUrl in values.yaml
# - Invalid registration token
# - Network policy blocking traffic
```

### CI/CD jobs fail to start pods

```bash
# Check runner configuration
kubectl-homelab get configmap -n gitlab-runner -o yaml

# Check RBAC permissions
kubectl-homelab auth can-i create pods -n gitlab-runner --as=system:serviceaccount:gitlab-runner:gitlab-runner

# Check if privileged pods allowed
kubectl-homelab get psp  # (if PSP enabled)
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
