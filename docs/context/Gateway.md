---
tags: [homelab, kubernetes, gateway, tls, cert-manager]
updated: 2026-02-03
---

# Gateway API

Gateway API for HTTPS ingress with automatic TLS certificates.

## Architecture

```
                        Internet
                            |
                            v
+-----------------------------------------------------+
|              AdGuard DNS (10.10.30.53)               |
|   *.k8s.rommelporras.com      -> 10.10.30.20        |
|   *.dev.k8s.rommelporras.com  -> 10.10.30.20        |
|   *.stg.k8s.rommelporras.com  -> 10.10.30.20        |
+-----------------------------------------------------+
                            |
                            v
+-----------------------------------------------------+
|           Cilium L2 Announcement                     |
|              VIP: 10.10.30.20                        |
+-----------------------------------------------------+
                            |
                            v
+-----------------------------------------------------+
|              homelab-gateway                         |
|         (Gateway in default namespace)               |
|                                                      |
|  Port 80  - http      (all hostnames)                |
|  Port 443 - https     (*.k8s.rommelporras.com)       |
|  Port 443 - https-dev (*.dev.k8s.rommelporras.com)   |
|  Port 443 - https-stg (*.stg.k8s.rommelporras.com)   |
+-----------------------------------------------------+
                            |
    +-------+-------+-------+-------+-------+---------+
    v       v       v       v       v       v         v
+------++------++------++------++------++--------++--------+
|Grafan||AdGuar||Homepg||Longh.||GitLab||Portfol.||Ghost   |
| base || base || base || base || base ||dev/stg/ ||dev/prod|
|      ||      ||      ||      ||      || prod   ||        |
+------++------++------++------++------++--------++--------+
```

## Components

| Component | Namespace | Purpose |
|-----------|-----------|---------|
| homelab-gateway | default | Shared Gateway for all services |
| letsencrypt-prod | cluster-wide | ClusterIssuer for TLS certs |
| wildcard-k8s-tls | default | Base wildcard cert (*.k8s.rommelporras.com) |
| wildcard-dev-k8s-tls | default | Dev wildcard cert (*.dev.k8s.rommelporras.com) |
| wildcard-stg-k8s-tls | default | Stg wildcard cert (*.stg.k8s.rommelporras.com) |
| HTTPRoutes | per-service | Route traffic to services |

## Gateway Resource

| Setting | Value |
|---------|-------|
| Name | homelab-gateway |
| Namespace | default |
| Class | cilium |
| VIP | 10.10.30.20 |
| Base wildcard | *.k8s.rommelporras.com |
| Dev wildcard | *.dev.k8s.rommelporras.com |
| Stg wildcard | *.stg.k8s.rommelporras.com |

Listeners:
- **http** (port 80) - For future HTTP->HTTPS redirect
- **https** (port 443) - TLS termination with `wildcard-k8s-tls` for `*.k8s.rommelporras.com`
- **https-dev** (port 443) - TLS termination with `wildcard-dev-k8s-tls` for `*.dev.k8s.rommelporras.com`
- **https-stg** (port 443) - TLS termination with `wildcard-stg-k8s-tls` for `*.stg.k8s.rommelporras.com`

## TLS Certificate Chain

```
cert-manager.io/cluster-issuer: letsencrypt-prod
        |
        v
+---------------------------------------------+
|         ClusterIssuer                        |
|         letsencrypt-prod                     |
|                                              |
|  ACME Server: Let's Encrypt                  |
|  Challenge: DNS-01 via Cloudflare            |
|  API Token: cloudflare-api-token secret      |
+---------------------------------------------+
        |
        +-------------------+-------------------+
        v                   v                   v
+---------------+   +---------------+   +---------------+
| Certificate   |   | Certificate   |   | Certificate   |
| wildcard-k8s  |   | wildcard-dev  |   | wildcard-stg  |
| -tls          |   | -k8s-tls      |   | -k8s-tls      |
|               |   |               |   |               |
| *.k8s.rommel  |   | *.dev.k8s.rom |   | *.stg.k8s.rom |
| porras.com    |   | melporras.com |   | melporras.com |
| 90d auto-renew|   | 90d auto-renew|   | 90d auto-renew|
+---------------+   +---------------+   +---------------+
```

## Exposed Services

