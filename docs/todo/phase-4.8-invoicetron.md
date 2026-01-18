# Phase 4.8: Invoicetron Migration

> **Status:** ⬜ Planned
> **Target:** v0.9.0
> **DevOps Topics:** StatefulSets, database migrations, secrets management
> **CKA Topics:** StatefulSets, PVCs, Jobs, Secrets

> **Purpose:** Migrate stateful application with database
> **Stack:** Next.js 16 + Bun + PostgreSQL 18 + Prisma 7
> **Source:** GitLab (imported from GitHub)

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                  invoicetron namespace                       │
├─────────────────────────────────────────────────────────────┤
│  ┌─────────────────────┐    ┌─────────────────────────────┐│
│  │    PostgreSQL 18    │    │     Invoicetron App         ││
│  │    StatefulSet      │◄───│     Deployment (2 replicas) ││
│  │    (10Gi Longhorn)  │    │     Next.js + Bun           ││
│  └─────────────────────┘    └─────────────────────────────┘│
│            │                              │                 │
│            │                              │                 │
│  ┌─────────────────────┐    ┌─────────────────────────────┐│
│  │   Prisma Migrate    │    │         Secrets             ││
│  │   Job (on deploy)   │    │  - postgres-password        ││
│  └─────────────────────┘    │  - better-auth-secret       ││
│                             └─────────────────────────────┘│
└─────────────────────────────────────────────────────────────┘
```

---

## 4.8.1 Create Invoicetron Namespace

- [ ] 4.8.1.1 Create namespace
  ```bash
  kubectl-homelab create namespace invoicetron
  kubectl-homelab label namespace invoicetron pod-security.kubernetes.io/enforce=baseline
  ```

---

## 4.8.2 Create Secrets

- [ ] 4.8.2.1 Add credentials to 1Password Kubernetes vault
  ```
  # Create items:
  # - Invoicetron/postgres-password
  # - Invoicetron/better-auth-secret (64 chars: openssl rand -base64 32)
  ```

- [ ] 4.8.2.2 Create K8s secrets
  ```bash
  kubectl-homelab create secret generic invoicetron-secrets \
    --from-literal=postgres-password="$(op read 'op://Kubernetes/Invoicetron/postgres-password')" \
    --from-literal=better-auth-secret="$(op read 'op://Kubernetes/Invoicetron/better-auth-secret')" \
    -n invoicetron
  ```

---

## 4.8.3 Deploy PostgreSQL

- [ ] 4.8.3.1 Create PostgreSQL StatefulSet
  ```bash
  kubectl-homelab apply -f manifests/invoicetron/postgresql.yaml
  ```
  ```yaml
  # manifests/invoicetron/postgresql.yaml
  apiVersion: apps/v1
  kind: StatefulSet
  metadata:
    name: postgresql
    namespace: invoicetron
  spec:
    serviceName: postgresql
    replicas: 1
    selector:
      matchLabels:
        app: postgresql
    template:
      metadata:
        labels:
          app: postgresql
      spec:
        containers:
        - name: postgresql
          image: postgres:18-alpine
          ports:
          - containerPort: 5432
          env:
          - name: POSTGRES_USER
            value: invoicetron
          - name: POSTGRES_PASSWORD
            valueFrom:
              secretKeyRef:
                name: invoicetron-secrets
                key: postgres-password
          - name: POSTGRES_DB
            value: invoicetron
          volumeMounts:
          - name: data
            mountPath: /var/lib/postgresql/data
          resources:
            requests:
              memory: "512Mi"
              cpu: "250m"
            limits:
              memory: "1Gi"
              cpu: "1000m"
          livenessProbe:
            exec:
              command: ["pg_isready", "-U", "invoicetron"]
            initialDelaySeconds: 30
            periodSeconds: 10
          readinessProbe:
            exec:
              command: ["pg_isready", "-U", "invoicetron"]
            initialDelaySeconds: 5
            periodSeconds: 5
    volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: longhorn
        resources:
          requests:
            storage: 10Gi
  ---
  apiVersion: v1
  kind: Service
  metadata:
    name: postgresql
    namespace: invoicetron
  spec:
    selector:
      app: postgresql
    ports:
    - port: 5432
      targetPort: 5432
    clusterIP: None  # Headless for StatefulSet
  ```

- [ ] 4.8.3.2 Wait for PostgreSQL to be ready
  ```bash
  kubectl-homelab get pods -n invoicetron -w
  kubectl-homelab logs -n invoicetron postgresql-0
  ```

---

## 4.8.4 Create GitLab CI/CD Pipeline

- [ ] 4.8.4.1 Create .gitlab-ci.yml in invoicetron repo
  ```yaml
  # .gitlab-ci.yml
  stages:
    - test
    - build
    - deploy

  variables:
    IMAGE_TAG: $CI_REGISTRY_IMAGE:$CI_COMMIT_SHORT_SHA
    IMAGE_LATEST: $CI_REGISTRY_IMAGE:latest

  test:
    stage: test
    image: oven/bun:1
    services:
      - postgres:18-alpine
    variables:
      POSTGRES_USER: test
      POSTGRES_PASSWORD: test
      POSTGRES_DB: test
      DATABASE_URL: postgresql://test:test@postgres:5432/test
    script:
      - cd web
      - bun install
      - bunx prisma generate
      - bunx prisma migrate deploy
      - bun test
    only:
      - main
      - merge_requests

  build:
    stage: build
    image: docker:24
    services:
      - docker:24-dind
    script:
      - cd web
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
      # Run migrations as a Job
      - |
        kubectl delete job prisma-migrate -n invoicetron --ignore-not-found
        kubectl apply -f - <<EOF
        apiVersion: batch/v1
        kind: Job
        metadata:
          name: prisma-migrate
          namespace: invoicetron
        spec:
          template:
            spec:
              containers:
              - name: migrate
                image: $IMAGE_TAG
                command: ["bunx", "prisma", "migrate", "deploy"]
                env:
                - name: DATABASE_URL
                  value: postgresql://invoicetron:\$(POSTGRES_PASSWORD)@postgresql:5432/invoicetron
                envFrom:
                - secretRef:
                    name: invoicetron-secrets
              restartPolicy: Never
          backoffLimit: 3
        EOF
      - kubectl wait --for=condition=complete job/prisma-migrate -n invoicetron --timeout=120s
      # Update deployment
      - kubectl set image deployment/invoicetron invoicetron=$IMAGE_TAG -n invoicetron
      - kubectl rollout status deployment/invoicetron -n invoicetron --timeout=180s
    only:
      - main
  ```

- [ ] 4.8.4.2 Create ServiceAccount for deployments (similar to portfolio)

- [ ] 4.8.4.3 Add CI/CD variables to GitLab project

---

## 4.8.5 Create K8s Deployment

- [ ] 4.8.5.1 Create invoicetron deployment
  ```bash
  kubectl-homelab apply -f manifests/invoicetron/deployment.yaml
  ```
  ```yaml
  # manifests/invoicetron/deployment.yaml
  apiVersion: apps/v1
  kind: Deployment
  metadata:
    name: invoicetron
    namespace: invoicetron
  spec:
    replicas: 2
    selector:
      matchLabels:
        app: invoicetron
    template:
      metadata:
        labels:
          app: invoicetron
      spec:
        containers:
        - name: invoicetron
          image: registry.k8s.home.rommelporras.com/invoicetron:latest
          ports:
          - containerPort: 3000
          env:
          - name: DATABASE_URL
            value: postgresql://invoicetron:$(POSTGRES_PASSWORD)@postgresql:5432/invoicetron
          - name: BETTER_AUTH_SECRET
            valueFrom:
              secretKeyRef:
                name: invoicetron-secrets
                key: better-auth-secret
          - name: NEXT_PUBLIC_APP_URL
            value: https://invoicetron.k8s.home.rommelporras.com
          envFrom:
          - secretRef:
              name: invoicetron-secrets
          resources:
            requests:
              memory: "512Mi"
              cpu: "250m"
            limits:
              memory: "2Gi"
              cpu: "2000m"
          livenessProbe:
            httpGet:
              path: /api/health
              port: 3000
            initialDelaySeconds: 30
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /api/health
              port: 3000
            initialDelaySeconds: 10
            periodSeconds: 5
  ---
  apiVersion: v1
  kind: Service
  metadata:
    name: invoicetron
    namespace: invoicetron
  spec:
    selector:
      app: invoicetron
    ports:
    - port: 3000
      targetPort: 3000
  ```

---

## 4.8.6 Configure Access

- [ ] 4.8.6.1 Create HTTPRoute (internal)
  ```bash
  kubectl-homelab apply -f manifests/gateway/routes/invoicetron.yaml
  ```

- [ ] 4.8.6.2 Configure Cloudflare Tunnel (external)
  ```
  # Cloudflare Zero Trust → Tunnels → Public Hostname
  # invoicetron.yourdomain.com → http://invoicetron.invoicetron.svc.cluster.local:3000
  ```

---

## 4.8.7 Migrate Data (if needed)

- [ ] 4.8.7.1 Export data from existing PostgreSQL
  ```bash
  # On Ubuntu VM
  docker exec invoicetron-db pg_dump -U invoicetron invoicetron > backup.sql
  ```

- [ ] 4.8.7.2 Import to K8s PostgreSQL
  ```bash
  # Copy to pod and restore
  kubectl-homelab cp backup.sql invoicetron/postgresql-0:/tmp/
  kubectl-homelab exec -n invoicetron postgresql-0 -- \
    psql -U invoicetron -d invoicetron -f /tmp/backup.sql
  ```

---

## 4.8.8 Retire Ubuntu VM

- [ ] 4.8.8.1 Run K8s alongside VM for 1 week

- [ ] 4.8.8.2 Stop Docker Compose on Ubuntu VM

- [ ] 4.8.8.3 After 1 week stable, delete/repurpose VM

**Rollback:** Restart Docker Compose on VM, revert tunnel route, restore database backup

---

## Final: Documentation Updates

- [ ] Update VERSIONS.md
  - Add Invoicetron and PostgreSQL components
  - Add version history entry

- [ ] Update docs/reference/CHANGELOG.md
  - Add Phase 4.8 section with milestone, decisions, lessons learned

- [ ] Move this file to completed folder
  ```bash
  mv docs/todo/phase-4.8-invoicetron.md docs/todo/completed/
  ```
