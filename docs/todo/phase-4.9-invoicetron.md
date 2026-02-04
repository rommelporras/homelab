# Phase 4.9: Invoicetron Migration

> **Status:** Complete (pending commit + release v0.13.0)
> **Target:** v0.13.0
> **Prerequisite:** Phase 4.8 complete (AdGuard Client IP), Phase 4.7 patterns learned
> **DevOps Topics:** StatefulSets, database migrations, secrets management, Prisma ORM, database backups
> **CKA Topics:** StatefulSets, PVCs, Jobs, CronJobs, Secrets, environment variables

> **Purpose:** Migrate stateful application with database (more complex than Portfolio)
> **Stack:** Next.js 16 + Bun 1.3.4 + PostgreSQL 18 + Prisma 7.2.0 + Better Auth 1.4.7
> **Source:** GitLab (primary), push-mirrored to GitHub
>
> **Learning Goal:** StatefulSet management, database migrations in CI/CD, handling state

> **Environments:**
> | Environment | Internal URL | Public URL |
> |-------------|--------------|------------|
> | Dev | `invoicetron.dev.k8s.rommelporras.com` | - |
> | Prod | `invoicetron.k8s.rommelporras.com` | `invoicetron.rommelporras.com` |

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
│               invoicetron-prod namespace (same for -dev)            │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  ┌─────────────────────┐         ┌─────────────────────────────┐   │
│  │   PostgreSQL 18     │         │     Invoicetron App         │   │
│  │   StatefulSet       │◄────────│     Deployment (1 replica)  │   │
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
│  │   Job (one-shot)    │    │  - database-url             │        │
│  │   runs migrations   │    │  - better-auth-secret       │        │
│  └─────────────────────┘    └─────────────────────────────┘        │
│                                                                     │
│  Daily:                                                             │
│  ┌─────────────────────┐                                           │
│  │  pg_dump CronJob    │                                           │
│  │  → Longhorn PVC     │                                           │
│  └─────────────────────┘                                           │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### CI/CD Flow

