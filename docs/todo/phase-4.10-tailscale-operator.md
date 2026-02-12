# Phase 4.10: Tailscale Operator (Subnet Router)

> **Status:** Planned
> **Target:** v0.24.0
> **Prerequisite:** Phase 4.24 complete (Karakeep running), AdGuard DNS operational (10.10.30.53)
> **Priority:** Medium (quality of life — mobile access to all services)
> **DevOps Topics:** Mesh VPN, zero-trust networking, subnet routing, WireGuard, CRDs
> **CKA Topics:** Ingress, Services, RBAC, CRDs, Namespaces, NetworkPolicy

> **Goal:** Enable secure remote access to ALL homelab services from phone/laptop via Tailscale mesh VPN using a subnet router — without exposing services to public internet and without per-service manifests.
>
> **Learning Goal:** Understand mesh VPN architecture, Kubernetes CRD operators, and subnet routing patterns.

---

## Architecture

**Approach: Subnet Router (Connector)** — mirrors old Proxmox pattern.

The Connector CRD creates a single pod that advertises the entire `10.10.30.0/24` subnet to the tailnet. All existing HTTPRoutes work through the subnet route — zero per-service manifests needed.

```
Phone/Laptop (Tailscale client)
    │
    │ WireGuard tunnel (encrypted)
    ▼
Connector Pod (subnet router, advertises 10.10.30.0/24)
    │
    │ subnet route (10.10.30.0/24 reachable from tailnet)
    ▼
AdGuard DNS (10.10.30.53) ← Tailscale global nameserver
    │
    │ resolves *.k8s.rommelporras.com → 10.10.30.20
    ▼
Cilium Gateway (10.10.30.20)
    │
    │ HTTPRoute matching
    ▼
Backend Service (Homepage, Grafana, Longhorn, Ghost, etc.)
```

### Traffic Flow Comparison

| Step | Old (Proxmox) | New (Kubernetes) |
|------|---------------|------------------|
| 1 | Phone → Tailscale | Phone → Tailscale |
| 2 | → AdGuard DNS (Proxmox VM) | → Connector Pod (subnet route) |
| 3 | → NPM reverse proxy | → AdGuard DNS (10.10.30.53) |
| 4 | → Service | → Cilium Gateway (10.10.30.20) → Service |

### Why Subnet Router (Not Per-Service Ingress)

| Approach | Pros | Cons |
|----------|------|------|
| **Connector (subnet router)** | 1 pod for ALL services, zero per-service manifests, mirrors Proxmox pattern | Entire subnet reachable (mitigated by ACLs) |
| **Per-service Ingress** | Fine-grained control per service | 1 proxy pod per service, Tailscale IngressClass, new manifests for every service |
| **ProxyGroup** | Shared replicas, HA | More complex, still per-service configuration |

**Decision:** Connector. Simpler, less resource overhead, and all existing HTTPRoutes + TLS certs continue working unchanged.

---

## Current Tailscale State

