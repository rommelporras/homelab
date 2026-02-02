# Phase 4.7: Portfolio Migration

> **Status:** Complete
> **Target:** v0.8.1
> **Prerequisite:** Phase 4.6 complete (GitLab + Runner installed)
> **Design:** [docs/plans/2026-01-25-portfolio-cicd-design.md](../plans/2026-01-25-portfolio-cicd-design.md)
> **DevOps Topics:** CI/CD pipelines, GitFlow branching, artifact promotion, container builds
> **CKA Topics:** Deployments, Services, RBAC (ServiceAccount for CI/CD), Namespaces

> **Purpose:** First app deployment using GitLab CI/CD with multi-environment promotion
> **Stack:** Next.js 16 + Bun + nginx (static export)
> **Source:** GitLab (imported from GitHub, mirrored back via SSH)
>
> **Learning Goals:**
> - GitFlow branching with artifact promotion
> - Multi-environment deployment (dev → staging → prod)
> - Manual approval gates (corporate pattern)
> - Same artifact promoted through environments

> **Environments:**
> | Environment | Internal URL | Public URL |
> |-------------|--------------|------------|
> | Dev | `portfolio.dev.k8s.rommelporras.com` | - |
> | Staging | `portfolio.stg.k8s.rommelporras.com` | `beta.rommelporras.com` |
> | Prod | `portfolio.k8s.rommelporras.com` | `www.rommelporras.com` |

---

## CI/CD Flow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    Portfolio CI/CD Pipeline (GitFlow)                        │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   feature/* ───────► develop ─────────────────────────► main                │
│                          │                                 │                │
│                    [Build image]                    [No rebuild]            │
│                          │                                 │                │
│                          ▼                                 ▼                │
│                     deploy:dev                       deploy:prod            │
│                       [auto]                      [auto on merge]           │
│                          │                                                  │
│                          ▼                                                  │
│                  ⏸️ deploy:staging                                          │
│                      [manual]                                               │
│                          │                                                  │
│                          ▼                                                  │
│                   [Test on staging]                                         │
│                          │                                                  │
│                          ▼                                                  │
│                  Create MR: develop → main                                  │
│                          │                                                  │
│                          ▼                                                  │
│                     Merge MR                                                │
│                          │                                                  │
│                          ▼                                                  │
│               [Deploys to prod automatically]                               │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Key Concepts This Phase Teaches

| Concept | What You'll Learn |
|---------|-------------------|
| **GitFlow branching** | Feature branches merge to develop, then promote to main |
| **Artifact promotion** | Same image deployed through dev → staging → prod |
| **Manual approval gates** | Corporate pattern for production readiness |
| **Docker multi-stage builds** | Bun build + nginx serve |
| **GitLab Container Registry** | Store images in your own registry |
| **Environment-scoped secrets** | Different KUBE_TOKEN per environment |
| **Kubernetes RBAC** | ServiceAccount with limited permissions per namespace |
| **Rolling deployments** | Zero-downtime updates |

---

## 4.7.1 GitLab Setup

- [x] 4.7.1.1 Import portfolio from GitHub ✅
  ```
  GitLab → New Project → Import project → GitHub
  Select: rommelporras/portfolio
  Imported to: 0xwsh/portfolio
  ```

- [x] 4.7.1.2 Enable Container Registry ✅
  ```
  Project → Settings → General → Visibility → Container Registry: Enabled
  (Enabled by default at instance level)
  ```

- [x] 4.7.1.3 Configure GitHub push mirroring (SSH method) ✅
  ```
  Project → Settings → Repository → Mirroring repositories

  Git repository URL: ssh://git@github.com/rommelporras/portfolio.git
  Mirror direction: Push
  Authentication method: SSH public key
  SSH host keys: (from ssh-keyscan github.com)
  Only mirror protected branches: Yes

  Then add GitLab's SSH public key to GitHub:
  GitHub repo → Settings → Deploy keys → Add deploy key
  Title: GitLab homelab push mirror
  Key: (paste GitLab's public key)
  Allow write access: Yes
  ```