```
┌──────────────────────────────────────────────────────────────────────┐
│             Invoicetron CI/CD Pipeline (Branch-based)                │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   feature/* ───────► develop ──────────────────────► main            │
│                          │                             │             │
│                  [Build image with                [Build image with  │
│                   dev APP_URL]                    prod APP_URL]      │
│                          │                             │             │
│                          ▼                             ▼             │
│                     deploy:dev                    deploy:prod        │
│                       [auto]                    [auto on merge]      │
│                          │                             │             │
│                          ▼                             ▼             │
│                    verify:dev                    verify:prod         │
│                   [health check]               [health check]       │
│                                                                      │
│   Note: NEXT_PUBLIC_APP_URL is baked at build time.                  │
│   Each environment builds its own image with the correct URL.        │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

**Key difference from Portfolio:** Invoicetron cannot promote the same artifact across
environments because `NEXT_PUBLIC_APP_URL` is baked into the JS bundle at build time.
Each environment needs its own Docker image built with the correct URL.

---

## 4.9.1 GitLab Setup

- [x] 4.9.1.1 Create GitLab project for invoicetron
  - Imported from GitHub (`rommelporras/invoicetron`) using GitHub PAT
  - Set GitLab as primary remote (origin), GitHub as secondary (github)

- [x] 4.9.1.2 Configure push mirror to GitHub
  - GitLab → Settings → Repository → Mirroring
  - SSH push mirror to `git@github.com:rommelporras/invoicetron.git`

- [x] 4.9.1.3 Create `develop` branch from current `main`

---

## 4.9.2 Create Namespaces

- [x] 4.9.2.1 Create dev namespace
  ```bash
  kubectl-homelab create namespace invoicetron-dev
  kubectl-homelab label namespace invoicetron-dev pod-security.kubernetes.io/enforce=baseline
  ```

- [x] 4.9.2.2 Create prod namespace
  ```bash
  kubectl-homelab create namespace invoicetron-prod
  kubectl-homelab label namespace invoicetron-prod pod-security.kubernetes.io/enforce=baseline
  ```

---

## 4.9.3 Create Secrets

Each environment gets its own secrets with different credentials.

- [x] 4.9.3.1 Add credentials to 1Password Kubernetes vault
  ```
  # Created items via 1Password CLI:
  # - Invoicetron Dev (postgres-password, better-auth-secret, database-url)
  # - Invoicetron Prod (postgres-password, better-auth-secret, database-url)
  ```

- [x] 4.9.3.2 Create K8s secrets for dev
  ```bash
  kubectl-homelab create secret generic invoicetron-db \
    --namespace invoicetron-dev \
    --from-literal=postgres-password="$(op read 'op://Kubernetes/Invoicetron Dev/postgres-password')"

  kubectl-homelab create secret generic invoicetron-app \
    --namespace invoicetron-dev \
    --from-literal=database-url="$(op read 'op://Kubernetes/Invoicetron Dev/database-url')" \
    --from-literal=better-auth-secret="$(op read 'op://Kubernetes/Invoicetron Dev/better-auth-secret')"
  ```

- [x] 4.9.3.3 Create K8s secrets for prod
  ```bash
  kubectl-homelab create secret generic invoicetron-db \
    --namespace invoicetron-prod \
    --from-literal=postgres-password="$(op read 'op://Kubernetes/Invoicetron Prod/postgres-password')"

  kubectl-homelab create secret generic invoicetron-app \
    --namespace invoicetron-prod \
    --from-literal=database-url="$(op read 'op://Kubernetes/Invoicetron Prod/database-url')" \
    --from-literal=better-auth-secret="$(op read 'op://Kubernetes/Invoicetron Prod/better-auth-secret')"
  ```

- [x] 4.9.3.4 Create secret placeholder manifests (following ghost-prod pattern)
  ```bash
  # manifests/invoicetron/secret.yaml
  # Documentation-only manifest with 1Password references and imperative commands
  # DATA INTENTIONALLY OMITTED — created imperatively from 1Password
  ```

- [x] 4.9.3.5 Create deploy token for private registry access
  ```
  # GitLab → invoicetron → Settings → Repository → Deploy tokens
  # Name: k8s-image-pull, Scope: read_registry
  # Created imagePullSecret in both namespaces:
  kubectl-homelab create secret docker-registry gitlab-registry \
    --namespace invoicetron-dev \
    --docker-server=registry.k8s.rommelporras.com \
    --docker-username="gitlab+deploy-token-1" \
    --docker-password="<from deploy token>"
  kubectl-homelab create secret docker-registry gitlab-registry \
    --namespace invoicetron-prod \
    --docker-server=registry.k8s.rommelporras.com \
    --docker-username="gitlab+deploy-token-1" \
    --docker-password="<from deploy token>"
  ```

### Lesson: Private GitLab projects need imagePullSecrets

Unlike Portfolio (public project), Invoicetron is a **private** GitLab project.
The container registry inherits the project's visibility, so cluster nodes get
`401 Unauthorized` when pulling images. The fix is a deploy token with
`read_registry` scope, stored as a `docker-registry` secret (`gitlab-registry`)
in each namespace. Both the Deployment and CI/CD migration Job reference it
via `imagePullSecrets`.

### Why `DATABASE_URL` is stored as a full secret

Kubernetes env vars don't support shell variable expansion. You can't do:
```yaml
# THIS DOES NOT WORK:
- name: DATABASE_URL
  value: postgresql://invoicetron:$(POSTGRES_PASSWORD)@postgresql:5432/invoicetron