| Item | Value |
|------|-------|
| Tailnet | `capybara-interval.ts.net` |
| MagicDNS | Enabled |
| HTTPS certs | Not enabled (not needed — using existing Let's Encrypt certs via Cilium Gateway) |
| Global nameserver | `100.123.128.54` (**dead** — old Proxmox AdGuard, offline since Aug 2025) |
| Active device | `immich` VM on Proxmox (100.74.244.90, v1.94.1) |
| Dead devices | `tailscale-adguardhome`, `tailscale-nginxproxymanager` |
| Expired phones | 2 Samsung, 1 iPhone |

### Cleanup Required Before Install

- Remove dead devices: `tailscale-adguardhome`, `tailscale-nginxproxymanager`
- Re-authorize expired phones
- Replace dead global nameserver `100.123.128.54` → `10.10.30.53` (K8s AdGuard via subnet route)
- Verify `immich` VM still works after changes (no conflicts — different subnet)

---

## Container Images

| Component | Image | Purpose |
|-----------|-------|---------|
| Operator | `tailscale/k8s-operator:v1.94.1` | Watches CRDs (Connector, ProxyGroup, etc.), manages proxy pods |
| Proxy | `tailscale/tailscale:v1.94.1` | WireGuard tunnel + subnet routing (created by operator for Connector) |

---

## Resource Limits

| Container | CPU Req/Limit | Memory Req/Limit | Notes |
|-----------|---------------|------------------|-------|
| Operator | 50m / 200m | 64Mi / 128Mi | Lightweight controller — watches CRDs, reconciles state |
| Proxy (Connector) | 50m / 200m | 64Mi / 128Mi | WireGuard userspace — minimal overhead for subnet routing |

---

## Security

### PSS Labels

```yaml
pod-security.kubernetes.io/enforce: privileged
pod-security.kubernetes.io/audit: privileged
pod-security.kubernetes.io/warn: privileged
```

**Why privileged:** Tailscale proxy pods require `NET_ADMIN` and `NET_RAW` capabilities for WireGuard tunnel setup and routing table manipulation. This is a hard requirement from the operator — pods create TUN devices and modify iptables rules.

### Network Policy Strategy

| Component | Direction | Rules |
|-----------|-----------|-------|
| Operator | Egress | K8s API (6443), Tailscale coordination servers (HTTPS/443), DNS |
| Connector proxy | Egress | Cluster network (10.10.30.0/24), Tailscale coordination (HTTPS/443), DNS |
| Connector proxy | Ingress | WireGuard from tailnet devices (UDP/41641) |

### 1Password Item

Create before deployment:

```bash
# Create 1Password item (store OAuth client credentials from Tailscale admin console)
# Item Name: Tailscale K8s Operator
# Vault: Kubernetes
# Type: API Credential
# Fields:
#   - client-id: <from OAuth client generation>
#   - client-secret: <from OAuth client generation>

# Verify:
op read "op://Kubernetes/Tailscale K8s Operator/client-id" >/dev/null && echo "ID OK"
op read "op://Kubernetes/Tailscale K8s Operator/client-secret" >/dev/null && echo "Secret OK"
```

---

## Tasks

### 4.10.0 Prerequisites

- [ ] 4.10.0.1 Verify Tailscale account active and MagicDNS enabled:
  ```
  Admin Console → DNS → MagicDNS: Enabled
  ```
- [ ] 4.10.0.2 Clean up dead Proxmox devices from tailnet:
  ```
  Admin Console → Machines → Remove:
    - tailscale-adguardhome (offline since Aug 2025)
    - tailscale-nginxproxymanager (offline since Aug 2025)
  ```
- [ ] 4.10.0.3 Re-authorize expired phones:
  ```
  Admin Console → Machines → Re-authorize:
    - Samsung phones (2)
    - iPhone (1)
  ```
- [ ] 4.10.0.4 Verify `immich` VM still active (100.74.244.90) — should not be affected by K8s changes

### 4.10.1 Tailscale Admin Console Setup

- [ ] 4.10.1.1 Configure ACL tags and auto-approvers:
  ```
  Admin Console → Access Controls → Edit policy
  ```
  ```json
  {
    "tagOwners": {
      "tag:k8s-operator": [],
      "tag:k8s": ["tag:k8s-operator"]
    },
    "autoApprovers": {
      "routes": {
        "10.10.30.0/24": ["tag:k8s"]
      }
    },
    "acls": [
      {
        "action": "accept",
        "src": ["autogroup:member"],
        "dst": ["*:*"]
      }
    ]
  }
  ```
  **Why `autoApprovers`:** Without this, the Connector advertises the subnet route but traffic won't flow until manually approved in the admin console. Auto-approval eliminates this manual step.

- [ ] 4.10.1.2 Create OAuth client:
  ```
  Admin Console → Settings → OAuth clients → Generate OAuth client
    Name: "K8s Operator"
    Scopes:
      - Devices: Core (Read & Write)
      - Auth Keys (Read & Write)
      - Services (Write)  -- not strictly required for Connector, but needed if adding Ingress later
    Tag: tag:k8s-operator
  ```
  **Copy Client ID and Client Secret immediately — shown only once.**

- [ ] 4.10.1.3 Store credentials in 1Password:
  ```bash
  # Create item manually in 1Password:
  #   Vault: Kubernetes
  #   Title: Tailscale K8s Operator
  #   Type: API Credential
  #   Fields: client-id, client-secret

  # Verify:
  eval $(op signin)
  op read "op://Kubernetes/Tailscale K8s Operator/client-id" >/dev/null && echo "ID OK"
  op read "op://Kubernetes/Tailscale K8s Operator/client-secret" >/dev/null && echo "Secret OK"
  ```

### 4.10.2 Cilium Compatibility Fix

> **BLOCKER:** Must be done BEFORE installing Tailscale operator. Without this fix, Cilium's eBPF socket-level load balancing intercepts traffic inside proxy pod network namespaces, breaking WireGuard routing. Symptoms: proxy pod starts but no traffic flows through subnet route.

- [ ] 4.10.2.1 Add `socketLB.hostNamespaceOnly: true` to `helm/cilium/values.yaml`:
  ```yaml
  # =============================================================================
  # Socket LB Scope
  # =============================================================================
  # Restrict eBPF socket-level LB to host namespace only.
  # Required for Tailscale proxy pods — without this, Cilium intercepts traffic
  # inside pod network namespaces, breaking WireGuard tunnel routing.
  # Docs: https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/#socket-lb
  socketLB:
    hostNamespaceOnly: true
  ```

- [ ] 4.10.2.2 Apply Cilium upgrade:
  ```bash
  helm-homelab upgrade cilium cilium/cilium \
    --namespace kube-system \
    --version 1.18.6 \
    -f helm/cilium/values.yaml
  ```

- [ ] 4.10.2.3 Verify Cilium rollout:
  ```bash
  kubectl-homelab -n kube-system rollout status daemonset/cilium --timeout=120s
  kubectl-homelab -n kube-system get pods -l k8s-app=cilium
  # All 3 cilium pods should be Running (1/1)
  ```

- [ ] 4.10.2.4 Verify existing services still work after Cilium change:
  ```bash
  # Quick smoke test — Homepage should still load
  curl -sk https://portal.k8s.rommelporras.com | head -5
  ```

### 4.10.3 Create Namespace & Manifests

- [ ] 4.10.3.1 Create `manifests/tailscale/namespace.yaml`:
  ```yaml
  # Tailscale operator namespace
  # Phase 4.10 - Tailscale Operator (Subnet Router)
  #
  # PSS: privileged enforce (proxy pods require NET_ADMIN + NET_RAW for WireGuard tunnel)
  ---
  apiVersion: v1
  kind: Namespace
  metadata:
    name: tailscale
    labels:
      app.kubernetes.io/part-of: tailscale
      pod-security.kubernetes.io/enforce: privileged
      pod-security.kubernetes.io/audit: privileged
      pod-security.kubernetes.io/warn: privileged
  ```

- [ ] 4.10.3.2 Document OAuth secret (Helm-managed — no file committed):
  ```
  The Tailscale OAuth secret is created by Helm during install (step 4.10.4.5)
  using --set-string flags with 1Password CLI values. No secret.yaml is committed.

  Secret name: operator-oauth (namespace: tailscale)
  Fields:
    - client_id:     op://Kubernetes/Tailscale K8s Operator/client-id
    - client_secret: op://Kubernetes/Tailscale K8s Operator/client-secret

  To recreate manually if Helm secret is lost:
    kubectl-homelab create secret generic operator-oauth -n tailscale \
      --from-literal=client_id="$(op read 'op://Kubernetes/Tailscale K8s Operator/client-id')" \
      --from-literal=client_secret="$(op read 'op://Kubernetes/Tailscale K8s Operator/client-secret')"
  ```

- [ ] 4.10.3.3 Create `manifests/tailscale/connector.yaml`:
  ```yaml
  # Tailscale Connector — subnet router for homelab network
  # Phase 4.10 - Tailscale Operator
  #
  # Advertises 10.10.30.0/24 to the tailnet, making all K8s services
  # reachable from Tailscale-connected devices via existing HTTPRoutes.
  # Routes are auto-approved via ACL autoApprovers (no manual approval needed).
  ---
  apiVersion: tailscale.com/v1alpha1
  kind: Connector
  metadata:
    name: homelab-network
  spec:
    subnetRouter:
      advertiseRoutes:
        - "10.10.30.0/24"
    tags:
      - "tag:k8s"
    hostname: "homelab-subnet"
  ```

- [ ] 4.10.3.4 Create `manifests/tailscale/networkpolicy.yaml`:
  - CiliumNetworkPolicy for operator and connector proxy pods
  - Operator egress: K8s API, Tailscale coordination servers (HTTPS), DNS
  - Connector proxy egress: cluster network (10.10.30.0/24), Tailscale coordination (HTTPS), DNS
  - Connector proxy ingress: WireGuard (UDP/41641) from any source (tailnet devices)

- [ ] 4.10.3.5 Dry-run validate all manifests:
  ```bash
  kubectl-homelab apply --dry-run=client -f manifests/tailscale/namespace.yaml
  # Note: connector.yaml requires CRDs from operator — dry-run after Helm install
  ```

### 4.10.4 Helm Values & Install

- [ ] 4.10.4.1 Create `helm/tailscale-operator/values.yaml`:
  ```yaml
  # Tailscale Kubernetes Operator Helm values
  # Phase 4.10 - Tailscale Operator (Subnet Router)
  # Docs: https://tailscale.com/kb/1236/kubernetes-operator

  operatorConfig:
    hostname: "tailscale-operator"
    resources:
      requests:
        cpu: 50m
        memory: 64Mi
      limits:
        cpu: 200m
        memory: 128Mi

  proxyConfig:
    defaultTags:
      - "tag:k8s"
    defaultResources:
      requests:
        cpu: 50m
        memory: 64Mi
      limits:
        cpu: 200m
        memory: 128Mi

  apiServerProxyConfig:
    mode: "false"  # Enable in 4.10.9 if desired
  ```

- [ ] 4.10.4.2 Add Tailscale Helm repo:
  ```bash
  helm-homelab repo add tailscale https://pkgs.tailscale.com/helmcharts --force-update
  helm-homelab repo update
  ```

- [ ] 4.10.4.3 Check latest chart version:
  ```bash
  helm-homelab search repo tailscale/tailscale-operator --versions | head -5
  # Note the latest chart version for use in the install command below
  ```

- [ ] 4.10.4.4 Apply namespace and network policy:
  ```bash
  kubectl-homelab apply -f manifests/tailscale/namespace.yaml
  kubectl-homelab apply -f manifests/tailscale/networkpolicy.yaml
  ```

- [ ] 4.10.4.5 Install operator with OAuth credentials from 1Password:
  ```bash
  eval $(op signin)

  helm-homelab upgrade --install tailscale-operator tailscale/tailscale-operator \
    --namespace tailscale \
    --version <CHART_VERSION_FROM_4.10.4.3> \
    -f helm/tailscale-operator/values.yaml \
    --set-string oauth.clientId="$(op read 'op://Kubernetes/Tailscale K8s Operator/client-id')" \
    --set-string oauth.clientSecret="$(op read 'op://Kubernetes/Tailscale K8s Operator/client-secret')" \
    --wait
  ```

- [ ] 4.10.4.6 Verify operator running:
  ```bash
  kubectl-homelab -n tailscale get pods
  # Should show operator pod in Running state

  kubectl-homelab get ingressclass
  # Should show 'tailscale' IngressClass (created automatically)
  ```

- [ ] 4.10.4.7 Verify operator device in Tailscale admin console:
  ```
  Admin Console → Machines
  Should see: "tailscale-operator" device with tag:k8s-operator
  ```

### 4.10.5 Deploy Connector (Subnet Router)

- [ ] 4.10.5.1 Apply Connector CRD:
  ```bash
  kubectl-homelab apply -f manifests/tailscale/connector.yaml
  ```

- [ ] 4.10.5.2 Verify connector proxy pod created:
  ```bash
  kubectl-homelab -n tailscale get pods
  # Should show: operator pod + connector proxy pod (ts-homelab-network-*)
  ```

- [ ] 4.10.5.3 Verify in Tailscale admin console:
  ```
  Admin Console → Machines
  Should see: "homelab-subnet" device with tag:k8s

  Click on "homelab-subnet" → Subnets
  Should show: 10.10.30.0/24 (auto-approved via ACL)
  ```

- [ ] 4.10.5.4 Verify route is approved (not just advertised):
  ```bash
  # From any tailnet device, verify the route exists
  tailscale status
  # Should show homelab-subnet with subnet route 10.10.30.0/24
  ```

### 4.10.6 Tailscale DNS Configuration

> **Critical:** The current global nameserver `100.123.128.54` is dead (old Proxmox AdGuard). This step replaces it with the K8s AdGuard instance reachable via the subnet route.

- [ ] 4.10.6.1 Remove dead global nameserver:
  ```
  Admin Console → DNS → Global Nameservers
  Remove: 100.123.128.54
  ```

- [ ] 4.10.6.2 Add K8s AdGuard as global nameserver:
  ```
  Admin Console → DNS → Global Nameservers
  Add: 10.10.30.53 (reachable via subnet route)
  Toggle: "Override local DNS" → ON
  ```
  **Why global nameserver (not Split DNS):** Global nameserver routes ALL tailnet DNS through AdGuard — same pattern as the old Proxmox setup. This gives ad-blocking + custom rewrites on all tailnet devices, not just `*.k8s.rommelporras.com` queries.

- [ ] 4.10.6.3 Verify DNS resolution from tailnet device:
  ```bash
  # From phone or laptop connected to Tailscale
  nslookup portal.k8s.rommelporras.com
  # Expected: 10.10.30.20 (Cilium Gateway VIP)

  nslookup grafana.k8s.rommelporras.com
  # Expected: 10.10.30.20
  ```

### 4.10.7 Test Mobile Access

- [ ] 4.10.7.1 Connect phone to Tailscale:
  ```
  Open Tailscale app → Ensure connected to capybara-interval.ts.net
  Settings → Use Tailscale DNS → ON
  ```

- [ ] 4.10.7.2 Test Homepage:
  ```
  Browser → https://portal.k8s.rommelporras.com
  Should load Homepage dashboard
  Traffic path: Phone → WireGuard → Connector → AdGuard → Gateway → Homepage
  ```

- [ ] 4.10.7.3 Test additional services (all should work without any new manifests):
  ```
  https://grafana.k8s.rommelporras.com    → Grafana dashboard
  https://longhorn.k8s.rommelporras.com   → Longhorn UI
  https://adguard.k8s.rommelporras.com    → AdGuard admin
  https://blog.k8s.rommelporras.com       → Ghost blog
  https://karakeep.k8s.rommelporras.com   → Karakeep bookmark manager
  ```

- [ ] 4.10.7.4 Verify `immich` VM still accessible on tailnet (no conflicts):
  ```
  # immich should still be reachable at 100.74.244.90
  # It's on a different subnet — no conflict with 10.10.30.0/24
  ```

- [ ] 4.10.7.5 Test with WiFi disabled (cellular only) to confirm true remote access:
  ```
  Disconnect from home WiFi → Use cellular data
  Enable Tailscale → Try https://portal.k8s.rommelporras.com
  Should work (traffic goes through WireGuard tunnel over cellular)
  ```

### 4.10.8 Monitoring

- [ ] 4.10.8.1 Create `manifests/monitoring/tailscale-alerts.yaml` — PrometheusRule:
  - `TailscaleConnectorDown`: connector pod count < 1 for 5m (severity: warning)
    **Why:** If the Connector pod dies, tailnet DNS (global nameserver 10.10.30.53) becomes unreachable, breaking ALL tailnet DNS — not just K8s access. This alert fires before users notice.
  - `TailscaleOperatorDown`: operator pod count < 1 for 5m (severity: warning)
- [ ] 4.10.8.2 Apply alert rules:
  ```bash
  kubectl-homelab apply -f manifests/monitoring/tailscale-alerts.yaml
  ```
- [ ] 4.10.8.3 Verify alerts registered:
  ```bash
  kubectl-homelab -n monitoring get prometheusrule tailscale-alerts
  ```

### 4.10.9 Optional: API Server Proxy

> **Skip initially.** Enable later if remote `kubectl` access is desired (CKA study value).

- [ ] 4.10.9.1 Enable API server proxy in Helm values:
  ```yaml
  apiServerProxyConfig:
    mode: "true"
  ```
  ```bash
  helm-homelab upgrade tailscale-operator tailscale/tailscale-operator \
    --namespace tailscale \
    --version <CHART_VERSION_FROM_4.10.4.3> \
    -f helm/tailscale-operator/values.yaml \
    --set-string oauth.clientId="$(op read 'op://Kubernetes/Tailscale K8s Operator/client-id')" \
    --set-string oauth.clientSecret="$(op read 'op://Kubernetes/Tailscale K8s Operator/client-secret')" \
    --wait
  ```

- [ ] 4.10.9.2 Add RBAC grants in Tailscale ACL:
  ```json
  {
    "grants": [{
      "src": ["autogroup:member"],
      "dst": ["tag:k8s-operator"],
      "app": {
        "tailscale.com/cap/kubernetes": [{
          "impersonate": {
            "groups": ["system:masters"]
          }
        }]
      }
    }]
  }
  ```

- [ ] 4.10.9.3 Configure kubeconfig on laptop:
  ```bash
  tailscale configure kubeconfig tailscale-operator
  ```

- [ ] 4.10.9.4 Test remote kubectl:
  ```bash
  kubectl --context tailscale-operator get nodes
  # Should show 3 homelab nodes
  ```

### 4.10.10 Documentation Updates

> Second commit: documentation only.

- [ ] 4.10.10.1 Update `docs/todo/README.md` — add `tailscale` namespace to table
- [ ] 4.10.10.2 Update `README.md` (root) — add Tailscale Operator to services list + project journey
- [ ] 4.10.10.3 Update `VERSIONS.md` — add Tailscale Operator + chart version (no new HTTPRoute — subnet router)
- [ ] 4.10.10.4 Update `docs/reference/CHANGELOG.md` — architecture decisions, Cilium fix, subnet router rationale
- [ ] 4.10.10.5 Update `docs/context/Networking.md` — add Tailscale VIP/DNS info
- [ ] 4.10.10.6 Update `docs/context/Secrets.md` — add Tailscale K8s Operator 1Password item
- [ ] 4.10.10.7 Update `docs/context/Conventions.md` — add `manifests/tailscale/` to tree
- [ ] 4.10.10.8 Create `docs/rebuild/v0.24.0-tailscale-operator.md` — rebuild guide
- [ ] 4.10.10.9 `/audit-docs`
- [ ] 4.10.10.10 `/commit` (documentation)

### 4.10.11 Commit and Release

- [ ] 4.10.11.1 `/audit-security`
- [ ] 4.10.11.2 `/commit` (infrastructure: Cilium fix + namespace + connector + network policy + alerts + Helm values)
- [ ] 4.10.11.3 Documentation updates (4.10.10)
- [ ] 4.10.11.4 `/release v0.24.0 "Tailscale Operator"`
- [ ] 4.10.11.5 Move this file to `docs/todo/completed/`

---

## Gotchas

| Issue | Impact | Solution |
|-------|--------|---------|
| Missing `socketLB.hostNamespaceOnly` | Proxy pods start but no traffic flows through subnet route | Add to Cilium values BEFORE operator install (step 4.10.2) |
| Proxy pods require `NET_ADMIN` + `NET_RAW` | PSS restricted/baseline blocks pod creation | Use PSS `privileged` on tailscale namespace |
| Routes need approval in admin console | Subnet router advertises but traffic won't flow | Use `autoApprovers` in ACL policy (step 4.10.1) |
| Global nameserver is dead | ALL tailnet DNS queries fail (affecting all devices) | Replace `100.123.128.54` → `10.10.30.53` during DNS migration (step 4.10.6) |
| OAuth client secret shown only once | Can't retrieve after closing the dialog | Store in 1Password immediately during step 4.10.1 |
| Helm creates namespace if `--create-namespace` used | Namespace lacks PSS labels | Apply namespace.yaml BEFORE Helm install (step 4.10.4.4) |
| Connector CRD requires operator running | `kubectl apply` fails if CRDs not yet registered | Deploy Connector AFTER Helm install (step 4.10.5) |
| `immich` VM on same tailnet | Could conflict with subnet routes | No conflict — immich is on Proxmox (different subnet), K8s Connector advertises 10.10.30.0/24 only |
| Global nameserver depends on subnet route | If Connector pod dies, ALL tailnet DNS fails (not just K8s) | PrometheusRule alert `TailscaleConnectorDown` fires within 5m; restart pod or rollback DNS to public resolver |
| First connection may be slow | WireGuard handshake + DERP relay before direct connection established | Normal — subsequent connections are fast (direct WireGuard) |

---

## Verification Checklist

- [ ] Cilium upgraded with `socketLB.hostNamespaceOnly: true`
- [ ] Existing services still work after Cilium upgrade (no regressions)
- [ ] Operator pod Running in `tailscale` namespace
- [ ] `tailscale` IngressClass created (`kubectl-homelab get ingressclass`)
- [ ] Operator device visible in Tailscale admin console
- [ ] Connector proxy pod Running in `tailscale` namespace
- [ ] Connector device (`homelab-subnet`) visible in Tailscale admin console
- [ ] Subnet route `10.10.30.0/24` approved (not just advertised)
- [ ] Dead global nameserver removed (`100.123.128.54`)
- [ ] New global nameserver set (`10.10.30.53`)
- [ ] DNS resolves `*.k8s.rommelporras.com` → `10.10.30.20` from tailnet device
- [ ] Homepage accessible from phone via Tailscale
- [ ] Grafana accessible from phone via Tailscale
- [ ] All existing services work from phone (no per-service manifests needed)
- [ ] `immich` VM still accessible on tailnet (no conflicts)
- [ ] Works from cellular (not home WiFi) — confirms true remote access
- [ ] PrometheusRule `tailscale-alerts` registered in monitoring namespace

---

## Rollback

```bash
# 1. Remove Connector (stops subnet routing)
kubectl-homelab delete connector homelab-network

# 2. Uninstall operator
helm-homelab uninstall tailscale-operator -n tailscale

# 3. Delete namespace
kubectl-homelab delete namespace tailscale

# 4. Revert Cilium (if needed — socketLB.hostNamespaceOnly has no negative impact)
# Remove socketLB section from helm/cilium/values.yaml
# helm-homelab upgrade cilium cilium/cilium -n kube-system -f helm/cilium/values.yaml

# 5. Clean up Tailscale admin console
# Remove orphaned K8s devices (tailscale-operator, homelab-subnet)

# 6. Revert DNS
# Admin Console → DNS → Global Nameservers
# Remove 10.10.30.53, add back 100.123.128.54 (or use public DNS like 1.1.1.1)
```

---

## Troubleshooting

### Operator pod not starting

```bash
kubectl-homelab describe pod -n tailscale -l app.kubernetes.io/name=operator
kubectl-homelab logs -n tailscale -l app.kubernetes.io/name=operator

# Common issues:
# - Invalid OAuth credentials → verify with op read, recreate if needed
# - ACL tags not configured → add tagOwners in Tailscale ACLs
# - PSS blocking → verify namespace has privileged enforce label
```

### Connector pod not starting

```bash
kubectl-homelab -n tailscale get pods
kubectl-homelab -n tailscale describe pod -l app=connector

# Common issues:
# - CRDs not registered → operator must be running first
# - Tag not authorized → verify tag:k8s in ACL tagOwners
```

### Subnet route advertised but not approved

```bash
# Check Tailscale admin console → Machines → homelab-subnet → Subnets
# If route shows "Awaiting approval":
# - Verify autoApprovers ACL includes 10.10.30.0/24 for tag:k8s
# - Manually approve as workaround, then fix ACL
```

### DNS not resolving from tailnet device

```bash
# Verify global nameserver is set correctly
# Admin Console → DNS → Global Nameservers → should show 10.10.30.53

# Verify AdGuard is reachable via subnet route
tailscale ping 10.10.30.53

# Verify AdGuard has DNS rewrites
# AdGuard admin → Filters → DNS Rewrites → should have *.k8s.rommelporras.com → 10.10.30.20
```

### Traffic not flowing through subnet route

```bash
# Verify Cilium socketLB fix applied
kubectl-homelab -n kube-system exec ds/cilium -- cilium status | grep SocketLB

# Verify subnet route is active
tailscale status
# Should show homelab-subnet with 10.10.30.0/24

# Try pinging a node directly
tailscale ping 10.10.30.11
```

---

## Files to Create

| File | Type | Purpose |
|------|------|---------|
| `manifests/tailscale/namespace.yaml` | Namespace | tailscale namespace (PSS privileged) |
| `manifests/tailscale/connector.yaml` | Connector CRD | Subnet router advertising 10.10.30.0/24 |
| `manifests/tailscale/networkpolicy.yaml` | CiliumNetworkPolicy | Operator + connector proxy network rules |
| `manifests/monitoring/tailscale-alerts.yaml` | PrometheusRule | TailscaleConnectorDown + TailscaleOperatorDown alerts |
| `helm/tailscale-operator/values.yaml` | Helm values | Operator configuration (resources, tags, API proxy) |

## Files to Modify

| File | Change |
|------|--------|
| `helm/cilium/values.yaml` | Add `socketLB.hostNamespaceOnly: true` (Tailscale compatibility) |

---

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Architecture | Connector (subnet router) over per-service Ingress | 1 pod for all services, zero per-service manifests, mirrors Proxmox pattern |
| PSS | Privileged enforce | Proxy pods require NET_ADMIN + NET_RAW for WireGuard (hard requirement) |
| DNS strategy | Global nameserver (not Split DNS) | Mirrors old Proxmox pattern — all tailnet DNS through AdGuard for ad-blocking + rewrites |
| API server proxy | Disabled initially | Enable later for remote kubectl (CKA study value) |
| HTTPS certs | Existing Let's Encrypt (via Cilium Gateway) | No need for Tailscale HTTPS certs — traffic enters through Gateway after subnet route |
| Cilium fix | `socketLB.hostNamespaceOnly: true` | Required — Cilium eBPF intercepts traffic in proxy pod netns, breaking WireGuard routing |
| Helm vs raw manifests | Helm for operator + raw manifests for Connector CRD | Operator is complex (RBAC, CRDs, webhooks), Connector is simple CRD |

---

## CKA Learnings

| Topic | Concept |
|-------|---------|
| CRD operators | Tailscale operator watches custom Connector CRD and creates proxy pods |
| Namespace security | PSS privileged requirement for network-level operations (NET_ADMIN) |
| Subnet routing | L3 routing patterns — advertising routes to external networks |
| CiliumNetworkPolicy | Controlling operator and proxy pod traffic |
| Helm lifecycle | Operator + CRDs managed by Helm, application resources by raw manifests |
| DNS resolution chain | Tailscale DNS → AdGuard → Cilium Gateway → Service (multi-hop) |
| eBPF side effects | Cilium socket LB interfering with pod network namespaces |

---

## References

- [Tailscale Kubernetes Operator](https://tailscale.com/kb/1236/kubernetes-operator)
- [Kubernetes Operator Connector](https://tailscale.com/kb/1441/kubernetes-operator-connector)
- [Tailscale on Kubernetes Overview](https://tailscale.com/kb/1185/kubernetes)
- [Cilium Socket LB + Tailscale](https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/#socket-lb)
- [Tailscale ACL Tags](https://tailscale.com/kb/1068/acl-tags)
- [Tailscale OAuth Clients](https://tailscale.com/kb/1215/oauth-clients)
- [Tailscale API Server Proxy](https://tailscale.com/kb/1437/kubernetes-operator-api-server-proxy)
