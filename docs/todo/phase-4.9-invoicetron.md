# Phase 4.9: Invoicetron Migration

> **Status:** Planned
> **Target:** v0.13.0
> **Prerequisite:** Phase 4.8 complete (AdGuard Client IP), Phase 4.7 patterns learned
> **DevOps Topics:** StatefulSets, database migrations, secrets management, Prisma ORM
> **CKA Topics:** StatefulSets, PVCs, Jobs, Secrets, environment variables

> **Purpose:** Migrate stateful application with database (more complex than Portfolio)
> **Stack:** Next.js 16 + Bun + PostgreSQL 18 + Prisma 7
> **Source:** GitLab (imported from GitHub)
>
> **Learning Goal:** StatefulSet management, database migrations in CI/CD, handling state

> **Access:**
> - **Public:** `invoicetron.rommelporras.com` (via Cloudflare Tunnel)
> - **Internal:** `invoicetron.k8s.home.rommelporras.com` (home network / Tailscale)

---

## Stateful vs Stateless Applications

This phase introduces **stateful** applications. Understand the difference:

| Aspect | Stateless (Portfolio) | Stateful (Invoicetron) |
|--------|----------------------|------------------------|
| Data storage | None (static files) | PostgreSQL database |
| Pod identity | Interchangeable | Stable network identity |
| Scaling | Add replicas freely | Requires careful planning |
| Migrations | Not needed | Schema migrations required |
| Backup | Not needed | Critical for data safety |

### Why StatefulSet for PostgreSQL?

| Feature | Deployment | StatefulSet |
|---------|------------|-------------|
| Pod names | Random (portfolio-xyz) | Stable (postgresql-0) |
| Storage | Shared or recreated | Persistent per pod |
| Network identity | Via Service only | Stable hostname |
| Startup order | Parallel | Sequential (0, 1, 2...) |

**PostgreSQL needs StatefulSet because:**
- Data must persist across restarts
- Pod-0 always gets the same PVC
- Headless Service provides stable DNS: `postgresql-0.postgresql`

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                      invoicetron namespace                           │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  ┌─────────────────────┐         ┌─────────────────────────────┐   │
│  │   PostgreSQL 18     │         │     Invoicetron App         │   │
│  │   StatefulSet       │◄────────│     Deployment (2 replicas) │   │
│  │   (10Gi Longhorn)   │  SQL    │     Next.js + Bun           │   │
│  │                     │         │                             │   │
│  │  postgresql-0       │         │  Uses Prisma ORM            │   │
│  └─────────────────────┘         └─────────────────────────────┘   │
│            ▲                                  ▲                     │
│            │                                  │                     │
│  ┌─────────┴─────────┐         ┌─────────────┴───────────────┐     │
│  │  Headless Service │         │         HTTPRoute           │     │
│  │  postgresql:5432  │         │  invoicetron.k8s.home...    │     │
│  └───────────────────┘         └─────────────────────────────┘     │
│                                                                     │
│  On each deploy:                                                    │
│  ┌─────────────────────┐    ┌─────────────────────────────┐        │
│  │   Prisma Migrate    │    │         Secrets             │        │
│  │   Job (one-shot)    │    │  - postgres-password        │        │
│  │   runs migrations   │    │  - better-auth-secret       │        │
│  └─────────────────────┘    └─────────────────────────────┘        │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 4.9.1 Create Invoicetron Namespace

- [ ] 4.9.1.1 Create namespace
  ```bash
  kubectl-homelab create namespace invoicetron
  kubectl-homelab label namespace invoicetron pod-security.kubernetes.io/enforce=baseline
  ```

---

## 4.9.2 Create Secrets

- [ ] 4.9.2.1 Add credentials to 1Password Kubernetes vault
  ```
  # Create items:
  # - Invoicetron/postgres-password
  # - Invoicetron/better-auth-secret (64 chars: openssl rand -base64 32)
  ```

- [ ] 4.9.2.2 Create K8s secrets
  ```bash
  kubectl-homelab create secret generic invoicetron-secrets \
    --from-literal=postgres-password="$(op read 'op://Kubernetes/Invoicetron/postgres-password')" \
    --from-literal=better-auth-secret="$(op read 'op://Kubernetes/Invoicetron/better-auth-secret')" \
    -n invoicetron
  ```

