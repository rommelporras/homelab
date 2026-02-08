# Phase 4.10: Tailscale Kubernetes Operator

> **Status:** Planned
> **Target:** v0.24.0
> **Prerequisite:** Phase 4.9 complete (Invoicetron), services to expose exist
> **Priority:** Medium (quality of life - mobile access)
> **DevOps Topics:** Mesh VPN, zero-trust networking, IngressClass
> **CKA Topics:** Ingress, Services, RBAC, Secrets

> **Goal:** Enable secure remote access to homelab services from phone/laptop via Tailscale mesh VPN, without exposing services to public internet
>
> **Learning Goal:** Understand mesh VPN architecture and Kubernetes Ingress patterns

---

## Overview

The Tailscale Kubernetes Operator manages Tailscale resources natively in Kubernetes, allowing:
- **Ingress**: Expose K8s services to your Tailscale network (access from phone)
- **Egress**: Allow pods to access external tailnet resources
- **Subnet Router**: Route traffic to cluster network from tailnet devices

**Use Case:** Access Homepage, Grafana, Longhorn UI, etc. from phone while away from home without Cloudflare Tunnel or public exposure.

---

## Prerequisites

Before starting, ensure:
- Tailscale account with tailnet configured
- MagicDNS enabled (Admin Console → DNS)
- HTTPS certificates enabled (Admin Console → Settings → Keys)
- Phone/laptop already joined to your tailnet

---

## 4.10.1 Create OAuth Credentials

- [ ] 4.10.1.1 Create OAuth client in Tailscale Admin Console
  ```
  1. Go to https://login.tailscale.com/admin/settings/oauth
  2. Click "Generate OAuth Client"
  3. Name: "K8s Operator"
  4. Select scopes:
     - devices:core (read/write)
     - auth_keys (read/write)
     - services (write)
  5. Add tag: tag:k8s-operator
  6. Click "Generate"
  7. Copy Client ID and Client Secret (shown only once!)
  ```

- [ ] 4.10.1.2 Store credentials in 1Password
  ```bash
  # Create item in 1Password Kubernetes vault:
  #   Item Name: Tailscale K8s Operator
  #   Type: API Credential
  #   Fields:
  #     - client-id: <from step above>
  #     - client-secret: <from step above>
  #
  # Verify:
  op read "op://Kubernetes/Tailscale K8s Operator/client-id" >/dev/null && echo "ID OK"
  op read "op://Kubernetes/Tailscale K8s Operator/client-secret" >/dev/null && echo "Secret OK"
  ```

---

## 4.10.2 Configure Tailnet ACL Tags

- [ ] 4.10.2.1 Add ACL tags for K8s operator
  ```
  1. Go to https://login.tailscale.com/admin/acls
  2. Edit the ACL policy
  3. Add to "tagOwners" section:
  ```
  ```json
  {
    "tagOwners": {
      "tag:k8s-operator": [],
      "tag:k8s": ["tag:k8s-operator"]
    }
  }
  ```
  ```
  4. Save changes
  ```

---

## 4.10.3 Install Operator via Helm

- [ ] 4.10.3.1 Add Tailscale Helm repo
  ```bash
  helm-homelab repo add tailscale https://pkgs.tailscale.com/helmcharts --force-update
  helm-homelab repo update
  ```

- [ ] 4.10.3.2 Create values file directory
  ```bash
  mkdir -p helm/tailscale-operator
  ```

- [ ] 4.10.3.3 Install operator with OAuth credentials from 1Password
  ```bash
  eval $(op signin)

  helm-homelab upgrade --install tailscale-operator tailscale/tailscale-operator \
    --namespace=tailscale \
    --create-namespace \
    --set-string oauth.clientId="$(op read 'op://Kubernetes/Tailscale K8s Operator/client-id')" \
    --set-string oauth.clientSecret="$(op read 'op://Kubernetes/Tailscale K8s Operator/client-secret')" \
    --wait
  ```

---

## 4.10.4 Verify Operator Installation

- [ ] 4.10.4.1 Check operator pod is running
  ```bash
  kubectl-homelab get pods -n tailscale
  # Should show operator pod in Running state
  ```

- [ ] 4.10.4.2 Verify IngressClass created
  ```bash
  kubectl-homelab get ingressclass
  # Should show 'tailscale' IngressClass
  ```

- [ ] 4.10.4.3 Check Tailscale admin console
  ```
  Go to https://login.tailscale.com/admin/machines
  Should see new device: "tailscale-operator" or similar
  ```

---

## 4.10.5 Expose Services via Tailscale Ingress

- [ ] 4.10.5.1 Create Tailscale Ingress for Homepage
  ```bash
  kubectl-homelab apply -f manifests/home/homepage/tailscale-ingress.yaml
  ```
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