---

## 4.7.2 Create Kubernetes Namespaces

- [x] 4.7.2.1 Create three namespaces ✅
  ```bash
  kubectl-homelab create namespace portfolio-dev
  kubectl-homelab create namespace portfolio-staging
  kubectl-homelab create namespace portfolio-prod

  # Apply pod security baseline to all
  kubectl-homelab label namespace portfolio-dev pod-security.kubernetes.io/enforce=baseline
  kubectl-homelab label namespace portfolio-staging pod-security.kubernetes.io/enforce=baseline
  kubectl-homelab label namespace portfolio-prod pod-security.kubernetes.io/enforce=baseline
  ```

---

## 4.7.3 Create ServiceAccounts + RBAC

- [x] 4.7.3.1 Create ServiceAccount manifest ✅
  ```bash
  mkdir -p manifests/portfolio
  ```
  ```yaml
  # manifests/portfolio/rbac.yaml
  # Apply this to each namespace: portfolio-dev, portfolio-staging, portfolio-prod
  ---
  apiVersion: v1
  kind: ServiceAccount
  metadata:
    name: gitlab-deploy
  ---
  apiVersion: rbac.authorization.k8s.io/v1
  kind: Role
  metadata:
    name: gitlab-deploy
  rules:
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "list", "watch", "patch", "update"]
  - apiGroups: ["apps"]
    resources: ["replicasets"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "watch"]
  ---
  apiVersion: rbac.authorization.k8s.io/v1
  kind: RoleBinding
  metadata:
    name: gitlab-deploy
  subjects:
  - kind: ServiceAccount
    name: gitlab-deploy
  roleRef:
    kind: Role
    name: gitlab-deploy
    apiGroup: rbac.authorization.k8s.io
  ---
  apiVersion: v1
  kind: Secret
  metadata:
    name: gitlab-deploy-token
    annotations:
      kubernetes.io/service-account.name: gitlab-deploy
  type: kubernetes.io/service-account-token
  ```

  > **Note:** `list` and `watch` verbs on deployments are required for `kubectl rollout status`.
  > `replicasets` resource is needed for rollout status to track replica progress.

- [x] 4.7.3.2 Apply RBAC to all namespaces ✅
  ```bash
  kubectl-homelab apply -f manifests/portfolio/rbac.yaml -n portfolio-dev
  kubectl-homelab apply -f manifests/portfolio/rbac.yaml -n portfolio-staging
  kubectl-homelab apply -f manifests/portfolio/rbac.yaml -n portfolio-prod
  ```

- [x] 4.7.3.3 Get tokens and add to GitLab CI/CD variables ✅
  ```bash
  # Get tokens (use tr -d '\n' to avoid whitespace issues)
  kubectl-homelab get secret gitlab-deploy-token -n portfolio-dev \
    -o jsonpath='{.data.token}' | base64 -d | tr -d '\n'

  kubectl-homelab get secret gitlab-deploy-token -n portfolio-staging \
    -o jsonpath='{.data.token}' | base64 -d | tr -d '\n'

  kubectl-homelab get secret gitlab-deploy-token -n portfolio-prod \
    -o jsonpath='{.data.token}' | base64 -d | tr -d '\n'
  ```

  ```
  # First create GitLab environments:
  # Operate → Environments → New environment
  # Create: dev, staging, production (with External URLs)

  # Then add CI/CD variables:
  # Project → Settings → CI/CD → Variables

  | Variable     | Environment | Visibility        | Protect? |
  |--------------|-------------|-------------------|----------|
  | KUBE_API_URL | All         | Masked and hidden | No       |
  | KUBE_TOKEN   | dev         | Masked and hidden | No       |
  | KUBE_TOKEN   | staging     | Masked and hidden | No       |
  | KUBE_TOKEN   | production  | Masked and hidden | Yes      |

  Values:
  - KUBE_API_URL: https://10.10.30.10:6443
  - KUBE_TOKEN (dev): Token from portfolio-dev/gitlab-deploy-token
  - KUBE_TOKEN (staging): Token from portfolio-staging/gitlab-deploy-token
  - KUBE_TOKEN (production): Token from portfolio-prod/gitlab-deploy-token
  ```

