# Phase 4.11: Uptime Kuma Monitoring

> **Status:** Planned
> **Target:** v0.12.0
> **Prerequisite:** Phase 4.12 complete (Ghost Blog)
> **DevOps Topics:** Uptime monitoring, status pages, synthetic monitoring
> **CKA Topics:** StatefulSet, PersistentVolumeClaim, HTTPRoute, SecurityContext

> **Purpose:** Self-hosted uptime monitoring for personal and work-related endpoints
> **Alternative to:** UptimeRobot (SaaS, paid for advanced features)
> **Features:** HTTP(s)/TCP/Ping monitoring, status pages, notifications, 90-second intervals

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                          Uptime Kuma                                │
│                                                                     │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │ Monitors:                                                    │   │
│  │ - Personal: rommelporras.com, blog, portfolio               │   │
│  │ - Work: internal tools, APIs, dashboards                    │   │
│  │ - Homelab: Grafana, AdGuard, Homepage, Longhorn            │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                              │                                      │
│                              ▼                                      │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │ Notifications:                                               │   │
│  │ - Discord #incidents (reuse existing webhook)                │   │
│  │ - Email (optional, reuse iCloud SMTP)                        │   │
│  │ - Push notifications (Ntfy, Pushover)                        │   │
│  └─────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│              K8s Cluster (uptime-kuma namespace)                    │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │  StatefulSet (1 replica)                                    │   │
│  │  - Image: louislam/uptime-kuma:2.0.2-slim-rootless              │   │
│  │  - SecurityContext (non-root, capabilities dropped)         │   │
│  │  - PVC for SQLite database (Longhorn)                       │   │
│  └─────────────────────────────────────────────────────────────┘   │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │  HTTPRoute: uptime.k8s.home.rommelporras.com                │   │
│  └─────────────────────────────────────────────────────────────┘   │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │  (Optional) Cloudflare Tunnel: status.rommelporras.com      │   │
│  │  - Public status page for personal sites                    │   │
│  └─────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Why Uptime Kuma?

| Feature | UptimeRobot (Free) | Uptime Kuma |
|---------|-------------------|-------------|
| Monitor count | 50 | Unlimited |
| Check interval | 5 minutes | 20 seconds (min) |
| Status pages | 1 (public) | Unlimited |
| Notifications | Limited | 90+ integrations |
| Data retention | 2 months | Unlimited (self-hosted) |
| Cost | Free / $7/mo | Free (self-hosted) |
| Privacy | Third-party | Self-hosted |

**Decision:** Self-host Uptime Kuma for unlimited monitors, faster intervals, and data ownership.

### Image Variant Selection

| Tag | Size | Root | Embedded MariaDB | Embedded Chromium |
|-----|------|------|-----------------|-------------------|
| `2` | ~800MB | Yes | Yes | Yes |
| `2-slim` | ~400MB | Yes | No | No |
| `2-rootless` | ~800MB | No (UID 1000) | Yes | Yes |
| **`2-slim-rootless`** | **~400MB** | **No (UID 1000)** | **No** | **No** |

**Decision:** Use `2-slim-rootless` — smallest image, runs as non-root natively (matches
`restricted` PSS), no unused embedded services. We use SQLite (not MariaDB) and don't
need browser-engine monitors.

### v2.0 Breaking Changes (from v1)

- MariaDB support added (optional, we use SQLite)
- Rootless Docker image variants available
- **JSON Backup/Restore removed** — back up `/app/data` directory directly
- Badge endpoints only accept: `24`, `24h`, `30d`, `1y`
- Legacy browser support dropped

---

## Monitoring Categories

### Personal Sites

| Endpoint | Type | Check Interval | Notes |
|----------|------|----------------|-------|
| rommelporras.com | HTTPS | 60s | Portfolio main site |
| blog.rommelporras.com | HTTPS | 60s | Blog (if exists) |
| status.rommelporras.com | HTTPS | 60s | Public status page (self-check) |

### Work-Related

| Endpoint | Type | Check Interval | Notes |
|----------|------|----------------|-------|
| (Add your work URLs) | HTTPS | 60s | Internal tools |
| (Add your work URLs) | HTTPS | 60s | APIs |

> **Note:** For work URLs, consider if monitoring from home network is appropriate.
> Some work URLs may only be accessible via VPN or Tailscale.

### Homelab Services (Internal)

