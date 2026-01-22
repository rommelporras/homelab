# Phase 4.9: Tailscale Kubernetes Operator

> **Status:** 📋 Planned
> **Priority:** Medium (quality of life - mobile access)
> **CKA Topics:** Ingress, Services, RBAC, Secrets
> **Namespace:** `tailscale`

> **Goal:** Enable secure remote access to homelab services from phone/laptop via Tailscale mesh VPN, without exposing services to public internet.

---

## Overview

The Tailscale Kubernetes Operator manages Tailscale resources natively in Kubernetes, allowing:
- **Ingress**: Expose K8s services to your Tailscale network (access from phone)
- **Egress**: Allow pods to access external tailnet resources
- **Subnet Router**: Route traffic to cluster network from tailnet devices

**Use Case:** Access Homepage, Grafana, Longhorn UI, etc. from phone while away from home without Cloudflare Tunnel or public exposure.

---

## Prerequisites

- [ ] Existing Tailscale account with tailnet configured
- [ ] MagicDNS and HTTPS enabled on tailnet (Tailscale admin console)
- [ ] Phone/devices already joined to tailnet

---

## Implementation Plan

### 4.9.1 Create OAuth Credentials

1. Go to Tailscale Admin Console → Settings → OAuth Clients
2. Create new OAuth client with scopes:
   - `devices:core` (read/write)
   - `auth_keys` (read/write)
   - `services` (write)
3. Save Client ID and Client Secret to 1Password
   ```bash
   op item create --category=login --title="Tailscale K8s Operator" \
     --vault=Kubernetes \
     client-id="<client-id>" \
     client-secret="<client-secret>"
   ```

### 4.9.2 Configure Tailnet ACL Tags

Add to Tailscale ACL policy (Admin Console → Access Controls):
```json
{
  "tagOwners": {
    "tag:k8s-operator": [],
    "tag:k8s": ["tag:k8s-operator"]
  }
}
```

### 4.9.3 Install Operator via Helm

```bash
# Add Tailscale Helm repo
helm-homelab repo add tailscale https://pkgs.tailscale.com/helmcharts
helm-homelab repo update

# Create values file
mkdir -p helm/tailscale-operator

# Install operator
helm-homelab upgrade --install tailscale-operator tailscale/tailscale-operator \
  --namespace=tailscale \
  --create-namespace \
  --set-string oauth.clientId="$(op read 'op://Kubernetes/Tailscale K8s Operator/client-id')" \
  --set-string oauth.clientSecret="$(op read 'op://Kubernetes/Tailscale K8s Operator/client-secret')" \
  --wait
```

### 4.9.4 Verify Operator Installation

```bash
kubectl-homelab get pods -n tailscale
kubectl-homelab get ingressclass
# Should show 'tailscale' IngressClass
```

### 4.9.5 Expose Services via Tailscale Ingress

Create Ingress resources for key services:

```yaml
# manifests/home/homepage/tailscale-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: homepage-tailscale
  namespace: home
spec:
  ingressClassName: tailscale
  tls:
    - hosts:
        - homepage
  rules:
    - host: homepage
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: homepage
                port:
                  number: 3000
```

Services to expose:
- [ ] Homepage → `homepage.<tailnet>.ts.net`
- [ ] Grafana → `grafana.<tailnet>.ts.net`
- [ ] Longhorn → `longhorn.<tailnet>.ts.net`
- [ ] AdGuard → `adguard.<tailnet>.ts.net`

### 4.9.6 Test Mobile Access

1. Open Tailscale app on phone
2. Connect to tailnet
3. Navigate to `https://homepage.<tailnet>.ts.net`
4. Verify all services accessible

### 4.9.7 Update Homepage Widget

After operator is running, update Homepage to use proper Tailscale widget:
```yaml
# services.yaml - Network section
- Tailscale:
    icon: tailscale.png
    href: https://login.tailscale.com/admin/machines
    description: VPN Mesh Network
    statusStyle: dot
    widget:
      type: tailscale
      deviceid: "{{HOMEPAGE_VAR_TAILSCALE_DEVICE}}"
      key: "{{HOMEPAGE_VAR_TAILSCALE_KEY}}"
```

---

## Architecture Decisions

### Why Tailscale Operator vs Manual Sidecar?

| Approach | Pros | Cons |
|----------|------|------|
| **Operator** | Native K8s resources, automatic cert management, IngressClass | Additional component to manage |
| **Sidecar** | Simple, per-pod control | Manual config per service, no central management |

**Decision:** Use Operator for centralized management and native Ingress support.

### Why Not Cloudflare Tunnel?

| Approach | Pros | Cons |
|----------|------|------|
| **Tailscale** | Private (tailnet only), no public exposure, works offline | Requires Tailscale on all devices |
| **Cloudflare** | Public access, no client needed | Exposes to internet, requires domain |

**Decision:** Tailscale for private/secure access; Cloudflare Tunnel for public services (Phase 4.5).

---

## Security Considerations

1. **OAuth Credentials**: Stored in 1Password, injected at Helm install time
2. **ACL Tags**: Operator tagged separately from workloads for least-privilege
3. **TLS**: Automatic via Tailscale (valid 90 days, auto-renew)
4. **No Public Exposure**: Services only accessible to tailnet members

---

## Files to Create

```
helm/tailscale-operator/
└── values.yaml                    # Helm values (if customization needed)

manifests/home/homepage/
└── tailscale-ingress.yaml         # Tailscale Ingress for Homepage

manifests/monitoring/
└── tailscale-ingress.yaml         # Tailscale Ingress for Grafana

manifests/storage/longhorn/
└── tailscale-ingress.yaml         # Tailscale Ingress for Longhorn
```

---

## Verification Checklist

- [ ] Operator pod running in `tailscale` namespace
- [ ] `tailscale` IngressClass available
- [ ] Services appear in Tailscale admin console
- [ ] Mobile access works via MagicDNS names
- [ ] TLS certificates valid
- [ ] Homepage Tailscale widget functional

---

## References

- [Tailscale Kubernetes Operator](https://tailscale.com/kb/1236/kubernetes-operator)
- [Kubernetes Operator Ingress](https://tailscale.com/kb/1439/kubernetes-operator-ingress)
- [Tailscale on Kubernetes Overview](https://tailscale.com/kb/1185/kubernetes)

---

## Notes for Talos Rebuild

When rebuilding on Talos Linux:
1. Same Helm install command works
2. OAuth credentials from 1Password
3. May need to adjust Pod Security Standards for operator
4. Ingress resources are portable (just re-apply)
