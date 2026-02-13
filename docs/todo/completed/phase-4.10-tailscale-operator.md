# Phase 4.10: Tailscale Operator (Subnet Router)

> **Status:** Complete
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
| Global nameserver | `10.10.30.53` (K8s AdGuard — replaced dead `100.123.128.54` on 2026-02-13) |
| Active devices | `tailscale-operator` (100.69.243.39), `homelab-subnet` (100.109.196.53) |
| Disabled devices | `immich` VM (100.74.244.90) — Tailscale disabled to prevent subnet route conflict with K8s Connector |
| Dead devices | Removed: `tailscale-adguardhome`, `tailscale-nginxproxymanager` |
| Phones | samsung-sm-s938b (connected), iphone-14-pro-max (re-authorized), samsung-sm-s931b (expired, deferred) |

### Cleanup Completed (2026-02-13)

- [x] Removed dead devices: `tailscale-adguardhome`, `tailscale-nginxproxymanager`
- [x] Re-authorized: iphone-14-pro-max, samsung-sm-s938b already active
- [ ] Deferred: samsung-sm-s931b — re-auth next time
- [x] Replaced dead global nameserver `100.123.128.54` → `10.10.30.53`
- [x] Verified `immich` VM still works (100.74.244.90) — later disabled Tailscale on VM to prevent subnet route conflict

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
| Operator | Ingress | kube-apiserver (webhook callbacks), host (kubelet probes) |
| Operator | Egress | kube-apiserver (entity), Tailscale coordination servers (HTTPS/443), DNS |
| Connector proxy | — | **No CiliumNetworkPolicy** — see note below |

**Why no connector proxy policy:** The connector is a subnet router that forwards WireGuard-tunneled packets via IP forwarding (`ip_forward=1`). CiliumNetworkPolicy filters forwarded/routed packets (not just pod-originated traffic), which breaks subnet routing entirely. The proxy is already isolated by Tailscale ACLs (`autogroup:member` only).

### 1Password Item

| Field | Reference | Notes |
|-------|-----------|-------|
| client-id | `op://Kubernetes/Tailscale K8s Operator/client-id` | OAuth client ID |
| client-secret | `op://Kubernetes/Tailscale K8s Operator/client-secret` | OAuth client secret |
| api-token | `op://Kubernetes/Tailscale K8s Operator/api-token` | API access token for Homepage widget |

Item has built-in expiry set to **2026-05-14** (90-day API token), with 1Password alert on **2026-04-30** (2 weeks before).

```bash
# Verify:
op read "op://Kubernetes/Tailscale K8s Operator/client-id" >/dev/null && echo "ID OK"
op read "op://Kubernetes/Tailscale K8s Operator/client-secret" >/dev/null && echo "Secret OK"
op read "op://Kubernetes/Tailscale K8s Operator/api-token" >/dev/null && echo "Token OK"
```

---

## Tasks

### 4.10.0 Prerequisites

- [x] 4.10.0.1 Verify Tailscale account active and MagicDNS enabled
- [x] 4.10.0.2 Clean up dead Proxmox devices from tailnet (removed tailscale-adguardhome + tailscale-nginxproxymanager)
- [x] 4.10.0.3 Re-authorize expired phones (iphone-14-pro-max done, samsung-sm-s931b deferred)
- [x] 4.10.0.4 Verify `immich` VM still active (100.74.244.90, expiry disabled, connected)

### 4.10.1 Tailscale Admin Console Setup

- [x] 4.10.1.1 Configure ACL tags and auto-approvers (via JSON editor, added `tagOwners` + `autoApprovers` to existing HuJSON policy with `grants` + `ssh` sections)
- [x] 4.10.1.2 Create OAuth client:
  **Note:** OAuth clients are under `Settings → Trust credentials` (not "OAuth clients" — renamed in Tailscale UI).
  Scopes: Devices Core (R&W), Auth Keys (R&W), Services (Write). Tag: `tag:k8s-operator`.
- [x] 4.10.1.3 Store credentials in 1Password (verified with `op read`)

### 4.10.2 Cilium Compatibility Fix

> **BLOCKER:** Must be done BEFORE installing Tailscale operator. Without this fix, Cilium's eBPF socket-level load balancing intercepts traffic inside proxy pod network namespaces, breaking WireGuard routing. Symptoms: proxy pod starts but no traffic flows through subnet route.

- [x] 4.10.2.1 Add `socketLB.hostNamespaceOnly: true` to `helm/cilium/values.yaml`
- [x] 4.10.2.2 Apply Cilium upgrade (revision 6, version 1.18.6)
- [x] 4.10.2.3 Verify Cilium rollout (all 3 pods Running 1/1)
- [x] 4.10.2.4 Verify existing services still work (Homepage smoke test passed)

### 4.10.3 Create Namespace & Manifests