```

Instead, store the full `DATABASE_URL` (including password) as a single secret value.

---

## 4.9.4 Deploy PostgreSQL

Apply to both namespaces. Manifests live in `manifests/invoicetron/`.

- [x] 4.9.4.1 Create PostgreSQL StatefulSet manifest
  ```yaml
  # manifests/invoicetron/postgresql.yaml
  # Apply to each namespace: invoicetron-dev, invoicetron-prod
  #
  # CKA topic: StatefulSet vs Deployment, volumeClaimTemplates, headless Service
  ---
  apiVersion: apps/v1
  kind: StatefulSet
  metadata:
    name: invoicetron-db
    labels:
      app: invoicetron-db
      app.kubernetes.io/part-of: invoicetron
  spec:
    serviceName: invoicetron-db
    replicas: 1
    selector:
      matchLabels:
        app: invoicetron-db
    template:
      metadata:
        labels:
          app: invoicetron-db
      spec:
        securityContext:
          seccompProfile:
            type: RuntimeDefault
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
                name: invoicetron-db
                key: postgres-password
          - name: POSTGRES_DB
            value: invoicetron
          volumeMounts:
          - name: data
            mountPath: /var/lib/postgresql  # PG 18+ uses subdirectory, mount parent
          resources:
            requests:
              memory: "256Mi"
              cpu: "100m"
            limits:
              memory: "1Gi"
              cpu: "500m"
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
  ```

- [x] 4.9.4.2 Create headless Service manifest (combined into postgresql.yaml)
  ```yaml
  # manifests/invoicetron/postgresql-service.yaml
  ---
  apiVersion: v1
  kind: Service
  metadata:
    name: invoicetron-db
    labels:
      app: invoicetron-db
      app.kubernetes.io/part-of: invoicetron
  spec:
    selector:
      app: invoicetron-db
    ports:
    - port: 5432
      targetPort: 5432
    clusterIP: None  # Headless for StatefulSet
  ```

- [x] 4.9.4.3 Apply to both namespaces
  ```bash
  kubectl-homelab apply -f manifests/invoicetron/postgresql.yaml -n invoicetron-dev
  kubectl-homelab apply -f manifests/invoicetron/postgresql.yaml -n invoicetron-prod
  # StatefulSet and headless Service are combined in one file
  ```

- [x] 4.9.4.4 Wait for PostgreSQL to be ready in both namespaces
  ```bash
  # Both invoicetron-db-0 pods Running and Ready
  ```

### Lesson: PostgreSQL 18+ mount path

PG 18+ changed its data directory layout. Mount at `/var/lib/postgresql` (parent),
not `/var/lib/postgresql/data`. PG creates the `data` subdirectory itself.
Initial deploy used the old path and pods went to CrashLoopBackOff. Fixed by
deleting StatefulSets+PVCs and reapplying with the correct mount path.

---

## 4.9.5 Create K8s Deployment

- [x] 4.9.5.1 Create invoicetron Deployment manifest
  ```yaml
  # manifests/invoicetron/deployment.yaml
  # Apply to each namespace: invoicetron-dev, invoicetron-prod
  #
  # WARNING: The image field is a placeholder. CI/CD sets the actual image via
  # `kubectl set image`. Do NOT `kubectl apply` on a running deployment — it reverts
  # the image. Use `kubectl set env` for runtime env var changes.
  #
  # Note: NEXT_PUBLIC_APP_URL is baked at Docker build time, not runtime.
  # Each environment has its own image built with the correct URL.
  # imagePullSecrets required — private GitLab project (see 4.9.3.5)
  # ADDITIONAL_TRUSTED_ORIGINS added at runtime for multi-URL auth support.
  #
  # CKA topics: Init containers, Deployments, RollingUpdate strategy, imagePullSecrets
  ---
  apiVersion: apps/v1
  kind: Deployment
  metadata:
    name: invoicetron
    labels:
      app: invoicetron
      app.kubernetes.io/part-of: invoicetron
  spec:
    replicas: 1
    selector:
      matchLabels:
        app: invoicetron
    strategy:
      type: RollingUpdate
      rollingUpdate:
        maxSurge: 1
        maxUnavailable: 0
    template:
      metadata:
        labels:
          app: invoicetron
      spec:
        imagePullSecrets:
        - name: gitlab-registry
        securityContext:
          runAsNonRoot: true
          runAsUser: 1001
          runAsGroup: 1001
          seccompProfile:
            type: RuntimeDefault
        initContainers:
        - name: wait-for-db
          image: busybox:1.36
          command: ['sh', '-c', 'until nc -z invoicetron-db 5432; do echo "Waiting for PostgreSQL..."; sleep 2; done; echo "PostgreSQL is ready!"']
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
        containers:
        - name: invoicetron
          image: registry.k8s.rommelporras.com/0xwsh/invoicetron:latest
          ports:
          - containerPort: 3000
            name: http
          env:
          - name: DATABASE_URL
            valueFrom:
              secretKeyRef:
                name: invoicetron-app
                key: database-url
          - name: BETTER_AUTH_SECRET
            valueFrom:
              secretKeyRef:
                name: invoicetron-app
                key: better-auth-secret
          - name: NODE_ENV
            value: production
          - name: ADDITIONAL_TRUSTED_ORIGINS
            value: "https://invoicetron.k8s.rommelporras.com"
          resources:
            requests:
              memory: "512Mi"
              cpu: "250m"
            limits:
              memory: "2Gi"
              cpu: "2000m"
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
          livenessProbe:
            httpGet:
              path: /api/health
              port: 3000
            initialDelaySeconds: 30
            periodSeconds: 10
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /api/health
              port: 3000
            initialDelaySeconds: 10
            periodSeconds: 5
            failureThreshold: 3
  ---
  apiVersion: v1
  kind: Service
  metadata:
    name: invoicetron
    labels:
      app: invoicetron
      app.kubernetes.io/part-of: invoicetron
  spec:
    type: ClusterIP
    selector:
      app: invoicetron
    ports:
    - port: 3000
      targetPort: 3000
      protocol: TCP
      name: http
  ```

---

## 4.9.6 Create GitLab CI/CD Pipeline

- [x] 4.9.6.1 Create RBAC for GitLab deployments
  ```yaml
  # manifests/invoicetron/rbac.yaml
  # Apply to each namespace: invoicetron-dev, invoicetron-prod
  #
  # Broader than portfolio — needs Jobs (migrations), Secrets (envFrom)
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
  - apiGroups: ["batch"]
    resources: ["jobs"]
    verbs: ["get", "list", "watch", "create", "delete"]
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

