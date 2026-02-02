# Phase 4.14: Uptime Kuma Monitoring

> **Status:** Planned
> **Target:** v0.13.0
> **Prerequisite:** Phase 4.13 complete (Domain Migration)
> **DevOps Topics:** Uptime monitoring, status pages, synthetic monitoring
> **CKA Topics:** StatefulSet, PersistentVolumeClaim, HTTPRoute, SecurityContext, CiliumNetworkPolicy

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
│  │  HTTPRoute: uptime.k8s.rommelporras.com                │   │
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

**Decision:** Use `2-slim-rootless` — smallest image, runs as non-root natively (compatible
with `baseline` PSS enforcement), no unused embedded services. We use SQLite (not MariaDB)
and don't need browser-engine monitors.

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
| grafana.k8s.rommelporras.com | HTTPS | 60s | Monitoring dashboard |
| adguard.k8s.rommelporras.com | HTTPS | 60s | DNS admin |
| portal.k8s.rommelporras.com | HTTPS | 60s | Homepage dashboard |
| longhorn.k8s.rommelporras.com | HTTPS | 60s | Storage dashboard |
| healthchecks.io dashboard | HTTPS | 300s | Verify healthchecks.io itself is reachable (external dependency) |

---

## 4.14.1 Create Namespace and Manifests Directory

- [ ] 4.14.1.1 Create manifests directory
  ```bash
  mkdir -p manifests/uptime-kuma
  ```

- [ ] 4.14.1.2 Create namespace manifest
  ```yaml
  # manifests/uptime-kuma/namespace.yaml
  # Uptime Kuma namespace with baseline PSS enforcement
  # Phase 4.14 - Uptime Kuma Monitoring
  ---
  apiVersion: v1
  kind: Namespace
  metadata:
    name: uptime-kuma
    labels:
      app.kubernetes.io/part-of: uptime-kuma
      pod-security.kubernetes.io/enforce: baseline
      pod-security.kubernetes.io/audit: restricted
      pod-security.kubernetes.io/warn: restricted
  ```

- [ ] 4.14.1.3 Apply namespace
  ```bash
  kubectl-homelab apply -f manifests/uptime-kuma/namespace.yaml
  ```

- [ ] 4.14.1.4 Verify namespace created
  ```bash
  kubectl-homelab get namespace uptime-kuma -o yaml | grep -A5 labels
  # Should show:
  #   pod-security.kubernetes.io/enforce: baseline
  #   pod-security.kubernetes.io/audit: restricted
  #   pod-security.kubernetes.io/warn: restricted
  ```

> **Note:** PVC is managed via `volumeClaimTemplates` in the StatefulSet (4.14.2.1).
> This is the idiomatic StatefulSet pattern — Kubernetes auto-creates and binds the PVC
> when the StatefulSet is applied. No separate PVC manifest needed.

---

## 4.14.2 Deploy Uptime Kuma