---

## 4.7.4 Create K8s Deployments + Services

- [x] 4.7.4.1 Create deployment manifest (applies to all environments) ✅
  ```yaml
  # manifests/portfolio/deployment.yaml
  apiVersion: apps/v1
  kind: Deployment
  metadata:
    name: portfolio
  spec:
    replicas: 2
    selector:
      matchLabels:
        app: portfolio
    template:
      metadata:
        labels:
          app: portfolio
      spec:
        containers:
        - name: portfolio
          image: registry.k8s.rommelporras.com/root/portfolio:latest
          ports:
          - containerPort: 80
          resources:
            requests:
              memory: "64Mi"
              cpu: "50m"
            limits:
              memory: "128Mi"
              cpu: "200m"
          livenessProbe:
            httpGet:
              path: /health
              port: 80
            initialDelaySeconds: 5
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /health
              port: 80
            initialDelaySeconds: 5
            periodSeconds: 5
  ---
  apiVersion: v1
  kind: Service
  metadata:
    name: portfolio
  spec:
    selector:
      app: portfolio
    ports:
    - port: 80
      targetPort: 80
  ```

- [x] 4.7.4.2 Apply deployments to all namespaces ✅
  ```bash
  kubectl-homelab apply -f manifests/portfolio/deployment.yaml -n portfolio-dev
  kubectl-homelab apply -f manifests/portfolio/deployment.yaml -n portfolio-staging
  kubectl-homelab apply -f manifests/portfolio/deployment.yaml -n portfolio-prod
  ```

---

## 4.7.5 Create HTTPRoutes

- [x] 4.7.5.1 Create HTTPRoute for dev ✅
  ```yaml
  # manifests/gateway/routes/portfolio-dev.yaml
  apiVersion: gateway.networking.k8s.io/v1
  kind: HTTPRoute
  metadata:
    name: portfolio
    namespace: portfolio-dev
  spec:
    parentRefs:
    - name: homelab-gateway
      namespace: default
    hostnames:
    - "portfolio.dev.k8s.rommelporras.com"
    rules:
    - matches:
      - path:
          type: PathPrefix
          value: /
      backendRefs:
      - name: portfolio
        port: 80
  ```

- [x] 4.7.5.2 Create HTTPRoute for staging ✅
  ```yaml
  # manifests/gateway/routes/portfolio-staging.yaml
  apiVersion: gateway.networking.k8s.io/v1
  kind: HTTPRoute
  metadata:
    name: portfolio
    namespace: portfolio-staging
  spec:
    parentRefs:
    - name: homelab-gateway
      namespace: default
    hostnames:
    - "portfolio.stg.k8s.rommelporras.com"
    rules:
    - matches:
      - path:
          type: PathPrefix
          value: /
      backendRefs:
      - name: portfolio
        port: 80
  ```

- [x] 4.7.5.3 Create HTTPRoute for prod ✅
  ```yaml
  # manifests/gateway/routes/portfolio-prod.yaml
  apiVersion: gateway.networking.k8s.io/v1
  kind: HTTPRoute
  metadata:
    name: portfolio
    namespace: portfolio-prod
  spec:
    parentRefs:
    - name: homelab-gateway
      namespace: default
    hostnames:
    - "portfolio.k8s.rommelporras.com"
    rules:
    - matches:
      - path:
          type: PathPrefix
          value: /
      backendRefs:
      - name: portfolio
        port: 80
  ```

- [x] 4.7.5.4 Apply all HTTPRoutes ✅
  ```bash
  kubectl-homelab apply -f manifests/gateway/routes/portfolio-dev.yaml
  kubectl-homelab apply -f manifests/gateway/routes/portfolio-staging.yaml
  kubectl-homelab apply -f manifests/gateway/routes/portfolio-prod.yaml
  ```

