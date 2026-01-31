# Phase 4.12: Ghost Blog Platform

> **Status:** In Progress
> **Target:** v0.11.0
> **Prerequisite:** Phase 4.8 complete (AdGuard Client IP)
> **DevOps Topics:** CMS deployment, MySQL StatefulSet, CI/CD theme pipelines, database migrations
> **CKA Topics:** StatefulSet, PersistentVolumeClaim, ConfigMap, Secret, HTTPRoute, multi-environment deployment

> **Purpose:** Self-hosted Ghost blog for personal writing, technical articles, and documentation
>
> **Why Ghost?** Easier content creation than MDX in portfolio project. Full CMS editor with draft/publish workflow.
>
> **Why not Ghost Core?** Theme-only customization is sufficient. No need to fork the entire monorepo.

---

## Overview

Deploy Ghost CMS to Kubernetes with two environments:
- **Dev** (`ghost-dev` namespace) - Theme development, internal access only
- **Prod** (`ghost-prod` namespace) - Public blog via Cloudflare Tunnel

### Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                         Ghost Blog Platform                          │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   ghost-dev namespace                ghost-prod namespace            │
│   ┌─────────────────────┐           ┌─────────────────────┐         │
│   │ Ghost (Deployment)  │           │ Ghost (Deployment)  │         │
│   │ - 1 replica         │           │ - 1 replica         │         │
│   │ - Custom theme      │           │ - Custom theme      │         │
│   └─────────┬───────────┘           └─────────┬───────────┘         │
│             │                                 │                      │
│   ┌─────────▼───────────┐           ┌─────────▼───────────┐         │
│   │ MySQL (StatefulSet) │           │ MySQL (StatefulSet) │         │
│   │ - Longhorn PVC 10Gi │           │ - Longhorn PVC 10Gi │         │
│   └─────────────────────┘           └─────────────────────┘         │
│                                                                      │
│   HTTPRoute (internal)              HTTPRoute + Cloudflare Tunnel   │
│   blog-dev.k8s.home...              blog.rommelporras.com           │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│   Theme Repo: gitlab.k8s.home.rommelporras.com/0xwsh/               │
│               eventually-consistent                                  │
│   - Forked from Dawn                                                 │
│   - GitLab CI/CD builds theme zip                                    │
│   - Deploys to Ghost via Admin API                                   │
│   - Mirror: github.com/rommelporras/eventually-consistent (public)  │
│   - Dual-remote: origin (GitLab) + github (GitHub)                  │
└─────────────────────────────────────────────────────────────────────┘
```

### Version Pinning

> **Important:** All environments (local, dev, prod) must use identical versions.
> Never use floating tags like `ghost:6` or `mysql:8.0`.

| Component | Version | Image | Notes |
|-----------|---------|-------|-------|
| Ghost | 6.14.0 | `ghost:6.14.0` | Debian Bookworm (not Alpine) |
| MySQL | 8.4.8 | `mysql:8.4.8` | LTS with utf8mb4 charset |

**Why MySQL 8.4 LTS over 8.0.x or 9.x?**
- MySQL 8.0.x EOL is April 2026 (too soon!)
- MySQL 9.x is Innovation release (not LTS, shorter support)
- MySQL 8.4 LTS has 5 years premier + 3 years extended support
- Uses `caching_sha2_password` by default (more secure than deprecated `mysql_native_password`)

**Why Debian over Alpine?**
- glibc compatibility (Alpine uses musl libc which can cause issues)
- Node.js officially supports Debian, not Alpine
- Only 22 MB larger (219 MB vs 197 MB) - not worth the stability risk
- Ghost's Sharp image library works better with glibc

**Ghost 6.x Requirements:**
- Node.js 22 (v18/v20 dropped)
- MySQL 8.x LTS
- New admin shell/sidebar UI

### Access

| Environment | URL | Access |
|-------------|-----|--------|
| Dev | blog-dev.k8s.home.rommelporras.com | Internal only (HTTPRoute) |
| Prod | blog.rommelporras.com | Public (Cloudflare Tunnel) |

---

## Critical Configuration Notes

> **Based on Ghost documentation research - these are required for proper operation.**

### 1. Admin API JWT Authentication

Ghost Admin API does NOT accept raw API keys. You must:
1. Split the API key (`id:secret` format)
2. Generate a JWT token with HMAC-SHA256 signature
3. Use `Authorization: Ghost <jwt_token>` header

See `.gitlab-ci.yml` in the blog theme repo for implementation.

### 2. MySQL utf8mb4 Character Set

Required for emoji/unicode support in blog posts:
```yaml
# MySQL args
args:
  - --character-set-server=utf8mb4
  - --collation-server=utf8mb4_0900_ai_ci

# Ghost env
- name: database__connection__charset
  value: utf8mb4
