# Phase 4.5: Cloudflare Tunnel Migration

> **Status:** ⬜ Planned
> **Target:** v0.7.0
> **Prerequisite:** Phase 3.10 complete (dead man's switch)
> **DevOps Topics:** Zero-trust networking, external access without port forwarding
> **CKA Topics:** Deployments, Secrets, Pod anti-affinity, environment variables

> **Purpose:** Move cloudflared from LXC to K8s for HA (no downtime on PVE restart)
> **Current:** cloudflared LXC on PVE Node (single point of failure)
> **Target:** cloudflared Deployment in K8s (2 replicas, survives node failure)

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
│  └───────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

---

## 4.5.1 Create Cloudflare Namespace

- [ ] 4.5.1.1 Create namespace
  ```bash
  kubectl-homelab create namespace cloudflare
  kubectl-homelab label namespace cloudflare pod-security.kubernetes.io/enforce=baseline
  ```

- [ ] 4.5.1.2 Verify namespace created
  ```bash
  kubectl-homelab get namespace cloudflare -o yaml | grep -A2 labels
  # Should show pod-security.kubernetes.io/enforce: baseline
  ```

---

## 4.5.2 Store Tunnel Credentials

- [ ] 4.5.2.1 Get tunnel token from existing LXC
  ```bash
  # Option A: From existing LXC container
  ssh pve "pct exec <cloudflared-lxc-id> -- cat /etc/cloudflared/config.yml"
  # Look for the tunnel token/credentials

  # Option B: From Cloudflare dashboard (generates new token)
  # https://one.dash.cloudflare.com/
  # Zero Trust → Networks → Tunnels → [your tunnel] → Configure
  # Click "Token" tab → Copy token
  ```

- [ ] 4.5.2.2 Store token in 1Password Kubernetes vault
  ```bash
  # Create item in 1Password:
  #   Vault: Kubernetes
  #   Item Name: Cloudflare-Tunnel
  #   Type: API Credential
  #   Field: token (the full tunnel token)
  #
  # Verify:
  op read "op://Kubernetes/Cloudflare-Tunnel/token" >/dev/null && echo "Token OK"
  ```

- [ ] 4.5.2.3 Create K8s Secret from 1Password
  ```bash
  kubectl-homelab create secret generic cloudflared-token \
    --from-literal=token="$(op read 'op://Kubernetes/Cloudflare-Tunnel/token')" \
    -n cloudflare
  ```

- [ ] 4.5.2.4 Verify secret created
  ```bash
  kubectl-homelab get secret cloudflared-token -n cloudflare
  # Should show 1 data item
  ```

---

## 4.5.3 Deploy cloudflared

- [ ] 4.5.3.1 Create manifests directory
  ```bash
  mkdir -p manifests/cloudflare
  ```

- [ ] 4.5.3.2 Create cloudflared Deployment manifest
  ```bash
  # Create file: manifests/cloudflare/deployment.yaml
  ```
  ```yaml
  # manifests/cloudflare/deployment.yaml
  # Cloudflare Tunnel - Zero-trust access to K8s services
  #
  # Why 2 replicas with anti-affinity?
  # - Survives single node failure
  # - Both replicas connect to Cloudflare (automatic load balancing)
  # - No downtime during rolling updates
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
    template:
      metadata:
        labels:
          app: cloudflared
      spec:
        containers:
        - name: cloudflared
          image: cloudflare/cloudflared:2024.12.2  # Pin version, don't use :latest
          args:
            - tunnel
            - --no-autoupdate
            - run
            - --token
            - $(TUNNEL_TOKEN)
          env:
          - name: TUNNEL_TOKEN
            valueFrom:
              secretKeyRef:
                name: cloudflared-token
                key: token
          resources:
            requests:
              memory: "64Mi"
              cpu: "100m"
            limits:
              memory: "128Mi"
              cpu: "500m"
          # Health check - cloudflared exposes metrics on :2000
          livenessProbe:
            httpGet:
              path: /ready
              port: 2000
            initialDelaySeconds: 10
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /ready
              port: 2000
            initialDelaySeconds: 5
            periodSeconds: 5
        # Spread pods across nodes for HA
        affinity:
          podAntiAffinity:
            preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                labelSelector:
                  matchLabels:
                    app: cloudflared
                topologyKey: kubernetes.io/hostname
  ```

- [ ] 4.5.3.3 Apply deployment
  ```bash
  kubectl-homelab apply -f manifests/cloudflare/deployment.yaml
  ```

- [ ] 4.5.3.4 Wait for pods to be ready
  ```bash
  kubectl-homelab rollout status deployment/cloudflared -n cloudflare --timeout=120s
  ```

- [ ] 4.5.3.5 Verify pods running on different nodes
  ```bash
  kubectl-homelab get pods -n cloudflare -o wide
  # Should see 2 pods on different nodes (k8s-cp1, k8s-cp2, or k8s-cp3)
  ```

- [ ] 4.5.3.6 Check cloudflared logs for successful tunnel connection
  ```bash
  kubectl-homelab logs -n cloudflare -l app=cloudflared --tail=20
  # Look for: "Connection registered" or "Registered tunnel connection"
  ```

---

## 4.5.4 Configure Tunnel Routes (Cloudflare Dashboard)

> **Note:** Routes are configured in Cloudflare dashboard, not in K8s manifests.
> cloudflared acts as a reverse proxy, forwarding requests to K8s Services.

- [ ] 4.5.4.1 Access Cloudflare Zero Trust dashboard
  ```
  https://one.dash.cloudflare.com/
  → Zero Trust → Networks → Tunnels
  → Select your tunnel → Public Hostname tab
  ```

- [ ] 4.5.4.2 Verify tunnel shows "Healthy" with 2 connectors
  ```
  # In Cloudflare dashboard, your tunnel should show:
  # Status: Healthy
  # Connectors: 2 (one per K8s pod)
  ```

- [ ] 4.5.4.3 Update existing routes to use K8s Service DNS
  ```
  # For each public hostname, update the Service URL:
  #
  # Before (LXC): http://10.10.30.X:3000
  # After (K8s):  http://SERVICE.NAMESPACE.svc.cluster.local:PORT
  #
  # Example routes to configure:
  #
  # rommelporras.com
  #   → http://portfolio.portfolio.svc.cluster.local:80
  #   (after Phase 4.7 - Portfolio migration)
  #
  # invoicetron.yourdomain.com
  #   → http://invoicetron.invoicetron.svc.cluster.local:3000
  #   (after Phase 4.8 - Invoicetron migration)
  ```

- [ ] 4.5.4.4 Test tunnel connectivity from external network
  ```bash
  # From your phone or external machine (not on home network):
  curl -I https://rommelporras.com
  # Should return HTTP 200 (or redirect)
  ```

---

## 4.5.5 Migrate from LXC

> **Strategy:** Run K8s alongside LXC for 1 day, then cut over.
> Cloudflare automatically load balances between all tunnel connectors.

- [ ] 4.5.5.1 Verify both tunnel endpoints are active
  ```
  # Cloudflare dashboard → Tunnels → [your tunnel]
  # Should show 3 connectors:
  # - 1 from LXC (existing)
  # - 2 from K8s (new)
  ```

- [ ] 4.5.5.2 Monitor for 1 day
  ```bash
  # Check K8s pod logs for errors
  kubectl-homelab logs -n cloudflare -l app=cloudflared -f

  # Check UptimeRobot for any downtime alerts
  # https://dashboard.uptimerobot.com/
  ```

- [ ] 4.5.5.3 Stop LXC cloudflared
  ```bash
  # SSH to Proxmox host
  ssh pve

  # Stop the LXC container (note the container ID)
  pct stop <cloudflared-lxc-id>

  # Verify it's stopped
  pct status <cloudflared-lxc-id>
  ```

- [ ] 4.5.5.4 Verify no downtime
  ```bash
  # Cloudflare dashboard should now show:
  # - Connectors: 2 (K8s only)
  # - Status: Healthy

  # Test all public hostnames
  curl -I https://rommelporras.com
  ```

- [ ] 4.5.5.5 Monitor for 1 week, then delete LXC
  ```bash
  # After 1 week stable operation:
  ssh pve "pct destroy <cloudflared-lxc-id>"
  ```

---

## 4.5.6 Documentation Updates

- [ ] 4.5.6.1 Update VERSIONS.md
  ```
  # Add to Infrastructure section:
  | cloudflared | 2024.12.2 | Cloudflare Tunnel connector |

  # Add to Version History:
  | YYYY-MM-DD | Phase 4.5: Cloudflare Tunnel migration to K8s |
  ```

- [ ] 4.5.6.2 Update docs/context/Secrets.md
  ```
  # Add 1Password item:
  | Cloudflare-Tunnel | token | Tunnel authentication token |
  ```

- [ ] 4.5.6.3 Update docs/reference/CHANGELOG.md
  - Add Phase 4.5 section with milestone, decisions, lessons learned

---

## Verification Checklist

- [ ] Namespace `cloudflare` exists with baseline PSS
- [ ] Secret `cloudflared-token` exists in cloudflare namespace
- [ ] 2 cloudflared pods running on different nodes
- [ ] Cloudflare dashboard shows tunnel "Healthy" with 2 connectors
- [ ] Public hostnames accessible from external network
- [ ] LXC cloudflared stopped (after migration period)
- [ ] No UptimeRobot alerts during migration
- [ ] Documentation updated (VERSIONS.md, Secrets.md)

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
```

### Only 1 connector showing in Cloudflare

```bash
# Check if both pods are running
kubectl-homelab get pods -n cloudflare -o wide

# Check if anti-affinity is working (pods on different nodes)
# If both pods on same node, check node resources

# Check individual pod logs
kubectl-homelab logs -n cloudflare cloudflared-xxxxx
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

---

## Final: Commit and Release

- [ ] Commit changes
  ```bash
  /commit
  ```

- [ ] Release v0.7.0
  ```bash
  /release v0.7.0
  ```

- [ ] Move this file to completed folder
  ```bash
  mv docs/todo/phase-4.5-cloudflare.md docs/todo/completed/
  ```
