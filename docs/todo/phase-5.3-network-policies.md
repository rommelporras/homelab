# Phase 5.3: Network Policies & Node Firewall

> **Status:** ⬜ Planned
> **Target:** v0.33.0
> **Prerequisite:** Phase 5.2 (v0.32.0 — RBAC audit complete, access control established)
> **DevOps Topics:** Network segmentation, zero-trust networking, microsegmentation, node-level firewall
> **CKA Topics:** NetworkPolicy, CiliumNetworkPolicy, ingress/egress rules, podSelector, namespaceSelector, ipBlock, toEntities, toFQDNs

> **Purpose:** Network segmentation — prevent lateral movement between namespaces and harden node-level access
>
> **Learning Goal:** Kubernetes NetworkPolicy + CiliumNetworkPolicy + node firewall — the single highest-impact security control

> **WARNING:** Incorrect NetworkPolicies can break the cluster. Apply one namespace at a time, test after each.

---

## Policy Architecture Decision

> **Why both K8s NetworkPolicy AND CiliumNetworkPolicy?**
>
> Standard K8s NetworkPolicy handles most cases and aligns with CKA exam prep.
> However, Cilium's Gateway API integration and several real-world needs **require**
> CiliumNetworkPolicy — there is no K8s-native workaround:
>
> | Capability | K8s NetworkPolicy | CiliumNetworkPolicy |
> |-----------|:-:|:-:|
> | Default deny (ingress + egress) | Yes | Yes |
> | Pod/namespace selector rules | Yes | Yes |
> | ipBlock CIDR rules | Yes | Yes |
> | **Gateway API ingress** (`reserved:ingress` identity) | **No** | Yes (`fromEntities: [ingress]`) |
> | **kube-apiserver egress** (host network) | Workaround only (`ipBlock`) | Yes (`toEntities: [kube-apiserver]`) |
> | **FQDN-based egress** (SMTP, Discord, Let's Encrypt) | **No** | Yes (`toFQDNs`) |
> | **Prometheus scraping** (pod CIDR) | **No** (Cilium ignores CIDR for managed pods) | Yes (`toEntities: [cluster]`) |
>
> **Approach:** K8s NetworkPolicy for default-deny + DNS. CiliumNetworkPolicy for
> everything else. This gives CKA learning value while being correct for Cilium.

> **Cilium policy mode:** `enable-policy=default` — endpoints without any matching policy
> allow all traffic. Once any policy selects an endpoint, default-deny kicks in for that direction.
> Policies are additive (unioned). K8s NP and CiliumNP can coexist on the same endpoint.

---

## Existing CiliumNetworkPolicies

These policies already exist in the cluster. Phase 5.3 must audit, extend, or replace them — not duplicate.

| Namespace | Policies | Notes |
|-----------|----------|-------|
| ai | ollama-ingress | Ingress only — needs default-deny + egress rules |
| arr-stack | default-deny-ingress, default-egress | Has deny — needs per-pod allow rules |
| atuin | 5 policies (server, postgres, backup) | Most complete — audit for gaps |
| cloudflare | cloudflared-egress | Egress only — needs default-deny + ingress |
| karakeep | 6 policies (chrome, karakeep, meilisearch) | Comprehensive — audit for gaps |
| tailscale | operator-egress, operator-ingress | Likely complete |
| uptime-kuma | uptime-kuma-egress | Egress only — needs ingress |
| gitlab | gitlab-redis (K8s NP) | Only covers Redis — rest of gitlab is open |

---

## Cluster Network Reference

All NetworkPolicies reference these CIDRs. Confirm before writing rules:

| CIDR | Purpose | Source |
|------|---------|--------|
| `10.96.0.0/12` | Kubernetes service CIDR | kubeadm ClusterConfiguration |
| `10.244.0.0/16` | Pod CIDR (DO NOT use in Cilium CIDR rules — see note) | kubeadm ClusterConfiguration |
| `10.10.30.0/24` | Node CIDR (K8s VLAN) | Physical network |
| `10.10.30.4` | NAS (OMV) — NFS | Physical network |

> **CRITICAL Cilium limitation:** `ipBlock`/`toCIDR` rules with pod CIDR `10.244.0.0/16`
> do NOT match pod-to-pod traffic. Cilium uses identity-based matching for managed endpoints.
> CIDR rules only match **unmanaged** endpoints (external IPs, NAS, nodes).
> For pod-to-pod traffic, use `podSelector`/`namespaceSelector` (K8s NP) or
> `toEndpoints`/`toEntities` (CiliumNP).

```bash
# Verify at runtime
kubectl-homelab cluster-info dump | grep -m1 service-cluster-ip-range
kubectl-homelab cluster-info dump | grep -m1 cluster-cidr
```

### hostNetwork Pods (Exempt from NetworkPolicy)

These pods run on the host network and are **not affected** by NetworkPolicy enforcement:
- kube-system: apiserver, etcd, controller-manager, scheduler, kube-vip, Cilium agents + envoy
- monitoring: node-exporter (DaemonSet)

No need to write policies for these pods — they are invisible to Cilium's eBPF datapath.

---

## 5.3.1 Audit Current Connectivity

- [ ] 5.3.1.1 Audit existing CiliumNetworkPolicies
  ```bash
  # Review what's already in place — don't duplicate
  kubectl-homelab get ciliumnetworkpolicies -A
  kubectl-homelab get networkpolicies -A

  # For each existing policy, check coverage gaps:
  # - Has default-deny? (both ingress AND egress)
  # - Has Gateway ingress via fromEntities: [ingress]?
  # - Has Prometheus scrape ingress from monitoring ns?
  # - Has DNS egress?
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

## 5.3.2 Default Deny + Cluster-Wide Policies

### 5.3.2.1 Default Deny Template (K8s NetworkPolicy)

Every namespace gets this as the base. Must deny BOTH ingress AND egress.

```yaml
# Default deny ALL traffic — ingress AND egress
# Without egress deny, a compromised pod can still phone home
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: <namespace>
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
---
# Always allow DNS — without this, nothing works
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
  namespace: <namespace>
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
```

### 5.3.2.2 Cluster-Wide Gateway Ingress Policy (CiliumClusterwideNetworkPolicy)

> **CRITICAL:** Cilium Gateway API uses `reserved:ingress` identity for proxied traffic.
> Standard K8s NetworkPolicy with `namespaceSelector: kube-system` does NOT match this
> identity — Gateway traffic will be silently dropped. This is a confirmed Cilium limitation
> ([cilium/cilium#36509](https://github.com/cilium/cilium/issues/36509)).

- [ ] 5.3.2.2 Create cluster-wide policy allowing Gateway `reserved:ingress` to reach backends
  ```yaml
  # Without this, ALL HTTPRoutes break when default-deny is applied
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
  name: allow-gateway-ingress
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

### 5.3.2.4 Prometheus Scrape Template (K8s NetworkPolicy)

Every namespace with metrics endpoints needs this to allow Prometheus scraping:

```yaml
# Allow Prometheus to scrape metrics
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-prometheus-scrape
  namespace: <namespace>
spec:
  podSelector: {}  # Or target specific metrics-exporting pods
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: monitoring
      ports:
        - protocol: TCP
          port: <metrics-port>
```

---

## 5.3.3 Infrastructure Namespace Policies

These are unique per namespace. Each gets a detailed traffic matrix.
Use CiliumNetworkPolicy for Gateway ingress, kube-apiserver egress, and FQDN egress.
Use K8s NetworkPolicy for default-deny, DNS, and simple pod/namespace selector rules.

### external-secrets

ESO is the highest-priority namespace to lock down. ESO docs warn: *"ESO may be used to exfiltrate data out of your cluster."*

| Direction | Policy Type | Target | Port | Why |
|-----------|------------|--------|------|-----|
| Egress | CiliumNP | kube-apiserver entity | 6443 | Read/write K8s Secrets, webhook validation |
| Egress | K8s NP | vault namespace | 8200 | Fetch secrets from Vault |
| Ingress | K8s NP | monitoring ns (Prometheus) | 8080 | Metrics scraping (3 ServiceMonitors) |
| Ingress | CiliumNP | kube-apiserver entity | 443 | Admission webhook requests (webhook pod) |
| Ingress | K8s NP | Node IPs (kubelet) | 8081 | Health checks |

- [ ] 5.3.3.1 Create `manifests/external-secrets/networkpolicy.yaml`
  ```yaml
  # K8s NP: Default deny + DNS (from template)
  # K8s NP: Allow egress to vault namespace (8200)
  # K8s NP: Allow ingress from monitoring ns (8080) — Prometheus scrapes
  # K8s NP: Allow ingress from node CIDR (8081) — kubelet health checks
  # CiliumNP: Allow egress to kube-apiserver entity (6443)
  # CiliumNP: Allow ingress from kube-apiserver entity (443) — webhook
  #
  # ESO has NO HTTPRoutes — no Gateway ingress needed
  ```

### vault

| Direction | Policy Type | Target | Port | Why |
|-----------|------------|--------|------|-----|
| Egress | CiliumNP | kube-apiserver entity | 6443 | Kubernetes auth backend |
| Egress | K8s NP | NAS 10.10.30.4 | 2049 | NFS for Raft snapshots |
| Ingress | K8s NP | external-secrets ns | 8200 | ESO fetches secrets |
| Ingress | K8s NP | monitoring ns | 8200 | Prometheus metrics scraping |
| Ingress | CiliumNP | Gateway (`ingress` entity) | 8200 | Vault UI via HTTPRoute |
| Ingress | K8s NP | vault ns (self) | 8200, 8201 | Unsealer, Raft internal |

> **CronJob:** `vault-snapshot` needs egress to vault API (8200) + NFS to NAS (2049).

- [ ] 5.3.3.2 Create `manifests/vault/networkpolicy.yaml`

### monitoring

The most complex namespace. Prometheus scrapes ALL namespaces. 19 running pods.

| Component | Direction | Policy Type | Target | Port | Why |
|-----------|-----------|------------|--------|------|-----|
| Prometheus | Egress | CiliumNP | `cluster` entity | various | Scrapes metrics from every namespace |
| Prometheus | Egress | CiliumNP | kube-apiserver entity | 6443 | Service discovery, kube-state-metrics |
| Alertmanager | Egress | CiliumNP (`toFQDNs`) | smtp.mail.me.com | 587 | SMTP notifications |
| Alertmanager | Egress | CiliumNP (`toFQDNs`) | discord.com | 443 | Discord webhooks |
| Alertmanager | Egress | CiliumNP (`toFQDNs`) | healthchecks.io, hc-ping.com | 443 | Watchdog dead man's switch |
| Alloy | Egress | K8s NP | Loki (same ns) | 3100 | Log shipping (internal, NOT external) |
| Alloy | Egress | CiliumNP | kube-apiserver entity | 6443 | K8s API for log enrichment |
| version-checker | Egress | CiliumNP (`toFQDNs`) | registry.k8s.io, ghcr.io, etc. | 443 | Check image versions |
| blackbox-exporter | Egress | CiliumNP | `world` entity | 443 | Probe external endpoints |
| OTel collector | Ingress | K8s NP | LAN CIDR 10.10.0.0/16 | 4317, 4318 | LoadBalancer (10.10.30.22) |
| Grafana, Prometheus, Alertmanager, Loki | Ingress | CiliumNP | Gateway (`ingress` entity) | 80, 9090, 9093, 3100 | HTTPRoutes (4 routes) |
| All metrics pods | Ingress | K8s NP | same ns (Prometheus) | various | Internal scraping |

> **`toFQDNs` requirement:** Alertmanager SMTP/Discord/healthchecks and version-checker
> all need CiliumNetworkPolicy with `toFQDNs`. Standard K8s NetworkPolicy **cannot** do
> FQDN-based egress. Each `toFQDNs` policy must include a DNS inspection rule
> (`rules.dns: [{matchPattern: "*"}]`) for Cilium's FQDN-to-IP cache.

> **CronJob:** `version-check` needs egress to external container registries (443).

- [ ] 5.3.3.3 Create `manifests/monitoring/networkpolicy.yaml`
  - Prometheus egress: use `toEntities: [cluster]` — NOT `toCIDR: 10.244.0.0/16` (won't work with Cilium)
  - Alertmanager: CiliumNP with `toFQDNs` for SMTP + Discord + healthchecks.io
  - Alloy: egress to Loki at `loki.monitoring.svc:3100` (same namespace, simple K8s NP)
  - OTel collector: ingress from LAN CIDR (LoadBalancer 10.10.30.22)
  - Grafana, Prometheus, Alertmanager, Loki: CiliumNP `fromEntities: [ingress]` for Gateway

### cert-manager

| Direction | Policy Type | Target | Port | Why |
|-----------|------------|--------|------|-----|
| Egress | CiliumNP | kube-apiserver entity | 6443 | Manage certificates, read secrets |
| Egress | CiliumNP (`toFQDNs`) | acme-v02.api.letsencrypt.org | 443 | ACME challenges |
| Egress | CiliumNP (`toFQDNs`) | api.cloudflare.com | 443 | DNS-01 validation |
| Ingress | CiliumNP | kube-apiserver entity | 443 | Webhook validation (cert-manager-webhook) |
| Ingress | K8s NP | Node IPs (kubelet) | 9402 | Health checks (all 3 pods) |

> **3 pods:** cert-manager, cert-manager-cainjector, cert-manager-webhook.
> Webhook needs ingress from kube-apiserver for admission webhook requests.

- [ ] 5.3.3.4 Create `manifests/cert-manager/networkpolicy.yaml`

---

## 5.3.4 Application Namespace Policies

Most app namespaces follow repeating patterns. Define templates, then apply.
All Gateway ingress uses CiliumNetworkPolicy `fromEntities: [ingress]` (not K8s NP `namespaceSelector`).

### Pattern A: Web App + Database

Applies to: ghost-dev, ghost-prod, invoicetron-dev, invoicetron-prod, atuin, karakeep

```
Gateway (CiliumNP) → app pod (HTTP) → database pod (DB port)
                                     → external SMTP (CiliumNP toFQDNs, optional)
```

| Direction | Policy Type | Target | Port | Why |
|-----------|------------|--------|------|-----|
| Ingress (app) | CiliumNP | Gateway (`ingress` entity) | app HTTP port | HTTPRoute traffic |
| Egress (app) | K8s NP | database pod (same ns) | DB port | App → DB |
| Egress (app) | CiliumNP (`toFQDNs`) | smtp.mail.me.com (optional) | 587 | Email sending |
| Ingress (db) | K8s NP | app pod (same ns) | DB port | Only app can reach DB |
| Ingress (metrics) | K8s NP | monitoring ns | metrics port | Prometheus scraping |

- [ ] 5.3.4.1 Create NetworkPolicies for ghost-dev, ghost-prod
  - Ghost HTTP: 2368, MySQL: 3306
  - Ghost needs SMTP egress (CiliumNP `toFQDNs`: smtp.mail.me.com:587)
  - **ghost-prod has 3 services:** ghost:2368, ghost-analytics:3000, ghost-mysql:3306
  - Ghost Analytics needs Gateway ingress on port 3000 (separate HTTPRoute)
  - ghost-dev has 2 services: ghost:2368, ghost-mysql:3306

- [ ] 5.3.4.2 Create NetworkPolicies for invoicetron-dev, invoicetron-prod
  - App HTTP: 3000, PostgreSQL: 5432
  - **CronJob:** `invoicetron-db-backup` (invoicetron-prod) needs egress to DB (5432)

- [ ] 5.3.4.3 Create/audit NetworkPolicies for atuin
  - Atuin HTTP: 8888, PostgreSQL: 5432
  - **Already has 5 CiliumNetworkPolicies** — audit for completeness, don't duplicate
  - CronJob `atuin-backup` needs NFS egress to NAS (10.10.30.4:2049) — check if covered

- [ ] 5.3.4.4 Create/audit NetworkPolicies for karakeep
  - Karakeep HTTP: 3000, Meilisearch: 7700, Chrome: 9222, Byparr: 8191
  - **Already has 6 CiliumNetworkPolicies** — audit for completeness
  - **Missing from existing:** Byparr (8191) — new pod, may need its own policy
  - Chrome needs broad internet egress (web scraping)

### Pattern B: Simple Web App

Applies to: browser, uptime-kuma, home (adguard, homepage, myspeed), ai, portfolio-dev/prod/staging

```
Gateway (CiliumNP) → app pod (HTTP)
```

| Direction | Policy Type | Target | Port | Why |
|-----------|------------|--------|------|-----|
| Ingress | CiliumNP | Gateway (`ingress` entity) | app HTTP port | HTTPRoute traffic |
| Egress | varies | varies | varies | App-specific |
| Ingress (metrics) | K8s NP | monitoring ns | metrics port | Prometheus scraping (if applicable) |

- [ ] 5.3.4.5 Create NetworkPolicies for home namespace
  - **AdGuard: CRITICAL** — LoadBalancer service (10.10.30.53) provides DNS for the entire network
    - Needs ingress from LAN CIDR `10.10.0.0/16` on port 53/UDP, 53/TCP (CiliumNP `fromCIDRSet`)
    - Needs Gateway ingress on port 3000 (admin UI HTTPRoute)
    - Needs DNS egress to upstream resolvers (53/UDP, 53/TCP)
    - Needs HTTPS egress for blocklist updates (443)
  - Homepage: needs egress to many services (widgets query other apps across namespaces)
  - MySpeed: needs egress to speedtest servers

- [ ] 5.3.4.6 Create/audit NetworkPolicies for browser, uptime-kuma
  - browser: Gateway ingress on port 3000, needs broad internet egress (web browsing)
  - **uptime-kuma already has CiliumNP** (egress only) — needs Gateway ingress + default-deny
  - Uptime Kuma needs broad egress to probe targets across cluster and internet

- [ ] 5.3.4.7 Create NetworkPolicies for ai namespace
  - **Already has CiliumNP** (ollama-ingress) — needs default-deny + egress rules
  - Ollama HTTP: 11434, Gateway ingress via HTTPRoute
  - Ollama may need internet egress for model downloads

- [ ] 5.3.4.8 Create NetworkPolicies for portfolio-dev, portfolio-prod, portfolio-staging
  - All 3 namespaces have identical setup: portfolio:80
  - Gateway ingress on port 80 (3 HTTPRoutes)
  - Static site — no database, no external egress needed beyond DNS

### Pattern C: ARR Stack (Complex)

arr-stack has **14 pods / 13 services** with extensive inter-pod communication + NFS + external trackers.

> **Already has CiliumNetworkPolicies:** `default-deny-ingress` + `default-egress` (24 days old).
> Audit existing policies and add per-pod allow rules on top.

| Component | Direction | Policy Type | Target | Port | Why |
|-----------|-----------|------------|--------|------|-----|
| All with HTTPRoutes | Ingress | CiliumNP | Gateway (`ingress` entity) | app port | UI access (9 HTTPRoutes) |
| Prowlarr | Egress | CiliumNP | `world` entity | 443 | Indexer searches |
| qBittorrent | Egress | CiliumNP | `world` entity | various | Torrent traffic (broad) |
| Sonarr, Radarr | Egress | K8s NP | Prowlarr (same ns) | 9696 | Indexer API |
| Sonarr, Radarr | Egress | K8s NP | qBittorrent (same ns) | 8080 | Download client API |
| Jellyfin | Egress | K8s NP | same ns | various | Connects to Sonarr/Radarr |
| Tdarr server | Egress | K8s NP | same ns (workers) | various | Dispatch transcode jobs |
| Tdarr workers | Ingress/Egress | K8s NP | Tdarr server (same ns) | 8265 | Server <-> worker API |
| Byparr | Egress | CiliumNP | `world` entity | 443 | CAPTCHA solving (web requests) |
| Recommendarr | Egress | K8s NP | Sonarr, Radarr (same ns) | 8989, 7878 | API access |
| Scraparr | Egress | K8s NP | Sonarr, Radarr (same ns) | 8989, 7878 | API scraping |
| qbittorrent-exporter | Egress | K8s NP | qBittorrent (same ns) | 8080 | Metrics collection |
| tdarr-exporter | Egress | K8s NP | Tdarr server (same ns) | 8265 | Metrics collection |
| All | Egress | K8s NP (`ipBlock`) | NAS 10.10.30.4 | 2049 | NFS media storage |
| Exporters | Ingress | K8s NP | monitoring ns | 8000, 9090 | Prometheus scraping |

> **CronJobs:** `arr-stall-resolver` needs same-ns API access. `configarr` needs Sonarr/Radarr API access.

- [ ] 5.3.4.9 Audit and extend NetworkPolicies for arr-stack
  - Audit existing `default-deny-ingress` + `default-egress` — check if they cover both directions
  - Add per-pod Gateway ingress rules (9 HTTPRoutes: bazarr, jellyfin, prowlarr, qbittorrent, radarr, recommendarr, seerr, sonarr, tdarr)
  - Add per-pod inter-service egress rules
  - qBittorrent + Prowlarr + Byparr need broad internet egress (`world` entity)
  - All apps need NFS egress to NAS

### Pattern D: GitLab

- [ ] 5.3.4.10 Create NetworkPolicies for gitlab, gitlab-runner
  - GitLab is Helm-managed with 13 pods and many internal services
  - Existing K8s NP: `gitlab-redis` — only covers Redis, rest is open
  - 2 HTTPRoutes: gitlab-webservice:8181, gitlab-registry:5000
  - GitLab SSH LoadBalancer (10.10.30.21:22) needs ingress from LAN CIDR
  - Runner needs egress to GitLab API + container registry
  - Registry needs ingress from cluster (image pulls from all namespaces)

### cloudflare

- [ ] 5.3.4.11 Audit NetworkPolicy for cloudflare namespace
  - **Already has CiliumNP:** `cloudflared-egress` — audit for completeness
  - Needs default-deny + DNS + Gateway ingress (cloudflared metrics: 2000)
  - cloudflared needs egress to Cloudflare edge servers (HTTPS — already handled by existing policy?)

### tailscale

- [ ] 5.3.4.12 Audit NetworkPolicies for tailscale namespace
  - **Already has CiliumNPs:** `operator-egress` + `operator-ingress`
  - Audit for completeness — likely already sufficient

### Remaining Namespaces

> These namespaces are Helm-managed or have limited workloads. Evaluate whether
> default-deny adds value vs. operational overhead.

- [ ] 5.3.4.13 Evaluate policies for longhorn-system, intel-device-plugins, node-feature-discovery
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
  # AdGuard DNS — CRITICAL (network-wide DNS)
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
> - DNS inspection rule (`rules.dns`) is **mandatory** — without it, Cilium can't populate FQDN-to-IP cache
> - Cannot mix `toFQDNs` with `toEndpoints`/`toCIDR` in the same egress rule — use separate array items
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

## 5.3.7 Node-Level Network Hardening

> **Why:** NetworkPolicies don't protect hostNetwork pods. The control plane components
> (API server, etcd, scheduler, controller-manager) and node-exporter use hostNetwork.
> A compromised pod with hostNetwork can reach etcd directly on port 2379.

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

> **Decision needed:** Implement via OPNsense firewall rules (recommended — centralized, visible in OPNsense UI) or via iptables/nftables on each node (more work, survives OPNsense failure).

- [ ] 5.3.7.2a Document current host port exposure on all 3 CP nodes
- [ ] 5.3.7.2b Decide on implementation approach (OPNsense vs. node-level)
- [ ] 5.3.7.2c If OPNsense: create firewall rules restricting etcd (2379-2380) to CP nodes only
- [ ] 5.3.7.2d If OPNsense: create firewall rules restricting kubelet (10250) to API server

### 5.3.7.3 Create GitOps namespace NetworkPolicy template

```yaml
# Pre-plan the NetworkPolicy for ArgoCD/FluxCD namespace (Phase 6)
# This isn't applied now — just documented for when GitOps is deployed
# ArgoCD/FluxCD needs:
# - Egress to kube-apiserver (6443) — manage cluster resources
# - Egress to GitLab (git pull) — source of truth
# - Egress to Helm registries (443) — chart pulls
# - Ingress from Gateway (UI access)
# - Ingress from monitoring (Prometheus scraping)
# - Default deny everything else
```

- [ ] 5.3.7.3a Draft CiliumNetworkPolicy for ArgoCD namespace (egress to apiserver + GitLab + registries)
- [ ] 5.3.7.3b Draft K8s NetworkPolicy for ArgoCD namespace (default-deny + DNS + monitoring ingress)
- [ ] 5.3.7.3c Document in phase-6 plan for application during ArgoCD deployment

---

## 5.3.8 Documentation

- [ ] 5.3.8.1 Update `docs/context/Security.md` with NetworkPolicy strategy
  - Document hybrid K8s NP + CiliumNP approach and rationale
  - Traffic matrix summary per namespace
  - Cilium-specific limitations (Gateway identity, FQDN, pod CIDR)
  - Node-level port exposure and firewall decisions
- [ ] 5.3.8.2 Update `docs/reference/CHANGELOG.md`

---

## Verification Checklist

- [ ] CiliumClusterwideNetworkPolicy for `reserved:ingress` applied FIRST
- [ ] Every namespace with workloads has a default-deny (ingress + egress)
- [ ] Every namespace has DNS egress allowed
- [ ] Gateway ingress uses CiliumNP `fromEntities: [ingress]` (NOT K8s NP `namespaceSelector`)
- [ ] kube-apiserver egress uses CiliumNP `toEntities: [kube-apiserver]` (NOT `ipBlock`)
- [ ] FQDN egress uses CiliumNP `toFQDNs` with DNS inspection rules
- [ ] external-secrets can ONLY reach Vault + kube-apiserver
- [ ] vault ingress limited to ESO + Prometheus + Gateway + unsealer
- [ ] monitoring: Prometheus scraping works (via `toEntities: [cluster]`, NOT pod CIDR)
- [ ] monitoring: Alertmanager can send Discord + email + healthchecks.io
- [ ] cert-manager egress allows Let's Encrypt + Cloudflare only
- [ ] App databases reachable only from their own app pods
- [ ] Cross-namespace DB access blocked (tested)
- [ ] All 31 HTTPRoutes still serve traffic via Gateway
- [ ] All 30 ExternalSecrets still synced
- [ ] AdGuard DNS LoadBalancer (10.10.30.53) still resolves from LAN
- [ ] GitLab SSH LoadBalancer (10.10.30.21) still accepts connections
- [ ] All 7 CronJobs complete successfully after policies applied
- [ ] Existing CiliumNetworkPolicies audited — no duplicates or conflicts
- [ ] OPNsense stale state issue investigated
- [ ] Node port exposure documented
- [ ] GitOps namespace NetworkPolicy template prepared

---

## Rollback

NetworkPolicies take effect immediately. If something breaks:

```bash
# 1. Identify which policy broke things
kubectl-homelab get networkpolicy -n <namespace>
kubectl-homelab get ciliumnetworkpolicy -n <namespace>

# 2. Delete the problematic policy — connectivity restores instantly
kubectl-homelab delete networkpolicy <name> -n <namespace>
kubectl-homelab delete ciliumnetworkpolicy <name> -n <namespace>

# 3. Fix the policy and re-apply
```

**Nuclear option (remove all policies from a namespace):**
```bash
kubectl-homelab delete networkpolicy --all -n <namespace>
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