---

## 4.7.6 Configure DNS (AdGuard)

- [x] 4.7.6.1 Verify DNS rewrites in AdGuard Home ✅
  ```
  Existing wildcard already covers all environments:
  *.k8s.rommelporras.com → 10.10.30.20

  AdGuard uses pattern matching (not strict DNS wildcards),
  so multi-level subdomains like *.dev.k8s.home... are covered.
  ```

- [x] 4.7.6.2 Test internal DNS resolution ✅
  ```bash
  nslookup portfolio.dev.k8s.rommelporras.com
  # Returns: 10.10.30.20 (Gateway IP)
  ```

---

## 4.7.7 Configure Cloudflare Tunnel

- [x] 4.7.7.1 Add route for beta.rommelporras.com (staging) ✅
  ```
  Cloudflare Zero Trust → Networks → Tunnels → (tunnel) → Public Hostname

  Added:
  Subdomain: beta
  Domain: rommelporras.com
  Service type: HTTP
  URL: portfolio.portfolio-staging.svc:80
  ```

- [x] 4.7.7.2 Update route for www.rommelporras.com (prod) ✅
  ```
  Cloudflare Zero Trust → Networks → Tunnels → Public Hostname

  Subdomain: www
  Domain: rommelporras.com
  Service type: HTTP
  URL: portfolio.portfolio-prod.svc:80

  Traffic confirmed hitting K8s pods (verified via nginx logs)
  ```

---

## 4.7.8 Update Portfolio Repository

- [x] 4.7.8.1 Dockerfile already configured ✅ (uses npm, works fine)
  ```dockerfile
  # Dockerfile (in portfolio repo)
  # ==================================
  # Stage 1: Install dependencies
  # ==================================
  FROM oven/bun:1 AS deps

  WORKDIR /app

  COPY package.json bun.lock ./

  RUN bun install --frozen-lockfile --production

  # ==================================
  # Stage 2: Build Next.js
  # ==================================
  FROM oven/bun:1 AS builder

  WORKDIR /app

  COPY --from=deps /app/node_modules ./node_modules
  COPY . .

  RUN bun run build

  # ==================================
  # Stage 3: Serve with nginx
  # ==================================
  FROM nginx:alpine

  COPY nginx.conf /etc/nginx/nginx.conf
  COPY --from=builder /app/out /usr/share/nginx/html

  HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
      CMD wget -qO- http://127.0.0.1/health || exit 1

  EXPOSE 80

  CMD ["nginx", "-g", "daemon off;"]
  ```

- [x] 4.7.8.2 Add type-check script to package.json ✅
  ```json
  {
    "scripts": {
      "type-check": "tsc --noEmit"
    }
  }
  ```

- [ ] 4.7.8.3 Add accessibility testing dependency (optional, deferred)
  ```bash
  cd /home/wsl/personal/portfolio
  npm install -D @axe-core/playwright
  ```

- [ ] 4.7.8.4 Create accessibility test file (optional, deferred)
  ```typescript
  // e2e/accessibility.spec.ts
  import { test, expect } from '@playwright/test';
  import AxeBuilder from '@axe-core/playwright';

  test.describe('Accessibility @a11y', () => {
    test('homepage has no accessibility violations', async ({ page }) => {
      await page.goto('/');
      const results = await new AxeBuilder({ page }).analyze();
      expect(results.violations).toEqual([]);
    });

    test('about page has no accessibility violations', async ({ page }) => {
      await page.goto('/about');
      const results = await new AxeBuilder({ page }).analyze();
      expect(results.violations).toEqual([]);
    });
  });
  ```