| Endpoint | Type | Check Interval | Notes |
|----------|------|----------------|-------|
| grafana.k8s.home.rommelporras.com | HTTPS | 60s | Monitoring dashboard |
| adguard.k8s.home.rommelporras.com | HTTPS | 60s | DNS admin |
| portal.k8s.home.rommelporras.com | HTTPS | 60s | Homepage dashboard |
| longhorn.k8s.home.rommelporras.com | HTTPS | 60s | Storage dashboard |
| healthchecks.io ping | HTTP | 60s | Dead man's switch (verify it's being pinged) |

---

## 4.11.1 Create Namespace

- [ ] 4.11.1.1 Create namespace with restricted PSS
  ```bash
  kubectl-homelab create namespace uptime-kuma
  kubectl-homelab label namespace uptime-kuma pod-security.kubernetes.io/enforce=restricted
  ```

- [ ] 4.11.1.2 Verify namespace created
  ```bash
  kubectl-homelab get namespace uptime-kuma -o yaml | grep -A2 labels
  # Should show pod-security.kubernetes.io/enforce: restricted
  ```

---

## 4.11.2 Create Manifests Directory

- [ ] 4.11.2.1 Create manifests directory
  ```bash
  mkdir -p manifests/uptime-kuma
  ```

> **Note:** PVC is managed via `volumeClaimTemplates` in the StatefulSet (4.11.3.1).
> This is the idiomatic StatefulSet pattern — Kubernetes auto-creates and binds the PVC
> when the StatefulSet is applied. No separate PVC manifest needed.

---

## 4.11.3 Deploy Uptime Kuma

- [ ] 4.11.3.1 Create StatefulSet manifest
  ```yaml
  # manifests/uptime-kuma/statefulset.yaml
  # StatefulSet for persistent SQLite database (single replica only)
  # Uses slim-rootless image: no embedded MariaDB/Chromium, runs as node (UID 1000)
  #
  apiVersion: apps/v1
  kind: StatefulSet
  metadata:
    name: uptime-kuma
    namespace: uptime-kuma
    labels:
      app: uptime-kuma
  spec:
    serviceName: uptime-kuma
    replicas: 1
    selector:
      matchLabels:
        app: uptime-kuma
    template:
      metadata:
        labels:
          app: uptime-kuma
      spec:
        # Security: Run as non-root (matches rootless image UID 1000)
        securityContext:
          runAsNonRoot: true
          runAsUser: 1000
          runAsGroup: 1000
          fsGroup: 1000
          seccompProfile:
            type: RuntimeDefault
        containers:
        - name: uptime-kuma
          # slim-rootless: ~400MB smaller (no MariaDB/Chromium), runs as node user
          # Pinned to 2.0.2 for reproducibility; bump manually when upgrading
          image: louislam/uptime-kuma:2.0.2-slim-rootless
          ports:
          - name: http
            containerPort: 3001
            protocol: TCP
          env:
          - name: UPTIME_KUMA_PORT
            value: "3001"
          volumeMounts:
          - name: data
            mountPath: /app/data
          resources:
            requests:
              memory: "128Mi"
              cpu: "100m"
            limits:
              memory: "512Mi"
              cpu: "500m"
          # Container security context
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
          # Startup probe: allows up to 5 min for first-boot DB migrations
          # Once startup succeeds, liveness takes over with aggressive checks
          startupProbe:
            httpGet:
              path: /
              port: 3001
            periodSeconds: 10
            failureThreshold: 30
          # Liveness: restart if unresponsive (only active after startup succeeds)
          livenessProbe:
            httpGet:
              path: /
              port: 3001
            periodSeconds: 10
            failureThreshold: 3
          # Readiness: remove from service if temporarily unhealthy
          readinessProbe:
            httpGet:
              path: /
              port: 3001
            periodSeconds: 5
            failureThreshold: 2
    # Use volumeClaimTemplates (idiomatic StatefulSet pattern)
    volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes:
          - ReadWriteOnce
        storageClassName: longhorn
        resources:
          requests:
            storage: 1Gi
  ```

- [ ] 4.11.3.2 Create Service
  ```yaml
  # manifests/uptime-kuma/service.yaml
  apiVersion: v1
  kind: Service
  metadata:
    name: uptime-kuma
    namespace: uptime-kuma
    labels:
      app: uptime-kuma
  spec:
    selector:
      app: uptime-kuma
    ports:
    - name: http
      port: 3001
      targetPort: 3001
      protocol: TCP
  ```

- [ ] 4.11.3.3 Create HTTPRoute for internal access
  ```yaml
  # manifests/uptime-kuma/httproute.yaml
  apiVersion: gateway.networking.k8s.io/v1
  kind: HTTPRoute
  metadata:
    name: uptime-kuma
    namespace: uptime-kuma
  spec:
    parentRefs:
    - name: homelab-gateway
      namespace: default
    hostnames:
    - "uptime.k8s.home.rommelporras.com"
    rules:
    - matches:
      - path:
          type: PathPrefix
          value: /
      backendRefs:
      - name: uptime-kuma
        port: 3001
  ```