- [ ] 4.10.5.2 Create Tailscale Ingress for Grafana
  ```bash
  kubectl-homelab apply -f manifests/monitoring/grafana-tailscale-ingress.yaml
  ```
  ```yaml
  # manifests/monitoring/grafana-tailscale-ingress.yaml
  apiVersion: networking.k8s.io/v1
  kind: Ingress
  metadata:
    name: grafana-tailscale
    namespace: monitoring
  spec:
    ingressClassName: tailscale
    tls:
      - hosts:
          - grafana
    rules:
      - host: grafana
        http:
          paths:
            - path: /
              pathType: Prefix
              backend:
                service:
                  name: prometheus-grafana
                  port:
                    number: 80
  ```

- [ ] 4.10.5.3 Create additional Ingresses as needed
  ```bash
  # Longhorn UI
  # Namespace: longhorn-system, Service: longhorn-frontend, Port: 80

  # AdGuard Home
  # Namespace: home, Service: adguard-home, Port: 3000
  ```

- [ ] 4.10.5.4 Verify Ingresses are provisioned
  ```bash
  kubectl-homelab get ingress -A | grep tailscale
  # Each should show an ADDRESS (may take 1-2 minutes)

  # Check Tailscale admin console for new devices
  # Each Ingress creates a new machine in your tailnet
  ```

---

## 4.10.6 Test Mobile Access

- [ ] 4.10.6.1 Connect phone to Tailscale
  ```
  1. Open Tailscale app on phone
  2. Ensure connected to your tailnet
  3. Check that MagicDNS is enabled (Settings → Use Tailscale DNS)
  ```

- [ ] 4.10.6.2 Test access to exposed services
  ```
  From phone browser, navigate to:
  - https://homepage.<tailnet-name>.ts.net
  - https://grafana.<tailnet-name>.ts.net

  Note: Your tailnet name is shown in Tailscale admin console
  Example: https://homepage.tail12345.ts.net
  ```

- [ ] 4.10.6.3 Verify TLS certificates
  ```
  Click the lock icon in browser
  Certificate should be issued by "Tailscale Inc"
  Valid for 90 days (auto-renews)
  ```

---

## 4.10.7 Update Homepage Widget

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

## 4.10.8 Documentation Updates

- [ ] 4.10.8.1 Update VERSIONS.md
  ```
  # Add to Infrastructure section:
  | Tailscale Operator | 1.x.x | VPN mesh access for K8s |

  # Add to Version History:
  | YYYY-MM-DD | Phase 4.10: Tailscale Operator for mobile access |
  ```

- [ ] 4.10.8.2 Update docs/context/Secrets.md
  ```
  # Add 1Password item:
  | Tailscale K8s Operator | client-id, client-secret | OAuth for operator |
  ```

- [ ] 4.10.8.3 Update docs/reference/CHANGELOG.md
  - Add Phase 4.10 section with milestone, decisions, lessons learned

---

## Verification Checklist

- [ ] Operator pod running in `tailscale` namespace
- [ ] `tailscale` IngressClass available (`kubectl-homelab get ingressclass`)
- [ ] Operator device appears in Tailscale admin console
- [ ] Ingress resources have ADDRESS assigned
- [ ] Services accessible via `https://<name>.<tailnet>.ts.net`
- [ ] Mobile access works from phone (not on home network)
- [ ] TLS certificates valid (issued by Tailscale)
- [ ] Homepage Tailscale widget functional (optional)

---

## Rollback

If issues occur:

```bash
# 1. Remove Ingress resources (stops exposing services)
kubectl-homelab delete ingress -l ingressClassName=tailscale -A

# 2. Uninstall operator
helm-homelab uninstall tailscale-operator -n tailscale

# 3. Clean up namespace
kubectl-homelab delete namespace tailscale

# 4. Remove devices from Tailscale admin console
#    Admin Console → Machines → Remove orphaned K8s devices
```

---

## Troubleshooting

### Operator pod not starting

```bash
# Check pod status
kubectl-homelab describe pod -n tailscale -l app.kubernetes.io/name=operator

# Check logs
kubectl-homelab logs -n tailscale -l app.kubernetes.io/name=operator

# Common issues:
# - Invalid OAuth credentials → recreate from 1Password
# - ACL tags not configured → add tagOwners in Tailscale ACLs
```

### Ingress stuck without ADDRESS

```bash
# Check Ingress status
kubectl-homelab describe ingress <name> -n <namespace>

# Check operator logs for errors
kubectl-homelab logs -n tailscale -l app.kubernetes.io/name=operator | grep -i error

# Common issues:
# - Service doesn't exist → verify backend service
# - OAuth scope missing → regenerate OAuth client with all scopes
```

### Can't access from mobile

```bash
# Verify phone is on Tailscale network
# Phone app should show "Connected"

# Verify MagicDNS is enabled on phone
# Settings → Use Tailscale DNS → ON

# Try IP instead of hostname
# Get IP from: Admin Console → Machines → click service
```

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

---

## Final: Commit and Release

- [ ] Commit changes
  ```bash
  /commit
  ```

- [ ] Release v0.12.0
  ```bash
  /release v0.12.0
  ```

- [ ] Move this file to completed folder
  ```bash
  mv docs/todo/phase-4.10-tailscale-operator.md docs/todo/completed/
  ```
