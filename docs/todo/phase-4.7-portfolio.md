# Phase 4.7: Portfolio Migration

> **Status:** Planned
> **Target:** v0.8.1
> **Prerequisite:** Phase 4.6 complete (GitLab + Runner installed)
> **Design:** [docs/plans/2026-01-25-portfolio-cicd-design.md](../plans/2026-01-25-portfolio-cicd-design.md)
> **DevOps Topics:** CI/CD pipelines, trunk-based development, artifact promotion, container builds
> **CKA Topics:** Deployments, Services, RBAC (ServiceAccount for CI/CD), Namespaces

> **Purpose:** First app deployment using GitLab CI/CD with multi-environment promotion
> **Stack:** Next.js 16 + Bun + nginx (static export)
> **Source:** GitLab (imported from GitHub, mirrored back)
>
> **Learning Goals:**
> - Trunk-based development with artifact promotion
> - Multi-environment deployment (dev → staging → prod)
> - Manual approval gates (corporate pattern)
> - Same artifact promoted through environments

> **Environments:**
> | Environment | Internal URL | Public URL |
> |-------------|--------------|------------|
> | Dev | `portfolio.dev.k8s.home.rommelporras.com` | - |
> | Staging | `portfolio.staging.k8s.home.rommelporras.com` | `beta.rommelporras.com` |
> | Prod | `portfolio.prod.k8s.home.rommelporras.com` | `www.rommelporras.com` |

---

## CI/CD Flow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    Portfolio CI/CD Pipeline (Trunk-Based)                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   feature/* ──► develop ──────────────────────────────► main                │
│                    │                                       │                │
│              [Build once]                           [No rebuild]            │
│                    │                                       │                │
│                    ▼                                       ▼                │
│               deploy:dev                             deploy:prod            │
│                 [auto]                            [auto on tag]             │
│                    │                                                        │
│                    ▼                                                        │
│            ⏸️ deploy:staging                                                │
│                [manual]                                                     │
│                    │                                                        │
│                    ▼                                                        │
│             [Test on staging]                                               │
│                    │                                                        │
│                    ▼                                                        │
│            Create MR: develop → main                                        │
│                    │                                                        │
│                    ▼                                                        │
│               Tag: v1.x.x                                                   │
│                    │                                                        │
│                    ▼                                                        │
│            Merge MR (deploys to prod)                                       │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Key Concepts This Phase Teaches

| Concept | What You'll Learn |
|---------|-------------------|
| **Trunk-based development** | Feature branches merge to develop, then promote to main |
| **Artifact promotion** | Same image deployed through dev → staging → prod |
| **Manual approval gates** | Corporate pattern for production readiness |
| **Docker multi-stage builds** | Bun build + nginx serve |
| **GitLab Container Registry** | Store images in your own registry |
| **Environment-scoped secrets** | Different KUBE_TOKEN per environment |
| **Kubernetes RBAC** | ServiceAccount with limited permissions per namespace |
| **Rolling deployments** | Zero-downtime updates |

---

## 4.7.1 GitLab Setup

- [ ] 4.7.1.1 Import portfolio from GitHub
  ```
  GitLab → New Project → Import project → GitHub
  Select: rommelporras/portfolio
  ```

- [ ] 4.7.1.2 Enable Container Registry
  ```
  Project → Settings → General → Visibility → Container Registry: Enabled
  ```

- [ ] 4.7.1.3 Configure GitHub push mirroring (main branch only)
  ```
  Project → Settings → Repository → Mirroring repositories
  Git repository URL: https://github.com/rommelporras/portfolio.git
  Mirror direction: Push
  Only mirror protected branches: Yes
  ```

---

## 4.7.2 Create Kubernetes Namespaces

- [ ] 4.7.2.1 Create three namespaces
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

- [ ] 4.7.3.1 Create ServiceAccount manifest
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
    verbs: ["get", "patch", "update"]
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

- [ ] 4.7.3.2 Apply RBAC to all namespaces
  ```bash
  kubectl-homelab apply -f manifests/portfolio/rbac.yaml -n portfolio-dev
  kubectl-homelab apply -f manifests/portfolio/rbac.yaml -n portfolio-staging
  kubectl-homelab apply -f manifests/portfolio/rbac.yaml -n portfolio-prod
  ```