---

## 4.9.3 Deploy PostgreSQL

- [ ] 4.9.3.1 Create PostgreSQL StatefulSet
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

- [ ] 4.9.3.2 Wait for PostgreSQL to be ready
  ```bash
  kubectl-homelab get pods -n invoicetron -w
  kubectl-homelab logs -n invoicetron postgresql-0
  ```

---

## 4.9.4 Create GitLab CI/CD Pipeline

- [ ] 4.9.4.1 Create .gitlab-ci.yml in invoicetron repo
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

- [ ] 4.9.4.2 Create ServiceAccount for deployments (similar to portfolio)

- [ ] 4.9.4.3 Add CI/CD variables to GitLab project

---

## 4.9.5 Create K8s Deployment

- [ ] 4.9.5.1 Create invoicetron deployment
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

## 4.9.6 Configure Access

- [ ] 4.9.6.1 Create HTTPRoute (internal)
  ```bash
  kubectl-homelab apply -f manifests/gateway/routes/invoicetron.yaml
  ```

- [ ] 4.9.6.2 Configure Cloudflare Tunnel (external)
  ```
  # Cloudflare Zero Trust → Tunnels → Public Hostname
  #
  # Public hostname: invoicetron.rommelporras.com
  # Service type: HTTP
  # URL: invoicetron.invoicetron.svc.cluster.local:3000
  #
  # Note: CiliumNetworkPolicy in cloudflare namespace allows this traffic
  ```

---

## 4.9.7 Migrate Data (if needed)

- [ ] 4.9.7.1 Export data from existing PostgreSQL
  ```bash
  # On Ubuntu VM
  docker exec invoicetron-db pg_dump -U invoicetron invoicetron > backup.sql
  ```

- [ ] 4.9.7.2 Import to K8s PostgreSQL
  ```bash
  # Copy to pod and restore
  kubectl-homelab cp backup.sql invoicetron/postgresql-0:/tmp/
  kubectl-homelab exec -n invoicetron postgresql-0 -- \
    psql -U invoicetron -d invoicetron -f /tmp/backup.sql
  ```

---

## 4.9.8 Retire Ubuntu VM

- [ ] 4.9.8.1 Run K8s alongside VM for 1 week

- [ ] 4.9.8.2 Stop Docker Compose on Ubuntu VM

- [ ] 4.9.8.3 After 1 week stable, delete/repurpose VM

---

## 4.9.9 Remove Temporary DMZ NetworkPolicy Rule

> **IMPORTANT:** After both Portfolio (Phase 4.7) and Invoicetron (Phase 4.9) are running
> in K8s, the temporary DMZ rule in the cloudflared NetworkPolicy must be removed.

- [ ] 4.9.9.1 Verify both services are running in K8s
  ```bash
  kubectl-homelab get pods -n portfolio
  kubectl-homelab get pods -n invoicetron
  # Both should show Running pods
  ```

- [ ] 4.9.9.2 Remove temporary DMZ rule from NetworkPolicy
  ```bash
  # Edit manifests/cloudflare/networkpolicy.yaml
  # Remove the entire "TEMPORARY: DMZ VM" section:
  #
  #   - toCIDR:
  #     - 10.10.50.10/32
  #     toPorts:
  #     - ports:
  #       - port: "3000"
  #         protocol: TCP
  #       - port: "3001"
  #         protocol: TCP
  ```

- [ ] 4.9.9.3 Apply updated NetworkPolicy
  ```bash
  kubectl-homelab apply -f manifests/cloudflare/networkpolicy.yaml
  ```

- [ ] 4.9.9.4 Verify tunnel still works (uses K8s services now)
  ```bash
  curl -I https://www.rommelporras.com
  curl -I https://invoicetron.rommelporras.com
  # Both should return HTTP 200
  ```

- [ ] 4.9.9.5 Run security validation script
  ```bash
  ./scripts/test-cloudflare-networkpolicy.sh
  # DMZ tests will now show BLOCKED (expected after migration)
  ```

---

## 4.9.10 Documentation Updates

- [ ] 4.9.10.1 Update VERSIONS.md
  ```
  # Add to Applications section:
  | Invoicetron | 1.x.x | Invoice management (Next.js + Bun) |
  | PostgreSQL (Invoicetron) | 18 | Invoicetron database |

  # Add to Version History:
  | YYYY-MM-DD | Phase 4.9: Invoicetron stateful migration |
  ```

