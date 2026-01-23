# Phase 4.7: Portfolio Migration

> **Status:** Planned
> **Target:** v0.8.1
> **Prerequisite:** Phase 4.6 complete (GitLab + Runner installed)
> **DevOps Topics:** CI/CD pipelines, container builds, K8s deployments, Docker multi-stage builds
> **CKA Topics:** Deployments, Services, RBAC (ServiceAccount for CI/CD)

> **Purpose:** First app deployment using GitLab CI/CD pipeline
> **Stack:** Static Next.js 16 + nginx (truly stateless)
> **Source:** GitLab (imported from GitHub)
>
> **Learning Goal:** Understand complete CI/CD flow from git push to production deployment

> **Access:**
> - **Public:** `www.rommelporras.com` (via Cloudflare Tunnel)
> - **Internal:** `portfolio.k8s.home.rommelporras.com` (home network / Tailscale)

---

## CI/CD Flow

This phase teaches you how to set up automated deployments:

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Portfolio CI/CD Pipeline                          │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│   1. TRIGGER                                                        │
│      Developer: git push origin main                                │
│                         │                                           │
│                         ▼                                           │
│   2. BUILD STAGE                                                    │
│      GitLab Runner spawns pod:                                      │
│      ┌────────────────────────────────────────┐                    │
│      │  docker:24-dind                         │                    │
│      │  ├── npm install                        │                    │
│      │  ├── next build --output export         │                    │
│      │  └── docker build -t portfolio:v1.2.3   │                    │
│      └────────────────────────────────────────┘                    │
│                         │                                           │
│                         ▼                                           │
│   3. PUSH STAGE                                                     │
│      Push to GitLab Container Registry:                             │
│      registry.k8s.home.rommelporras.com/portfolio:v1.2.3           │
│                         │                                           │
│                         ▼                                           │
│   4. DEPLOY STAGE                                                   │
│      GitLab Runner uses ServiceAccount to:                          │
│      kubectl set image deployment/portfolio portfolio=...:v1.2.3   │
│                         │                                           │
│                         ▼                                           │
│   5. RESULT                                                         │
│      K8s performs rolling update:                                   │
│      - Spins up new pods with new image                            │
│      - Routes traffic to new pods                                   │
│      - Terminates old pods                                          │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### Key Concepts This Phase Teaches

| Concept | What You'll Learn |
|---------|-------------------|
| **Docker multi-stage builds** | Build Next.js app, copy to nginx image |
| **GitLab Container Registry** | Store images in your own registry |
| **Kubernetes RBAC** | ServiceAccount with limited permissions |
| **Rolling deployments** | Zero-downtime updates |
| **Environment variables** | CI/CD variables for secrets |

---

## 4.7.1 Create Portfolio Namespace

- [ ] 4.7.1.1 Create namespace
  ```bash
  kubectl-homelab create namespace portfolio
  kubectl-homelab label namespace portfolio pod-security.kubernetes.io/enforce=baseline
  ```

---

## 4.7.2 Create GitLab CI/CD Pipeline

- [ ] 4.7.2.1 Create .gitlab-ci.yml in portfolio repo
  ```yaml
  # .gitlab-ci.yml
  stages:
    - build
    - deploy

  variables:
    IMAGE_TAG: $CI_REGISTRY_IMAGE:$CI_COMMIT_SHORT_SHA
    IMAGE_LATEST: $CI_REGISTRY_IMAGE:latest

  build:
    stage: build
    image: docker:24
    services:
      - docker:24-dind
    script:
      - docker login -u $CI_REGISTRY_USER -p $CI_REGISTRY_PASSWORD $CI_REGISTRY
      - docker build -t $IMAGE_TAG -t $IMAGE_LATEST .
      - docker push $IMAGE_TAG
      - docker push $IMAGE_LATEST
    only:
      - main

  deploy:
    stage: deploy
    image: bitnami/kubectl:latest
    script:
      - kubectl config set-cluster homelab --server=$KUBE_API_URL --insecure-skip-tls-verify=true
      - kubectl config set-credentials gitlab --token=$KUBE_TOKEN
      - kubectl config set-context homelab --cluster=homelab --user=gitlab
      - kubectl config use-context homelab
      - kubectl set image deployment/portfolio portfolio=$IMAGE_TAG -n portfolio
      - kubectl rollout status deployment/portfolio -n portfolio --timeout=120s
    only:
      - main
  ```