- [ ] 4.11.3.4 Apply all manifests
  ```bash
  kubectl-homelab apply -f manifests/uptime-kuma/
  ```

- [ ] 4.11.3.5 Wait for pod to be ready
  ```bash
  kubectl-homelab rollout status statefulset/uptime-kuma -n uptime-kuma --timeout=300s
  ```

- [ ] 4.11.3.6 Verify PVC auto-created and bound
  ```bash
  kubectl-homelab get pvc -n uptime-kuma
  # Should show: data-uptime-kuma-0  Bound  (auto-created by volumeClaimTemplates)
  ```

- [ ] 4.11.3.7 Check pod logs
  ```bash
  kubectl-homelab logs -n uptime-kuma -l app=uptime-kuma --tail=50
  # Look for: "Listening on 3001"
  ```

---

## 4.11.4 Configure DNS

- [ ] 4.11.4.1 Add DNS record in AdGuard
  ```
  # AdGuard Home → Filters → DNS rewrites
  # Add: uptime.k8s.home.rommelporras.com → 10.10.30.20
  ```

- [ ] 4.11.4.2 Verify DNS resolution
  ```bash
  nslookup uptime.k8s.home.rommelporras.com 10.10.30.55
  # Should resolve to 10.10.30.20 (Gateway IP)
  ```

- [ ] 4.11.4.3 Access Uptime Kuma UI
  ```
  https://uptime.k8s.home.rommelporras.com
  ```

---

## 4.11.5 Initial Setup

- [ ] 4.11.5.1 Create admin account
  ```
  # First access prompts for admin account creation
  # Username: admin (or your preference)
  # Password: Store in 1Password
  ```

- [ ] 4.11.5.2 Store credentials in 1Password
  ```bash
  op item create \
    --category=login \
    --vault="Kubernetes" \
    --title="Uptime Kuma" \
    "username=admin" \
    "password=<your-password>"
  ```

- [ ] 4.11.5.3 Configure general settings
  ```
  Settings → General:
  - Primary Base URL: https://uptime.k8s.home.rommelporras.com
  - Check update: Disabled (managed via K8s image tag)
  ```

---

## 4.11.6 Configure Notifications

> **Reuse existing notification channels from Alertmanager.**

- [ ] 4.11.6.1 Add Discord notification
  ```
  Settings → Notifications → Setup Notification:
  - Notification Type: Discord
  - Friendly Name: Discord Incidents
  - Discord Webhook URL: (from 1Password: Discord Webhook Incidents)
  - Test → Should receive test message
  ```

- [ ] 4.11.6.2 (Optional) Add Email notification
  ```
  Settings → Notifications → Setup Notification:
  - Notification Type: SMTP
  - Friendly Name: Email Critical
  - SMTP Host: smtp.mail.me.com
  - SMTP Port: 587
  - SMTP Security: STARTTLS
  - SMTP Username: (from 1Password: iCloud SMTP/username)
  - SMTP Password: (from 1Password: iCloud SMTP/password)
  - From Email: noreply@rommelporras.com
  - To Email: critical@rommelporras.com
  ```

---

## 4.11.7 Add Monitors

### Personal Sites

- [ ] 4.11.7.1 Add rommelporras.com
  ```
  Add New Monitor:
  - Monitor Type: HTTP(s)
  - Friendly Name: rommelporras.com
  - URL: https://rommelporras.com
  - Heartbeat Interval: 60 seconds
  - Retries: 3
  - Notification: Discord Incidents
  ```

### Homelab Services

- [ ] 4.11.7.2 Add Grafana
  ```
  Add New Monitor:
  - Monitor Type: HTTP(s) - Keyword
  - Friendly Name: Grafana
  - URL: https://grafana.k8s.home.rommelporras.com
  - Keyword: Grafana
  - Heartbeat Interval: 60 seconds
  - Notification: Discord Incidents
  ```

- [ ] 4.11.7.3 Add AdGuard
  ```
  Add New Monitor:
  - Monitor Type: HTTP(s)
  - Friendly Name: AdGuard DNS
  - URL: https://adguard.k8s.home.rommelporras.com
  - Heartbeat Interval: 60 seconds
  - Notification: Discord Incidents
  ```