- [x] 4.7.8.5 Create .gitlab-ci.yml ✅
  See [docs/plans/2026-01-25-portfolio-cicd-design.md](../plans/2026-01-25-portfolio-cicd-design.md#gitlab-cicd-configuration) for full configuration.

---

## 4.7.9 Test Pipeline

- [x] 4.7.9.1 Create develop branch and push ✅
  ```bash
  cd /home/wsl/personal/portfolio
  git checkout -b develop
  git add .
  git commit -m "feat: add GitLab CI/CD pipeline with Bun"
  git push -u origin develop
  ```

- [x] 4.7.9.2 Watch pipeline in GitLab UI ✅
  ```
  Project → Build → Pipelines

  Pipeline #16 passed:
  ✅ validate (lint, type-check, security-audit)
  ✅ test (unit, e2e:smoke)
  ✅ build (Docker image)
  ✅ deploy:dev (automatic)
  ⏸️ deploy:staging (manual trigger)

  Note: Made project public to allow anonymous registry pulls.
  ```

- [x] 4.7.9.3 Verify dev deployment ✅
  ```bash
  kubectl-homelab get pods -n portfolio-dev
  # NAME                        READY   STATUS    RESTARTS   AGE
  # portfolio-549cdcc76-hqzv8   1/1     Running   0          37s
  # portfolio-549cdcc76-qx5p9   1/1     Running   0          45s

  curl -sk https://portfolio.dev.k8s.rommelporras.com
  # Returns 200 OK (cert warning expected - multi-level subdomain)
  ```

- [x] 4.7.9.4 Manually promote to staging ✅
  ```
  GitLab → Pipelines → Click "Promote to Staging" (play button)
  Pipeline #19 deploy:staging succeeded
  ```

- [x] 4.7.9.5 Verify staging deployment ✅
  ```bash
  kubectl-homelab get pods -n portfolio-staging
  # 2/2 Running

  curl -I https://portfolio.stg.k8s.rommelporras.com
  # 200 OK

  curl -I https://beta.rommelporras.com
  # 200 OK (fixed CiliumNetworkPolicy to allow portfolio-staging)
  ```

- [x] 4.7.9.6 Create production release ✅
  ```bash
  git checkout main
  git merge develop --no-edit
  git push origin main
  # Pipeline triggered deploy:prod automatically
  ```

- [x] 4.7.9.7 Verify production deployment ✅
  ```bash
  kubectl-homelab get pods -n portfolio-prod
  # portfolio-5658bff458-mkq7s   1/1     Running
  # portfolio-5658bff458-s4tx9   1/1     Running

  curl -I https://portfolio.k8s.rommelporras.com
  # 200 OK

  curl -I https://www.rommelporras.com
  # 200 OK (traffic confirmed via pod logs)
  ```

---

## 4.7.10 Retire PVE VM

- [x] 4.7.10.1 Run K8s portfolio alongside VM ✅ (tested same day)

- [x] 4.7.10.2 Stop Docker Compose on PVE VM ✅
  ```bash
  ssh reverse-mountain "cd /home/wawashi/portfolio && docker compose down"
  ```

- [ ] 4.7.10.3 After stable, delete VM (or repurpose)

---

## 4.7.11 Documentation Updates

- [x] 4.7.11.1 Update VERSIONS.md ✅
  - Added portfolio HTTPRoutes to table
  - Added Version History entry for Phase 4.7

- [x] 4.7.11.2 Update docs/reference/CHANGELOG.md ✅
  - Added Phase 4.7 section with milestone, decisions, lessons learned

- [x] 4.7.11.3 Update docs/context/ files ✅
  - _Index.md: Updated status to Phase 4.7
  - Cluster.md: Added portfolio namespaces
  - Gateway.md: Added portfolio HTTPRoutes and updated diagram

---

## Verification Checklist

- [x] GitLab repository with Container Registry enabled
- [x] GitHub push mirror working
- [x] Three namespaces created (portfolio-dev, portfolio-staging, portfolio-prod)
- [x] RBAC configured with environment-scoped tokens
- [x] Deployments created in all three namespaces
- [x] HTTPRoutes configured for all environments
- [x] DNS rewrites covered by existing *.k8s.home... wildcard
- [x] Pipeline passes all stages on develop branch ✅ (Pipeline #16)
- [x] Auto-deploy to dev works ✅
- [x] Manual staging promotion works ✅
- [x] Production deploy works ✅ (main branch auto-deploy)
- [x] All internal URLs accessible:
  - [x] portfolio.dev.k8s.rommelporras.com ✅
  - [x] portfolio.stg.k8s.rommelporras.com ✅
  - [x] portfolio.k8s.rommelporras.com ✅ (pods running, internal access works)
- [x] Cloudflare Tunnel routes working:
  - [x] beta.rommelporras.com → staging ✅
  - [x] www.rommelporras.com → prod ✅
- [x] VM Docker Compose stopped ✅

---

## Rollback

### Quick Rollback (K8s)

```bash
# Rollback to previous deployment
kubectl-homelab rollout undo deployment/portfolio -n portfolio-prod

# Rollback to specific revision
kubectl-homelab rollout undo deployment/portfolio -n portfolio-prod --to-revision=2
```

### Image-based Rollback

```bash
# Deploy previous version
kubectl-homelab set image deployment/portfolio \
  portfolio=registry.k8s.rommelporras.com/root/portfolio:v1.18.3 \
  -n portfolio-prod
```

### Emergency Fallback to VM

```bash
# 1. Restart VM
ssh reverse-mountain "cd /home/wawashi/portfolio && docker compose up -d"

# 2. Revert Cloudflare tunnel route to VM IP
#    Cloudflare dashboard → Tunnels → Public Hostname
#    Change: http://portfolio.portfolio-prod.svc:80
#    Back to: http://10.10.30.X:3000 (VM IP)
```

---

## Troubleshooting

### Pipeline fails at validate stage

```bash
# Check for linting errors locally
cd /home/wsl/personal/portfolio
bun run lint
bunx tsc --noEmit
```

### Pipeline fails at build stage

```bash
# Check runner logs
kubectl-homelab logs -n gitlab-runner -l app=gitlab-runner --tail=100

# Common issues:
# - Docker-in-Docker not working → check privileged: true in runner config
# - Out of memory → increase runner pod limits
# - bun install fails → check bun.lock is committed
```

### Pipeline fails at deploy stage

```bash
# Verify ServiceAccount token is valid
kubectl-homelab get secret gitlab-deploy-token -n portfolio-dev -o yaml

# Verify RBAC permissions
kubectl-homelab auth can-i update deployments -n portfolio-dev \
  --as=system:serviceaccount:portfolio-dev:gitlab-deploy

# Check CI/CD variables in GitLab
# Ensure KUBE_TOKEN is scoped to correct environment
```

### Pods not starting after deploy

```bash
# Check deployment status
kubectl-homelab describe deployment portfolio -n portfolio-dev

# Check pod events
kubectl-homelab get pods -n portfolio-dev
kubectl-homelab describe pod <pod-name> -n portfolio-dev
kubectl-homelab logs -n portfolio-dev -l app=portfolio

# Common issues:
# - ImagePullBackOff → registry auth issue, check imagePullSecrets
# - CrashLoopBackOff → check container logs, possibly nginx config issue
```

### Container registry auth issues

```bash
# Option A: Make project public (used for portfolio)
# GitLab → Project → Settings → General → Visibility → Public
# This allows anonymous pulls from the registry

# Option B: For private registries, create imagePullSecret:
kubectl-homelab create secret docker-registry gitlab-registry \
  --docker-server=registry.k8s.rommelporras.com \
  --docker-username=<gitlab-deploy-token-user> \
  --docker-password=<gitlab-deploy-token> \
  -n portfolio-dev

# Then add to deployment spec:
# spec:
#   template:
#     spec:
#       imagePullSecrets:
#       - name: gitlab-registry
```

---

## Final: Commit and Release

- [ ] Commit changes
  ```bash
  /commit
  ```

- [ ] Release v0.8.1
  ```bash
  /release v0.8.1
  ```

- [x] Move this file to completed folder ✅