- [ ] 4.9.10.2 Update docs/context/Secrets.md
  ```
  # Add 1Password items:
  | Invoicetron | postgres-password | Database credentials |
  | Invoicetron | better-auth-secret | Auth session secret |
  ```

- [ ] 4.9.10.3 Update docs/reference/CHANGELOG.md
  - Add Phase 4.9 section with milestone, decisions, lessons learned

---

## Verification Checklist

- [ ] Namespace `invoicetron` exists with baseline PSS
- [ ] PostgreSQL StatefulSet running (postgresql-0 pod ready)
- [ ] PostgreSQL PVC bound and healthy in Longhorn
- [ ] Invoicetron deployment running with 2 replicas
- [ ] Prisma migration Job completed successfully
- [ ] Secrets created (invoicetron-secrets)
- [ ] HTTPRoute configured for invoicetron.k8s.home.rommelporras.com
- [ ] DNS rewrite configured in AdGuard
- [ ] GitLab CI/CD pipeline passes all stages
- [ ] Can login to Invoicetron web UI
- [ ] Data migrated from VM (if applicable)
- [ ] External access via Cloudflare Tunnel works

---

## Rollback

If issues occur:

```bash
# 1. Quick rollback - restart VM
ssh ubuntu-vm "cd /home/wawashi/invoicetron && docker compose up -d"

# 2. Revert Cloudflare tunnel route
#    Dashboard → Tunnels → Public Hostname
#    Change back to VM IP

# 3. If only app is broken (DB is fine)
kubectl-homelab rollout undo deployment/invoicetron -n invoicetron

# 4. If migration broke the schema
#    Restore from backup (see section 4.8.7.1)
kubectl-homelab cp backup.sql invoicetron/postgresql-0:/tmp/
kubectl-homelab exec -n invoicetron postgresql-0 -- \
  psql -U invoicetron -d invoicetron -f /tmp/backup.sql

# 5. Full cleanup and restart
kubectl-homelab delete deployment invoicetron -n invoicetron
kubectl-homelab delete statefulset postgresql -n invoicetron
kubectl-homelab delete pvc --all -n invoicetron
# Then restart from 4.8.3
```

---

## Troubleshooting

### PostgreSQL pod stuck in Pending

```bash
# Check PVC status
kubectl-homelab get pvc -n invoicetron

# Check Longhorn for storage issues
kubectl-homelab -n longhorn-system get volumes

# Common issues:
# - Insufficient storage → check Longhorn capacity
# - Scheduling issues → check node resources
```

### Prisma migration Job fails

```bash
# Check Job status
kubectl-homelab get jobs -n invoicetron
kubectl-homelab describe job prisma-migrate -n invoicetron

# Check migration logs
kubectl-homelab logs -n invoicetron job/prisma-migrate

# Common issues:
# - DATABASE_URL wrong → check secret values
# - Schema conflicts → check Prisma migration history
# - PostgreSQL not ready → wait and retry
```

### App can't connect to PostgreSQL

```bash
# Verify PostgreSQL is running
kubectl-homelab get pods -n invoicetron | grep postgresql

# Test connectivity from app pod
kubectl-homelab exec -n invoicetron -it deployment/invoicetron -- \
  nc -zv postgresql 5432

# Check DATABASE_URL is correct
kubectl-homelab exec -n invoicetron -it deployment/invoicetron -- \
  printenv DATABASE_URL
```

### Authentication not working (better-auth)

```bash
# Check BETTER_AUTH_SECRET is set
kubectl-homelab exec -n invoicetron -it deployment/invoicetron -- \
  printenv BETTER_AUTH_SECRET

# Verify it matches what's in 1Password
op read "op://Kubernetes/Invoicetron/better-auth-secret"

# Check NEXT_PUBLIC_APP_URL matches your actual URL
```

---

## Final: Commit and Release

- [ ] Commit changes
  ```bash
  /commit
  ```

- [ ] Release v0.11.0
  ```bash
  /release v0.11.0
  ```

- [ ] Move this file to completed folder
  ```bash
  mv docs/todo/phase-4.9-invoicetron.md docs/todo/completed/
  ```