- [ ] 4.11.7.4 Add Homepage
  ```
  Add New Monitor:
  - Monitor Type: HTTP(s)
  - Friendly Name: Homepage Dashboard
  - URL: https://portal.k8s.home.rommelporras.com
  - Heartbeat Interval: 60 seconds
  - Notification: Discord Incidents
  ```

- [ ] 4.11.7.5 Add Longhorn
  ```
  Add New Monitor:
  - Monitor Type: HTTP(s)
  - Friendly Name: Longhorn Storage
  - URL: https://longhorn.k8s.home.rommelporras.com
  - Heartbeat Interval: 60 seconds
  - Notification: Discord Incidents
  ```

### Work-Related (Add your own)

- [ ] 4.11.7.6 Add work monitors as needed
  ```
  # Example:
  Add New Monitor:
  - Monitor Type: HTTP(s)
  - Friendly Name: Work Tool X
  - URL: https://internal-tool.company.com
  - Heartbeat Interval: 60 seconds
  ```

---

## 4.11.8 Create Public Status Page (Optional)

> **Expose a public status page for personal sites via Cloudflare Tunnel.**
> The admin dashboard (`/dashboard`) is blocked at the Cloudflare edge —
> only the status page path is publicly accessible.

- [ ] 4.11.8.1 Create status page in Uptime Kuma UI
  ```
  Status Pages → New Status Page:
  - Title: Rommel Porras Services
  - Slug: status
  - Add monitors: rommelporras.com, blog, etc.
  # Status page will be at: /status/status
  ```

- [ ] 4.11.8.2 Configure Cloudflare Tunnel route
  ```
  # Cloudflare Zero Trust → Networks → Tunnels → homelab tunnel → Public Hostname:
  # Add public hostname: status.rommelporras.com
  # Service: http://uptime-kuma.uptime-kuma.svc.cluster.local:3001
  ```

- [ ] 4.11.8.3 Create Cloudflare Access policy to block admin paths
  ```
  # Cloudflare Zero Trust → Access → Applications → Add an application:
  #
  # Application name: Uptime Kuma Admin Block
  # Application domain: status.rommelporras.com
  # Path: /dashboard
  #
  # Policy name: Block Public
  # Action: Block
  # Include: Everyone
  #
  # This blocks /dashboard (admin UI) at the Cloudflare edge.
  # Only /status/* (public status page) is accessible to the internet.
  ```

- [ ] 4.11.8.4 Verify public access
  ```bash
  # Status page should load:
  curl -I https://status.rommelporras.com/status/status
  # Expected: 200 OK

  # Admin dashboard should be blocked:
  curl -I https://status.rommelporras.com/dashboard
  # Expected: 403 Forbidden (blocked by Cloudflare Access)
  ```

---

## 4.11.9 Backup Strategy

> **SQLite database should be backed up regularly.**

- [ ] 4.11.9.1 Longhorn handles storage replication (2x)
  ```bash
  # Verify Longhorn volume replication
  kubectl-homelab -n longhorn-system get volumes.longhorn.io | grep uptime-kuma
  ```

- [ ] 4.11.9.2 (Optional) Enable Longhorn snapshots
  ```bash
  # Create recurring snapshot job in Longhorn UI
  # Longhorn → Volume → uptime-kuma-data → Recurring Jobs
  # Schedule: Daily at 2am
  # Retain: 7 snapshots
  ```

- [ ] 4.11.9.3 (Optional) Manual backup of data directory
  ```bash
  # JSON export was removed in v2.0. Back up the /app/data directory directly.
  # Copy SQLite DB from pod to local machine:
  kubectl-homelab cp uptime-kuma/uptime-kuma-0:/app/data/kuma.db ./kuma-backup-$(date +%F).db
  ```

---

## 4.11.10 Commit Deployment

> **First commit: manifests and configuration only.**

- [ ] 4.11.10.1 Commit deployment changes
  ```bash
  /commit
  ```

---

## 4.11.11 Documentation and Audit

> **Second commit: documentation updates and audit.**

- [ ] 4.11.11.1 Update VERSIONS.md
  ```markdown
  # Add to Home Services section:
  | Uptime Kuma | v2.0.2 (slim-rootless) | Running | Self-hosted uptime monitoring |

  # Add to Version History:
  | YYYY-MM-DD | Phase 4.11: Uptime Kuma deployed for endpoint monitoring |
  ```

- [ ] 4.11.11.2 Update docs/context/Secrets.md
  ```markdown
  # Add 1Password item:
  | Uptime Kuma | `username`, `password` | Uptime Kuma admin login |

  # Add 1Password path:
  op://Kubernetes/Uptime Kuma/username
  op://Kubernetes/Uptime Kuma/password
  ```