- [ ] 4.7.2.2 Create ServiceAccount for GitLab deployments
  ```bash
  kubectl-homelab apply -f manifests/gitlab/deploy-sa.yaml
  ```
  ```yaml
  # manifests/gitlab/deploy-sa.yaml
  apiVersion: v1
  kind: ServiceAccount
  metadata:
    name: gitlab-deploy
    namespace: portfolio
  ---
  apiVersion: rbac.authorization.k8s.io/v1
  kind: Role
  metadata:
    name: gitlab-deploy
    namespace: portfolio
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
    namespace: portfolio
  subjects:
  - kind: ServiceAccount
    name: gitlab-deploy
    namespace: portfolio
  roleRef:
    kind: Role
    name: gitlab-deploy
    apiGroup: rbac.authorization.k8s.io
  ---
  apiVersion: v1
  kind: Secret
  metadata:
    name: gitlab-deploy-token
    namespace: portfolio
    annotations:
      kubernetes.io/service-account.name: gitlab-deploy
  type: kubernetes.io/service-account-token
  ```

- [ ] 4.7.2.3 Get deploy token and add to GitLab CI/CD variables
  ```bash
  # Get token
  kubectl-homelab get secret gitlab-deploy-token -n portfolio \
    -o jsonpath='{.data.token}' | base64 -d

  # Add to GitLab:
  # Project → Settings → CI/CD → Variables
  # KUBE_TOKEN: <token from above>
  # KUBE_API_URL: https://10.10.30.10:6443
  ```

---

## 4.7.3 Create K8s Manifests

- [ ] 4.7.3.1 Create portfolio deployment
  ```bash
  kubectl-homelab apply -f manifests/portfolio/deployment.yaml
  ```
  ```yaml
  # manifests/portfolio/deployment.yaml
  apiVersion: apps/v1
  kind: Deployment
  metadata:
    name: portfolio
    namespace: portfolio
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
          image: registry.k8s.home.rommelporras.com/portfolio:latest
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
    namespace: portfolio
  spec:
    selector:
      app: portfolio
    ports:
    - port: 80
      targetPort: 80
  ```

- [ ] 4.7.3.2 Create HTTPRoute
  ```bash
  kubectl-homelab apply -f manifests/gateway/routes/portfolio.yaml
  ```
  ```yaml
  # manifests/gateway/routes/portfolio.yaml
  apiVersion: gateway.networking.k8s.io/v1
  kind: HTTPRoute
  metadata:
    name: portfolio
    namespace: portfolio
  spec:
    parentRefs:
    - name: homelab-gateway
      namespace: default
    hostnames:
    - "portfolio.k8s.home.rommelporras.com"
    rules:
    - matches:
      - path:
          type: PathPrefix
          value: /
      backendRefs:
      - name: portfolio
        port: 80
  ```

---

## 4.7.4 Configure Cloudflare Tunnel

- [ ] 4.7.4.1 Update tunnel route for www.rommelporras.com
  ```
  # Cloudflare Zero Trust → Tunnels → Public Hostname
  #
  # Public hostname: www.rommelporras.com
  # Service type: HTTP
  # URL: portfolio.portfolio.svc.cluster.local:80
  #
  # Note: CiliumNetworkPolicy in cloudflare namespace allows this traffic
  ```

- [ ] 4.7.4.2 Test public access
  ```bash
  # From external network (phone, or outside home):
  curl -I https://www.rommelporras.com
  # Should return HTTP 200
  ```

---

## 4.7.5 Test CI/CD Pipeline

- [ ] 4.7.5.1 Push a change to main branch
  ```bash
  cd /home/wsl/personal/portfolio
  git add .gitlab-ci.yml
  git commit -m "feat: add GitLab CI/CD pipeline"
  git push origin main
  ```

- [ ] 4.7.5.2 Watch pipeline in GitLab UI
  ```
  Project → Build → Pipelines
  ```

