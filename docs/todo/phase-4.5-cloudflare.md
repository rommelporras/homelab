# Phase 4.5: Cloudflare Tunnel Migration

> **Status:** ⬜ Planned
> **Target:** v0.7.0
> **DevOps Topics:** Zero-trust networking, external access without port forwarding

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

---

## 4.5.2 Store Tunnel Credentials

- [ ] 4.5.2.1 Add tunnel token to 1Password Kubernetes vault
  ```bash
  # Get tunnel token from Cloudflare dashboard or existing LXC
  # Zero Trust → Networks → Tunnels → [your tunnel] → Configure → Token
  ```

- [ ] 4.5.2.2 Create K8s Secret from 1Password
  ```bash
  kubectl-homelab create secret generic cloudflared-token \
    --from-literal=token="$(op read 'op://Kubernetes/Cloudflare-Tunnel/token')" \
    -n cloudflare
  ```

---

## 4.5.3 Deploy cloudflared

- [ ] 4.5.3.1 Create cloudflared Deployment
  ```bash
  kubectl-homelab apply -f manifests/cloudflare/cloudflared-deployment.yaml
  ```
  ```yaml
  # manifests/cloudflare/cloudflared-deployment.yaml
  apiVersion: apps/v1
  kind: Deployment
  metadata:
    name: cloudflared
    namespace: cloudflare
  spec:
    replicas: 2  # HA - survives node failure
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
          image: cloudflare/cloudflared:latest
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

- [ ] 4.5.3.2 Verify pods running on different nodes
  ```bash
  kubectl-homelab get pods -n cloudflare -o wide
  # Should see 2 pods on different nodes
  ```

---

## 4.5.4 Configure Tunnel Routes (Cloudflare Dashboard)

- [ ] 4.5.4.1 Update tunnel public hostnames to point to K8s Services
  ```
  # Cloudflare Zero Trust → Networks → Tunnels → [tunnel] → Public Hostname

  # Example routes:
  # rommelporras.com     → http://portfolio.portfolio.svc.cluster.local:80
  # gitlab.home.xxx      → http://gitlab-webservice.gitlab.svc.cluster.local:8181
  # invoicetron.xxx      → http://invoicetron.invoicetron.svc.cluster.local:3000
  ```

- [ ] 4.5.4.2 Test tunnel connectivity
  ```bash
  # Check cloudflared logs
  kubectl-homelab logs -n cloudflare -l app=cloudflared --tail=50
  ```

---

## 4.5.5 Migrate from LXC

- [ ] 4.5.5.1 Run K8s cloudflared alongside LXC for 1 day
  - Both tunnels connect to Cloudflare (load balanced automatically)
  - Verify traffic routes correctly

- [ ] 4.5.5.2 Stop LXC cloudflared
  ```bash
  # On PVE Node
  pct stop <cloudflared-lxc-id>
  ```

- [ ] 4.5.5.3 Verify no downtime
  - Check Cloudflare dashboard for tunnel status
  - Test all public hostnames

- [ ] 4.5.5.4 Delete LXC cloudflared (after 1 week stable)

**Rollback:** Restart LXC cloudflared, it will reconnect automatically