- [x] 4.9.6.2 Apply RBAC to both namespaces
  ```bash
  kubectl-homelab apply -f manifests/invoicetron/rbac.yaml -n invoicetron-dev
  kubectl-homelab apply -f manifests/invoicetron/rbac.yaml -n invoicetron-prod
  ```

- [x] 4.9.6.3 Create `.gitlab-ci.yml` in invoicetron repo
  The actual `.gitlab-ci.yml` lives in the invoicetron repo. Key design points:
  ```
  # Stages: validate → test → build → deploy → verify
  # Validate: type-check (bunx tsc), lint, security-audit (allow_failure)
  # Test: unit tests with node:22-slim (vitest needs real Node.js for SSR/zod v4 ESM)
  # Build: per-environment images (NEXT_PUBLIC_APP_URL is build-time)
  #   - dev: $IMAGE_BASE/dev:$CI_COMMIT_SHORT_SHA
  #   - prod: $IMAGE_BASE/prod:$CI_COMMIT_SHORT_SHA
  # Deploy: Prisma migration Job (with imagePullSecrets + explicit DATABASE_URL env)
  #   then kubectl set image + rollout status
  # Verify: curl health check
  #
  # Environment names: "development" and "production"
  # CI/CD variables are scoped to these environment names
  #
  # Lessons learned during implementation:
  # - Migration Job needs imagePullSecrets (private registry, see 4.9.3.5)
  # - Migration Job needs explicit env mapping (DATABASE_URL → secret key database-url)
  #   NOT envFrom, because K8s secret keys use hyphens but Prisma expects DATABASE_URL
  # - Dummy DATABASE_URL needed as global variable for prisma generate in validate/test
  # - Vitest requires node:22-slim (not oven/bun:1) for SSR module resolution (zod v4 ESM)
  ```

- [x] 4.9.6.4 Add CI/CD variables to GitLab project
  ```
  # Created environments: "development" and "production" in GitLab
  # Per-environment variables (scoped to environment):
  # development:
  #   KUBE_TOKEN (from invoicetron-dev/gitlab-deploy-token)
  #   KUBE_API_URL (https://api.k8s.rommelporras.com:6443)
  # production:
  #   KUBE_TOKEN (from invoicetron-prod/gitlab-deploy-token)
  #   KUBE_API_URL (https://api.k8s.rommelporras.com:6443)
  ```

### Lesson: envFrom vs explicit env mapping

K8s secret keys use hyphens (`database-url`), but tools like Prisma expect
`DATABASE_URL` (uppercase with underscores). Using `envFrom` injects keys as-is,
so the migration Job gets `database-url` as the env var name — Prisma can't find it.

Fix: Use explicit `env` entries with `valueFrom.secretKeyRef` to map
`DATABASE_URL` → secret key `database-url`. Only inject what the Job needs
(just `DATABASE_URL` for migrations, not `BETTER_AUTH_SECRET`).

---

## 4.9.7 Configure Access

- [x] 4.9.7.1 Create HTTPRoute for dev (internal only)
  ```yaml
  # manifests/gateway/routes/invoicetron-dev.yaml
  apiVersion: gateway.networking.k8s.io/v1
  kind: HTTPRoute
  metadata:
    name: invoicetron
    namespace: invoicetron-dev
  spec:
    parentRefs:
      - name: homelab-gateway
        namespace: default
        sectionName: https-dev
    hostnames:
      - "invoicetron.dev.k8s.rommelporras.com"
    rules:
      - matches:
          - path:
              type: PathPrefix
              value: /
        backendRefs:
          - name: invoicetron
            port: 3000
  ```

- [x] 4.9.7.2 Create HTTPRoute for prod (internal)
  ```yaml
  # manifests/gateway/routes/invoicetron-prod.yaml
  apiVersion: gateway.networking.k8s.io/v1
  kind: HTTPRoute
  metadata:
    name: invoicetron
    namespace: invoicetron-prod
  spec:
    parentRefs:
      - name: homelab-gateway
        namespace: default
        sectionName: https
    hostnames:
      - "invoicetron.k8s.rommelporras.com"
    rules:
      - matches:
          - path:
              type: PathPrefix
              value: /
        backendRefs:
          - name: invoicetron
            port: 3000
  ```

- [x] 4.9.7.3 ~~Configure DNS in AdGuard~~ — SKIPPED
  ```
  # Not needed — existing AdGuard wildcards already handle this:
  # *.k8s.rommelporras.com → 10.10.30.20
  # *.dev.k8s.rommelporras.com → 10.10.30.20
  ```