- [ ] 4.7.5.3 Verify deployment updated
  ```bash
  kubectl-homelab get pods -n portfolio
  kubectl-homelab describe deployment portfolio -n portfolio
  ```

---

## 4.7.6 Retire PVE VM

- [ ] 4.7.6.1 Run K8s portfolio alongside VM for 1 week

- [ ] 4.7.6.2 Stop Docker Compose on PVE VM
  ```bash
  ssh reverse-mountain "cd /home/wawashi/portfolio && docker compose down"
  ```

- [ ] 4.7.6.3 After 1 week stable, delete VM (or repurpose)

---

## 4.7.7 Documentation Updates

- [ ] 4.7.7.1 Update VERSIONS.md
  ```
  # Add to Applications section:
  | Portfolio | 1.x.x | Personal website (Next.js static) |

  # Add to Version History:
  | YYYY-MM-DD | Phase 4.7: Portfolio CI/CD migration |
  ```

- [ ] 4.7.7.2 Update docs/reference/CHANGELOG.md
  - Add Phase 4.7 section with milestone, decisions, lessons learned

---

## Verification Checklist

- [ ] Namespace `portfolio` exists with baseline PSS
- [ ] ServiceAccount `gitlab-deploy` has correct RBAC permissions
- [ ] Portfolio deployment running with 2 replicas
- [ ] HTTPRoute configured for portfolio.k8s.home.rommelporras.com
- [ ] DNS rewrite configured in AdGuard
- [ ] GitLab CI/CD pipeline passes all stages (build, deploy)
- [ ] Portfolio accessible internally via https://portfolio.k8s.home.rommelporras.com
- [ ] Portfolio accessible externally via https://rommelporras.com (Cloudflare Tunnel)
- [ ] VM Docker Compose stopped (after migration period)

---

## Rollback

If issues occur:

```bash
# 1. Quick rollback - restart VM
ssh reverse-mountain "cd /home/wawashi/portfolio && docker compose up -d"

# 2. Revert Cloudflare tunnel route to VM IP
#    Cloudflare dashboard → Tunnels → Public Hostname
#    Change: http://portfolio.portfolio.svc.cluster.local:80
#    Back to: http://10.10.30.X:3000 (VM IP)

# 3. Debug K8s deployment
kubectl-homelab logs -n portfolio -l app=portfolio
kubectl-homelab describe deployment portfolio -n portfolio

# 4. Roll back to previous image if needed
kubectl-homelab rollout undo deployment/portfolio -n portfolio
```

---

## Troubleshooting

### Pipeline fails at build stage

```bash
# Check runner logs
kubectl-homelab logs -n gitlab-runner -l app=gitlab-runner --tail=100

# Common issues:
# - Docker-in-Docker not working → check privileged: true in runner config
# - Out of memory → increase runner pod limits
# - npm install fails → check if registry.npmjs.org is accessible
```

### Pipeline fails at deploy stage (kubectl errors)

```bash
# Verify ServiceAccount token is valid
kubectl-homelab get secret gitlab-deploy-token -n portfolio -o yaml

# Verify RBAC permissions
kubectl-homelab auth can-i update deployments -n portfolio \
  --as=system:serviceaccount:portfolio:gitlab-deploy

# Check CI/CD variables in GitLab
# Project → Settings → CI/CD → Variables
# KUBE_TOKEN should match the service account token
```

### Pods not starting after deploy

```bash
# Check deployment status
kubectl-homelab describe deployment portfolio -n portfolio

# Check pod events
kubectl-homelab get pods -n portfolio
kubectl-homelab describe pod <pod-name> -n portfolio

# Common issues:
# - ImagePullBackOff → registry auth issue, check imagePullSecrets
# - CrashLoopBackOff → check container logs
```

### Container registry auth issues

```bash
# GitLab registry credentials are auto-injected by CI/CD
# For manual pull, create imagePullSecret:

kubectl-homelab create secret docker-registry gitlab-registry \
  --docker-server=registry.k8s.home.rommelporras.com \
  --docker-username=<gitlab-deploy-token-user> \
  --docker-password=<gitlab-deploy-token> \
  -n portfolio
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