| Service | URL | HTTPRoute | Namespace | Listener |
|---------|-----|-----------|-----------|----------|
| Grafana | https://grafana.k8s.rommelporras.com | grafana | monitoring | https |
| AdGuard | https://adguard.k8s.rommelporras.com | adguard | home | https |
| Homepage | https://portal.k8s.rommelporras.com | homepage | home | https |
| Longhorn | https://longhorn.k8s.rommelporras.com | longhorn | longhorn-system | https |
| GitLab | https://gitlab.k8s.rommelporras.com | gitlab | gitlab | https |
| GitLab Registry | https://registry.k8s.rommelporras.com | gitlab-registry | gitlab | https |
| Portfolio Dev | https://portfolio.dev.k8s.rommelporras.com | portfolio | portfolio-dev | https-dev |
| Portfolio Staging | https://portfolio.stg.k8s.rommelporras.com | portfolio | portfolio-staging | https-stg |
| Portfolio Prod | https://portfolio.k8s.rommelporras.com | portfolio | portfolio-prod | https |
| Ghost Dev | https://blog.dev.k8s.rommelporras.com | ghost | ghost-dev | https-dev |
| Ghost Prod | https://blog.k8s.rommelporras.com | ghost | ghost-prod | https |
| Uptime Kuma | https://uptime.k8s.rommelporras.com | uptime-kuma | uptime-kuma | https |

## Adding a New Service

### Base tier (*.k8s.rommelporras.com)

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: myapp
  namespace: myapp-namespace
spec:
  parentRefs:
    - name: homelab-gateway
      namespace: default
      sectionName: https
  hostnames:
    - myapp.k8s.rommelporras.com
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: myapp-service
          port: 80
```

### Dev tier (*.dev.k8s.rommelporras.com)

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: myapp
  namespace: myapp-dev
spec:
  parentRefs:
    - name: homelab-gateway
      namespace: default
      sectionName: https-dev
  hostnames:
    - myapp.dev.k8s.rommelporras.com
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: myapp-service
          port: 80
```

### Stg tier (*.stg.k8s.rommelporras.com)

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: myapp
  namespace: myapp-staging
spec:
  parentRefs:
    - name: homelab-gateway
      namespace: default
      sectionName: https-stg
  hostnames:
    - myapp.stg.k8s.rommelporras.com
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: myapp-service
          port: 80
```

### Apply and Verify

```bash
# Apply the HTTPRoute
kubectl-homelab apply -f manifests/myapp/httproute.yaml

# Check HTTPRoute status
kubectl-homelab get httproute -A

# Check Gateway accepts the route
kubectl-homelab describe httproute myapp -n myapp-namespace

# Test access
curl -I https://myapp.k8s.rommelporras.com
```

## Key Points

| Topic | Detail |
|-------|--------|
| Namespace | HTTPRoutes can be in ANY namespace |
| Parent ref | Always reference `homelab-gateway` in `default` |
| Base tier | Use `sectionName: https` for *.k8s.rommelporras.com |
| Dev tier | Use `sectionName: https-dev` for *.dev.k8s.rommelporras.com |
| Stg tier | Use `sectionName: https-stg` for *.stg.k8s.rommelporras.com |
| No TLS config | HTTPRoute doesn't need TLS - Gateway handles it |
| DNS | Wildcard already points to Gateway VIP |

## Troubleshooting

```bash
# Check Gateway status
kubectl-homelab get gateway homelab-gateway

# Check certificates
kubectl-homelab get certificate -A
kubectl-homelab describe certificate wildcard-k8s-tls
kubectl-homelab describe certificate wildcard-dev-k8s-tls
kubectl-homelab describe certificate wildcard-stg-k8s-tls

# Check HTTPRoutes
kubectl-homelab get httproute -A

# Check Cilium Gateway
kubectl-homelab -n kube-system get pods -l app.kubernetes.io/name=cilium

# Test DNS resolution
dig grafana.k8s.rommelporras.com
dig portfolio.dev.k8s.rommelporras.com

# Test TLS
curl -vI https://grafana.k8s.rommelporras.com 2>&1 | grep -A5 "Server certificate"
```

## Configuration Files

| File | Purpose |
|------|---------|
| manifests/gateway/homelab-gateway.yaml | Gateway resource |
| manifests/cert-manager/cluster-issuer.yaml | Let's Encrypt issuers |
| manifests/monitoring/grafana-httproute.yaml | Grafana route |

## Related

- [[Networking]] - VIPs, DNS records
- [[Secrets]] - Cloudflare API token
- [[Monitoring]] - Grafana access