- [x] 4.9.7.4 Configure Cloudflare Tunnel (external, prod only)
  ```
  # Cloudflare Zero Trust → Tunnels → Public Hostname
  #
  # Public hostname: invoicetron.rommelporras.com
  # Service type: HTTP
  # URL: invoicetron.invoicetron-prod.svc.cluster.local:3000
  #
  # Required: CiliumNetworkPolicy cloudflared-egress must allow traffic to
  # namespace invoicetron-prod (NOT "invoicetron") on port 3000.
  # Also updated deployment with ADDITIONAL_TRUSTED_ORIGINS env var
  # so Better Auth server accepts requests from both public and internal URLs.
  ```

- [x] 4.9.7.5 Configure Cloudflare Access (prod only)
  ```
  # Cloudflare Zero Trust → Access → Applications → Add an application
  #
  # Application type: Self-hosted
  # Application name: Invoicetron
  # Application domain: invoicetron.rommelporras.com
  #
  # Reused existing "Allow Admin" policy (same as Ghost blog):
  # - Action: Allow
  # - Include: Emails (cloudflare@rommelporras.com, rommelcporras@gmail.com)
  # - Authentication: One-time PIN (email OTP)
  # - Session duration: 24 hours
  # - Policy ID: 7f65c50c-xxxx-xxxx-xxxx-xxxxxxxxxxxx
  ```

---

## 4.9.8 Database Backup CronJob

Daily pg_dump for production data safety. Database is ~14MB, so this is lightweight.

- [x] 4.9.8.1 Create backup CronJob manifest
  ```yaml
  # manifests/invoicetron/backup-cronjob.yaml
  # Apply to invoicetron-prod namespace
  #
  # CKA topic: CronJobs, volume mounts, backup strategies
  ---
  apiVersion: batch/v1
  kind: CronJob
  metadata:
    name: invoicetron-db-backup
    labels:
      app: invoicetron-db
      app.kubernetes.io/part-of: invoicetron
  spec:
    schedule: "0 3 * * *"  # Daily at 3 AM
    successfulJobsHistoryLimit: 3
    failedJobsHistoryLimit: 3
    jobTemplate:
      spec:
        template:
          spec:
            securityContext:
              seccompProfile:
                type: RuntimeDefault
            containers:
            - name: backup
              image: postgres:18-alpine
              command:
              - /bin/sh
              - -c
              - |
                TIMESTAMP=$(date +%Y%m%d_%H%M%S)
                BACKUP_FILE="/backups/invoicetron_${TIMESTAMP}.sql"
                pg_dump -h invoicetron-db -U invoicetron -d invoicetron > "${BACKUP_FILE}"
                echo "Backup completed: ${BACKUP_FILE}"
                # Keep only last 7 days of backups
                find /backups -name "invoicetron_*.sql" -mtime +7 -delete
              env:
              - name: PGPASSWORD
                valueFrom:
                  secretKeyRef:
                    name: invoicetron-db
                    key: postgres-password
              volumeMounts:
              - name: backups
                mountPath: /backups
            restartPolicy: OnFailure
            volumes:
            - name: backups
              persistentVolumeClaim:
                claimName: invoicetron-backups
  ---
  apiVersion: v1
  kind: PersistentVolumeClaim
  metadata:
    name: invoicetron-backups
    labels:
      app: invoicetron-db
      app.kubernetes.io/part-of: invoicetron
  spec:
    accessModes: ["ReadWriteOnce"]
    storageClassName: longhorn
    resources:
      requests:
        storage: 2Gi
  ```

- [x] 4.9.8.2 Apply backup CronJob to prod
  ```bash
  kubectl-homelab apply -f manifests/invoicetron/backup-cronjob.yaml -n invoicetron-prod
  ```

- [x] 4.9.8.3 Test backup manually
  ```bash
  kubectl-homelab create job --from=cronjob/invoicetron-db-backup invoicetron-db-backup-test -n invoicetron-prod
  kubectl-homelab logs -n invoicetron-prod job/invoicetron-db-backup-test
  # Output: Backup completed: /backups/invoicetron_20260204_182224.sql
  ```

---

## 4.9.9 Migrate Data

> **Source:** Local WSL database (NOT reverse-mountain VM — VM backups are stale/broken since Jan 6, 2026).
> **Dump files:** Need to be regenerated by invoicetron agent (originals deleted from repo during cleanup).

- [x] 4.9.9.1 Restore to K8s PostgreSQL (both dev and prod)
  ```bash
  # Dump file: invoicetron-full-20260205.dump (custom format, ~14MB)
  # Generated by invoicetron agent from local Docker PostgreSQL
  #
  # Restored to both namespaces:
  for NS in invoicetron-dev invoicetron-prod; do
    kubectl-homelab cp /home/wsl/personal/invoicetron/backups/invoicetron-full-20260205.dump \
      $NS/invoicetron-db-0:/tmp/invoicetron-full-20260205.dump
    kubectl-homelab exec -n $NS invoicetron-db-0 -- \
      pg_restore --username=invoicetron --dbname=invoicetron \
        --clean --if-exists --no-owner --no-privileges --verbose \
        /tmp/invoicetron-full-20260205.dump
  done
  # Note: pg_restore shows errors for "does not exist" on --clean — safe to ignore
  ```