- [ ] 4.14.2.1 Create StatefulSet manifest
  ```yaml
  # manifests/uptime-kuma/statefulset.yaml
  # StatefulSet for persistent SQLite database (single replica only)
  # Uses slim-rootless image: no embedded MariaDB/Chromium, runs as non-root (UID 1000)
  #
  # CKA topic: StatefulSet vs Deployment, volumeClaimTemplates, headless Service
  ---
  apiVersion: apps/v1
  kind: StatefulSet
  metadata:
    name: uptime-kuma
    namespace: uptime-kuma
    labels:
      app: uptime-kuma
      app.kubernetes.io/part-of: uptime-kuma
  spec:
    serviceName: uptime-kuma-headless
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

- [ ] 4.14.2.2 Create Services (headless + ClusterIP)
  ```yaml
  # manifests/uptime-kuma/service.yaml
  # Headless service for StatefulSet pod DNS identity (uptime-kuma-0.uptime-kuma-headless)
  # Regular ClusterIP service for HTTPRoute backend
  #
  # CKA topic: Headless Service (clusterIP: None) for StatefulSet stable network identity
  ---
  apiVersion: v1
  kind: Service
  metadata:
    name: uptime-kuma-headless
    namespace: uptime-kuma
    labels:
      app: uptime-kuma
      app.kubernetes.io/part-of: uptime-kuma
  spec:
    clusterIP: None
    selector:
      app: uptime-kuma
    ports:
    - name: http
      port: 3001
      targetPort: 3001
      protocol: TCP
  ---
  apiVersion: v1
  kind: Service
  metadata:
    name: uptime-kuma
    namespace: uptime-kuma
    labels:
      app: uptime-kuma
      app.kubernetes.io/part-of: uptime-kuma
  spec:
    selector:
      app: uptime-kuma
    ports:
    - name: http
      port: 3001
      targetPort: 3001
      protocol: TCP
  ```

- [ ] 4.14.2.3 Create HTTPRoute for internal access
  ```yaml
  # manifests/uptime-kuma/httproute.yaml
  # HTTPRoute for Uptime Kuma - exposes via Gateway API
  # URL: https://uptime.k8s.rommelporras.com
  #
  # Gateway API Architecture:
  #   Client -> Gateway (10.10.30.20:443) -> HTTPRoute -> Service -> Pod
  #
  # The Gateway handles TLS termination using the wildcard cert.
  # This HTTPRoute just defines the routing rules.
  ---
  apiVersion: gateway.networking.k8s.io/v1
  kind: HTTPRoute
  metadata:
    name: uptime-kuma
    namespace: uptime-kuma
  spec:
    parentRefs:
    - name: homelab-gateway
      namespace: default
      sectionName: https
    hostnames:
    - "uptime.k8s.rommelporras.com"
    rules:
    - matches:
      - path:
          type: PathPrefix
          value: /
      backendRefs:
      - name: uptime-kuma
        port: 3001
  ```

- [ ] 4.14.2.4 Apply all manifests
  ```bash
  kubectl-homelab apply -f manifests/uptime-kuma/
  ```

- [ ] 4.14.2.5 Wait for pod to be ready
  ```bash
  kubectl-homelab rollout status statefulset/uptime-kuma -n uptime-kuma --timeout=300s
  ```

- [ ] 4.14.2.6 Verify PVC auto-created and bound
  ```bash
  kubectl-homelab get pvc -n uptime-kuma
  # Should show: data-uptime-kuma-0  Bound  (auto-created by volumeClaimTemplates)
  ```

- [ ] 4.14.2.7 Check pod logs
  ```bash
  kubectl-homelab logs -n uptime-kuma -l app=uptime-kuma --tail=50
  # Look for: "Listening on 3001"
  ```

- [ ] 4.14.2.8 Create CiliumNetworkPolicy
  ```yaml
  # manifests/uptime-kuma/networkpolicy.yaml
  # CiliumNetworkPolicy - Egress rules for Uptime Kuma
  #
  # ALLOWED: DNS, internet (for external endpoint monitoring), cluster services
  # BLOCKED: NAS, other private subnets not needed
  #
  # Uptime Kuma needs broad outbound access to monitor external endpoints.
  # We allow internet egress and cluster-internal DNS but document the scope.
  ---
  apiVersion: cilium.io/v2
  kind: CiliumNetworkPolicy
  metadata:
    name: uptime-kuma-egress
    namespace: uptime-kuma
    labels:
      app: uptime-kuma
      app.kubernetes.io/part-of: uptime-kuma
  spec:
    endpointSelector:
      matchLabels:
        app: uptime-kuma

    egress:
    # DNS (required for service discovery and external domain resolution)
    - toEndpoints:
      - matchLabels:
          k8s:io.kubernetes.pod.namespace: kube-system
          k8s-app: kube-dns
      toPorts:
      - ports:
        - port: "53"
          protocol: UDP

    # Internet egress for monitoring external endpoints (HTTPS)
    - toCIDRSet:
      - cidr: 0.0.0.0/0
        except:
        - 10.0.0.0/8
        - 172.16.0.0/12
        - 192.168.0.0/16
      toPorts:
      - ports:
        - port: "443"
          protocol: TCP
        - port: "80"
          protocol: TCP

    # Cluster-internal monitoring (homelab services via Gateway VIP)
    - toCIDR:
      - 10.10.30.20/32
      toPorts:
      - ports:
        - port: "443"
          protocol: TCP

    # AdGuard DNS (for monitoring AdGuard directly)
    - toCIDR:
      - 10.10.30.53/32
      toPorts:
      - ports:
        - port: "53"
          protocol: UDP
        - port: "443"
          protocol: TCP
  ```

- [ ] 4.14.2.9 Apply network policy
  ```bash
  kubectl-homelab apply -f manifests/uptime-kuma/networkpolicy.yaml
  ```

---

## 4.14.3 Configure DNS

- [ ] 4.14.3.1 Add DNS record in AdGuard
  ```
  # AdGuard Home → Filters → DNS rewrites
  # Add: uptime.k8s.rommelporras.com → 10.10.30.20
  ```

- [ ] 4.14.3.2 Verify DNS resolution
  ```bash
  nslookup uptime.k8s.rommelporras.com 10.10.30.55
  # Should resolve to 10.10.30.20 (Gateway IP)
  ```

- [ ] 4.14.3.3 Access Uptime Kuma UI
  ```
  https://uptime.k8s.rommelporras.com
  ```

---

## 4.14.4 Initial Setup

- [ ] 4.14.4.1 Create admin account
  ```
  # First access prompts for admin account creation
  # Username: admin (or your preference)
  # Password: Store in 1Password
  ```

- [ ] 4.14.4.2 Store credentials in 1Password
  ```bash
  op item create \
    --category=login \
    --vault="Kubernetes" \
    --title="Uptime Kuma" \
    "username=admin" \
    "password=<your-password>"
  ```

- [ ] 4.14.4.3 Configure general settings
  ```
  Settings → General:
  - Primary Base URL: https://uptime.k8s.rommelporras.com
  - Check update: Disabled (managed via K8s image tag)
  ```

---

## 4.14.5 Configure Notifications

> **Reuse existing notification channels from Alertmanager.**

- [ ] 4.14.5.1 Add Discord notification
  ```
  Settings → Notifications → Setup Notification:
  - Notification Type: Discord
  - Friendly Name: Discord Incidents
  - Discord Webhook URL: (from 1Password: Discord Webhook Incidents)
  - Test → Should receive test message
  ```

- [ ] 4.14.5.2 (Optional) Add Email notification
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

## 4.14.6 Add Monitors

### Personal Sites

- [ ] 4.14.6.1 Add rommelporras.com
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

- [ ] 4.14.6.2 Add Grafana
  ```
  Add New Monitor:
  - Monitor Type: HTTP(s) - Keyword
  - Friendly Name: Grafana
  - URL: https://grafana.k8s.rommelporras.com
  - Keyword: Grafana
  - Heartbeat Interval: 60 seconds
  - Notification: Discord Incidents
  ```

- [ ] 4.14.6.3 Add AdGuard
  ```
  Add New Monitor:
  - Monitor Type: HTTP(s)
  - Friendly Name: AdGuard DNS
  - URL: https://adguard.k8s.rommelporras.com
  - Heartbeat Interval: 60 seconds
  - Notification: Discord Incidents
  ```

- [ ] 4.14.6.4 Add Homepage
  ```
  Add New Monitor:
  - Monitor Type: HTTP(s)
  - Friendly Name: Homepage Dashboard
  - URL: https://portal.k8s.rommelporras.com
  - Heartbeat Interval: 60 seconds
  - Notification: Discord Incidents
  ```

- [ ] 4.14.6.5 Add Longhorn
  ```
  Add New Monitor:
  - Monitor Type: HTTP(s)
  - Friendly Name: Longhorn Storage
  - URL: https://longhorn.k8s.rommelporras.com
  - Heartbeat Interval: 60 seconds
  - Notification: Discord Incidents
  ```

### Work-Related (Add your own)

- [ ] 4.14.6.6 Add work monitors as needed
  ```
  # Example:
  Add New Monitor:
  - Monitor Type: HTTP(s)
  - Friendly Name: Work Tool X
  - URL: https://internal-tool.company.com
  - Heartbeat Interval: 60 seconds
  ```

---

## 4.14.7 Create Public Status Page (Optional)

> **Expose a public status page for personal sites via Cloudflare Tunnel.**
> Uses an allowlist approach: only `/status/*` is publicly accessible.
> Everything else (`/dashboard`, `/api/*`, etc.) is blocked at the Cloudflare edge.

- [ ] 4.14.7.1 Create status page in Uptime Kuma UI
  ```
  Status Pages → New Status Page:
  - Title: Rommel Porras Services
  - Slug: status
  - Add monitors: rommelporras.com, blog, etc.
  # Status page will be at: /status/status
  ```

- [ ] 4.14.7.2 Configure Cloudflare Tunnel route
  ```
  # Cloudflare Zero Trust → Networks → Tunnels → homelab tunnel → Public Hostname:
  # Add public hostname: status.rommelporras.com
  # Service: http://uptime-kuma.uptime-kuma.svc.cluster.local:3001
  ```

- [ ] 4.14.7.2a Update cloudflared CiliumNetworkPolicy
  ```yaml
  # Add to manifests/cloudflare/networkpolicy.yaml egress rules:
  # (after the invoicetron block)

  # Uptime Kuma namespace (status.rommelporras.com)
  - toEndpoints:
    - matchLabels:
        k8s:io.kubernetes.pod.namespace: uptime-kuma
    toPorts:
    - ports:
      - port: "3001"
        protocol: TCP
  ```
  ```bash
  kubectl-homelab apply -f manifests/cloudflare/networkpolicy.yaml
  ```

- [ ] 4.14.7.3 Create Cloudflare Access policy (allowlist approach)
  ```
  # Cloudflare Zero Trust → Access → Applications → Add an application:
  #
  # --- Application 1: Block everything by default ---
  # Application name: Uptime Kuma Block All
  # Application domain: status.rommelporras.com
  # Path: /                (catches everything)
  #
  # Policy name: Block Public
  # Action: Block
  # Include: Everyone
  #
  # --- Application 2: Allow status page only ---
  # Application name: Uptime Kuma Status Page
  # Application domain: status.rommelporras.com
  # Path: /status/         (public status page only)
  #
  # Policy name: Allow Public
  # Action: Bypass
  # Include: Everyone
  #
  # ORDER MATTERS: Cloudflare evaluates more-specific paths first.
  # /status/* is allowed, everything else (/dashboard, /api/*, etc.) is blocked.
  ```

- [ ] 4.14.7.4 Verify public access
  ```bash
  # Status page should load:
  curl -I https://status.rommelporras.com/status/status
  # Expected: 200 OK

  # Admin dashboard should be blocked:
  curl -I https://status.rommelporras.com/dashboard
  # Expected: 403 Forbidden (blocked by Cloudflare Access)

  # API should also be blocked:
  curl -I https://status.rommelporras.com/api/status-page/status
  # Expected: 403 Forbidden
  ```

---

## 4.14.8 Backup Strategy

> **SQLite database should be backed up regularly.**

- [ ] 4.14.8.1 Longhorn handles storage replication (2x)
  ```bash
  # Verify Longhorn volume replication
  kubectl-homelab -n longhorn-system get volumes.longhorn.io | grep uptime-kuma
  ```

- [ ] 4.14.8.2 (Optional) Enable Longhorn snapshots
  ```bash
  # Create recurring snapshot job in Longhorn UI
  # Longhorn → Volume → uptime-kuma-data → Recurring Jobs
  # Schedule: Daily at 2am
  # Retain: 7 snapshots
  ```

- [ ] 4.14.8.3 (Optional) Manual backup of data directory
  ```bash
  # JSON export was removed in v2.0. Back up the /app/data directory directly.
  # Copy SQLite DB from pod to local machine:
  kubectl-homelab cp uptime-kuma/uptime-kuma-0:/app/data/kuma.db ./kuma-backup-$(date +%F).db
  ```

---

## 4.14.9 Prometheus Probe (Monitor the Monitor)

> **Add a blackbox-exporter Probe so Prometheus monitors Uptime Kuma itself.**
> Matches the existing pattern in `manifests/monitoring/adguard-dns-probe.yaml`.

- [ ] 4.14.9.1 Create Probe manifest
  ```yaml
  # manifests/monitoring/uptime-kuma-probe.yaml
  # Blackbox HTTP probe for Uptime Kuma
  # Fires alert if Uptime Kuma becomes unreachable
  ---
  apiVersion: monitoring.coreos.com/v1
  kind: Probe
  metadata:
    name: uptime-kuma
    namespace: monitoring
    labels:
      app: uptime-kuma-probe
  spec:
    jobName: uptime-kuma
    interval: 60s
    module: http_2xx
    prober:
      url: blackbox-exporter-prometheus-blackbox-exporter.monitoring.svc:9115
    targets:
      staticConfig:
        static:
        - https://uptime.k8s.rommelporras.com
        labels:
          target_name: uptime-kuma
  ```

- [ ] 4.14.9.2 Apply probe
  ```bash
  kubectl-homelab apply -f manifests/monitoring/uptime-kuma-probe.yaml
  ```

- [ ] 4.14.9.3 Verify probe in Prometheus
  ```bash
  # Check target is up in Prometheus UI or via API
  kubectl-homelab -n monitoring port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090
  # Open http://localhost:9090/targets and look for uptime-kuma job
  ```

---

## 4.14.10 Commit Deployment

> **First commit: manifests and configuration only.**

- [ ] 4.14.10.1 Commit deployment changes
  ```bash
  /commit
  ```

---

## 4.14.11 Documentation and Audit

> **Second commit: documentation updates and audit.**

- [ ] 4.14.11.1 Update VERSIONS.md
  ```markdown
  # Add to Home Services section:
  | Uptime Kuma | v2.0.2 (slim-rootless) | Running | Self-hosted uptime monitoring |

  # Add to HTTPRoutes table:
  | Uptime Kuma | uptime.k8s.rommelporras.com | base | uptime-kuma |

  # Add to Version History:
  | YYYY-MM-DD | Phase 4.14: Uptime Kuma deployed for endpoint monitoring |
  ```

- [ ] 4.14.11.2 Update docs/context/Secrets.md
  ```markdown
  # Add 1Password item:
  | Uptime Kuma | `username`, `password` | Uptime Kuma admin login |

  # Add 1Password path:
  op://Kubernetes/Uptime Kuma/username
  op://Kubernetes/Uptime Kuma/password
  ```

- [ ] 4.14.11.3 Update docs/context/Monitoring.md
  ```markdown
  # Add to Components table:
  | Uptime Kuma | v2.0.2 | uptime-kuma |

  # Add Access URL:
  | Uptime Kuma | https://uptime.k8s.rommelporras.com |
  ```

- [ ] 4.14.11.4 Update README.md
  ```markdown
  # Add Uptime Kuma to services list and architecture overview
  ```

- [ ] 4.14.11.5 Create rebuild guide
  ```markdown
  # docs/rebuild/v0.13.0-uptime-kuma.md
  # Must include (matching v0.11.0-ghost-blog.md pattern):
  #   - Header with release info, phase, goal, prerequisite
  #   - Overview with architecture and access URLs
  #   - Numbered steps with exact commands and full YAML
  #   - 1Password items table (Uptime Kuma: username, password)
  #   - Verification checklist
  #   - Rollback procedure (kubectl delete namespace uptime-kuma)
  #   - Files reference table
  #   - Key learnings table
  ```

- [ ] 4.14.11.6 Run audit-docs
  ```bash
  /audit-docs
  ```

- [ ] 4.14.11.7 Commit documentation changes
  ```bash
  /commit
  ```

---

## Verification Checklist

- [ ] Namespace `uptime-kuma` exists with **baseline** PSS enforce, **restricted** audit/warn
- [ ] PVC `data-uptime-kuma-0` auto-created and bound to Longhorn volume
- [ ] StatefulSet running with 1 replica (image: `2.0.2-slim-rootless`)
- [ ] Headless service `uptime-kuma-headless` exists (`clusterIP: None`)
- [ ] ClusterIP service `uptime-kuma` exists (for HTTPRoute backend)
- [ ] CiliumNetworkPolicy `uptime-kuma-egress` applied
- [ ] Pod running as non-root (UID 1000)
- [ ] HTTPRoute accessible: https://uptime.k8s.rommelporras.com
- [ ] HTTPRoute has `sectionName: https` in parentRef
- [ ] Prometheus blackbox probe target is UP
- [ ] Admin account created and stored in 1Password
- [ ] Discord notification configured and tested
- [ ] Monitors added for personal sites
- [ ] Monitors added for homelab services
- [ ] (Optional) Status page created with allowlist Cloudflare Access
- [ ] (Optional) cloudflared-egress networkpolicy updated for uptime-kuma
- [ ] Documentation updated (VERSIONS.md, Secrets.md, Monitoring.md, README.md)

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
nslookup uptime.k8s.rommelporras.com
```

---

## Security Considerations

| Feature | Implementation |
|---------|----------------|
| **Non-root execution** | `runAsUser: 1000` via `2-slim-rootless` image |
| **No privilege escalation** | `allowPrivilegeEscalation: false` |
| **Minimal capabilities** | `capabilities.drop: ["ALL"]` |
| **Pod Security Standard** | `baseline` enforce, `restricted` audit/warn |
| **Network policy** | CiliumNetworkPolicy: DNS + internet HTTPS + Gateway VIP |
| **Credential storage** | 1Password (admin password) |
| **Network access** | Outbound only (no ingress, uses Gateway) |
| **Public access** | Cloudflare Access allowlist: only `/status/*` exposed |

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

- [ ] Release v0.13.0
  ```bash
  /release v0.13.0
  ```

- [ ] Move this file to completed folder
  ```bash
  mv docs/todo/phase-4.14-uptime-kuma.md docs/todo/completed/
  ```
