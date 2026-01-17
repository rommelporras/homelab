# Phase 4.7: Portfolio Migration

> **Status:** ⬜ Planned
> **Target:** v0.9.0
> **DevOps Topics:** CI/CD pipelines, container builds, K8s deployments
> **CKA Topics:** Deployments, Services, ConfigMaps

> **Purpose:** First app deployment using GitLab CI/CD pipeline
> **Stack:** Static Next.js 16 + nginx (truly stateless)
> **Source:** GitLab (imported from GitHub)

---

## CI/CD Flow

```
┌─────────────────────────────────────────────────────────────┐
│  git push → GitLab CI/CD                                    │
├─────────────────────────────────────────────────────────────┤
│  Stage 1: Build                                             │
│  ├── npm install                                            │
│  ├── next build (static export)                             │
│  └── docker build (nginx + /out)                            │
│                                                             │
│  Stage 2: Push                                              │
│  └── docker push registry.k8s.home.rommelporras.com/...     │
│                                                             │
│  Stage 3: Deploy                                            │
│  └── kubectl set image deployment/portfolio ...             │
└─────────────────────────────────────────────────────────────┘
```

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

- [ ] 4.7.4.1 Update tunnel route for rommelporras.com
  ```
  # Cloudflare Zero Trust → Tunnels → Public Hostname
  # rommelporras.com → http://portfolio.portfolio.svc.cluster.local:80
  ```

- [ ] 4.7.4.2 Test public access
  ```bash
  curl -I https://rommelporras.com
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

**Rollback:** Restart Docker Compose on VM, revert tunnel route