- [x] 4.9.9.2 Clean up ephemeral tables
  ```bash
  # Sessions and RateLimit tables cleaned during restore (--clean flag)
  ```

- [x] 4.9.9.3 Verify data integrity
  ```bash
  # Verified in both namespaces:
  # invoices=567, invoice_items=988, products=639, user=1, _prisma_migrations=29
  # Login tested and working on all three URLs
  ```

---

## 4.9.10 Retire Reverse-Mountain VM

- [x] 4.9.10.1 Run K8s alongside VM for 1 week

- [x] 4.9.10.2 Stop Docker Compose on reverse-mountain VM
  ```
  # docker compose stop on reverse-mountain VM — done 2026-02-05
  ```

- [x] 4.9.10.3 Retired reverse-mountain VM
  ```
  # Invoicetron project removed from VM — 2026-02-05
  # Local WSL machine has the latest database, VM version was outdated
  ```

---

## 4.9.11 Remove Temporary DMZ NetworkPolicy Rule

> **IMPORTANT:** After both Portfolio (Phase 4.7) and Invoicetron (Phase 4.9) are running
> in K8s, the temporary DMZ rule in the cloudflared NetworkPolicy must be removed.

- [x] 4.9.11.1 Verify both services are running in K8s
  ```bash
  # portfolio-prod: 2 replicas Running
  # invoicetron-prod: 1 replica Running + invoicetron-db-0 Running
  ```

- [x] 4.9.11.2 Remove temporary DMZ rule from NetworkPolicy
  ```bash
  # Removed entire "TEMPORARY: DMZ VM" toCIDR section from
  # manifests/cloudflare/networkpolicy.yaml
  # Also updated header comment to reflect current allowed namespaces
  ```

- [x] 4.9.11.3 Apply updated NetworkPolicy
  ```bash
  kubectl-homelab apply -f manifests/cloudflare/networkpolicy.yaml
  ```

- [x] 4.9.11.4 Verify tunnel still works (uses K8s services now)
  ```bash
  # invoicetron.rommelporras.com: 200
  # blog.rommelporras.com: 200
  # status.rommelporras.com: 302 (redirect to login, expected)
  # www.rommelporras.com: 404 (portfolio root, pre-existing)
  ```

- [x] 4.9.11.5 Run security validation script
  ```bash
  ./scripts/test-cloudflare-networkpolicy.sh
  # Result: 35 passed, 0 failed, 3 warnings (all expected)
  # DMZ VM tests: TIMEOUT (expected — DMZ rule removed)
  # QUIC UDP test: inconclusive (always, tunnel uses QUIC)
  ```

---

## 4.9.12 Documentation Updates

- [x] 4.9.12.1 Update VERSIONS.md
  ```
  # Add to Applications section:
  | Invoicetron | 2.x.x | Invoice management (Next.js + Bun) |
  | PostgreSQL (Invoicetron) | 18 | Invoicetron database |

  # Add to Version History:
  | YYYY-MM-DD | Phase 4.9: Invoicetron stateful migration |
  ```

- [x] 4.9.12.2 Update docs/context/Secrets.md
  ```
  # Add 1Password items:
  | Invoicetron Dev | postgres-password | Dev database credentials |
  | Invoicetron Dev | better-auth-secret | Dev auth session secret |
  | Invoicetron Dev | database-url | Dev full connection string |
  | Invoicetron Prod | postgres-password | Prod database credentials |
  | Invoicetron Prod | better-auth-secret | Prod auth session secret |
  | Invoicetron Prod | database-url | Prod full connection string |
  ```

- [x] 4.9.12.3 Update docs/reference/CHANGELOG.md
  - Add Phase 4.9 section with milestone, decisions, lessons learned

- [x] 4.9.12.4 Update invoicetron CLAUDE.md with K8s deployment context
  ```
  # Add to /home/wsl/personal/invoicetron/CLAUDE.md:
  #
  # Kubernetes Deployment section covering:
  # - GitLab is primary remote (origin), GitHub is push mirror
  # - Two namespaces: invoicetron-dev (develop branch), invoicetron-prod (main branch)
  # - NEXT_PUBLIC_APP_URL is a build-time arg (--build-arg), NOT a runtime env var
  # - DATABASE_URL stored as full connection string in K8s secret (invoicetron-app)
  # - PostgreSQL runs as StatefulSet (invoicetron-db) with Longhorn PVC
  # - Prisma migrations run as a K8s Job before deployment
  # - CI/CD: GitLab 4-stage pipeline (test → build → deploy → verify)
  # - Internal URLs: invoicetron.dev.k8s.rommelporras.com / invoicetron.k8s.rommelporras.com
  # - Public URL: invoicetron.rommelporras.com (behind Cloudflare Access, email OTP)
  # - Daily pg_dump CronJob in prod (3 AM, 7-day retention)
  #
  # This prevents the agent from guessing Docker Compose values or wrong URLs.
  ```

