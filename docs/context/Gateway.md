---
tags: [homelab, kubernetes, gateway, tls, cert-manager]
updated: 2026-02-01
---

# Gateway API

Gateway API for HTTPS ingress with automatic TLS certificates.

## Architecture

```
                        Internet
                            │
                            ▼
┌─────────────────────────────────────────────────────┐
│              AdGuard DNS (10.10.30.53)              │
│     *.k8s.home.rommelporras.com → 10.10.30.20       │
└─────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────┐
│           Cilium L2 Announcement                    │
│              VIP: 10.10.30.20                       │
└─────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────┐
│              homelab-gateway                        │
│         (Gateway in default namespace)              │
│    Port 80 (HTTP) │ Port 443 (HTTPS + TLS)          │
└─────────────────────────────────────────────────────┘
                            │
    ┌───────┬───────┬───────┼───────┬───────┬───────┬─────────┐
    ▼       ▼       ▼       ▼       ▼       ▼       ▼         ▼
┌──────┐┌──────┐┌──────┐┌──────┐┌──────┐┌──────┐┌──────┐┌─────────┐
│Grafan││AdGuar││Homepg││Longh.││GitLab││Regist││Portfol││Portfolio││Ghost ││Ghost │
│ :80  ││:3000 ││:3000 ││ :80  ││:8181 ││:5000 ││dev:80 ││stag/prod││dev   ││prod  │
└──────┘└──────┘└──────┘└──────┘└──────┘└──────┘└──────┘└─────────┘└──────┘└──────┘
```

## Components

| Component | Namespace | Purpose |
|-----------|-----------|---------|
| homelab-gateway | default | Shared Gateway for all services |
| letsencrypt-prod | cluster-wide | ClusterIssuer for TLS certs |
| wildcard-k8s-home-tls | default | Wildcard certificate secret |
| HTTPRoutes | per-service | Route traffic to services |

## Gateway Resource

| Setting | Value |
|---------|-------|
| Name | homelab-gateway |
| Namespace | default |
| Class | cilium |
| VIP | 10.10.30.20 |
| Wildcard | *.k8s.home.rommelporras.com |

Listeners:
- **http** (port 80) - For future HTTP→HTTPS redirect
- **https** (port 443) - TLS termination with wildcard cert

## TLS Certificate Chain

```
cert-manager.io/cluster-issuer: letsencrypt-prod
        │
        ▼
┌─────────────────────────────────────────┐
│         ClusterIssuer                   │
│         letsencrypt-prod                │
│                                         │
│  ACME Server: Let's Encrypt             │
│  Challenge: DNS-01 via Cloudflare       │
│  API Token: cloudflare-api-token secret │
└─────────────────────────────────────────┘
        │
        ▼
┌─────────────────────────────────────────┐
│         Certificate (auto-created)      │
│         wildcard-k8s-home-tls           │
│                                         │
│  Domains: *.k8s.home.rommelporras.com   │
│  Validity: 90 days (auto-renewed)       │
└─────────────────────────────────────────┘
```

## Exposed Services

| Service | URL | HTTPRoute | Namespace |
|---------|-----|-----------|-----------|
| Grafana | https://grafana.k8s.home.rommelporras.com | grafana | monitoring |
| AdGuard | https://adguard.k8s.home.rommelporras.com | adguard | home |
| Homepage | https://portal.k8s.home.rommelporras.com | homepage | home |
| Longhorn | https://longhorn.k8s.home.rommelporras.com | longhorn | longhorn-system |
| GitLab | https://gitlab.k8s.home.rommelporras.com | gitlab | gitlab |
| GitLab Registry | https://registry.k8s.home.rommelporras.com | gitlab-registry | gitlab |
| Portfolio Dev | https://portfolio-dev.k8s.home.rommelporras.com | portfolio | portfolio-dev |
| Portfolio Staging | https://portfolio-staging.k8s.home.rommelporras.com | portfolio | portfolio-staging |
| Portfolio Prod | https://portfolio-prod.k8s.home.rommelporras.com | portfolio | portfolio-prod |
| Ghost Dev | https://blog-dev.k8s.home.rommelporras.com | ghost | ghost-dev |
| Ghost Prod | https://blog.k8s.home.rommelporras.com | ghost | ghost-prod |

## Adding a New Service

### 1. Create HTTPRoute

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
    - myapp.k8s.home.rommelporras.com
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: myapp-service
          port: 80
```

### 2. Apply and Verify

```bash
# Apply the HTTPRoute
kubectl-homelab apply -f manifests/myapp/httproute.yaml

# Check HTTPRoute status
kubectl-homelab get httproute -A

# Check Gateway accepts the route
kubectl-homelab describe httproute myapp -n myapp-namespace

# Test access
curl -I https://myapp.k8s.home.rommelporras.com
```

## Key Points

| Topic | Detail |
|-------|--------|
| Namespace | HTTPRoutes can be in ANY namespace |
| Parent ref | Always reference `homelab-gateway` in `default` |
| Section | Use `sectionName: https` for TLS |
| No TLS config | HTTPRoute doesn't need TLS - Gateway handles it |
| DNS | Wildcard already points to Gateway VIP |

## Troubleshooting

```bash
# Check Gateway status
kubectl-homelab get gateway homelab-gateway

# Check certificate
kubectl-homelab get certificate -A
kubectl-homelab describe certificate wildcard-k8s-home-tls

# Check HTTPRoutes
kubectl-homelab get httproute -A

# Check Cilium Gateway
kubectl-homelab -n kube-system get pods -l app.kubernetes.io/name=cilium

# Test DNS resolution
dig grafana.k8s.home.rommelporras.com

# Test TLS
curl -vI https://grafana.k8s.home.rommelporras.com 2>&1 | grep -A5 "Server certificate"
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