- [ ] 4.7.3.3 Get tokens and add to GitLab CI/CD variables
  ```bash
  # Get tokens
  echo "Dev token:"
  kubectl-homelab get secret gitlab-deploy-token -n portfolio-dev \
    -o jsonpath='{.data.token}' | base64 -d && echo

  echo "Staging token:"
  kubectl-homelab get secret gitlab-deploy-token -n portfolio-staging \
    -o jsonpath='{.data.token}' | base64 -d && echo

  echo "Prod token:"
  kubectl-homelab get secret gitlab-deploy-token -n portfolio-prod \
    -o jsonpath='{.data.token}' | base64 -d && echo
  ```

  ```
  # Add to GitLab:
  # Project → Settings → CI/CD → Variables

  | Variable | Scope | Value |
  |----------|-------|-------|
  | KUBE_API_URL | All | https://10.10.30.10:6443 |
  | KUBE_TOKEN | dev | Token from portfolio-dev/gitlab-deploy-token |
  | KUBE_TOKEN | staging | Token from portfolio-staging/gitlab-deploy-token |
  | KUBE_TOKEN | production | Token from portfolio-prod/gitlab-deploy-token |
  ```

---

## 4.7.4 Create K8s Deployments + Services

- [ ] 4.7.4.1 Create deployment manifest (applies to all environments)
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
          image: registry.k8s.home.rommelporras.com/root/portfolio:latest
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

- [ ] 4.7.4.2 Apply deployments to all namespaces
  ```bash
  kubectl-homelab apply -f manifests/portfolio/deployment.yaml -n portfolio-dev
  kubectl-homelab apply -f manifests/portfolio/deployment.yaml -n portfolio-staging
  kubectl-homelab apply -f manifests/portfolio/deployment.yaml -n portfolio-prod
  ```

---

## 4.7.5 Create HTTPRoutes

- [ ] 4.7.5.1 Create HTTPRoute for dev
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
    - "portfolio.dev.k8s.home.rommelporras.com"
    rules:
    - matches:
      - path:
          type: PathPrefix
          value: /
      backendRefs:
      - name: portfolio
        port: 80
  ```

- [ ] 4.7.5.2 Create HTTPRoute for staging
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
    - "portfolio.staging.k8s.home.rommelporras.com"
    rules:
    - matches:
      - path:
          type: PathPrefix
          value: /
      backendRefs:
      - name: portfolio
        port: 80
  ```