- [x] 4.9.12.5 Update invoicetron README.md with K8s deployment info
  ```
  # Update /home/wsl/personal/invoicetron/README.md:
  #
  # Replace or update the deployment section to reflect:
  # - Kubernetes deployment (no longer Docker Compose on a VM)
  # - GitLab CI/CD pipeline (push to develop → auto-deploy dev, merge to main → auto-deploy prod)
  # - Environment URLs
  # - Remove references to reverse-mountain VM / manual docker compose workflow
  ```

---

## Verification Checklist

- [x] Namespaces `invoicetron-dev` and `invoicetron-prod` exist with baseline PSS
- [x] PostgreSQL StatefulSet running in both namespaces (invoicetron-db-0 pod ready)
- [x] PostgreSQL PVCs bound and healthy in Longhorn
- [x] Invoicetron Deployment running in both namespaces
- [x] Prisma migration Job completed successfully in both
- [x] Secrets created (`invoicetron-db`, `invoicetron-app`, `gitlab-registry`) in both namespaces
- [x] HTTPRoutes configured for both dev and prod
- [x] DNS handled by existing AdGuard wildcards (no new rewrites needed)
- [x] GitLab CI/CD pipeline passes all stages (validate → test → build → deploy → verify)
- [x] Can login to Invoicetron web UI (all 3 URLs: public, internal prod, internal dev)
- [x] Data migrated from local WSL database (both dev and prod)
- [x] External access via Cloudflare Tunnel works
- [x] Cloudflare Access with email OTP configured (reused Allow Admin policy)
- [x] Database backup CronJob manifest applied in prod
- [ ] Database backup CronJob tested manually
- [x] Push mirror to GitHub working
- [x] CiliumNetworkPolicy updated for invoicetron-prod namespace

---

## Rollback

If issues occur:

```bash
# 1. Quick rollback - restart VM
ssh wawashi@reverse-mountain "cd /home/wawashi/invoicetron && docker compose up -d"

# 2. Revert Cloudflare tunnel route
#    Dashboard → Tunnels → Public Hostname
#    Change back to VM IP

# 3. If only app is broken (DB is fine)
kubectl-homelab rollout undo deployment/invoicetron -n invoicetron-prod

# 4. If migration broke the schema
#    Restore from backup
kubectl-homelab cp backup.sql invoicetron-prod/invoicetron-db-0:/tmp/
kubectl-homelab exec -n invoicetron-prod invoicetron-db-0 -- \
  psql -U invoicetron -d invoicetron -f /tmp/backup.sql

# 5. Full cleanup and restart
kubectl-homelab delete deployment invoicetron -n invoicetron-prod
kubectl-homelab delete statefulset invoicetron-db -n invoicetron-prod
kubectl-homelab delete pvc --all -n invoicetron-prod
# Then restart from 4.9.4
```

---

## Troubleshooting

### PostgreSQL pod stuck in Pending

```bash
# Check PVC status
kubectl-homelab get pvc -n invoicetron-prod

# Check Longhorn for storage issues
kubectl-homelab -n longhorn-system get volumes

# Common issues:
# - Insufficient storage → check Longhorn capacity
# - Scheduling issues → check node resources
```

### Image pull fails (ImagePullBackOff)

```bash
# Check if imagePullSecrets is set on the pod
kubectl-homelab get deployment invoicetron -n invoicetron-prod -o jsonpath='{.spec.template.spec.imagePullSecrets}'

# Check if gitlab-registry secret exists
kubectl-homelab get secret gitlab-registry -n invoicetron-prod

# Test registry auth directly
curl -s https://registry.k8s.rommelporras.com/v2/0xwsh/invoicetron/dev/tags/list

# Common issues:
# - Missing imagePullSecrets → add to Deployment and migration Job
# - Deploy token expired → create new one in GitLab → recreate secret
# - Private project → container registry inherits visibility, needs auth
```

### Prisma migration Job fails

```bash
# Check Job status
kubectl-homelab get jobs -n invoicetron-prod
kubectl-homelab describe job invoicetron-migrate -n invoicetron-prod

# Check migration logs
kubectl-homelab logs -n invoicetron-prod job/invoicetron-migrate

# Common issues:
# - DATABASE_URL wrong → check invoicetron-app secret
# - "datasource.url property is required" → envFrom injects hyphenated keys (database-url)
#   but Prisma needs DATABASE_URL. Use explicit env mapping, NOT envFrom.
# - Schema conflicts → check Prisma migration history
# - PostgreSQL not ready → wait and retry
# - ImagePullBackOff on Job pod → check imagePullSecrets in Job spec
```