- [ ] 4.11.11.3 Update docs/context/Monitoring.md
  ```markdown
  # Add to Components table:
  | Uptime Kuma | v2.0.2 | uptime-kuma |

  # Add Access URL:
  | Uptime Kuma | https://uptime.k8s.home.rommelporras.com |
  ```

- [ ] 4.11.11.4 Update README.md
  ```markdown
  # Add Uptime Kuma to services list and architecture overview
  ```

- [ ] 4.11.11.5 Create rebuild guide
  ```bash
  # docs/rebuild/v0.12.0-uptime-kuma.md
  # Step-by-step rebuild instructions for disaster recovery
  ```

- [ ] 4.11.11.6 Run audit-docs
  ```bash
  /audit-docs
  ```

- [ ] 4.11.11.7 Commit documentation changes
  ```bash
  /commit
  ```

---

## Verification Checklist

- [ ] Namespace `uptime-kuma` exists with **restricted** PSS
- [ ] PVC `data-uptime-kuma-0` auto-created and bound to Longhorn volume
- [ ] StatefulSet running with 1 replica (image: `2.0.2-slim-rootless`)
- [ ] Pod running as non-root (UID 1000)
- [ ] HTTPRoute accessible: https://uptime.k8s.home.rommelporras.com
- [ ] Admin account created and stored in 1Password
- [ ] Discord notification configured and tested
- [ ] Monitors added for personal sites
- [ ] Monitors added for homelab services
- [ ] (Optional) Status page created
- [ ] Documentation updated (VERSIONS.md, Secrets.md, Monitoring.md)

---

## Troubleshooting

### Pod won't start (CrashLoopBackOff)

```bash
# Check logs
kubectl-homelab logs -n uptime-kuma -l app=uptime-kuma

# Check events
kubectl-homelab get events -n uptime-kuma --sort-by='.lastTimestamp'

# Common issues:
# - PVC not bound → check Longhorn status
# - Permission denied → ensure using slim-rootless image (not default root image)
# - Startup timeout → first boot runs DB migrations, may need up to 5 min
```

### Database locked error

```bash
# SQLite can lock if multiple processes try to write
# Uptime Kuma should only have 1 replica

# If persists, restart the pod
kubectl-homelab rollout restart statefulset/uptime-kuma -n uptime-kuma
```

### Monitors showing as "Pending"

```bash
# Check network connectivity from pod
kubectl-homelab exec -n uptime-kuma uptime-kuma-0 -- \
  wget -q -O- --timeout=5 https://example.com

# If DNS issues, check CoreDNS
kubectl-homelab get pods -n kube-system -l k8s-app=kube-dns
```

### HTTPRoute not working (404)

```bash
# Verify HTTPRoute exists
kubectl-homelab get httproute -n uptime-kuma

# Check Gateway status
kubectl-homelab get gateway -n default

# Verify DNS resolves to Gateway IP (10.10.30.20)
nslookup uptime.k8s.home.rommelporras.com
```

---

## Security Considerations

| Feature | Implementation |
|---------|----------------|
| **Non-root execution** | `runAsUser: 1000` via `2-slim-rootless` image |
| **No privilege escalation** | `allowPrivilegeEscalation: false` |
| **Minimal capabilities** | `capabilities.drop: ["ALL"]` |
| **Pod Security Standard** | `restricted` |
| **Credential storage** | 1Password (admin password) |
| **Network access** | Outbound only (no ingress, uses Gateway) |

> **Note:** `readOnlyRootFilesystem` is NOT enabled because the Node.js app
> requires writable `/tmp` for runtime operations. The data directory is
> mounted as a PVC which provides persistence.

---

## Comparison: Uptime Kuma vs healthchecks.io

| Use Case | Tool |
|----------|------|
| **Dead man's switch** (is Alertmanager working?) | healthchecks.io |
| **Endpoint monitoring** (is my website up?) | Uptime Kuma |
| **Cron job monitoring** (did backup run?) | healthchecks.io |
| **Status page** (public dashboard) | Uptime Kuma |

**Both tools complement each other:**
- healthchecks.io: Monitors YOUR systems are sending heartbeats (push model)
- Uptime Kuma: Monitors EXTERNAL endpoints are responding (pull model)

---

## Final: Release

- [ ] Release v0.12.0
  ```bash
  /release v0.12.0
  ```

- [ ] Move this file to completed folder
  ```bash
  mv docs/todo/phase-4.11-uptime-kuma.md docs/todo/completed/
  ```