- [x] 4.10.3.1 Create `manifests/tailscale/namespace.yaml`
- [x] 4.10.3.2 Document OAuth secret (Helm-managed — no file committed)
- [x] 4.10.3.3 Create `manifests/tailscale/connector.yaml`
- [x] 4.10.3.4 Create `manifests/tailscale/networkpolicy.yaml`:
  **Final state:** Operator-only policies (ingress + egress). All connector proxy policies removed.
  **Fixes during implementation:**
  - Added `operator-ingress` policy (kube-apiserver webhook callbacks + kubelet probes) — without this, operator couldn't receive API server webhooks
  - Changed operator egress K8s API rule from `toCIDR` (node IPs only) to `toEntities: kube-apiserver` — operator uses in-cluster Service IP (10.96.0.1), not node IPs
  - Removed ALL connector proxy policies — CiliumNetworkPolicy filters forwarded/routed packets, breaking subnet routing entirely
- [x] 4.10.3.5 Dry-run validated all manifests

### 4.10.4 Helm Values & Install

- [x] 4.10.4.1 Create `helm/tailscale-operator/values.yaml`:
  **Fixes during implementation:**
  - `proxyConfig.defaultTags` must be a **string** (`"tag:k8s"`), not a YAML array — chart passes it as env var
  - `proxyConfig.defaultResources` does not exist in this chart — proxy resources managed via ProxyClass CRD
- [x] 4.10.4.2 Add Tailscale Helm repo
- [x] 4.10.4.3 Check latest chart version → **1.94.1**
- [x] 4.10.4.4 Apply namespace and network policy
- [x] 4.10.4.5 Install operator with OAuth credentials (chart version 1.94.1, revision 2)
- [x] 4.10.4.6 Verify operator running (1/1 Running, `AuthLoop: state is Running; done`)
- [x] 4.10.4.7 Verify operator device in Tailscale admin console (tailscale-operator, tag:k8s-operator, 100.69.243.39)

### 4.10.5 Deploy Connector (Subnet Router)

- [x] 4.10.5.1 Apply Connector CRD
- [x] 4.10.5.2 Verify connector proxy pod created (ts-homelab-network-6556h-0, 1/1 Running)
- [x] 4.10.5.3 Verify in Tailscale admin console (homelab-subnet, tag:k8s, 100.109.196.53, DERP-20 hkg ~31ms)
- [x] 4.10.5.4 Verify subnet route 10.10.30.0/24 approved (auto-approved via ACL autoApprovers)

### 4.10.6 Tailscale DNS Configuration

> **Critical:** The current global nameserver `100.123.128.54` is dead (old Proxmox AdGuard). This step replaces it with the K8s AdGuard instance reachable via the subnet route.

- [x] 4.10.6.1 Remove dead global nameserver (removed 100.123.128.54)
- [x] 4.10.6.2 Add K8s AdGuard as global nameserver (10.10.30.53, "Override DNS servers" ON)
  **Note:** UI label is "Override DNS servers", not "Override local DNS" (renamed in Tailscale UI).
- [x] 4.10.6.3 Verify DNS resolution from tailnet device (confirmed during mobile testing — `*.k8s.rommelporras.com` resolves correctly)

### 4.10.7 Test Mobile Access

- [x] 4.10.7.1 Connect phone to Tailscale (samsung-sm-s938b connected to capybara-interval.ts.net)
- [x] 4.10.7.2 Test Homepage (portal.k8s.rommelporras.com loads correctly)
  **Fix during implementation:** Initial test failed — CiliumNetworkPolicy on connector proxy blocked forwarded packets. Removed all connector proxy policies (see Gotchas table).
- [x] 4.10.7.3 Test additional services (all work without new manifests)
- [x] 4.10.7.4 Verify `immich` VM:
  **Issue discovered:** Tailscale on immich VM intercepted LAN traffic due to K8s subnet route (10.10.30.0/24). NPM couldn't reach immich (TTL dropped from 64→61 indicating packets routed through connector). Fixed: `sudo tailscale down` then `sudo systemctl disable --now tailscaled` on immich VM.
- [x] 4.10.7.5 Test with different WiFi (upstream of OPNsense) — confirmed true remote access works
- [x] 4.10.7.6 Verified ad-blocking works through Tailscale (ads blocked on test sites)

### 4.10.8 Monitoring

- [x] 4.10.8.1 Create `manifests/monitoring/tailscale-alerts.yaml` — PrometheusRule:
  - `TailscaleConnectorDown`: connector StatefulSet replicas ready < 1 for 5m (severity: warning)
  - `TailscaleOperatorDown`: operator deployment replicas < 1 for 5m (severity: warning)
  **Fix:** Original query used `kube_deployment_status_replicas_available` for connector — wrong because connector is a StatefulSet. Fixed to `kube_statefulset_status_replicas_ready`.