### App can't connect to PostgreSQL

```bash
# Verify PostgreSQL is running
kubectl-homelab get pods -n invoicetron-prod | grep invoicetron-db

# Test connectivity from app pod
kubectl-homelab exec -n invoicetron-prod -it deployment/invoicetron -- \
  nc -zv invoicetron-db 5432

# Check DATABASE_URL is correct
kubectl-homelab exec -n invoicetron-prod -it deployment/invoicetron -- \
  printenv DATABASE_URL
```

### Authentication not working (better-auth)

```bash
# Check BETTER_AUTH_SECRET is set
kubectl-homelab exec -n invoicetron-prod -it deployment/invoicetron -- \
  printenv BETTER_AUTH_SECRET

# Verify it matches what's in 1Password
op read "op://Kubernetes/Invoicetron Prod/better-auth-secret"
```

### NEXT_PUBLIC_APP_URL wrong (shows wrong domain)

```
# This is a build-time issue, not runtime.
# The image was built with the wrong --build-arg.
# Rebuild via GitLab CI/CD — do NOT try to set this at runtime.
```

### Login works on canonical URL but not internal URL

```
# Better Auth client SDK used to hardcode baseURL to NEXT_PUBLIC_APP_URL.
# When accessing via a different hostname, auth requests went cross-origin → cookies failed.
#
# Fix (applied in invoicetron commit 15c0f2c):
# - Removed hardcoded baseURL from createAuthClient() in src/lib/auth-client.ts
# - Better Auth's built-in fallback uses window.location.origin automatically
# - Server-side: ADDITIONAL_TRUSTED_ORIGINS env var lists allowed origins
#   (set via kubectl set env, NOT in the manifest to avoid reverting CI/CD image)
#
# All three URLs now work:
# - https://invoicetron.rommelporras.com (public via Cloudflare Tunnel)
# - https://invoicetron.k8s.rommelporras.com (internal prod via Gateway)
# - https://invoicetron.dev.k8s.rommelporras.com (internal dev via Gateway)
```

### Cloudflare Tunnel returns 502

```
# CiliumNetworkPolicy cloudflared-egress must use the EXACT namespace name.
# Bug: used "invoicetron" instead of "invoicetron-prod" → cloudflared couldn't reach the app.
# Fix: manifests/cloudflare/networkpolicy.yaml line 72:
#   k8s:io.kubernetes.pod.namespace: invoicetron-prod  (not "invoicetron")
```

### DATABASE_URL password with special characters

```
# Passwords containing / or other URL-special characters break Prisma's URL parsing.
# URL-encoding (e.g., %2F) works for Prisma CLI but the runtime client may send it literally.
#
# Safest fix: Generate hex-only passwords (no special characters):
#   openssl rand -hex 20
#
# If password was already set in PostgreSQL, changing the K8s secret alone is NOT enough.
# PostgreSQL only reads POSTGRES_PASSWORD on first init (empty data dir).
# Must also run ALTER USER inside the running PostgreSQL pod:
#   kubectl-homelab exec -n <ns> invoicetron-db-0 -- \
#     psql -U invoicetron -c "ALTER USER invoicetron WITH PASSWORD '<new-password>';"
```

### kubectl apply reverts CI/CD image

```
# The deployment.yaml manifest has a placeholder image (registry.../invoicetron:latest).
# CI/CD sets the actual image via `kubectl set image`.
# Running `kubectl apply -f deployment.yaml` REVERTS the image to the placeholder.
#
# To change env vars on a running deployment without touching the image:
#   kubectl-homelab set env deployment/invoicetron -n <ns> ADDITIONAL_TRUSTED_ORIGINS="..."
#
# If accidentally reverted: kubectl-homelab rollout undo deployment/invoicetron -n <ns>
```

### 1Password CLI session expired

```
# If `op read` returns empty values, the 1Password CLI session has expired.
# Secrets created with empty values will cause auth failures.
# Always run `eval $(op signin)` before creating secrets.
# Verify secrets after creation:
#   kubectl-homelab get secret <name> -n <ns> -o jsonpath='{.data}' | base64 -d
```

---

## Final: Commit and Release

- [ ] Commit changes
  ```bash
  /commit
  ```

- [ ] Release v0.13.0
  ```bash
  /release v0.13.0
  ```

- [ ] Move this file to completed folder
  ```bash
  mv docs/todo/phase-4.9-invoicetron.md docs/todo/completed/
  ```