```

### 3. Resource Requirements

Ghost recommends at least 1GB memory. Our configuration:

| Component | Request | Limit |
|-----------|---------|-------|
| Ghost | 512Mi | 1Gi |
| MySQL | 512Mi | 1Gi |

### 4. Health Probes

Ghost health endpoint: `/ghost/api/admin/site/`

---

## 4.12.1 Create Namespaces

- [x] 4.12.1.1 Create ghost-dev namespace
  ```yaml
  # manifests/ghost-dev/namespace.yaml
  apiVersion: v1
  kind: Namespace
  metadata:
    name: ghost-dev
    labels:
      app.kubernetes.io/part-of: ghost
  ```
  ```bash
  kubectl-homelab apply -f manifests/ghost-dev/namespace.yaml
  ```

- [x] 4.12.1.2 Create ghost-prod namespace
  ```yaml
  # manifests/ghost-prod/namespace.yaml
  apiVersion: v1
  kind: Namespace
  metadata:
    name: ghost-prod
    labels:
      app.kubernetes.io/part-of: ghost
  ```
  ```bash
  kubectl-homelab apply -f manifests/ghost-prod/namespace.yaml
  ```

---

## 4.12.2 Create 1Password Secrets

- [x] 4.12.2.1 Create Ghost Dev MySQL credentials in 1Password
  ```
  Vault: Kubernetes
  Item: Ghost Dev MySQL
  Fields:
    - root-password: (generate with: openssl rand -hex 32)
    - user-password: (generate with: openssl rand -hex 32)
  ```

- [x] 4.12.2.2 Create Ghost Prod MySQL credentials in 1Password
  ```
  Vault: Kubernetes
  Item: Ghost Prod MySQL
  Fields:
    - root-password: (generate with: openssl rand -hex 32)
    - user-password: (generate with: openssl rand -hex 32)
  ```

- [x] 4.12.2.3 Create Ghost Mail credentials in 1Password (or reuse existing SMTP) — reused iCloud SMTP
  ```
  Vault: Kubernetes
  Item: Ghost Mail
  Fields:
    - smtp-host: smtp.mail.me.com
    - smtp-user: <iCloud email>
    - smtp-password: <app-specific password>
    - from-address: noreply@rommelporras.com
  Note: Port (587) is hardcoded in deployment, not stored in secret
  ```

- [x] 4.12.2.4 Create Kubernetes secrets from 1Password (dev)
  ```bash
  eval $(op signin)

  kubectl-homelab create secret generic ghost-mysql \
    --namespace ghost-dev \
    --from-literal=root-password="$(op read 'op://Kubernetes/Ghost Dev MySQL/root-password')" \
    --from-literal=user-password="$(op read 'op://Kubernetes/Ghost Dev MySQL/user-password')"

  kubectl-homelab create secret generic ghost-mail \
    --namespace ghost-dev \
    --from-literal=smtp-host="$(op read 'op://Kubernetes/Ghost Mail/smtp-host')" \
    --from-literal=smtp-user="$(op read 'op://Kubernetes/Ghost Mail/smtp-user')" \
    --from-literal=smtp-password="$(op read 'op://Kubernetes/Ghost Mail/smtp-password')" \
    --from-literal=from-address="$(op read 'op://Kubernetes/Ghost Mail/from-address')"
  ```

- [x] 4.12.2.5 Create Kubernetes secrets from 1Password (prod)
  ```bash
  kubectl-homelab create secret generic ghost-mysql \
    --namespace ghost-prod \
    --from-literal=root-password="$(op read 'op://Kubernetes/Ghost Prod MySQL/root-password')" \
    --from-literal=user-password="$(op read 'op://Kubernetes/Ghost Prod MySQL/user-password')"

  kubectl-homelab create secret generic ghost-mail \
    --namespace ghost-prod \
    --from-literal=smtp-host="$(op read 'op://Kubernetes/Ghost Mail/smtp-host')" \
    --from-literal=smtp-user="$(op read 'op://Kubernetes/Ghost Mail/smtp-user')" \
    --from-literal=smtp-password="$(op read 'op://Kubernetes/Ghost Mail/smtp-password')" \
    --from-literal=from-address="$(op read 'op://Kubernetes/Ghost Mail/from-address')"
  ```

---

## 4.12.3 Deploy MySQL StatefulSets

- [x] 4.12.3.1 Create MySQL manifests for dev
  ```bash
  mkdir -p manifests/ghost-dev
  ```
  ```yaml
  # manifests/ghost-dev/mysql-statefulset.yaml
  apiVersion: apps/v1
  kind: StatefulSet
  metadata:
    name: ghost-mysql
    namespace: ghost-dev
  spec:
    serviceName: ghost-mysql
    replicas: 1
    selector:
      matchLabels:
        app: ghost-mysql
    template:
      metadata:
        labels:
          app: ghost-mysql
      spec:
        containers:
        - name: mysql
          image: mysql:8.4.8
          # Configure utf8mb4 for full unicode/emoji support
          # Note: mysql_native_password is deprecated in 8.4, using caching_sha2_password (default)
          args:
            - --character-set-server=utf8mb4
            - --collation-server=utf8mb4_0900_ai_ci
          ports:
          - containerPort: 3306
          env:
          - name: MYSQL_ROOT_PASSWORD
            valueFrom:
              secretKeyRef:
                name: ghost-mysql
                key: root-password
          - name: MYSQL_DATABASE
            value: ghost
          - name: MYSQL_USER
            value: ghost
          - name: MYSQL_PASSWORD
            valueFrom:
              secretKeyRef:
                name: ghost-mysql
                key: user-password
          volumeMounts:
          - name: mysql-data
            mountPath: /var/lib/mysql
          resources:
            requests:
              memory: "512Mi"
              cpu: "100m"
            limits:
              memory: "1Gi"
              cpu: "500m"
          livenessProbe:
            exec:
              command:
                - mysqladmin
                - ping
                - -h
                - localhost
            initialDelaySeconds: 30
            periodSeconds: 10
            timeoutSeconds: 5
          readinessProbe:
            exec:
              command:
                - mysqladmin
                - ping
                - -h
                - localhost
            initialDelaySeconds: 5
            periodSeconds: 5
            timeoutSeconds: 3
    volumeClaimTemplates:
    - metadata:
        name: mysql-data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: longhorn
        resources:
          requests:
            storage: 10Gi
  ```

- [x] 4.12.3.2 Create MySQL Service for dev
  ```yaml
  # manifests/ghost-dev/mysql-service.yaml
  apiVersion: v1
  kind: Service
  metadata:
    name: ghost-mysql
    namespace: ghost-dev
  spec:
    selector:
      app: ghost-mysql
    ports:
    - port: 3306
      targetPort: 3306
    clusterIP: None
  ```

- [x] 4.12.3.3 Create MySQL manifests for prod (same structure, different namespace)
  ```bash
  mkdir -p manifests/ghost-prod
  # Copy and modify namespace from ghost-dev to ghost-prod
  ```

- [x] 4.12.3.4 Deploy MySQL to both environments
  ```bash
  kubectl-homelab apply -f manifests/ghost-dev/mysql-statefulset.yaml
  kubectl-homelab apply -f manifests/ghost-dev/mysql-service.yaml
  kubectl-homelab apply -f manifests/ghost-prod/mysql-statefulset.yaml
  kubectl-homelab apply -f manifests/ghost-prod/mysql-service.yaml
  ```

- [x] 4.12.3.5 Verify MySQL is running
  ```bash
  kubectl-homelab get pods -n ghost-dev -l app=ghost-mysql
  kubectl-homelab get pods -n ghost-prod -l app=ghost-mysql
  ```

---

## 4.12.4 Deploy Ghost Deployments

- [x] 4.12.4.1 Create Ghost PVC for content (dev)
  ```yaml
  # manifests/ghost-dev/ghost-pvc.yaml
  apiVersion: v1
  kind: PersistentVolumeClaim
  metadata:
    name: ghost-content
    namespace: ghost-dev
  spec:
    accessModes:
    - ReadWriteOnce
    storageClassName: longhorn
    resources:
      requests:
        storage: 5Gi
  ```

- [x] 4.12.4.2 Create Ghost Deployment (dev)
  ```yaml
  # manifests/ghost-dev/ghost-deployment.yaml
  apiVersion: apps/v1
  kind: Deployment
  metadata:
    name: ghost
    namespace: ghost-dev
  spec:
    replicas: 1
    selector:
      matchLabels:
        app: ghost
    template:
      metadata:
        labels:
          app: ghost
      spec:
        # Wait for MySQL to be ready before starting Ghost
        initContainers:
        - name: wait-for-mysql
          image: busybox:1.36
          command: ['sh', '-c', 'until nc -z ghost-mysql 3306; do echo "Waiting for MySQL..."; sleep 2; done; echo "MySQL is ready!"']
        containers:
        - name: ghost
          image: ghost:6.14.0
          ports:
          - containerPort: 2368
          env:
          - name: url
            value: https://blog-dev.k8s.home.rommelporras.com
          # Database configuration
          - name: database__client
            value: mysql
          - name: database__connection__host
            value: ghost-mysql
          - name: database__connection__port
            value: "3306"
          - name: database__connection__user
            value: ghost
          - name: database__connection__password
            valueFrom:
              secretKeyRef:
                name: ghost-mysql
                key: user-password
          - name: database__connection__database
            value: ghost
          - name: database__connection__charset
            value: utf8mb4
          # Mail configuration (iCloud SMTP with STARTTLS)
          - name: mail__transport
            value: SMTP
          - name: mail__options__host
            valueFrom:
              secretKeyRef:
                name: ghost-mail
                key: smtp-host
          - name: mail__options__port
            value: "587"  # Hardcoded - Ghost expects number, secretKeyRef gives string
          - name: mail__options__secure
            value: "false"  # STARTTLS (port 587), not implicit TLS (port 465)
          - name: mail__options__auth__user
            valueFrom:
              secretKeyRef:
                name: ghost-mail
                key: smtp-user
          - name: mail__options__auth__pass
            valueFrom:
              secretKeyRef:
                name: ghost-mail
                key: smtp-password
          - name: mail__from
            valueFrom:
              secretKeyRef:
                name: ghost-mail
                key: from-address
          # Logging
          - name: logging__level
            value: info
          - name: logging__transports
            value: '["stdout"]'
          volumeMounts:
          - name: ghost-content
            mountPath: /var/lib/ghost/content
          resources:
            requests:
              memory: "512Mi"
              cpu: "100m"
            limits:
              memory: "1Gi"
              cpu: "500m"
          # Health probes
          livenessProbe:
            httpGet:
              path: /ghost/api/admin/site/
              port: 2368
            initialDelaySeconds: 60
            periodSeconds: 30
            timeoutSeconds: 10
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /ghost/api/admin/site/
              port: 2368
            initialDelaySeconds: 30
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 3
        volumes:
        - name: ghost-content
          persistentVolumeClaim:
            claimName: ghost-content
  ```

- [x] 4.12.4.3 Create Ghost Service (dev)
  ```yaml
  # manifests/ghost-dev/ghost-service.yaml
  apiVersion: v1
  kind: Service
  metadata:
    name: ghost
    namespace: ghost-dev
  spec:
    selector:
      app: ghost
    ports:
    - port: 2368
      targetPort: 2368
  ```

- [x] 4.12.4.4 Create Ghost manifests for prod
  ```yaml
  # manifests/ghost-prod/ghost-deployment.yaml
  # Same as dev, but change:
  #   - namespace: ghost-prod
  #   - url: https://blog.rommelporras.com
  ```

- [x] 4.12.4.5 Deploy Ghost to both environments
  ```bash
  kubectl-homelab apply -f manifests/ghost-dev/
  kubectl-homelab apply -f manifests/ghost-prod/
  ```

- [x] 4.12.4.6 Verify Ghost is running
  ```bash
  kubectl-homelab get pods -n ghost-dev -l app=ghost
  kubectl-homelab get pods -n ghost-prod -l app=ghost
  kubectl-homelab logs -n ghost-dev -l app=ghost --tail=50
  ```

---

## 4.12.5 Create HTTPRoutes and Cloudflare Tunnel

- [x] 4.12.5.1 Create HTTPRoute for dev (internal)
  ```yaml
  # manifests/ghost-dev/httproute.yaml
  apiVersion: gateway.networking.k8s.io/v1
  kind: HTTPRoute
  metadata:
    name: ghost
    namespace: ghost-dev
  spec:
    parentRefs:
    - name: homelab-gateway
      namespace: kube-system
    hostnames:
    - blog-dev.k8s.home.rommelporras.com
    rules:
    - matches:
      - path:
          type: PathPrefix
          value: /
      backendRefs:
      - name: ghost
        port: 2368
  ```

- [x] 4.12.5.2 Create HTTPRoute for prod (internal access)
  ```yaml
  # manifests/ghost-prod/httproute.yaml
  apiVersion: gateway.networking.k8s.io/v1
  kind: HTTPRoute
  metadata:
    name: ghost
    namespace: ghost-prod
  spec:
    parentRefs:
    - name: homelab-gateway
      namespace: kube-system
    hostnames:
    - blog.k8s.home.rommelporras.com
    rules:
    - matches:
      - path:
          type: PathPrefix
          value: /
      backendRefs:
      - name: ghost
        port: 2368
  ```

- [x] 4.12.5.3 Update Cloudflare Tunnel config for public prod access
  ```
  # Cloudflare Tunnel uses Dashboard configuration (token-based), not ConfigMap
  # Go to: Cloudflare Zero Trust → Networks → Tunnels → homelab → Public Hostname
  # Add new public hostname:
  #   Subdomain: blog
  #   Domain: rommelporras.com
  #   Type: HTTP
  #   URL: ghost.ghost-prod.svc.cluster.local:2368
  ```

- [x] 4.12.5.4 Apply HTTPRoutes
  ```bash
  kubectl-homelab apply -f manifests/ghost-dev/httproute.yaml
  kubectl-homelab apply -f manifests/ghost-prod/httproute.yaml
  # Note: No cloudflared restart needed - Cloudflare Dashboard changes are instant
  ```

- [x] 4.12.5.5 Add DNS record in Cloudflare (if not using wildcard)
  ```
  Type: CNAME
  Name: blog
  Target: <tunnel-id>.cfargotunnel.com
  Proxy: ON
  ```

- [x] 4.12.5.6 Verify access
  ```bash
  # Internal dev
  curl -I https://blog-dev.k8s.home.rommelporras.com

  # Public prod
  curl -I https://blog.rommelporras.com
  ```

---

## 4.12.5b Cloudflare Security — Block Public `/ghost` Admin Access

> **Why?** The `/ghost` path is the Ghost admin portal. Public access exposes the login page to brute force attacks.
> Internal access via `blog.k8s.home.rommelporras.com/ghost/` is unaffected (bypasses Cloudflare entirely).

### Approach: WAF Custom Rules (two ordered rules)

> **Why WAF over Cloudflare Access?** Access path precedence ("most specific path wins") has
> [known bugs](https://community.cloudflare.com/t/policy-inheritance-not-prioritizing-most-specific-path/820213)
> where broader rules override more specific ones. WAF custom rules evaluate in strict order —
> deterministic and reliable. Admin access is available internally via the `.home.rommelporras.com`
> domain, so external authenticated access is unnecessary.

#### Ghost `/ghost/*` path classification (from research):

| Path | Purpose | Public? |
|------|---------|---------|
| `/ghost/` | Admin panel (Ember.js SPA) | No — admin only |
| `/ghost/api/content/*` | Content API (search, headless frontends) | **Yes — required by Sodo Search** |
| `/ghost/api/admin/*` | Admin API (create posts, upload themes) | No — admin only |
| `/ghost/*` (all other) | Admin SPA assets (JS/CSS bundles) | No — admin only |

> **Note:** Hash routes (`/ghost/#/dashboard`) are never sent to the server — Cloudflare only
> sees `/ghost`. Portal/comments/membership use `/members/api/` (outside `/ghost/`), unaffected.

- [x] 4.12.5b.1 Create WAF Rule 1: Allow Ghost Content API
  ```
  Cloudflare Dashboard → Security → WAF → Custom Rules → Create Rule

  Rule name: Ghost - Allow Content API
  Expression (edit expression):
    (http.host eq "blog.rommelporras.com" and
     starts_with(http.request.uri.path, "/ghost/api/content"))

  Action: Skip → Skip all remaining custom rules

  Priority: This rule MUST be ordered ABOVE the block rule (Rule 2).

  Why: Ghost's Sodo Search widget calls /ghost/api/content/posts/,
       /ghost/api/content/tags/, and /ghost/api/content/authors/ from
       the browser. Blocking this breaks public site search.
       The Content API is read-only and requires a public API key parameter.
  ```

- [x] 4.12.5b.2 Create WAF Rule 2: Block Ghost Admin
  ```
  Cloudflare Dashboard → Security → WAF → Custom Rules → Create Rule

  Rule name: Ghost - Block Admin
  Expression (edit expression):
    (http.host eq "blog.rommelporras.com" and
     starts_with(http.request.uri.path, "/ghost"))

  Action: Block

  Priority: This rule MUST be ordered BELOW the skip rule (Rule 1).

  Why: Blocks /ghost/ (admin panel), /ghost/api/admin/ (Admin API),
       and all other /ghost/* paths (admin SPA assets).
       Content API traffic never reaches this rule because Rule 1 skips it.
  ```

- [x] 4.12.5b.3 Verify WAF protection
  ```bash
  # Should return 403 Forbidden (blocked by WAF)
  curl -sI https://blog.rommelporras.com/ghost/ | head -5

  # Should return 403 Forbidden (Admin API also blocked)
  curl -sI https://blog.rommelporras.com/ghost/api/admin/site/ | head -5

  # Should return 200 OK (Content API allowed through)
  curl -s https://blog.rommelporras.com/ghost/api/content/settings/?key=placeholder | head -5

  # Public blog should work normally
  curl -sI https://blog.rommelporras.com/ | head -5

  # Internal access still works directly (bypasses Cloudflare)
  curl -sI https://blog.k8s.home.rommelporras.com/ghost/ | head -5
  ```

### Rejected: Cloudflare Access approach

> Two Access apps (`/ghost/api` Bypass + `/ghost` Allow) was the original plan but rejected because:
> 1. Access path precedence has [known bugs](https://community.cloudflare.com/t/policy-inheritance-not-prioritizing-most-specific-path/820213) — broader rules sometimes override specific ones
> 2. Bypass policy on `/ghost/api` would expose the Admin API (`/ghost/api/admin/`) — only `/ghost/api/content/` should be public
> 3. Bypass disables audit logging — no visibility into API access
> 4. WAF rules evaluate in strict order — deterministic and debuggable

---

## 4.12.6 Create Theme Repo in GitLab

- [x] 4.12.6.1 Theme folder prepared
  ```bash
  # Created at ~/personal/eventually-consistent
  # Contains: CLAUDE.md, docker-compose.dev.yml, .gitlab-ci.yml,
  # Handlebars templates, CSS, JS, and all necessary files
  cd ~/personal/eventually-consistent
  ```

- [x] 4.12.6.2 Local development docker-compose (already created in ~/personal/eventually-consistent)

  Key configuration includes utf8mb4 charset and health checks:
  ```yaml
  # docker-compose.dev.yml (summary - full file in ~/personal/eventually-consistent)
  services:
    ghost:
      image: ghost:6.14.0
      environment:
        database__connection__charset: utf8mb4  # Required for emoji support
        logging__level: info
      healthcheck:
        test: ["CMD", "wget", "-q", "--spider", "http://localhost:2368/ghost/api/admin/site/"]

    mysql:
      image: mysql:8.4.8
      command:
        - --character-set-server=utf8mb4
        - --collation-server=utf8mb4_0900_ai_ci
  ```

- [x] 4.12.6.3 Create GitLab repo and push
  ```bash
  # GitLab: gitlab.k8s.home.rommelporras.com/0xwsh/eventually-consistent
  cd ~/personal/eventually-consistent
  git init -b main
  git remote add origin git@ssh.gitlab.k8s.home.rommelporras.com:0xwsh/eventually-consistent.git
  git remote add github git@github.com:rommelporras/eventually-consistent.git
  git add .
  git commit -m "feat: eventually-consistent Ghost theme"
  git push -u origin main
  git push -u github main
  git checkout -b develop
  git push -u origin develop
  git push -u github develop
  ```

---

## 4.12.7 Set Up GitLab CI/CD for Theme Deployment

> **Note:** Steps 4.12.7.1-4.12.7.2 require Ghost Admin access. Complete 4.12.10.3 first
> (initial Ghost setup), then return here to create API integrations.

- [x] 4.12.7.1 Create Ghost Admin API integrations (after Ghost Admin is accessible)
  ```
  1. Go to Ghost Admin → Settings → Integrations
  2. Create "GitLab CI/CD" integration (do this in BOTH dev and prod)
  3. Copy Admin API Key (format: id:secret)
  4. Store in 1Password:
     - Item: Ghost Dev Admin API (key field)
     - Item: Ghost Prod Admin API (key field)
  ```

- [x] 4.12.7.2 Add CI/CD variables in GitLab
  ```
  Settings → CI/CD → Variables:

  GHOST_DEV_URL = https://blog-dev.k8s.home.rommelporras.com
  GHOST_DEV_ADMIN_API_KEY = (from 1Password)
  GHOST_PROD_URL = https://blog.rommelporras.com
  GHOST_PROD_ADMIN_API_KEY = (from 1Password)
  ```

- [x] 4.12.7.3 Create .gitlab-ci.yml (already created in ~/personal/blog)

  **Important:** Ghost Admin API requires JWT authentication, not raw API keys.
  The pipeline generates a JWT token from the `id:secret` format API key.

  ```yaml
  # .gitlab-ci.yml (key parts - full file in ~/personal/blog)
  stages:
    - validate
    - build
    - deploy

  variables:
    THEME_NAME: eventually-consistent

  deploy-dev:
    stage: deploy
    image: alpine:3.19
    before_script:
      - apk add --no-cache curl openssl
    script:
      - |
        # Split API key into ID and SECRET
        KEY="${GHOST_DEV_ADMIN_API_KEY}"
        ID=$(echo "$KEY" | cut -d':' -f1)
        SECRET=$(echo "$KEY" | cut -d':' -f2)

        # Generate JWT token (required by Ghost Admin API)
        NOW=$(date +%s)
        EXP=$((NOW + 300))

        base64url() {
          openssl base64 -e -A | tr '+/' '-_' | tr -d '='
        }

        HEADER=$(printf '{"alg":"HS256","typ":"JWT","kid":"%s"}' "$ID" | base64url)
        PAYLOAD=$(printf '{"iat":%d,"exp":%d,"aud":"/admin/"}' "$NOW" "$EXP" | base64url)
        SIGNATURE=$(printf '%s.%s' "$HEADER" "$PAYLOAD" | \
          openssl dgst -sha256 -mac HMAC -macopt hexkey:"$SECRET" -binary | base64url)

        TOKEN="${HEADER}.${PAYLOAD}.${SIGNATURE}"

        # Upload theme with JWT token
        curl -X POST "${GHOST_DEV_URL}/ghost/api/admin/themes/upload/" \
          -H "Authorization: Ghost ${TOKEN}" \
          -H "Accept-Version: v5.0" \
          -F "file=@dist/${THEME_NAME}.zip"
    rules:
      - if: $CI_COMMIT_BRANCH == "develop"
  ```

- [x] 4.12.7.4 Add npm scripts for theme building
  ```json
  // package.json (add to scripts)
  {
    "scripts": {
      "zip": "npm run build && zip -r dist/eventually-consistent.zip . -x 'node_modules/*' -x '.git/*' -x 'dist/*'"
    }
  }
  ```

---

## 4.12.8 Set Up GitHub Mirror

> **Approach changed:** Instead of GitLab push mirror, using dual-remote setup with `/push` command.
> This gives explicit control over when both remotes are updated.

- [x] 4.12.8.1 Create public GitHub repo
  ```
  github.com/rommelporras/eventually-consistent (public)
  ```

- [x] 4.12.8.2 Configure dual-remote (replaced GitLab push mirror)
  ```bash
  # Remotes configured in 4.12.6.3:
  # origin → GitLab (primary, CI/CD)
  # github → GitHub (public mirror/showcase)
  #
  # Use /push command to push current branch to both remotes
  # Use /release command for full GitFlow release to both remotes
  ```

- [x] 4.12.8.3 Verify mirror sync — both remotes in sync at v1.0.0

---

## 4.12.9 Create Database Sync Script

- [x] 4.12.9.1 Create sync script
  ```bash
  # scripts/sync-ghost-prod-to-dev.sh
  #!/bin/bash
  set -euo pipefail

  # Sync Ghost production database and content to dev environment
  # Usage: ./scripts/sync-ghost-prod-to-dev.sh

  PROD_NS="ghost-prod"
  DEV_NS="ghost-dev"
  BACKUP_DIR="/tmp/ghost-backup-$(date +%Y%m%d-%H%M%S)"

  echo "=== Ghost Prod → Dev Sync ==="
  echo "Backup directory: ${BACKUP_DIR}"
  mkdir -p "${BACKUP_DIR}"

  # 1. Dump production database
  echo "Dumping production database..."
  kubectl-homelab exec -n ${PROD_NS} ghost-mysql-0 -- \
    mysqldump -u ghost -p"$(kubectl-homelab get secret -n ${PROD_NS} ghost-mysql -o jsonpath='{.data.user-password}' | base64 -d)" \
    ghost > "${BACKUP_DIR}/ghost.sql"

  # 2. Copy production content (images, themes)
  echo "Copying production content..."
  PROD_POD=$(kubectl-homelab get pod -n ${PROD_NS} -l app=ghost -o jsonpath='{.items[0].metadata.name}')
  kubectl-homelab cp ${PROD_NS}/${PROD_POD}:/var/lib/ghost/content "${BACKUP_DIR}/content"

  # 3. Scale down dev Ghost
  echo "Scaling down dev Ghost..."
  kubectl-homelab scale deployment ghost -n ${DEV_NS} --replicas=0
  sleep 5

  # 4. Import database to dev
  echo "Importing database to dev..."
  kubectl-homelab exec -i -n ${DEV_NS} ghost-mysql-0 -- \
    mysql -u ghost -p"$(kubectl-homelab get secret -n ${DEV_NS} ghost-mysql -o jsonpath='{.data.user-password}' | base64 -d)" \
    ghost < "${BACKUP_DIR}/ghost.sql"

  # 5. Update URL in dev database
  echo "Updating site URL in dev database..."
  kubectl-homelab exec -n ${DEV_NS} ghost-mysql-0 -- \
    mysql -u ghost -p"$(kubectl-homelab get secret -n ${DEV_NS} ghost-mysql -o jsonpath='{.data.user-password}' | base64 -d)" \
    -e "UPDATE ghost.settings SET value='https://blog-dev.k8s.home.rommelporras.com' WHERE \`key\`='url';" \
    ghost

  # 6. Copy content to dev pod (after scaling up)
  echo "Scaling up dev Ghost..."
  kubectl-homelab scale deployment ghost -n ${DEV_NS} --replicas=1
  kubectl-homelab wait --for=condition=ready pod -l app=ghost -n ${DEV_NS} --timeout=120s

  DEV_POD=$(kubectl-homelab get pod -n ${DEV_NS} -l app=ghost -o jsonpath='{.items[0].metadata.name}')
  echo "Copying content to dev..."
  kubectl-homelab cp "${BACKUP_DIR}/content" ${DEV_NS}/${DEV_POD}:/var/lib/ghost/content

  # 7. Restart dev Ghost to pick up changes
  echo "Restarting dev Ghost..."
  kubectl-homelab rollout restart deployment ghost -n ${DEV_NS}

  echo "=== Sync complete! ==="
  echo "Backup retained at: ${BACKUP_DIR}"
  echo "Dev URL: https://blog-dev.k8s.home.rommelporras.com"
  ```

- [x] 4.12.9.2 Create local sync script
  ```bash
  # scripts/sync-ghost-prod-to-local.sh
  #!/bin/bash
  set -euo pipefail

  # Sync Ghost production to local docker-compose
  # Usage: ./scripts/sync-ghost-prod-to-local.sh <theme-repo-path>

  THEME_PATH="${1:-$HOME/personal/eventually-consistent}"
  PROD_NS="ghost-prod"
  BACKUP_DIR="/tmp/ghost-backup-$(date +%Y%m%d-%H%M%S)"

  echo "=== Ghost Prod → Local Sync ==="
  mkdir -p "${BACKUP_DIR}"

  # 1. Dump production database
  echo "Dumping production database..."
  kubectl-homelab exec -n ${PROD_NS} ghost-mysql-0 -- \
    mysqldump -u ghost -p"$(kubectl-homelab get secret -n ${PROD_NS} ghost-mysql -o jsonpath='{.data.user-password}' | base64 -d)" \
    ghost > "${BACKUP_DIR}/ghost.sql"

  # 2. Copy to theme repo
  cp "${BACKUP_DIR}/ghost.sql" "${THEME_PATH}/backup/"

  echo "=== Database dumped to ${THEME_PATH}/backup/ghost.sql ==="
  echo ""
  echo "To restore locally:"
  echo "  cd ${THEME_PATH}"
  echo "  docker compose -f docker-compose.dev.yml up -d mysql"
  echo "  docker compose -f docker-compose.dev.yml exec mysql mysql -u ghost -pghost ghost < backup/ghost.sql"
  echo "  # Update URL for local (note: backticks around 'key' - it's a MySQL reserved word):"
  echo "  docker compose -f docker-compose.dev.yml exec mysql mysql -u ghost -pghost -e \"UPDATE settings SET value='http://localhost:2368' WHERE \\\`key\\\`='url';\" ghost"
  echo "  docker compose -f docker-compose.dev.yml up -d ghost"
  ```

- [x] 4.12.9.3 Make scripts executable
  ```bash
  chmod +x scripts/sync-ghost-prod-to-dev.sh
  chmod +x scripts/sync-ghost-prod-to-local.sh
  ```

---

## 4.12.10 Verification & Smoke Tests

- [x] 4.12.10.1 Verify MySQL connectivity — confirmed by Ghost running successfully in both environments

- [x] 4.12.10.2 Verify Ghost health — confirmed by Ghost Admin accessible and blog serving traffic in both environments

- [x] 4.12.10.3 Access Ghost Admin and complete setup (dev + prod done)
  ```
  Dev: https://blog-dev.k8s.home.rommelporras.com/ghost/
  Prod: https://blog.rommelporras.com/ghost/

  1. Create admin account (first-time setup wizard)
  2. Set site title, description
  3. Upload default Casper theme if needed

  IMPORTANT: After this step, go back to 4.12.7.1 to create Admin API integrations
  ```

- [x] 4.12.10.4 Test theme deployment pipeline (dev pipeline passed)
  ```bash
  cd ~/personal/eventually-consistent
  # On develop branch, make changes, then:
  # /commit → /push → verify theme deploys to dev
  ```

- [x] 4.12.10.5 Test mail delivery — confirmed working (2FA emails and admin account creation)

- [~] 4.12.10.6 Database sync scripts — ready but untested (fixed path: `blog` → `eventually-consistent`)
  ```bash
  # Scripts prepared and reviewed, not yet run:
  ./scripts/sync-ghost-prod-to-dev.sh    # Prod → Dev (K8s)
  ./scripts/sync-ghost-prod-to-local.sh  # Prod → Local (Docker)
  ```

---

## 4.12.11 Documentation Updates

- [x] 4.12.11.1 Update VERSIONS.md
  ```markdown
  ## Home Services (Phase 4)

  | Component | Version | Status | Notes |
  |-----------|---------|--------|-------|
  | Ghost (Dev) | v6.14.0 | Running | Theme development |
  | Ghost (Prod) | v6.14.0 | Running | Public blog |
  | MySQL (Ghost) | 8.4.8 | Running | Per-environment databases (LTS) |

  **HTTPRoutes:**
  | Service | URL | Namespace |
  |---------|-----|-----------|
  | Ghost Dev | blog-dev.k8s.home.rommelporras.com | ghost-dev |
  | Ghost Prod | blog.rommelporras.com (Cloudflare) | ghost-prod |
  ```

- [x] 4.12.11.2 Update docs/context/Secrets.md
  ```markdown
  | Item | Fields | Used By |
  |------|--------|---------|
  | Ghost Dev MySQL | root-password, user-password | ghost-dev MySQL |
  | Ghost Prod MySQL | root-password, user-password | ghost-prod MySQL |
  | Ghost Dev Admin API | key | GitLab CI/CD theme deploy |
  | Ghost Prod Admin API | key | GitLab CI/CD theme deploy |
  | Ghost Mail | smtp-host, smtp-user, smtp-password, from-address | Ghost email |
  ```

- [x] 4.12.11.3 Update docs/reference/CHANGELOG.md
  - Add Phase 4.12 section with decisions and learnings

- [x] 4.12.11.4 Update Homepage dashboard — added Blog (Dev) and Blog (Prod) to Apps section
  ```yaml
  # Add Ghost to services.yaml
  - Ghost Blog:
      icon: ghost.png
      href: https://blog.rommelporras.com
      description: Personal blog
  ```

---

## Verification Checklist

- [x] `ghost-dev` and `ghost-prod` namespaces exist
- [x] MySQL StatefulSets running (1 pod each)
- [x] Ghost Deployments running (1 pod each)
- [x] PVCs bound (ghost-content + mysql-data per environment)
- [x] HTTPRoutes resolving internally
- [x] Cloudflare Tunnel routing `blog.rommelporras.com` to prod
- [x] WAF rules protecting `/ghost` admin path (public)
- [x] Ghost Admin accessible and setup complete (dev + prod done)
- [x] Theme repo exists in GitLab
- [x] GitLab CI/CD variables configured (dev + prod done)
- [x] Theme deploys on push to develop (dev pipeline passed)
- [x] GitHub mirror syncing (dual-remote, both at v1.0.0)
- [x] Mail delivery working (2FA + admin account creation)
- [~] Database sync scripts ready (untested)

---

## Rollback

If issues occur:

```bash
# 1. Scale down Ghost (stops traffic)
kubectl-homelab scale deployment ghost -n ghost-dev --replicas=0
kubectl-homelab scale deployment ghost -n ghost-prod --replicas=0

# 2. Delete deployments if needed
kubectl-homelab delete -f manifests/ghost-dev/
kubectl-homelab delete -f manifests/ghost-prod/

# 3. Delete PVCs (WARNING: data loss)
kubectl-homelab delete pvc -n ghost-dev --all
kubectl-homelab delete pvc -n ghost-prod --all

# 4. Delete namespaces (full cleanup)
kubectl-homelab delete namespace ghost-dev ghost-prod

# 5. Remove Cloudflare Tunnel config
# Go to Cloudflare Zero Trust Dashboard → Networks → Tunnels → homelab
# Delete the blog.rommelporras.com public hostname
```

---

## Troubleshooting

### Ghost won't start

```bash
# Check logs
kubectl-homelab logs -n ghost-dev -l app=ghost --tail=100

# Common issues:
# - MySQL not ready: wait for MySQL pod to be Running
# - Wrong database password: verify secret matches
# - URL mismatch: ensure env.url matches HTTPRoute hostname
```

### MySQL connection refused

```bash
# Verify MySQL is running
kubectl-homelab get pods -n ghost-dev -l app=ghost-mysql

# Test connectivity from Ghost pod
kubectl-homelab exec -n ghost-dev -l app=ghost -- nc -zv ghost-mysql 3306
```

### Theme not deploying via CI/CD

```bash
# Check GitLab CI/CD job logs
# Common issues:
# - Invalid Admin API key: regenerate in Ghost Admin
# - Wrong URL: ensure GHOST_DEV_URL/GHOST_PROD_URL correct
# - Theme zip not found: check build stage artifacts
```

### Mail not sending

```bash
# Test SMTP connectivity from Ghost pod
kubectl-homelab exec -n ghost-prod -l app=ghost -- nc -zv smtp.mail.me.com 587

# Check Ghost logs for mail errors
kubectl-homelab logs -n ghost-prod -l app=ghost | grep -i mail
```

---

## Files to Create

```
manifests/ghost-dev/
├── namespace.yaml
├── mysql-statefulset.yaml
├── mysql-service.yaml
├── ghost-deployment.yaml
├── ghost-service.yaml
├── ghost-pvc.yaml
└── httproute.yaml

manifests/ghost-prod/
├── namespace.yaml
├── mysql-statefulset.yaml
├── mysql-service.yaml
├── ghost-deployment.yaml
├── ghost-service.yaml
├── ghost-pvc.yaml
└── httproute.yaml

scripts/
├── sync-ghost-prod-to-dev.sh
└── sync-ghost-prod-to-local.sh

# In separate theme repo (~/personal/eventually-consistent):
eventually-consistent/
├── .gitlab-ci.yml
├── docker-compose.dev.yml
├── package.json
├── CLAUDE.md
├── README.md
└── eventually-consistent/    # Ghost theme (forked from Dawn)
```

---

## References

- [Ghost Documentation](https://docs.ghost.org/)
- [Ghost Docker Installation](https://docs.ghost.org/install/docker/)
- [Ghost Admin API Authentication](https://docs.ghost.org/admin-api/) - JWT token required
- [Ghost Theme Upload via Admin API](https://www.autodidacts.io/ghost-theme-upload-admin-api-bash-curl/) - Working JWT example
- [Ghost Configuration Options](https://docs.ghost.org/config/)
- [Ghost Hosting Recommendations](https://docs.ghost.org/hosting/) - 1GB memory minimum
- [MySQL utf8mb4 for Ghost](https://github.com/TryGhost/Ghost/issues/5945) - Character set config
- [Casper Theme](https://github.com/TryGhost/Casper)
- [Ghost 6.0 Changelog](https://ghost.org/changelog/6-0/)

---

## Notes for Theme Agent

When customizing the theme:

1. **Local development:** Run `docker compose -f docker-compose.dev.yml up`
2. **Live reload:** Edit files, run `gulp build` + restart Ghost, refresh browser
3. **Test with real content:** Use `sync-ghost-prod-to-local.sh` to get production data
4. **Commit:** Use `/commit` for conventional commit messages
5. **Deploy to dev:** Use `/push` to push `develop` to both remotes → CI/CD deploys automatically
6. **Deploy to prod:** Use `/release` for full GitFlow release (develop→main merge, tag, gh release)

**Theme structure:**
- `*.hbs` - Handlebars templates (index, post, page, etc.)
- `assets/css/` - Stylesheets
- `assets/js/` - JavaScript
- `partials/` - Reusable template components
- `package.json` - Theme metadata and build scripts

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
  mv docs/todo/phase-4.12-ghost-blog.md docs/todo/completed/
  ```