- [x] 4.10.8.2 Apply alert rules
- [x] 4.10.8.3 Verify alerts registered in monitoring namespace
- [x] 4.10.8.4 Create `manifests/monitoring/tailscale-dashboard-configmap.yaml` — Grafana dashboard:
  - Pod Status: Connector/Operator UP/DOWN, uptime, container restarts
  - VPN Tunnel Traffic (tailscale0): throughput + packet rate (WireGuard tunnel interface)
  - Pod Network Traffic (eth0): throughput + packet rate (cluster network interface)
  - Resource Usage: CPU + memory with dashed request/limit lines
  - All panels and rows have description tooltips (info icon on hover)

### 4.10.8.5 Homepage Widget

- [x] 4.10.8.5.1 Update `manifests/home/homepage/config/services.yaml` — added Tailscale widget (type: tailscale, deviceid + key from secret)
- [x] 4.10.8.5.2 Generate Tailscale API access token (90-day expiry, expires 2026-05-14)
- [x] 4.10.8.5.3 Store api-token in 1Password with built-in expiry alert (2026-04-30)
- [x] 4.10.8.5.4 Patch Homepage secret with `HOMEPAGE_VAR_TAILSCALE_DEVICE` and `HOMEPAGE_VAR_TAILSCALE_KEY`
- [x] 4.10.8.5.5 Apply kustomize and restart Homepage

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
| `proxyConfig.defaultTags` is a string | Helm chart passes it as env var — YAML array causes `cannot unmarshal array into Go struct field EnvVar` | Use `"tag:k8s"` string, not `- "tag:k8s"` array |
| `proxyConfig.defaultResources` doesn't exist | Chart doesn't support resource limits via values — use ProxyClass CRD instead | Removed from values.yaml |
| Operator needs ingress from kube-apiserver | CiliumNetworkPolicy with endpointSelector creates implicit default-deny for ingress | Added `operator-ingress` policy allowing kube-apiserver + host entities |
| Operator uses in-cluster Service IP (10.96.0.1) | Egress policy with `toCIDR` for node IPs (10.10.30.x) doesn't cover ClusterIP | Use `toEntities: kube-apiserver` instead of CIDR-based rules |
| Connector proxy needs API access | Proxy reads config secrets from K8s API — blocked by network policy | Added `toEntities: kube-apiserver` to connector proxy egress |
| OAuth clients under "Trust credentials" | Tailscale UI renamed "OAuth clients" to "Trust credentials" in Settings | Navigate to `Settings → Trust credentials` |
| CiliumNetworkPolicy blocks subnet routing | Connector forwards packets via IP forwarding — CNP filters forwarded packets, breaking all routed traffic | No CNP on connector proxy — rely on Tailscale ACLs for access control |
| Existing Tailscale VM conflicts with K8s subnet route | `immich` VM had Tailscale running — saw new 10.10.30.0/24 route and intercepted LAN traffic (TTL 64→61), breaking NPM→immich path | Disable Tailscale on VM: `sudo systemctl disable --now tailscaled` |
| Homepage Tailscale API token expires in 90 days | Widget stops showing device status after expiry | Set 1Password item expiry to token date (2026-05-14) with alert 2 weeks before |

---

## Verification Checklist

- [x] Cilium upgraded with `socketLB.hostNamespaceOnly: true`
- [x] Existing services still work after Cilium upgrade (no regressions)
- [x] Operator pod Running in `tailscale` namespace
- [x] `tailscale` IngressClass created
- [x] Operator device visible in Tailscale admin console (100.69.243.39)
- [x] Connector proxy pod Running in `tailscale` namespace
- [x] Connector device (`homelab-subnet`) visible in Tailscale admin console (100.109.196.53)
- [x] Subnet route `10.10.30.0/24` approved (auto-approved via ACL)
- [x] Dead global nameserver removed (`100.123.128.54`)
- [x] New global nameserver set (`10.10.30.53`)
- [x] DNS resolves `*.k8s.rommelporras.com` → `10.10.30.20` from tailnet device
- [x] Homepage accessible from phone via Tailscale
- [x] All existing services work from phone (no per-service manifests needed)
- [x] `immich` VM conflict resolved (Tailscale disabled on VM — `systemctl disable --now tailscaled`)
- [x] Works from different WiFi (upstream of OPNsense) — confirms remote access
- [x] Ad-blocking works through Tailscale (AdGuard global nameserver)
- [x] PrometheusRule `tailscale-alerts` registered in monitoring namespace
- [x] Homepage Tailscale widget showing device status
- [x] Grafana dashboard showing Connector/Operator UP, VPN tunnel traffic, resource usage

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
| `manifests/monitoring/tailscale-dashboard-configmap.yaml` | ConfigMap | Grafana dashboard (pod status, VPN/pod traffic, resources) |
| `helm/tailscale-operator/values.yaml` | Helm values | Operator configuration (resources, tags, API proxy) |

## Files to Modify

| File | Change |
|------|--------|
| `helm/cilium/values.yaml` | Add `socketLB.hostNamespaceOnly: true` (Tailscale compatibility) |
| `manifests/home/homepage/config/services.yaml` | Added Tailscale widget (type: tailscale, deviceid + key vars) |

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
