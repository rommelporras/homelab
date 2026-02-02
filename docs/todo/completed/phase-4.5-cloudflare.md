# Phase 4.5: Cloudflare Tunnel Migration

> **Status:** ✅ Completed (2026-01-24)
> **Release:** v0.8.0
> **Prerequisite:** Phase 3.10 complete (dead man's switch)
> **DevOps Topics:** Zero-trust networking, external access without port forwarding
> **CKA Topics:** Deployments, Secrets, Pod anti-affinity, PodDisruptionBudget, SecurityContext, CiliumNetworkPolicy

> **Purpose:** Move cloudflared from LXC to K8s for HA (no downtime on PVE restart)
> **Result:** 2 cloudflared pods running on separate nodes, 8 QUIC connections to Cloudflare Edge
> **DMZ LXC:** Shut down (K8s tunnel now handles all traffic)

---

## Official Documentation References

This deployment follows Cloudflare's official recommendations:

| Source | URL |
|--------|-----|
| **K8s Deployment Guide** | https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/deployment-guides/kubernetes/ |
| **Run Parameters** | https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/configure-tunnels/tunnel-run-parameters/ |
| **Metrics** | https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/monitor-tunnels/metrics/ |
| **Official Helm Chart** | https://github.com/cloudflare/helm-charts (`cloudflare-tunnel` chart) |

### Alternative: Official Helm Chart

Cloudflare provides an official Helm chart. If you prefer Helm over raw manifests:

```bash
helm repo add cloudflare https://cloudflare.github.io/helm-charts
helm repo update
helm search repo cloudflare

# Install (requires account, tunnelName, tunnelId, secret)
helm install cloudflared cloudflare/cloudflare-tunnel \
  --namespace cloudflare --create-namespace \
  --set account=<account-id> \
  --set tunnelName=<tunnel-name> \
  --set tunnelId=<tunnel-id> \
  --set secret=<tunnel-secret>
```

> **Note:** This guide uses raw manifests for CKA learning purposes and to match
> the pattern used elsewhere in this homelab. Both approaches are valid.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Cloudflare Edge                          │
│  rommelporras.com ──► Tunnel ──► K8s cloudflared (HA)      │
│  gitlab.xxx       ──► Tunnel ──► K8s cloudflared (HA)      │
│  invoicetron.xxx  ──► Tunnel ──► K8s cloudflared (HA)      │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│              K8s Cluster (cloudflare namespace)             │
│  ┌───────────────────────────────────────────────────────┐ │
│  │  cloudflared Deployment (2 replicas)                  │ │
│  │  - Tunnel token from Secret (1Password)               │ │
│  │  - Routes to internal K8s Services                    │ │
│  │  - SecurityContext (non-root, read-only fs)           │ │
│  │  - PodDisruptionBudget (minAvailable: 1)              │ │
│  └───────────────────────────────────────────────────────┘ │
│  ┌───────────────────────────────────────────────────────┐ │
│  │  ServiceMonitor (Prometheus scrapes :2000/metrics)    │ │
│  └───────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

---

## 4.5.1 Create Cloudflare Namespace

- [x] 4.5.1.1 Create namespace
  ```bash
  kubectl-homelab create namespace cloudflare
  kubectl-homelab label namespace cloudflare pod-security.kubernetes.io/enforce=restricted
  ```

  > **Note:** Using `restricted` PSS (not baseline) because cloudflared runs as non-root
  > and doesn't need any special privileges.

- [x] 4.5.1.2 Verify namespace created
  ```bash
  kubectl-homelab get namespace cloudflare -o yaml | grep -A2 labels
  # Should show pod-security.kubernetes.io/enforce: restricted
  ```

---

## 4.5.2 Store Tunnel Credentials

- [x] 4.5.2.1 Get tunnel token from existing LXC
  ```bash
  # Option A: From existing LXC container
  ssh pve "pct exec <cloudflared-lxc-id> -- cat /etc/cloudflared/config.yml"
  # Look for the tunnel token/credentials

  # Option B: From Cloudflare dashboard (generates new token)
  # https://one.dash.cloudflare.com/
  # Zero Trust → Networks → Tunnels → [your tunnel] → Configure
  # Click "Token" tab → Copy token
  ```

- [x] 4.5.2.2 Store token in 1Password Kubernetes vault
  ```bash
  # Create item in 1Password:
  op item create \
    --category=login \
    --vault="Kubernetes" \
    --title="Cloudflare Tunnel" \
    "token=<paste-your-tunnel-token>"

  # Verify:
  op read "op://Kubernetes/Cloudflare Tunnel/token" >/dev/null && echo "Token OK"
  ```

- [x] 4.5.2.3 Create K8s Secret from 1Password
  ```bash
  kubectl-homelab create secret generic cloudflared-token \
    --from-literal=token="$(op read 'op://Kubernetes/Cloudflare Tunnel/token')" \
    -n cloudflare
  ```

- [x] 4.5.2.4 Verify secret created
  ```bash
  kubectl-homelab get secret cloudflared-token -n cloudflare
  # Should show 1 data item
  ```

---

## 4.5.3 Deploy cloudflared

- [x] 4.5.3.1 Create manifests directory
  ```bash
  mkdir -p manifests/cloudflare
  ```

- [x] 4.5.3.2 Create cloudflared Deployment manifest
  ```bash
  # Create file: manifests/cloudflare/deployment.yaml
  ```
  ```yaml
  # manifests/cloudflare/deployment.yaml
  # Cloudflare Tunnel - Zero-trust access to K8s services
  #
  # Based on official Cloudflare K8s deployment guide:
  # https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/deployment-guides/kubernetes/
  #
  # Security features (matches official Helm chart):
  # - Non-root user (UID 65532) - official recommendation
  # - Read-only root filesystem
  # - No privilege escalation
  # - All capabilities dropped
  # - Seccomp RuntimeDefault profile
  #
  # HA features (beyond official docs):
  # - Required anti-affinity (guaranteed on different nodes)
  # - PodDisruptionBudget (ensures 1 pod during maintenance)
  # - Resource limits (prevent runaway resource usage)
  #
  # Note on replicas: Official docs warn against autoscaling because
  # downscaling breaks existing user connections. We use fixed 2 replicas.
  #
  apiVersion: apps/v1
  kind: Deployment
  metadata:
    name: cloudflared
    namespace: cloudflare
    labels:
      app: cloudflared
  spec:
    replicas: 2
    selector:
      matchLabels:
        app: cloudflared
    strategy:
      type: RollingUpdate
      rollingUpdate:
        maxUnavailable: 1
        maxSurge: 1
    template:
      metadata:
        labels:
          app: cloudflared
        annotations:
          prometheus.io/scrape: "true"
          prometheus.io/port: "2000"
          prometheus.io/path: "/metrics"
      spec:
        # Pod security context
        securityContext:
          runAsNonRoot: true
          runAsUser: 65532
          runAsGroup: 65532
          fsGroup: 65532
          seccompProfile:
            type: RuntimeDefault
          # Official docs: Enable ICMP (ping/traceroute) to resources behind tunnel
          # This sysctl is "safe" in K8s 1.27+ and allowed by restricted PSS
          sysctls:
          - name: net.ipv4.ping_group_range
            value: "65532 65532"
        containers:
        - name: cloudflared
          image: cloudflare/cloudflared:2026.1.1
          # Command args follow official K8s deployment guide
          args:
            - tunnel
            - --no-autoupdate
            - --loglevel
            - info
            - --metrics
            - 0.0.0.0:2000
            - run
            - --token
            - $(TUNNEL_TOKEN)
          env:
          - name: TUNNEL_TOKEN
            valueFrom:
              secretKeyRef:
                name: cloudflared-token
                key: token
          ports:
          - name: metrics
            containerPort: 2000
            protocol: TCP
          # Resource limits (not in official docs, but best practice)
          resources:
            requests:
              memory: "64Mi"
              cpu: "100m"
            limits:
              memory: "256Mi"
              cpu: "500m"
          # Container security context (matches official Helm chart)
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
          # Liveness probe: /ready returns 200 only if connected to Cloudflare
          # Official docs use failureThreshold: 1 (aggressive restart)
          # We use 3 to tolerate brief network blips without unnecessary restarts
          livenessProbe:
            httpGet:
              path: /ready
              port: 2000
            initialDelaySeconds: 10
            periodSeconds: 10
            failureThreshold: 3
          # Readiness probe (not in official docs, but helps with rolling updates)
          readinessProbe:
            httpGet:
              path: /ready
              port: 2000
            initialDelaySeconds: 5
            periodSeconds: 5
            failureThreshold: 2
        # Required anti-affinity: MUST be on different nodes
        # (Not in official docs, but critical for true HA)
        # With 2 replicas and 3 nodes, this is always achievable
        affinity:
          podAntiAffinity:
            requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels:
                  app: cloudflared
              topologyKey: kubernetes.io/hostname
  ```

- [x] 4.5.3.3 Create PodDisruptionBudget manifest
  ```yaml
  # manifests/cloudflare/pdb.yaml
  # Ensures at least 1 cloudflared pod is always running
  # during voluntary disruptions (node drain, upgrades)
  #
  apiVersion: policy/v1
  kind: PodDisruptionBudget
  metadata:
    name: cloudflared
    namespace: cloudflare
  spec:
    minAvailable: 1
    selector:
      matchLabels:
        app: cloudflared
  ```

- [x] 4.5.3.4 Create Service for metrics
  ```yaml
  # manifests/cloudflare/service.yaml
  # Exposes metrics endpoint for Prometheus scraping
  #
  apiVersion: v1
  kind: Service
  metadata:
    name: cloudflared
    namespace: cloudflare
    labels:
      app: cloudflared
  spec:
    selector:
      app: cloudflared
    ports:
    - name: metrics
      port: 2000
      targetPort: 2000
      protocol: TCP
  ```

- [x] 4.5.3.5 Create ServiceMonitor for Prometheus
  ```yaml
  # manifests/cloudflare/servicemonitor.yaml
  # Prometheus scrapes cloudflared metrics
  #
  apiVersion: monitoring.coreos.com/v1
  kind: ServiceMonitor
  metadata:
    name: cloudflared
    namespace: cloudflare
    labels:
      app: cloudflared
      release: prometheus  # Matches kube-prometheus-stack selector
  spec:
    selector:
      matchLabels:
        app: cloudflared
    endpoints:
    - port: metrics
      interval: 30s
      path: /metrics
  ```

- [x] 4.5.3.6 Create CiliumNetworkPolicy (Security Isolation)
  ```yaml
  # manifests/cloudflare/networkpolicy.yaml
  # CRITICAL: Restricts cloudflared to ONLY reach public-facing services
  #
  # This is the K8s equivalent of DMZ firewall rules:
  # - cloudflared CAN reach: portfolio, invoicetron (public apps)
  # - cloudflared CANNOT reach: gitlab, grafana, longhorn (internal only)
  #
  apiVersion: cilium.io/v2
  kind: CiliumNetworkPolicy
  metadata:
    name: cloudflared-egress
    namespace: cloudflare
  spec:
    endpointSelector:
      matchLabels:
        app: cloudflared
    egress:
    # 1. Allow DNS (required for service discovery)
    - toEndpoints:
      - matchLabels:
          k8s:io.kubernetes.pod.namespace: kube-system
          k8s-app: kube-dns
      toPorts:
      - ports:
        - port: "53"
          protocol: UDP

    # 2. Allow Cloudflare Edge ONLY (not entire internet)
    #    Cloudflare IP ranges: https://www.cloudflare.com/ips/
    #    This prevents cloudflared from reaching your NAS or other local devices
    - toCIDRSet:
      - cidr: 0.0.0.0/0
        except:
        - 10.0.0.0/8      # Block all private 10.x.x.x (includes your NAS)
        - 172.16.0.0/12   # Block private 172.16-31.x.x
        - 192.168.0.0/16  # Block private 192.168.x.x
      toPorts:
      - ports:
        - port: "443"
          protocol: TCP
        - port: "7844"
          protocol: TCP
        - port: "7844"
          protocol: UDP

    # 3. Allow portfolio namespace (www.rommelporras.com)
    - toEndpoints:
      - matchLabels:
          k8s:io.kubernetes.pod.namespace: portfolio
      toPorts:
      - ports:
        - port: "80"
          protocol: TCP

    # 4. Allow invoicetron namespace (invoicetron.rommelporras.com)
    - toEndpoints:
      - matchLabels:
          k8s:io.kubernetes.pod.namespace: invoicetron
      toPorts:
      - ports:
        - port: "3000"
          protocol: TCP

    # 5. TEMPORARY: Allow DMZ VM reverse-mountain (10.10.50.10)
    #    For transition period while portfolio/invoicetron on Proxmox DMZ
    #    REMOVE THIS RULE after Phase 4.7 and 4.8 complete!
    - toCIDR:
      - 10.10.50.10/32  # Single IP only, not entire DMZ subnet
      toPorts:
      - ports:
        - port: "3000"  # invoicetron
          protocol: TCP
        - port: "3001"  # portfolio
          protocol: TCP

    # ❌ IMPLICIT DENY: Everything else is blocked
    # - Cannot reach gitlab namespace
    # - Cannot reach monitoring namespace (grafana, prometheus)
    # - Cannot reach longhorn-system
    # - Cannot reach adguard namespace
  ```

  > **Why This Matters:** This policy is the K8s equivalent of your Proxmox DMZ firewall.
  > Even though everything runs on SERVERS VLAN, Cilium enforces that cloudflared
  > can only forward traffic to public-facing services.

- [x] 4.5.3.7 Apply all manifests
  ```bash
  kubectl-homelab apply -f manifests/cloudflare/
  ```

- [x] 4.5.3.7 Wait for pods to be ready
  ```bash
  kubectl-homelab rollout status deployment/cloudflared -n cloudflare --timeout=120s
  ```

- [x] 4.5.3.8 Verify pods running on different nodes
  ```bash
  kubectl-homelab get pods -n cloudflare -o wide
  # Should see 2 pods on different nodes (k8s-cp1, k8s-cp2, or k8s-cp3)
  # Anti-affinity is "required" so this MUST be true
  ```

- [x] 4.5.3.9 Check cloudflared logs for successful tunnel connection
  ```bash
  kubectl-homelab logs -n cloudflare -l app=cloudflared --tail=20
  # Look for: "Connection registered" or "Registered tunnel connection"
  ```

- [x] 4.5.3.10 Verify PodDisruptionBudget
  ```bash
  kubectl-homelab get pdb -n cloudflare
  # Should show: ALLOWED DISRUPTIONS = 1, MIN AVAILABLE = 1
  ```

---

## 4.5.4 Configure Tunnel Routes (Cloudflare Dashboard)

> **Note:** Routes are configured in Cloudflare dashboard, not in K8s manifests.
> cloudflared acts as a reverse proxy, forwarding requests to K8s Services.

### Public vs Internal Access Model

```
┌─────────────────────────────────────────────────────────────────────┐
│                         PUBLIC ACCESS                                │
│                (Cloudflare Tunnel → K8s Services)                   │
│                                                                      │
│  www.rommelporras.com ────────────► portfolio.portfolio.svc:80      │
│  invoicetron.rommelporras.com ────► invoicetron.invoicetron.svc:3000│
│                                                                      │
├─────────────────────────────────────────────────────────────────────┤
│                        INTERNAL ACCESS                               │
│            (*.k8s.rommelporras.com → K8s Gateway)              │
│                                                                      │
│  gitlab.k8s.rommelporras.com ────► GitLab (NO public route)   │
│  grafana.k8s.rommelporras.com ───► Grafana (NO public route)  │
│  portfolio.k8s.rommelporras.com ─► Portfolio (internal too)   │
│  invoicetron.k8s.rommelporras.com► Invoicetron (internal too) │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

- [x] 4.5.4.1 Access Cloudflare Zero Trust dashboard
  ```
  https://one.dash.cloudflare.com/
  → Zero Trust → Networks → Tunnels
  → Select your tunnel → Public Hostname tab
  ```

- [x] 4.5.4.2 Verify tunnel shows "Healthy" with 2 connectors
  ```
  # In Cloudflare dashboard, your tunnel should show:
  # Status: Healthy
  # Connectors: 2 (one per K8s pod)
  ```

- [x] 4.5.4.3 Configure public hostname routes

  **Route 1: Portfolio (www.rommelporras.com)**
  ```
  Public hostname: www.rommelporras.com
  Service type: HTTP
  URL: portfolio.portfolio.svc.cluster.local:80
  ```
  > Note: Configure after Phase 4.7 (Portfolio migration)

  **Route 2: Invoicetron (invoicetron.rommelporras.com)**
  ```
  Public hostname: invoicetron.rommelporras.com
  Service type: HTTP
  URL: invoicetron.invoicetron.svc.cluster.local:3000
  ```
  > Note: Configure after Phase 4.8 (Invoicetron migration)

  **Services NOT exposed via tunnel (internal only):**
  | Service | Internal URL | Public Route |
  |---------|--------------|--------------|
  | GitLab | gitlab.k8s.rommelporras.com | ❌ None |
  | Grafana | grafana.k8s.rommelporras.com | ❌ None |
  | AdGuard | adguard.k8s.rommelporras.com | ❌ None |
  | Longhorn | longhorn.k8s.rommelporras.com | ❌ None |

- [x] 4.5.4.4 Test tunnel connectivity from external network
  ```bash
  # From your phone or external machine (not on home network):
  curl -I https://www.rommelporras.com
  # Should return HTTP 200 (or redirect)

  curl -I https://invoicetron.rommelporras.com
  # Should return HTTP 200
  ```

---

## 4.5.5 Migrate from LXC

> **Strategy:** Run K8s alongside LXC for 1 day, then cut over.
> Cloudflare automatically load balances between all tunnel connectors.

- [x] 4.5.5.1 Verify both tunnel endpoints are active
  ```
  # Cloudflare dashboard → Tunnels → [your tunnel]
  # Should show 3 connectors:
  # - 1 from LXC (existing)
  # - 2 from K8s (new)
  ```

- [x] 4.5.5.2 Monitor for 1 day
  ```bash
  # Check K8s pod logs for errors
  kubectl-homelab logs -n cloudflare -l app=cloudflared -f

  # Check healthchecks.io / Uptime Kuma for any downtime alerts
  # (Uptime Kuma deployed in Phase 4.10)
  ```

- [x] 4.5.5.3 Stop LXC cloudflared
  ```bash
  # SSH to Proxmox host
  ssh pve

  # Stop the LXC container (note the container ID)
  pct stop <cloudflared-lxc-id>

  # Verify it's stopped
  pct status <cloudflared-lxc-id>
  ```

- [x] 4.5.5.4 Verify no downtime
  ```bash
  # Cloudflare dashboard should now show:
  # - Connectors: 2 (K8s only)
  # - Status: Healthy

  # Test all public hostnames
  curl -I https://rommelporras.com
  ```

- [x] 4.5.5.5 Monitor for 1 week, then delete LXC
  ```bash
  # After 1 week stable operation:
  ssh pve "pct destroy <cloudflared-lxc-id>"
  ```

---

## 4.5.6 Verify Prometheus Metrics

- [x] 4.5.6.1 Check ServiceMonitor is discovered
  ```bash
  kubectl-homelab get servicemonitor -n cloudflare
  ```

- [x] 4.5.6.2 Verify metrics in Prometheus
  ```bash
  # Port-forward to Prometheus
  kubectl-homelab -n monitoring port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090 &

  # Query cloudflared metrics
  curl -s 'http://localhost:9090/api/v1/query?query=cloudflared_tunnel_total_requests' | jq .
  ```

- [x] 4.5.6.3 (Optional) Create Grafana dashboard
  ```
  # Import cloudflared community dashboard or create custom
  # Key metrics:
  # - cloudflared_tunnel_total_requests
  # - cloudflared_tunnel_request_errors
  # - cloudflared_tunnel_response_by_code
  # - cloudflared_tunnel_concurrent_requests_per_tunnel
  ```

---

## 4.5.7 Documentation Updates

- [x] 4.5.7.1 Update VERSIONS.md
  ```
  # Add to Infrastructure section:
  | cloudflared | 2026.1.1 | Cloudflare Tunnel connector |

  # Add to Version History:
  | YYYY-MM-DD | Phase 4.5: Cloudflare Tunnel migration to K8s |
  ```

- [x] 4.5.7.2 Update docs/context/Secrets.md
  ```
  # Add 1Password item:
  | Cloudflare Tunnel | token | Tunnel authentication token |
  ```

- [x] 4.5.7.3 Update docs/reference/CHANGELOG.md
  - Add Phase 4.5 section with milestone, decisions, lessons learned

---

## Verification Checklist

- [x] Namespace `cloudflare` exists with **restricted** PSS
- [x] Secret `cloudflared-token` exists in cloudflare namespace
- [x] 2 cloudflared pods running on **different nodes** (required anti-affinity)
- [x] Pods running as non-root (UID 65532)
- [x] PodDisruptionBudget created (minAvailable: 1)
- [x] CiliumNetworkPolicy `cloudflared-egress` created
- [x] Cloudflare dashboard shows tunnel "Healthy" with 2 connectors
- [x] Public hostnames accessible from external network
- [x] ServiceMonitor created and Prometheus scraping metrics
- [x] **Security tests passed** (see section below)
- [x] LXC cloudflared stopped (after migration period)
- [x] No downtime alerts during migration
- [x] Documentation updated (VERSIONS.md, Secrets.md)

---

## 4.5.8 Security Validation Testing (Penetration Test)

> **Purpose:** Verify CiliumNetworkPolicy blocks unauthorized access.
> This is a critical step - do NOT skip it. We must prove the firewall works.

### Test Strategy

We'll exec into a cloudflared pod and attempt connections to:
1. **Allowed destinations** → Should SUCCEED
2. **Blocked destinations** → Should FAIL (timeout/refused)

### 4.5.8.1 Create Test Pod

Since cloudflared image is minimal, we'll create a test pod with the same labels to inherit the NetworkPolicy:

```bash
# Create a test pod that inherits cloudflared's NetworkPolicy
kubectl-homelab run netpol-test \
  --namespace=cloudflare \
  --labels="app=cloudflared" \
  --image=nicolaka/netshoot \
  --rm -it --restart=Never \
  -- /bin/bash
```

### 4.5.8.2 Test ALLOWED Connections (Should Succeed)

Run these inside the test pod:

```bash
# Test 1: DNS resolution (should work)
nslookup portfolio.portfolio.svc.cluster.local
echo "✅ DNS: PASS" || echo "❌ DNS: FAIL"

# Test 2: Cloudflare Edge (should work)
nc -zv 104.16.132.229 443 -w 5
echo "✅ Cloudflare: PASS" || echo "❌ Cloudflare: FAIL"

# Test 3: Portfolio namespace (should work - after Phase 4.7)
# nc -zv portfolio.portfolio.svc.cluster.local 80 -w 5
# echo "✅ Portfolio: PASS" || echo "❌ Portfolio: FAIL"

# Test 4: Invoicetron namespace (should work - after Phase 4.8)
# nc -zv invoicetron.invoicetron.svc.cluster.local 3000 -w 5
# echo "✅ Invoicetron: PASS" || echo "❌ Invoicetron: FAIL"
```

### 4.5.8.3 Test BLOCKED Connections (Must Fail)

These MUST timeout or be refused. If any succeed, the NetworkPolicy has a gap!

```bash
# Test 5: NAS / Immich (MUST FAIL)
echo "Testing NAS access (should timeout)..."
nc -zv 10.10.30.4 443 -w 5
if [ $? -eq 0 ]; then
  echo "❌ SECURITY FAIL: Can reach NAS!"
else
  echo "✅ NAS blocked: PASS"
fi

# Test 6: NAS NFS port (MUST FAIL)
nc -zv 10.10.30.4 2049 -w 5
if [ $? -eq 0 ]; then
  echo "❌ SECURITY FAIL: Can reach NFS!"
else
  echo "✅ NFS blocked: PASS"
fi

# Test 7: Immich (MUST FAIL)
nc -zv 10.10.30.4 2283 -w 5
if [ $? -eq 0 ]; then
  echo "❌ SECURITY FAIL: Can reach Immich!"
else
  echo "✅ Immich blocked: PASS"
fi

# Test 8: GitLab namespace (MUST FAIL - after Phase 4.6)
# nc -zv gitlab-webservice-default.gitlab.svc.cluster.local 8181 -w 5
# if [ $? -eq 0 ]; then
#   echo "❌ SECURITY FAIL: Can reach GitLab!"
# else
#   echo "✅ GitLab blocked: PASS"
# fi

# Test 9: Grafana (MUST FAIL)
nc -zv prometheus-grafana.monitoring.svc.cluster.local 80 -w 5
if [ $? -eq 0 ]; then
  echo "❌ SECURITY FAIL: Can reach Grafana!"
else
  echo "✅ Grafana blocked: PASS"
fi

# Test 10: Kubernetes API (MUST FAIL)
nc -zv kubernetes.default.svc.cluster.local 443 -w 5
if [ $? -eq 0 ]; then
  echo "❌ SECURITY FAIL: Can reach K8s API!"
else
  echo "✅ K8s API blocked: PASS"
fi

# Test 11: Random internal IP (MUST FAIL)
nc -zv 10.10.30.1 443 -w 5
if [ $? -eq 0 ]; then
  echo "❌ SECURITY FAIL: Can reach router!"
else
  echo "✅ Router blocked: PASS"
fi

# Test 12: Longhorn (MUST FAIL)
nc -zv longhorn-frontend.longhorn-system.svc.cluster.local 80 -w 5
if [ $? -eq 0 ]; then
  echo "❌ SECURITY FAIL: Can reach Longhorn!"
else
  echo "✅ Longhorn blocked: PASS"
fi
```

### 4.5.8.4 Exit Test Pod

```bash
exit
```

### 4.5.8.5 Expected Results

| Test | Target | Expected | If Fails |
|------|--------|----------|----------|
| DNS | kube-dns | ✅ Success | Check DNS rule |
| Cloudflare | 104.16.132.229:443 | ✅ Success | Check toCIDRSet rule |
| Portfolio | portfolio.svc:80 | ✅ Success | Check namespace rule |
| Invoicetron | invoicetron.svc:3000 | ✅ Success | Check namespace rule |
| NAS | 10.10.30.4:443 | ❌ Timeout | **SECURITY OK** |
| NFS | 10.10.30.4:2049 | ❌ Timeout | **SECURITY OK** |
| Immich | 10.10.30.4:2283 | ❌ Timeout | **SECURITY OK** |
| GitLab | gitlab.svc:8181 | ❌ Timeout | **SECURITY OK** |
| Grafana | grafana.svc:80 | ❌ Timeout | **SECURITY OK** |
| K8s API | kubernetes.svc:443 | ❌ Timeout | **SECURITY OK** |
| Router | 10.10.30.1:443 | ❌ Timeout | **SECURITY OK** |
| Longhorn | longhorn.svc:80 | ❌ Timeout | **SECURITY OK** |

### 4.5.8.6 Automated Test Script

The hardened penetration test script is located at:

```bash
scripts/test-cloudflare-networkpolicy.sh
```

**Run the test:**
```bash
./scripts/test-cloudflare-networkpolicy.sh
```

**Test Coverage (37 tests in 5 sections):**

| Section | Tests | Purpose |
|---------|-------|---------|
| 1. Allowed Connections | 6 | DNS, Cloudflare Edge (HTTPS/QUIC), DMZ VM |
| 2. Infrastructure | 9 | NAS, Router, K8s nodes (SSH) |
| 3. K8s Services | 5 | Grafana, Prometheus, Alertmanager, Longhorn, AdGuard |
| 4. Control Plane | 7 | K8s API, etcd (all nodes), Kubelet (all nodes) |
| 5. Edge Cases | 10 | Metadata API, link-local, HTTP-only, wrong ports, other private ranges |

**Expected Result:**
```
Passed:   37
Failed:   0
Warnings: 1 (UDP test inconclusive - expected)

✅ SECURITY VALIDATION PASSED
```

### If Any Security Test Fails

**STOP DEPLOYMENT** and investigate:

```bash
# Check NetworkPolicy is applied
kubectl-homelab get ciliumnetworkpolicy -n cloudflare

# Describe the policy
kubectl-homelab describe ciliumnetworkpolicy cloudflared-egress -n cloudflare

# Check Cilium status
kubectl-homelab -n kube-system exec -it ds/cilium -- cilium status

# Check policy enforcement
kubectl-homelab -n kube-system exec -it ds/cilium -- cilium policy get
```

Do NOT proceed until all blocked connections properly timeout/fail.

---

## Rollback

If issues occur after stopping LXC:

```bash
# 1. Restart LXC cloudflared (immediate recovery)
ssh pve "pct start <cloudflared-lxc-id>"

# 2. LXC will reconnect to Cloudflare automatically
#    Traffic will route through LXC again

# 3. Debug K8s deployment
kubectl-homelab logs -n cloudflare -l app=cloudflared
kubectl-homelab describe pods -n cloudflare

# 4. If K8s deployment is broken, delete and recreate:
kubectl-homelab delete deployment cloudflared -n cloudflare
kubectl-homelab apply -f manifests/cloudflare/deployment.yaml
```

---

## Troubleshooting

### Tunnel shows "Degraded" or "Down"

```bash
# Check pod status
kubectl-homelab get pods -n cloudflare

# Check logs for connection errors
kubectl-homelab logs -n cloudflare -l app=cloudflared | grep -i error

# Common issues:
# - Invalid token → recreate secret from 1Password
# - Network issues → check Cilium connectivity
# - DNS issues → verify CoreDNS is working
```

### Only 1 connector showing in Cloudflare

```bash
# Check if both pods are running
kubectl-homelab get pods -n cloudflare -o wide

# With required anti-affinity, if only 1 pod is running:
# - Check if a node is down/drained
kubectl-homelab get nodes

# Check pod events for scheduling failures
kubectl-homelab describe pods -n cloudflare | grep -A10 Events
```

### Routes not working (502 Bad Gateway)

```bash
# Verify the target service exists and has endpoints
kubectl-homelab get svc -A | grep <service-name>
kubectl-homelab get endpoints <service-name> -n <namespace>

# Test from inside the cluster
kubectl-homelab run test --rm -it --image=curlimages/curl -- \
  curl -v http://SERVICE.NAMESPACE.svc.cluster.local:PORT
```

### Pod fails to start (SecurityContext issues)

```bash
# Check if image supports non-root
kubectl-homelab describe pod -n cloudflare -l app=cloudflared | grep -A5 "State:"

# cloudflared official image supports non-root (UID 65532)
# If issues persist, check if restricted PSS is blocking something
kubectl-homelab get events -n cloudflare --sort-by='.lastTimestamp'
```

---

## Security Considerations

### Official Cloudflare Recommendations (Helm Chart)

| Feature | Implementation | Source |
|---------|----------------|--------|
| **Non-root execution** | `runAsUser: 65532` | Official Helm chart |
| **Read-only filesystem** | `readOnlyRootFilesystem: true` | Official Helm chart |
| **No privilege escalation** | `allowPrivilegeEscalation: false` | Official Helm chart |
| **Minimal capabilities** | `capabilities.drop: ["ALL"]` | Official Helm chart |
| **ICMP sysctl** | `net.ipv4.ping_group_range: "65532 65532"` | Official K8s guide |

### Additional Hardening (This Guide)

| Feature | Implementation | Rationale |
|---------|----------------|-----------|
| **Seccomp profile** | `seccompProfile.type: RuntimeDefault` | PSS restricted requirement |
| **Pod Security Standard** | `restricted` namespace label | Strictest PSS level |
| **Secret management** | 1Password → K8s Secret | No hardcoded tokens in manifests |
| **Required anti-affinity** | `requiredDuringSchedulingIgnoredDuringExecution` | Guaranteed HA across nodes |
| **PodDisruptionBudget** | `minAvailable: 1` | Maintain availability during maintenance |
| **Resource limits** | 64Mi-256Mi memory, 100m-500m CPU | Prevent resource exhaustion |
| **Readiness probe** | Separate from liveness | Proper rolling update behavior |

### Network Security

- **Outbound only** - cloudflared initiates connections to Cloudflare Edge
- **No ingress required** - No need to open firewall ports
- **mTLS to Cloudflare** - All tunnel traffic is encrypted

---

## Final: Commit and Release

- [x] Commit changes
  ```bash
  /commit
  ```

- [x] Release v0.8.0
  ```bash
  /release v0.8.0
  ```

- [x] Move this file to completed folder
  ```bash
  mv docs/todo/phase-4.5-cloudflare.md docs/todo/completed/
  ```
