# Phase 5.3: Network Policies & Node Firewall

> **Status:** ⬜ Planned
> **Target:** v0.33.0
> **Prerequisite:** Phase 5.2 (v0.32.0 - RBAC audit complete, access control established)
> **DevOps Topics:** Network segmentation, zero-trust networking, microsegmentation, node-level firewall
> **CKA Topics:** CiliumNetworkPolicy, ingress/egress rules, endpointSelector, toEntities, toFQDNs, fromCIDRSet

> **Purpose:** Network segmentation - prevent lateral movement between namespaces and harden node-level access
>
> **Learning Goal:** CiliumNetworkPolicy + node firewall - the single highest-impact security control

> **WARNING:** Incorrect NetworkPolicies can break the cluster. Apply one namespace at a time, test after each.

---

## Policy Architecture Decision

> **Why CiliumNetworkPolicy exclusively (not K8s NetworkPolicy)?**
>
> The cluster already has **18 CiliumNetworkPolicies** across 7 namespaces and **zero** K8s
> NetworkPolicies (except the Helm-bundled `gitlab-redis`). Mixing both policy types on
> the same endpoint creates debugging complexity - both independently trigger default-deny,
> and allow rules union across both, making it harder to trace why traffic is allowed or denied.
>
> CiliumNetworkPolicy is a **strict superset** of K8s NetworkPolicy capabilities:
>
> | Capability | K8s NetworkPolicy | CiliumNetworkPolicy |
> |-----------|:-:|:-:|
> | Default deny (ingress + egress) | Yes | Yes |
> | Pod/namespace selector rules | Yes | Yes |
> | ipBlock CIDR rules | Yes | Yes |
> | **Gateway API ingress** (`reserved:ingress` identity) | **No** | Yes (`fromEntities: [ingress]`) |
> | **kube-apiserver egress** (host network) | Workaround only (`ipBlock`) | Yes (`toEntities: [kube-apiserver]`) |
> | **FQDN-based egress** (SMTP, Discord, Let's Encrypt) | **No** | Yes (`toFQDNs`) |
> | **Kubelet health probes** | Workaround only (`ipBlock`) | Yes (`fromEntities: [host]`) |
> | **Prometheus scraping** (pod CIDR) | **No** (Cilium ignores CIDR for managed pods) | Yes (`toEntities: [cluster]`) |
>
> **Approach:** CiliumNetworkPolicy for everything. This is consistent with existing policies,
> avoids coexistence gotchas, and gives deeper Cilium knowledge beyond what CKA covers.

> **Cilium policy mode:** `enable-policy=default` - endpoints without any matching policy
> allow all traffic. Once any policy selects an endpoint, default-deny kicks in for that direction.
> Policies are additive (unioned).

> **Cilium version:** v1.18.6 (includes fix for GHSA-24qp-4xx8-3jvj - Gateway API LoadBalancer
> egress policy bypass for east-west traffic, fixed in 1.17.2+).

---

## Existing CiliumNetworkPolicies

These policies already exist in the cluster. Phase 5.3 must audit, extend, or replace them - not duplicate.

| Namespace | Policies | Notes |
|-----------|----------|-------|
| ai | ollama-ingress | Ingress only - needs egress rules (default-deny already in effect via ingress policy) |
| arr-stack | default-deny-ingress, default-egress | Has deny + broad allow - audit whether per-pod rules are needed |
| atuin | 5 policies (server-ingress/egress, postgres-ingress/egress, backup-egress) | Most complete - audit for gaps |
| cloudflare | cloudflared-egress | Egress only - needs ingress rules |
| karakeep | 6 policies (chrome-ingress/egress, karakeep-ingress/egress, meilisearch-ingress/egress) | Comprehensive - audit for gaps |
| tailscale | operator-egress, operator-ingress | Likely complete |
| uptime-kuma | uptime-kuma-egress | Egress only - needs ingress rules |
| gitlab | gitlab-redis (K8s NP - Helm-bundled) | Only covers Redis - rest of gitlab is open |

---

## Cluster Network Reference

All policies reference these CIDRs. Confirm before writing rules:

| CIDR | Purpose | Source |
|------|---------|--------|
| `10.96.0.0/12` | Kubernetes service CIDR | kubeadm ClusterConfiguration |
| `10.244.0.0/16` | Pod CIDR (DO NOT use in Cilium CIDR rules - see note) | kubeadm ClusterConfiguration |
| `10.10.30.0/24` | Node CIDR (K8s VLAN) | Physical network |
| `10.10.30.4` | NAS (OMV) - NFS | Physical network |

> **CRITICAL Cilium limitation:** `toCIDR`/`fromCIDR`/`toCIDRSet`/`fromCIDRSet` rules with pod
> CIDR `10.244.0.0/16` do NOT match pod-to-pod traffic. Cilium uses identity-based matching for
> managed endpoints. CIDR rules only match **unmanaged** endpoints (external IPs, NAS, nodes).
> For pod-to-pod traffic, use `toEndpoints`/`fromEndpoints` or `toEntities`/`fromEntities`.
>
> Source: Cilium docs - "CIDR rules do not apply to traffic where both sides of the connection
> are either managed by Cilium or use an IP belonging to a node in the cluster."

```bash
# Verify at runtime
kubectl-homelab cluster-info dump | grep -m1 service-cluster-ip-range
kubectl-homelab cluster-info dump | grep -m1 cluster-cidr
```

### hostNetwork Pods (Exempt from NetworkPolicy)

These pods run on the host network and are **not affected** by NetworkPolicy enforcement:
- kube-system: apiserver, etcd, controller-manager, scheduler, kube-vip, Cilium agents + envoy + operator
- monitoring: node-exporter (DaemonSet, 3 pods)

No need to write policies for these pods - they are invisible to Cilium's eBPF datapath.

### Namespaces Not Requiring Policies

- `cilium-secrets` - Cilium-managed namespace for Gateway API TLS secrets. No pods run here.
- `default` - Only contains the `cilium-gateway-homelab-gateway` LoadBalancer service (managed by Cilium).
- `kube-node-lease`, `kube-public` - System namespaces with no workload pods.

---

## Execution Order

Apply policies in this order, from lowest-risk to highest-risk. Test after each namespace.

| Phase | Namespace(s) | Risk | Why this order |
|-------|-------------|------|----------------|
| 0 | CiliumClusterwideNetworkPolicy (Gateway) | **MUST BE FIRST** | Without this, all HTTPRoutes break on first default-deny |
| 1 | portfolio-dev, portfolio-staging, portfolio-prod | Lowest | Static sites, DNS-only egress, easy to validate |
| 2 | browser | Low | Single pod, no DB, broad egress |
| 3 | atuin, karakeep, tailscale | Low | Already have comprehensive policies - audit only |
| 4 | cloudflare, ai, uptime-kuma | Low | Already have partial policies - extend |
| 5 | ghost-dev, ghost-prod | Medium | Pattern A with DB, test SMTP egress |
| 6 | invoicetron-dev, invoicetron-prod | Medium | Pattern A with DB + CronJob |
| 7 | home | Medium-High | AdGuard DNS is network-critical (10.10.30.53) |
| 8 | external-secrets | High | Blocks ESO = blocks all secret syncing |
| 9 | vault | High | Blocks Vault = blocks ESO = blocks everything |
| 10 | cert-manager | High | Blocks cert-manager = certs stop renewing |
| 11 | arr-stack | High | 14 pods + 2 CronJobs, complex inter-pod traffic, already has policies |
| 12 | monitoring | Highest | 19 pods (16 non-hostNetwork), scrapes everything, FQDN egress, most complex |
| 13 | gitlab, gitlab-runner | Highest | Helm-managed, 13+ pods, many internal services |
| 14 | longhorn-system, intel-device-plugins, node-feature-discovery | Deferred | Storage/device plugins - high breakage risk, low attack surface |

---

## 5.3.1 Audit Current Connectivity

- [ ] 5.3.1.1 Audit existing CiliumNetworkPolicies
  ```bash
  # Review what's already in place - don't duplicate
  kubectl-homelab get ciliumnetworkpolicies -A
  kubectl-homelab get networkpolicies -A
  kubectl-homelab get ciliumclusterwidenetworkpolicies

  # For each existing policy, check coverage gaps:
  # - Has default-deny? (both ingress AND egress selected)
  # - Has Gateway ingress via fromEntities: [ingress]?
  # - Has Prometheus scrape ingress from monitoring ns?
  # - Has DNS egress to kube-dns?
  # - Has kubelet health probe ingress via fromEntities: [host]?
  ```

- [ ] 5.3.1.2 Map cross-namespace traffic
  ```bash
  # Test: can any pod reach any other namespace?
  kubectl-homelab run test --rm -it --image=curlimages/curl -n home -- \
    curl -s --max-time 5 http://prometheus-grafana.monitoring.svc:80 && echo "OPEN"

  # Test: can app pods reach external internet?
  kubectl-homelab run test --rm -it --image=curlimages/curl -n home -- \
    curl -s --max-time 5 http://example.com && echo "OPEN"
  ```

- [ ] 5.3.1.3 Document what currently talks to what (baseline before locking down)

---

## 5.3.2 Cluster-Wide Policies + Templates

### 5.3.2.1 Default Deny + DNS Template (CiliumNetworkPolicy)

Every namespace gets these two policies as the base. Separate policies for deny and DNS
so that removing default-deny during debugging doesn't also remove DNS.

```yaml
# Default deny ALL traffic - ingress AND egress
# Without egress deny, a compromised pod can still phone home
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: default-deny-all
  namespace: <namespace>
spec:
  endpointSelector: {}
  # Empty arrays = section present but no allow rules = default-deny for that direction
  # IMPORTANT: ingress: [{}] (with empty object) means ALLOW ALL - that is wrong
  # ingress: [] (empty array) means no rules = default-deny - that is correct
  ingress: []
  egress: []
---
# Always allow DNS - without this, nothing works
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-dns
  namespace: <namespace>
spec:
  endpointSelector: {}
  egress:
    - toEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: kube-system
            k8s-app: kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: UDP
            - port: "53"
              protocol: TCP
```

> **Implementation note:** In `enable-policy=default` mode, the existing policies already
> create default-deny for the directions they cover. For namespaces that already have both
> ingress and egress policies (arr-stack, atuin, karakeep), an explicit default-deny policy
> is redundant but adds clarity. For namespaces with only one direction covered (ai, cloudflare,
> uptime-kuma), adding the missing direction's policy triggers default-deny for it.

### 5.3.2.2 Cluster-Wide Gateway Ingress Policy (CiliumClusterwideNetworkPolicy)

> **CRITICAL:** Cilium Gateway API uses `reserved:ingress` identity for proxied traffic.
> Standard K8s NetworkPolicy with `namespaceSelector: kube-system` does NOT match this
> identity - Gateway traffic will be silently dropped. This is a confirmed Cilium limitation
> ([cilium/cilium#36509](https://github.com/cilium/cilium/issues/36509)).
>
> A `gateway` entity alias has been proposed ([cilium/cilium#43952](https://github.com/cilium/cilium/issues/43952))
> but `ingress` is the current API and must be used.

- [ ] 5.3.2.2 Create cluster-wide policy allowing Gateway `reserved:ingress` to reach backends
  ```yaml
  # Without this, ALL 32 HTTPRoutes break when default-deny is applied
  # Source: docs.cilium.io/en/stable/network/servicemesh/ingress-and-network-policy/
  apiVersion: cilium.io/v2
  kind: CiliumClusterwideNetworkPolicy
  metadata:
    name: allow-gateway-ingress-egress
  spec:
    endpointSelector:
      matchExpressions:
        - key: reserved:ingress
          operator: Exists
    egress:
      - toEntities:
          - cluster
  ```

  > **Apply this BEFORE any default-deny policies.** If forgotten, every Gateway-exposed
  > service becomes unreachable instantly.

### 5.3.2.3 Gateway Ingress Template (CiliumNetworkPolicy)

Every namespace with HTTPRoutes needs this to allow ingress from Gateway:

```yaml
# Allow Cilium Gateway proxy to reach app pods
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: <app>-gateway-ingress
  namespace: <namespace>
spec:
  endpointSelector:
    matchLabels:
      app: <app-label>
  ingress:
    - fromEntities:
        - ingress
      toPorts:
        - ports:
            - port: "<app-port>"
              protocol: TCP
```

### 5.3.2.4 Monitoring Ingress Template (CiliumNetworkPolicy)

Every namespace with metrics endpoints needs this to allow Prometheus scraping:

```yaml
# Allow Prometheus to scrape metrics + Blackbox Exporter probes
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-monitoring-ingress
  namespace: <namespace>
spec:
  endpointSelector: {}  # Or target specific metrics-exporting pods
  ingress:
    - fromEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: monitoring
      toPorts:
        - ports:
            - port: "<metrics-port>"
              protocol: TCP
```

### 5.3.2.5 Kubelet Health Probe Template (CiliumNetworkPolicy)

Pods with liveness/readiness probes need ingress from the host (kubelet):

```yaml
# Allow kubelet health probes (liveness/readiness/startup)
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-kubelet-probes
  namespace: <namespace>
spec:
  endpointSelector: {}
  ingress:
    - fromEntities:
        - host
```

---

## 5.3.3 Infrastructure Namespace Policies

These are unique per namespace. Each gets a detailed traffic matrix.

### external-secrets

ESO is the highest-priority namespace to lock down. ESO docs warn: *"ESO may be used to exfiltrate data out of your cluster."*

3 pods: `external-secrets`, `external-secrets-cert-controller`, `external-secrets-webhook`

| Direction | Target | Port | Why |
|-----------|--------|------|-----|
| Egress | kube-apiserver entity | 6443 | Read/write K8s Secrets, webhook validation |
| Egress | vault namespace | 8200 | Fetch secrets from Vault |
| Ingress | monitoring ns (Prometheus) | 8080 | Metrics scraping (3 ServiceMonitors) |
| Ingress | kube-apiserver entity | 443 | Admission webhook requests (webhook pod only) |
| Ingress | host entity (kubelet) | 8081 | Health checks |

- [ ] 5.3.3.1 Create `manifests/external-secrets/networkpolicy.yaml`
  ```yaml
  # CiliumNP: Default deny + DNS (from template)
  # CiliumNP: Allow egress to vault namespace (8200)
  # CiliumNP: Allow egress to kube-apiserver entity (6443)
  # CiliumNP: Allow ingress from monitoring ns (8080) - Prometheus scrapes
  # CiliumNP: Allow ingress from kube-apiserver entity (443) - webhook only
  # CiliumNP: Allow ingress from host entity (8081) - kubelet health checks
  #
  # ESO has NO HTTPRoutes - no Gateway ingress needed
  ```

### vault

2 running pods + 1 CronJob: `vault-0` (StatefulSet), `vault-unsealer` (Deployment), `vault-snapshot-*` (CronJob)

| Direction | Target | Port | Why |
|-----------|--------|------|-----|
| Egress (vault-0) | kube-apiserver entity | 6443 | Kubernetes auth backend |
| Egress (vault-snapshot) | NAS 10.10.30.4 | 2049 | NFS for Raft snapshots |
| Egress (vault-snapshot) | vault service (same ns) | 8200 | Snapshot API call |
| Egress (vault-unsealer) | vault service (same ns) | 8200 | Unseal API calls |
| Egress (vault-unsealer) | kube-apiserver entity | 6443 | Watch vault pod status (if applicable) |
| Ingress (vault-0) | external-secrets ns | 8200 | ESO fetches secrets |
| Ingress (vault-0) | monitoring ns | 8200 | Prometheus metrics scraping |
| Ingress (vault-0) | Gateway (`ingress` entity) | 8200 | Vault UI via HTTPRoute |
| Ingress (vault-0) | vault ns (self) | 8200, 8201 | Unsealer + Raft internal |
| Ingress | host entity (kubelet) | 8200 | Health checks |

> **CronJob:** `vault-snapshot` needs egress to vault API (8200) + NFS to NAS (2049).
> **Deployment:** `vault-unsealer` needs egress to vault API (8200) for unseal operations.

- [ ] 5.3.3.2 Create `manifests/vault/networkpolicy.yaml`

### monitoring

The most complex namespace. Prometheus scrapes ALL namespaces. **19 running pods** (16 non-hostNetwork + 3 node-exporter hostNetwork, not counting completed CronJob pods).

| Component | Direction | Target | Port | Why |
|-----------|-----------|--------|------|-----|
| Prometheus | Egress | `cluster` entity | various | Scrapes metrics from every namespace |
| Prometheus | Egress | kube-apiserver entity | 6443 | Service discovery, kube-state-metrics |
| Alertmanager | Egress | `toFQDNs` smtp.mail.me.com | 587 | SMTP notifications |
| Alertmanager | Egress | `toFQDNs` discord.com | 443 | Discord webhooks |
| Alertmanager | Egress | `toFQDNs` healthchecks.io, hc-ping.com | 443 | Watchdog dead man's switch |
| Alloy (DaemonSet, 3 pods) | Egress | Loki (same ns) | 3100 | Log shipping |
| Alloy | Egress | kube-apiserver entity | 6443 | K8s API for log enrichment |
| version-checker | Egress | `toFQDNs` registry.k8s.io, ghcr.io, etc. | 443 | Check image versions |
| blackbox-exporter | Egress | `world` entity | 443 | Probe external endpoints |
| blackbox-exporter | Egress | `cluster` entity | various | Probe internal endpoints |
| nut-exporter | Egress | NAS/UPS 10.10.30.4 | 3493 | NUT protocol to UPS |
| OTel collector | Ingress | LAN CIDR 10.10.0.0/16 | 4317, 4318, 8889 | LoadBalancer (10.10.30.22) - 8889 is Prometheus metrics |
| Grafana, Prometheus, Alertmanager, Loki | Ingress | Gateway (`ingress` entity) | 80, 9090, 9093, 3100 | HTTPRoutes (4 routes) |
| All metrics pods | Ingress | same ns (Prometheus) | various | Internal scraping |
| kube-vip (metrics svc) | Ingress | monitoring ns (Prometheus) | 2112 | kube-vip metrics |
| smartctl-exporter (DaemonSet, 3 pods) | Ingress | monitoring ns (Prometheus) | 80 | SMART disk metrics |

> **`toFQDNs` requirement:** Alertmanager SMTP/Discord/healthchecks and version-checker
> all need CiliumNetworkPolicy with `toFQDNs`. Each `toFQDNs` policy must include a DNS
> inspection rule (`rules.dns: [{matchPattern: "*"}]`) for Cilium's FQDN-to-IP cache.
> The DNS rule and `toFQDNs` rules must be in the **same policy** applied to the **same endpoint**.

> **CronJob:** `version-check` needs egress to external container registries (443).

- [ ] 5.3.3.3 Create `manifests/monitoring/networkpolicy.yaml`
  - Prometheus egress: use `toEntities: [cluster]` - NOT `toCIDR: 10.244.0.0/16` (won't work with Cilium)
  - Alertmanager: `toFQDNs` for SMTP + Discord + healthchecks.io
  - Alloy: egress to Loki at `loki.monitoring.svc:3100` (same namespace)
  - OTel collector: ingress from LAN CIDR via `fromCIDRSet` (LoadBalancer 10.10.30.22)
  - nut-exporter: egress to NAS 10.10.30.4:3493 via `toCIDRSet`
  - Grafana, Prometheus, Alertmanager, Loki: `fromEntities: [ingress]` for Gateway
  - version-checker + blackbox-exporter: broad egress (world entity or toFQDNs)

### cert-manager

3 pods: `cert-manager`, `cert-manager-cainjector`, `cert-manager-webhook`

| Direction | Target | Port | Why |
|-----------|--------|------|-----|
| Egress | kube-apiserver entity | 6443 | Manage certificates, read secrets |
| Egress | `toFQDNs` acme-v02.api.letsencrypt.org | 443 | ACME challenges |
| Egress | `toFQDNs` api.cloudflare.com | 443 | DNS-01 validation |
| Ingress (webhook only) | kube-apiserver entity | 443 | Webhook validation |
| Ingress | host entity (kubelet) | 9402 | Health checks (all 3 pods) |
| Ingress | monitoring ns (Prometheus) | 9402 | Metrics scraping (ServiceMonitor) |

> Webhook needs ingress from kube-apiserver for admission webhook requests.
> cainjector and cert-manager only need egress - no ingress except probes/metrics.

- [ ] 5.3.3.4 Create `manifests/cert-manager/networkpolicy.yaml`

---

## 5.3.4 Application Namespace Policies

Most app namespaces follow repeating patterns. Define templates, then apply.

### Pattern A: Web App + Database

Applies to: ghost-dev, ghost-prod, invoicetron-dev, invoicetron-prod, atuin, karakeep

```
Gateway (CiliumNP) -> app pod (HTTP) -> database pod (DB port)
                                      -> external SMTP (CiliumNP toFQDNs, optional)
```

| Direction | Target | Port | Why |
|-----------|--------|------|-----|
| Ingress (app) | Gateway (`ingress` entity) | app HTTP port | HTTPRoute traffic |
| Egress (app) | database pod (same ns) | DB port | App -> DB |
| Egress (app) | `toFQDNs` smtp.mail.me.com (optional) | 587 | Email sending |
| Ingress (db) | app pod (same ns) | DB port | Only app can reach DB |
| Ingress | monitoring ns | metrics port | Prometheus scraping (if applicable) |
| Ingress | host entity | probe port | Kubelet health checks |

- [ ] 5.3.4.1 Create NetworkPolicies for ghost-dev, ghost-prod
  - Ghost HTTP: 2368, MySQL: 3306
  - Ghost needs SMTP egress (`toFQDNs`: smtp.mail.me.com:587)
  - **ghost-prod has 3 pods:** ghost:2368, ghost-analytics:3000, ghost-mysql:3306
  - ghost-analytics is internal only (accessed by Ghost app, no HTTPRoute) - needs ingress from ghost pod on 3000
  - ghost-dev has 2 pods: ghost:2368, ghost-mysql:3306

- [ ] 5.3.4.2 Create NetworkPolicies for invoicetron-dev, invoicetron-prod
  - App HTTP: 3000, PostgreSQL: 5432
  - **CronJob:** `invoicetron-db-backup` (invoicetron-prod) needs egress to DB (5432)

- [ ] 5.3.4.3 Audit NetworkPolicies for atuin
  - Atuin HTTP: 8888, PostgreSQL: 5432
  - **Already has 5 CiliumNetworkPolicies** - audit for completeness, don't duplicate
  - CronJob `atuin-backup` needs NFS egress to NAS (10.10.30.4:2049) - already covered by `atuin-backup-egress`

- [ ] 5.3.4.4 Audit NetworkPolicies for karakeep
  - Karakeep HTTP: 3000, Meilisearch: 7700, Chrome: 9222
  - **Already has 6 CiliumNetworkPolicies** - audit for completeness
  - Chrome needs broad internet egress (web scraping) - already covered by `chrome-egress`
  - No Byparr pod in this namespace (Byparr is in arr-stack)

### Pattern B: Simple Web App

Applies to: browser, uptime-kuma, home (adguard, homepage, myspeed), ai, portfolio-dev/prod/staging

```
Gateway (CiliumNP) -> app pod (HTTP)
```

| Direction | Target | Port | Why |
|-----------|--------|------|-----|
| Ingress | Gateway (`ingress` entity) | app HTTP port | HTTPRoute traffic |
| Egress | varies | varies | App-specific |
| Ingress | monitoring ns | metrics port | Prometheus scraping (if applicable) |
| Ingress | host entity | probe port | Kubelet health checks |

- [ ] 5.3.4.5 Create NetworkPolicies for home namespace
  - **AdGuard: CRITICAL** - LoadBalancer service (10.10.30.53) provides DNS for the entire network
    - Needs ingress from LAN CIDR `10.10.0.0/16` on port 53/UDP, 53/TCP (`fromCIDRSet`)
    - Needs Gateway ingress on port 3000 (admin UI HTTPRoute)
    - Needs DNS egress to upstream resolvers (53/UDP, 53/TCP) - `toCIDRSet: 0.0.0.0/0` on port 53
    - Needs HTTPS egress for blocklist updates (443)
  - **Homepage: needs egress to many services** (widgets query apps across namespaces)
    - Most cluster services accessed via Gateway VIP `10.10.30.20:443` (`*.k8s.rommelporras.com`)
    - Direct internal connection: Vault (`vault.vault.svc.cluster.local:8200`) via customapi widget
    - LAN targets (private CIDR, not via Gateway):
      - Proxmox VE (`pve.home.rommelporras.com:443`), Firewall (`firewall.home.rommelporras.com:443`)
      - OPNsense (`10.10.10.1:443`), OpenWRT (`10.10.70.4:80`)
      - Node exporters (`10.10.30.11-13:9100`)
      - NAS: OMV (`omv.home.rommelporras.com:443`), Glances (`10.10.30.4:61208`)
    - External internet: Tailscale API (`login.tailscale.com:443`), OpenWeather API
    - Cluster widgets via Gateway VIP: Grafana, Prometheus, Alertmanager, Sonarr, Radarr, Jellyfin,
      qBittorrent, Prowlarr, Bazarr, Tdarr, Recommendarr, Seerr, Karakeep, AdGuard, Longhorn,
      Uptime Kuma, GitLab, Browser, Atuin, Blog (dev+prod), MySpeed, Immich (home network)
    - Kubernetes API (kube-apiserver egress) for cluster/node/pod widgets via RBAC
    - Full widget inventory: `manifests/home/homepage/config/services.yaml`
  - MySpeed HTTP: 5216, needs egress to speedtest servers (broad internet)

- [ ] 5.3.4.6 Create/audit NetworkPolicies for browser, uptime-kuma
  - browser: Gateway ingress on port 3000, needs broad internet egress (web browsing)
  - **uptime-kuma already has CiliumNP** (egress only) - needs ingress rules added
  - Uptime Kuma needs broad egress to probe targets across cluster and internet

- [ ] 5.3.4.7 Create NetworkPolicies for ai namespace
  - **Already has CiliumNP** (ollama-ingress) - needs egress rules added
  - Ollama HTTP: 11434, no HTTPRoute (accessed directly by other namespaces, not via Gateway)
  - Ollama may need internet egress for model downloads
  - Existing ingress allows from: monitoring (probes), karakeep (tagging), arr-stack (Recommendarr)
  - Note: ollama-ingress does NOT have `fromEntities: [ingress]` - no Gateway ingress needed

- [ ] 5.3.4.8 Create NetworkPolicies for portfolio-dev, portfolio-prod, portfolio-staging
  - All 3 namespaces have identical setup: portfolio:80
  - Gateway ingress on port 80 (3 HTTPRoutes)
  - Static site - no database, no external egress needed beyond DNS
  - Simplest possible policy: default-deny + DNS + Gateway ingress + kubelet probes

### Pattern C: ARR Stack (Complex)

arr-stack has **14 running pods + 2 CronJobs / 13 services** with extensive inter-pod communication + NFS + external trackers.

> **Already has CiliumNetworkPolicies:** `default-deny-ingress` + `default-egress`.
> Current policies allow broad intra-namespace + internet egress for all pods.
> Phase 5.3 should audit whether tighter per-pod rules are worth the complexity,
> or whether the current broad approach is acceptable given all pods share the same trust domain.

| Component | Direction | Target | Port | Why |
|-----------|-----------|--------|------|-----|
| All with HTTPRoutes | Ingress | Gateway (`ingress` entity) | app port | UI access (9 HTTPRoutes: bazarr:6767, jellyfin:8096, prowlarr:9696, qbittorrent:8080, radarr:7878, recommendarr:3000, seerr:5055, sonarr:8989, tdarr:8265) |
| Prowlarr | Egress | `world` entity | 443 | Indexer searches |
| qBittorrent | Egress | `world` entity | various | Torrent traffic (broad) |
| Byparr | Egress | `world` entity | 443 | CAPTCHA solving (web requests) |
| Sonarr, Radarr | Egress | Prowlarr (same ns) | 9696 | Indexer API |
| Sonarr, Radarr | Egress | qBittorrent (same ns) | 8080 | Download client API |
| Jellyfin | Egress | same ns | various | Connects to Sonarr/Radarr for library scan triggers |
| Tdarr | Egress | NFS to NAS | 2049 | Media transcoding reads/writes |
| Unpackerr | Egress | qBittorrent (same ns) | 8080 | Monitor download completion |
| Unpackerr | Egress | Sonarr (same ns) | 8989 | Notify on unpack completion |
| Unpackerr | Egress | Radarr (same ns) | 7878 | Notify on unpack completion |
| Recommendarr | Egress | Sonarr, Radarr (same ns) | 8989, 7878 | API access |
| Recommendarr | Egress | ai namespace (Ollama) | 11434 | AI recommendations |
| Scraparr | Egress | Sonarr, Radarr (same ns) | 8989, 7878 | API scraping |
| qbittorrent-exporter | Egress | qBittorrent (same ns) | 8080 | Metrics collection |
| tdarr-exporter | Egress | Tdarr (same ns) | 8265 | Metrics collection |
| All | Egress | NAS 10.10.30.4 | 2049 | NFS media storage |
| Exporters | Ingress | monitoring ns | 8000, 9090 | Prometheus scraping |

> **CronJobs:** `arr-stall-resolver` needs same-ns API access. `configarr` needs Sonarr/Radarr API access.

- [ ] 5.3.4.9 Audit and extend NetworkPolicies for arr-stack
  - Review existing `default-deny-ingress` + `default-egress` - they already allow broad intra-namespace + internet
  - Decide: keep broad policy (simpler, all pods share trust domain) or add per-pod rules (more secure, much more complex)
  - Ensure Unpackerr is covered (currently allowed by broad intra-namespace rule)
  - Ensure CronJobs (arr-stall-resolver, configarr) are covered
  - All apps need NFS egress to NAS (already covered by `default-egress` toCIDRSet)

### Pattern D: GitLab

- [ ] 5.3.4.10 Create NetworkPolicies for gitlab, gitlab-runner
  - GitLab is Helm-managed with 13 pods and many internal services
  - Existing K8s NP: `gitlab-redis` (Helm-bundled) - only covers Redis, rest is open
  - 2 HTTPRoutes: gitlab-webservice:8181, gitlab-registry:5000
  - GitLab SSH LoadBalancer (10.10.30.21:22) needs ingress from LAN CIDR
  - Internal services: gitaly:8075, kas:8150-8154, minio:9000, postgresql:5432, redis:6379
  - Sidekiq + Toolbox need egress to internal services
  - Runner (separate namespace) needs egress to GitLab API + container registry
  - Registry needs ingress from cluster (image pulls from all namespaces)
  - gitlab-exporter needs ingress from monitoring on port 9168
  - postgresql-metrics (9187) and redis-metrics (9121) need ingress from monitoring

### cloudflare

- [ ] 5.3.4.11 Audit NetworkPolicy for cloudflare namespace
  - **Already has CiliumNP:** `cloudflared-egress` - audit for completeness
  - Needs ingress rules added (currently only egress is covered)
  - cloudflared needs ingress from monitoring ns (metrics port 2000, ServiceMonitor exists)
  - cloudflared egress already handles Cloudflare edge + internal service proxying

### tailscale

- [ ] 5.3.4.12 Audit NetworkPolicies for tailscale namespace
  - **Already has CiliumNPs:** `operator-egress` + `operator-ingress`
  - Audit for completeness - likely already sufficient
  - Note: tailscale-connector (subnet router) may not work with CiliumNetworkPolicy due to WireGuard subnet routing

### kube-system CronJobs

- [ ] 5.3.4.13 Evaluate policies for kube-system CronJobs
  - `cluster-janitor` (every 10min): needs kube-apiserver access (deletes failed pods, stopped replicas)
  - `cert-expiry-check` (weekly): needs kube-apiserver access (checks cert expiry dates)
  - `pki-backup` (weekly): needs kube-apiserver or node access for PKI files
  - These run in kube-system which is largely hostNetwork-exempt, but the CronJob pods themselves
    do NOT use hostNetwork (verified) - they WILL need network policies
  - All 3 need: DNS egress + kube-apiserver egress (6443)

### Remaining Namespaces

> These namespaces are Helm-managed or have limited workloads. Evaluate whether
> default-deny adds value vs. operational overhead.

- [ ] 5.3.4.14 Evaluate policies for longhorn-system, intel-device-plugins, node-feature-discovery
  - longhorn-system: 23 pods, complex internal traffic. Default-deny may break storage.
    Consider deferring or using a permissive intra-namespace policy.
  - intel-device-plugins: 4 pods, webhook + controller. Needs apiserver access.
  - node-feature-discovery: 5 pods (DaemonSet + master). Needs apiserver access.

---

## 5.3.5 Testing & Validation

- [ ] 5.3.5.1 Test authorized traffic after each namespace policy
  ```bash
  # Verify app is reachable via Gateway
  curl -I https://<app>.k8s.rommelporras.com

  # Verify database is reachable from app pod
  kubectl-homelab exec -n <ns> deployment/<app> -- nc -zv <db-svc> <port>
  ```

- [ ] 5.3.5.2 Test unauthorized traffic is blocked
  ```bash
  # From one namespace, try to reach another namespace's DB
  kubectl-homelab run test --rm -it --image=curlimages/curl -n home -- \
    nc -zv postgresql.invoicetron-prod.svc 5432 -w 5
  # Should timeout
  ```

- [ ] 5.3.5.3 Force ESO re-sync after all policies applied
  ```bash
  kubectl-homelab annotate externalsecret ghost-mysql -n ghost-prod \
    force-sync=$(date +%s) --overwrite
  kubectl-homelab get externalsecret -A | grep -v True
  # Should return nothing (all synced)
  ```

- [ ] 5.3.5.4 Verify LoadBalancer services still reachable
  ```bash
  # AdGuard DNS - CRITICAL (network-wide DNS)
  dig @10.10.30.53 google.com +short

  # GitLab SSH
  ssh -T git@10.10.30.21 2>&1 | head -1

  # OTel Collector
  curl -s http://10.10.30.22:4318/v1/traces -o /dev/null -w "%{http_code}"
  ```

- [ ] 5.3.5.5 Verify CronJobs still run successfully
  ```bash
  kubectl-homelab get jobs -A --sort-by=.metadata.creationTimestamp | tail -10
  # Check for Failed jobs after policies applied
  ```

- [ ] 5.3.5.6 Verify vault unsealer can still unseal
  ```bash
  # Check unsealer logs for connectivity errors
  kubectl-homelab logs -n vault deployment/vault-unsealer --tail=20
  ```

- [ ] 5.3.5.7 Verify Alloy log shipping to Loki
  ```bash
  # Check Alloy logs for errors sending to Loki
  kubectl-homelab logs -n monitoring ds/alloy --tail=20 | grep -i error
  ```

- [ ] 5.3.5.8 Verify Homepage widgets load
  ```bash
  # Check Homepage logs for widget connection failures
  kubectl-homelab logs -n home deployment/homepage --tail=30 | grep -i error
  ```

---

## 5.3.6 CiliumNetworkPolicy Reference Patterns

These patterns are used throughout Phase 5.3. Documented here for reference.

### kube-apiserver egress (for ESO, Vault, cert-manager, monitoring)
```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-apiserver-egress
  namespace: <namespace>
spec:
  endpointSelector: {}
  egress:
    - toEntities:
        - kube-apiserver
      toPorts:
        - ports:
            - port: "6443"
              protocol: TCP
```

### FQDN egress (for Alertmanager, cert-manager, version-checker)
```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: alertmanager-fqdn-egress
  namespace: monitoring
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: alertmanager
  egress:
    # DNS inspection required for toFQDNs to work
    # MUST be in the same policy as the toFQDNs rules
    - toEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: kube-system
            k8s-app: kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: ANY
          rules:
            dns:
              - matchPattern: "*"
    # FQDN-based egress rules
    - toFQDNs:
        - matchName: "smtp.mail.me.com"
      toPorts:
        - ports:
            - port: "587"
              protocol: TCP
    - toFQDNs:
        - matchName: "discord.com"
        - matchPattern: "*.discord.com"
      toPorts:
        - ports:
            - port: "443"
              protocol: TCP
```

> **`toFQDNs` gotchas:**
> - DNS inspection rule (`rules.dns`) is **mandatory** - without it, Cilium can't populate FQDN-to-IP cache
> - DNS rule and `toFQDNs` must be in the **same policy** on the **same endpoint** -
>   a cluster-wide DNS allow rule in a separate policy does NOT satisfy this
>   ([cilium/cilium#44452](https://github.com/cilium/cilium/issues/44452))
> - Cannot mix `toFQDNs` with `toEndpoints`/`toCIDR` in the same egress rule - use separate array items
> - Wildcard `*` in `matchPattern` matches valid DNS characters **except** `.` (dot) -
>   `*.discord.com` matches `api.discord.com` but NOT `api.cdn.discord.com`.
>   If deeper subdomains are needed, add `*.*.discord.com` or test after applying
> - Per-endpoint limit of 50 IPs per FQDN (usually sufficient)
> - DNS cache TTL minimum 1 hour by default

### LoadBalancer ingress (for AdGuard DNS, GitLab SSH, OTel)
```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-loadbalancer-ingress
  namespace: home
spec:
  endpointSelector:
    matchLabels:
      app: adguard
  ingress:
    - fromCIDRSet:
        - cidr: 10.10.0.0/16  # All VLANs
      toPorts:
        - ports:
            - port: "53"
              protocol: UDP
            - port: "53"
              protocol: TCP
```

---

## 5.3.7 Node-Level Network Hardening (Stretch Goals)

> **Why stretch goals?** These are OPNsense/node-level firewall tasks, not Kubernetes
> NetworkPolicy. They add security value but are a different domain of work. Complete
> all namespace policies first (5.3.1-5.3.5), then tackle these if time permits.

### 5.3.7.1 OPNsense Stale Firewall States

> **Problem:** After node reboot, OPNsense keeps stale TCP states. Cross-VLAN SSH times out
> until states are manually cleared. Happened on every node reboot.

- [ ] 5.3.7.1a Investigate OPNsense state timeout tuning for K8s VLAN
  - Current behavior: stale states persist for minutes after node comes back
  - Options: reduce state timeout for VLAN 30, or use adaptive timeouts

- [ ] 5.3.7.1b Evaluate OPNsense API for automated state clearing
  - Ansible pre/post-reboot task to clear states via OPNsense REST API
  - Would eliminate manual intervention during rolling reboots

### 5.3.7.2 Evaluate node-level port restrictions

```bash
# Document which host ports are exposed on each node
ssh wawashi@10.10.30.11 "sudo ss -tlnp | grep -E '(6443|2379|2380|10250|10255|10257|10259)'"
```

Consider whether OPNsense firewall rules on the K8s VLAN (10.10.30.0/24) should restrict:

| Port | Service | Who Should Access |
|------|---------|------------------|
| 6443 | kube-apiserver | VIP (10.10.30.10), nodes, WSL (10.10.50.X) |
| 2379-2380 | etcd | Only other CP nodes (10.10.30.11-13) |
| 10250 | kubelet | Only API server (via VIP or node IPs) |
| 10255 | kubelet read-only | Nobody (disabled in Phase 5.1) |
| 10257 | controller-manager | Only localhost (already bound to 127.0.0.1) |
| 10259 | scheduler | Only localhost (already bound to 127.0.0.1) |

> **Decision needed:** Implement via OPNsense firewall rules (recommended - centralized, visible in OPNsense UI) or via iptables/nftables on each node (more work, survives OPNsense failure).

- [ ] 5.3.7.2a Document current host port exposure on all 3 CP nodes
- [ ] 5.3.7.2b Decide on implementation approach (OPNsense vs. node-level)
- [ ] 5.3.7.2c If OPNsense: create firewall rules restricting etcd (2379-2380) to CP nodes only
- [ ] 5.3.7.2d If OPNsense: create firewall rules restricting kubelet (10250) to API server

### 5.3.7.3 Create GitOps namespace NetworkPolicy template

```yaml
# Pre-plan the NetworkPolicy for ArgoCD/FluxCD namespace (Phase 6)
# This isn't applied now - just documented for when GitOps is deployed
# ArgoCD/FluxCD needs:
# - Egress to kube-apiserver (6443) - manage cluster resources
# - Egress to GitLab (git pull) - source of truth
# - Egress to Helm registries (443) - chart pulls
# - Ingress from Gateway (UI access)
# - Ingress from monitoring (Prometheus scraping)
# - Default deny everything else
```

- [ ] 5.3.7.3a Draft CiliumNetworkPolicy for ArgoCD namespace (egress to apiserver + GitLab + registries)
- [ ] 5.3.7.3b Document in phase-6 plan for application during ArgoCD deployment

---

## 5.3.8 Documentation

- [ ] 5.3.8.1 Update `docs/context/Security.md` with NetworkPolicy strategy
  - Document CiliumNetworkPolicy-only approach and rationale
  - Traffic matrix summary per namespace
  - Cilium-specific limitations (Gateway identity, FQDN, pod CIDR)
  - Node-level port exposure and firewall decisions (if stretch goals completed)
- [ ] 5.3.8.2 Update `docs/reference/CHANGELOG.md`

---

## Verification Checklist

### Cluster-Wide
- [ ] CiliumClusterwideNetworkPolicy for `reserved:ingress` applied FIRST
- [ ] Every namespace with workloads has policies covering both ingress and egress
- [ ] Every namespace has DNS egress allowed (kube-dns on port 53)
- [ ] Gateway ingress uses `fromEntities: [ingress]` (NOT `namespaceSelector`)
- [ ] kube-apiserver egress uses `toEntities: [kube-apiserver]` (NOT `ipBlock`)
- [ ] FQDN egress uses `toFQDNs` with DNS inspection rules in the same policy
- [ ] Kubelet health probes use `fromEntities: [host]`

### Infrastructure
- [ ] external-secrets can ONLY reach Vault + kube-apiserver (no internet egress)
- [ ] vault ingress limited to ESO + Prometheus + Gateway + unsealer
- [ ] vault-unsealer can still unseal vault after policies applied
- [ ] monitoring: Prometheus scraping works (via `toEntities: [cluster]`, NOT pod CIDR)
- [ ] monitoring: Alertmanager can send Discord + email + healthchecks.io
- [ ] monitoring: Alloy can ship logs to Loki
- [ ] monitoring: nut-exporter can reach UPS/NAS
- [ ] cert-manager egress allows Let's Encrypt + Cloudflare only

### Applications
- [ ] App databases reachable only from their own app pods
- [ ] Cross-namespace DB access blocked (tested)
- [ ] Homepage widgets still load (cross-namespace queries)
- [ ] Unpackerr in arr-stack can access qBittorrent + Sonarr/Radarr
- [ ] All 32 HTTPRoutes still serve traffic via Gateway
- [ ] All 30 ExternalSecrets still synced

### LoadBalancers + CronJobs
- [ ] AdGuard DNS LoadBalancer (10.10.30.53) still resolves from LAN
- [ ] GitLab SSH LoadBalancer (10.10.30.21) still accepts connections
- [ ] OTel Collector LoadBalancer (10.10.30.22) still accepts traces
- [ ] All 9 CronJobs complete successfully after policies applied
  - arr-stall-resolver, configarr (arr-stack)
  - atuin-backup (atuin)
  - invoicetron-db-backup (invoicetron-prod)
  - cert-expiry-check, cluster-janitor, pki-backup (kube-system)
  - version-check (monitoring)
  - vault-snapshot (vault)

### Audit
- [ ] Existing CiliumNetworkPolicies audited - no duplicates or conflicts
- [ ] GitOps namespace NetworkPolicy template prepared (stretch)
- [ ] Node port exposure documented (stretch)
- [ ] OPNsense stale state issue investigated (stretch)

---

## Rollback

NetworkPolicies take effect immediately. If something breaks:

```bash
# 1. Identify which policy broke things
kubectl-homelab get ciliumnetworkpolicy -n <namespace>
kubectl-homelab get ciliumclusterwidenetworkpolicy

# 2. Delete the problematic policy - connectivity restores instantly
kubectl-homelab delete ciliumnetworkpolicy <name> -n <namespace>

# 3. Fix the policy and re-apply
```

**Nuclear option (remove all policies from a namespace):**
```bash
kubectl-homelab delete ciliumnetworkpolicy --all -n <namespace>
```

**If Gateway traffic breaks across ALL namespaces:**
```bash
# Check the cluster-wide Gateway ingress policy
kubectl-homelab get ciliumclusterwidenetworkpolicy allow-gateway-ingress-egress
# If missing, re-apply it immediately
```

---

## Final: Commit and Release

- [ ] `/audit-security` then `/commit`
- [ ] `/audit-docs` then `/commit`
- [ ] `/release v0.33.0 "Network Policies & Node Firewall"`
- [ ] `mv docs/todo/phase-5.3-network-policies.md docs/todo/completed/`