- [ ] 4.7.5.3 Create HTTPRoute for prod
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
    - "portfolio.prod.k8s.home.rommelporras.com"
    rules:
    - matches:
      - path:
          type: PathPrefix
          value: /
      backendRefs:
      - name: portfolio
        port: 80
  ```

- [ ] 4.7.5.4 Apply all HTTPRoutes
  ```bash
  kubectl-homelab apply -f manifests/gateway/routes/portfolio-dev.yaml
  kubectl-homelab apply -f manifests/gateway/routes/portfolio-staging.yaml
  kubectl-homelab apply -f manifests/gateway/routes/portfolio-prod.yaml
  ```

---

## 4.7.6 Configure DNS (AdGuard)

- [ ] 4.7.6.1 Add DNS rewrites in AdGuard Home
  ```
  AdGuard Home → Filters → DNS rewrites

  Add:
  portfolio.dev.k8s.home.rommelporras.com → 10.10.30.10
  portfolio.staging.k8s.home.rommelporras.com → 10.10.30.10
  portfolio.prod.k8s.home.rommelporras.com → 10.10.30.10
  ```

- [ ] 4.7.6.2 Test internal DNS resolution
  ```bash
  nslookup portfolio.dev.k8s.home.rommelporras.com
  nslookup portfolio.staging.k8s.home.rommelporras.com
  nslookup portfolio.prod.k8s.home.rommelporras.com
  ```

---

## 4.7.7 Configure Cloudflare Tunnel

- [ ] 4.7.7.1 Add route for beta.rommelporras.com (staging)
  ```
  Cloudflare Zero Trust → Tunnels → homelab → Public Hostname

  Add:
  Subdomain: beta
  Domain: rommelporras.com
  Service type: HTTP
  URL: portfolio.portfolio-staging.svc:80
  ```

- [ ] 4.7.7.2 Update route for www.rommelporras.com (prod)
  ```
  Subdomain: www
  Domain: rommelporras.com
  Service type: HTTP
  URL: portfolio.portfolio-prod.svc:80
  ```

---

## 4.7.8 Update Portfolio Repository

- [ ] 4.7.8.1 Update Dockerfile for Bun
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

- [ ] 4.7.8.2 Add type-check script to package.json
  ```json
  {
    "scripts": {
      "type-check": "tsc --noEmit"
    }
  }
  ```

- [ ] 4.7.8.3 Add accessibility testing dependency
  ```bash
  cd /home/wsl/personal/portfolio
  bun add -d @axe-core/playwright
  ```

- [ ] 4.7.8.4 Create accessibility test file
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

- [ ] 4.7.8.5 Create .gitlab-ci.yml
  See [docs/plans/2026-01-25-portfolio-cicd-design.md](../plans/2026-01-25-portfolio-cicd-design.md#gitlab-cicd-configuration) for full configuration.

---

## 4.7.9 Test Pipeline

- [ ] 4.7.9.1 Create develop branch and push
  ```bash
  cd /home/wsl/personal/portfolio
  git checkout -b develop
  git add .
  git commit -m "feat: add GitLab CI/CD pipeline with Bun"
  git push -u origin develop
  ```

- [ ] 4.7.9.2 Watch pipeline in GitLab UI
  ```
  Project → Build → Pipelines

  Expected stages:
  ✅ validate (lint, type-check, security-audit)
  ✅ test (unit, e2e, accessibility)
  ✅ build (Docker image)
  ✅ deploy:dev (automatic)
  ⏸️ deploy:staging (manual trigger)
  ```

- [ ] 4.7.9.3 Verify dev deployment
  ```bash
  kubectl-homelab get pods -n portfolio-dev
  curl -I https://portfolio.dev.k8s.home.rommelporras.com
  ```

- [ ] 4.7.9.4 Manually promote to staging
  ```
  GitLab → Pipelines → Click "Promote to Staging" (play button)
  ```

- [ ] 4.7.9.5 Verify staging deployment
  ```bash
  kubectl-homelab get pods -n portfolio-staging
  curl -I https://portfolio.staging.k8s.home.rommelporras.com
  curl -I https://beta.rommelporras.com
  ```

- [ ] 4.7.9.6 Create production release
  ```bash
  git checkout develop
  git pull origin develop
  git tag v1.19.0
  git push origin v1.19.0

  # Create MR: develop → main in GitLab
  # Merge MR
  ```

- [ ] 4.7.9.7 Verify production deployment
  ```bash
  kubectl-homelab get pods -n portfolio-prod
  curl -I https://portfolio.prod.k8s.home.rommelporras.com
  curl -I https://www.rommelporras.com
  ```

---

## 4.7.10 Retire PVE VM

- [ ] 4.7.10.1 Run K8s portfolio alongside VM for 1 week

- [ ] 4.7.10.2 Stop Docker Compose on PVE VM
  ```bash
  ssh reverse-mountain "cd /home/wawashi/portfolio && docker compose down"
  ```

- [ ] 4.7.10.3 After 1 week stable, delete VM (or repurpose)

---

## 4.7.11 Documentation Updates

- [ ] 4.7.11.1 Update VERSIONS.md
  ```
  # Add to Applications section:
  | Portfolio | 1.x.x | Personal website (Next.js static) |

  # Add to Version History:
  | YYYY-MM-DD | Phase 4.7: Portfolio CI/CD migration |
  ```

- [ ] 4.7.11.2 Update docs/reference/CHANGELOG.md
  - Add Phase 4.7 section with milestone, decisions, lessons learned

---

## Verification Checklist

- [ ] GitLab repository with Container Registry enabled
- [ ] GitHub push mirror working
- [ ] Three namespaces created (portfolio-dev, portfolio-staging, portfolio-prod)
- [ ] RBAC configured with environment-scoped tokens
- [ ] Deployments running in all three namespaces
- [ ] HTTPRoutes configured for all environments
- [ ] DNS rewrites configured in AdGuard (3 hostnames)
- [ ] Pipeline passes all stages on develop branch
- [ ] Auto-deploy to dev works
- [ ] Manual staging promotion works
- [ ] Tag-based production deploy works
- [ ] All internal URLs accessible:
  - [ ] portfolio.dev.k8s.home.rommelporras.com
  - [ ] portfolio.staging.k8s.home.rommelporras.com
  - [ ] portfolio.prod.k8s.home.rommelporras.com
- [ ] Cloudflare Tunnel routes working:
  - [ ] beta.rommelporras.com → staging
  - [ ] www.rommelporras.com → prod
- [ ] VM Docker Compose stopped (after migration period)

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
  portfolio=registry.k8s.home.rommelporras.com/root/portfolio:v1.18.3 \
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
# GitLab registry credentials are auto-injected by CI/CD
# For manual pull, create imagePullSecret:

kubectl-homelab create secret docker-registry gitlab-registry \
  --docker-server=registry.k8s.home.rommelporras.com \
  --docker-username=<gitlab-deploy-token-user> \
  --docker-password=<gitlab-deploy-token> \
  -n portfolio-dev
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

- [ ] Move this file to completed folder
  ```bash
  mv docs/todo/phase-4.7-portfolio.md docs/todo/completed/
  ```
