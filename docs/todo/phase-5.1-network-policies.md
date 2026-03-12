# Phase 5.1: Network Policies

> **Status:** ⬜ Planned
> **Target:** v0.31.0
> **Prerequisite:** Phase 5.0 (v0.30.0 — namespace manifests and PSS must exist first)
> **DevOps Topics:** Network segmentation, zero-trust networking, microsegmentation
> **CKA Topics:** NetworkPolicy (ingress/egress rules, podSelector, namespaceSelector, ipBlock)

> **Purpose:** Network segmentation — prevent lateral movement between namespaces
>
> **Learning Goal:** Kubernetes NetworkPolicy — the single highest-impact security control

> **WARNING:** Incorrect NetworkPolicies can break the cluster. Apply one namespace at a time, test after each.

---

## Cluster Network Reference

All NetworkPolicies reference these CIDRs. Confirm before writing rules:

| CIDR | Purpose | Source |
|------|---------|--------|
| `10.96.0.0/12` | Kubernetes service CIDR | kubeadm ClusterConfiguration |
| `10.244.0.0/16` | Pod CIDR | kubeadm ClusterConfiguration |
| `10.10.30.0/24` | Node CIDR (K8s VLAN) | Physical network |
| `10.10.30.4` | NAS (OMV) — NFS | Physical network |

```bash
# Verify at runtime
kubectl-homelab cluster-info dump | grep -m1 service-cluster-ip-range
kubectl-homelab cluster-info dump | grep -m1 cluster-cidr
```

---

## 5.1.1 Audit Current Connectivity

- [ ] 5.1.1.1 Map cross-namespace traffic
  ```bash
  # Test: can any pod reach any other namespace?
  kubectl-homelab run test --rm -it --image=curlimages/curl -n home -- \
    curl -s --max-time 5 http://prometheus-grafana.monitoring.svc:80 && echo "OPEN"

  # Test: can app pods reach external internet?
  kubectl-homelab run test --rm -it --image=curlimages/curl -n home -- \
    curl -s --max-time 5 http://example.com && echo "OPEN"
  ```

- [ ] 5.1.1.2 Document what currently talks to what (baseline before locking down)

---

## 5.1.2 Default Deny Template

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

---

## 5.1.3 Infrastructure Namespace Policies

These are unique per namespace. Each gets a detailed traffic matrix.

### external-secrets

ESO is the highest-priority namespace to lock down. ESO docs warn: *"ESO may be used to exfiltrate data out of your cluster."*

| Direction | Target | Port | Why |
|-----------|--------|------|-----|
| Egress | vault.vault.svc | 8200 | Fetch secrets from Vault |
| Egress | kube-apiserver | 443/6443 | Read/write K8s Secrets, webhook validation |
| Ingress | monitoring ns (Prometheus) | 8080 | Metrics scraping |
| Ingress | Node IPs (kubelet) | 8081 | Health checks |
| Ingress | kube-apiserver | 10250 | Admission webhook requests |

- [ ] 5.1.3.1 Create `manifests/external-secrets/networkpolicy.yaml`
  ```yaml
  # Default deny + DNS (from template above), plus:
  # Allow egress: Vault namespace (8200), apiserver (443/6443)
  # Allow ingress: Prometheus (8080), kubelet (8081), apiserver (10250)
  #
  # Note: kube-apiserver runs on host network — use ipBlock for node CIDR
  # or allow ports 443/6443 broadly. Standard K8s NetworkPolicy cannot
  # target apiserver by entity. CiliumNetworkPolicy can (see 5.1.6).
  ```

### vault

| Direction | Target | Port | Why |
|-----------|--------|------|-----|
| Egress | kube-apiserver | 443/6443 | Kubernetes auth backend |
| Egress | NAS 10.10.30.4 | 2049 | NFS for Raft snapshots |
| Ingress | external-secrets ns | 8200 | ESO fetches secrets |
| Ingress | monitoring ns | 8200 | Prometheus metrics scraping |
| Ingress | kube-system ns | 8200 | Cilium Gateway proxy (Vault UI) |
| Ingress | vault ns (self) | 8200, 8201 | Unsealer, Raft internal |

- [ ] 5.1.3.2 Create `manifests/vault/networkpolicy.yaml`

### monitoring

The most complex namespace. Prometheus scrapes ALL namespaces.

| Direction | Target | Port | Why |
|-----------|--------|------|-----|
| Egress | ALL namespaces | various | Prometheus scrapes metrics from every namespace |
| Egress | smtp.mail.me.com | 587 | Alertmanager SMTP |
| Egress | discord.com | 443 | Alertmanager Discord webhooks |
| Egress | healthchecks.io | 443 | Watchdog dead man's switch |
| Egress | kube-apiserver | 443/6443 | kube-state-metrics, operator |
| Egress | Loki/Grafana Cloud (if applicable) | 443 | Alloy log shipping (check current config) |
| Ingress | kube-system ns | 443 | Cilium Gateway (Grafana, Prometheus, Alertmanager UI) |
| Ingress | Node IPs | various | kubelet health checks |

- [ ] 5.1.3.3 Create `manifests/monitoring/networkpolicy.yaml`
  - Prometheus needs broad egress — consider allowing egress to pod CIDR `10.244.0.0/16` on common metrics ports (8080, 9090, 9100, etc.)
  - Alertmanager needs SMTP + HTTPS egress to specific external hosts
  - Alloy needs egress to its log destination (check current Alloy config for target endpoint)
  - Grafana only needs ingress from Gateway

### cert-manager

| Direction | Target | Port | Why |
|-----------|--------|------|-----|
| Egress | kube-apiserver | 443/6443 | Manage certificates, read secrets |
| Egress | acme-v02.api.letsencrypt.org | 443 | ACME challenges |
| Egress | api.cloudflare.com | 443 | DNS-01 validation |
| Ingress | Node IPs (kubelet) | various | Health checks |

- [ ] 5.1.3.4 Create `manifests/cert-manager/networkpolicy.yaml`

---

## 5.1.4 Application Namespace Policies

Most app namespaces follow repeating patterns. Define templates, then apply.

### Pattern A: Web App + Database

Applies to: ghost-dev, ghost-prod, invoicetron-dev, invoicetron-prod, atuin, karakeep

```
Gateway → app pod (HTTP) → database pod (DB port)
                         → external SMTP (optional)
```

| Direction | Target | Port | Why |
|-----------|--------|------|-----|
| Ingress (app) | kube-system ns (Gateway) | app HTTP port | Cilium Gateway routes traffic |
| Egress (app) | database pod (same ns) | DB port | App → DB |
| Egress (app) | smtp.mail.me.com (optional) | 587 | Email sending (Ghost, Invoicetron) |
| Ingress (db) | app pod (same ns) | DB port | Only app can reach DB |

- [ ] 5.1.4.1 Create NetworkPolicies for ghost-dev, ghost-prod
  - Ghost HTTP: 2368, MySQL: 3306
  - Ghost needs SMTP egress (mail sending)

- [ ] 5.1.4.2 Create NetworkPolicies for invoicetron-dev, invoicetron-prod
  - App HTTP: 3000, PostgreSQL: 5432

- [ ] 5.1.4.3 Create NetworkPolicies for atuin
  - Atuin HTTP: 8888, PostgreSQL: 5432
  - Backup CronJob needs NFS egress to NAS (10.10.30.4:2049)

- [ ] 5.1.4.4 Create NetworkPolicies for karakeep
  - Karakeep HTTP: 3000, Meilisearch: 7700, Chrome: 9222

### Pattern B: Simple Web App

Applies to: browser, uptime-kuma, home (adguard, homepage, myspeed)

```
Gateway → app pod (HTTP)
```

| Direction | Target | Port | Why |
|-----------|--------|------|-----|
| Ingress | kube-system ns (Gateway) | app HTTP port | UI access |
| Egress | varies | varies | App-specific (AdGuard: DNS, Uptime Kuma: probe targets) |

- [ ] 5.1.4.5 Create NetworkPolicies for home namespace
  - AdGuard: needs DNS egress (53/UDP, 53/TCP) + HTTPS egress (blocklist updates)
  - Homepage: needs egress to many services (widgets query other apps)
  - MySpeed: needs egress to speedtest servers

- [ ] 5.1.4.6 Create NetworkPolicies for browser, uptime-kuma

### Pattern C: ARR Stack (Complex)

arr-stack has 12+ workloads with extensive inter-pod communication + NFS + external trackers.

| Direction | Target | Port | Why |
|-----------|--------|------|-----|
| Ingress (all apps) | kube-system ns (Gateway) | app ports | UI access |
| Egress (Prowlarr) | Internet | 443 | Indexer searches |
| Egress (qBittorrent) | Internet | various | Torrent traffic |
| Egress (Sonarr/Radarr) | same ns (Prowlarr) | 9696 | Indexer API |
| Egress (all) | NAS 10.10.30.4 | 2049 | NFS media storage |
| Egress (Jellyfin) | same ns | various | Connects to Sonarr/Radarr |
| Egress (Tdarr server) | same ns (workers) | various | Dispatches transcode jobs |
| Ingress (Tdarr server) | same ns (workers) | 8265 | Workers report back to server API |

- [ ] 5.1.4.7 Create NetworkPolicies for arr-stack
  - Most complex namespace — needs careful inter-pod allow rules
  - qBittorrent needs broad internet egress (torrent traffic)
  - Tdarr server ↔ worker communication (port 8265 API + worker connections)
  - All apps need NFS egress to NAS

### Pattern D: GitLab

- [ ] 5.1.4.8 Create NetworkPolicies for gitlab, gitlab-runner
  - GitLab is Helm-managed with many internal services
  - Runner needs egress to GitLab API + container registry
  - Registry needs ingress from cluster (image pulls)

### cloudflare

- [ ] 5.1.4.9 Create NetworkPolicy for cloudflare namespace
  - cloudflared needs egress to Cloudflare edge servers (HTTPS)

---

## 5.1.5 Testing & Validation

- [ ] 5.1.5.1 Test authorized traffic after each namespace policy
  ```bash
  # Verify app is reachable via Gateway
  curl -I https://<app>.k8s.rommelporras.com

  # Verify database is reachable from app pod
  kubectl-homelab exec -n <ns> deployment/<app> -- nc -zv <db-svc> <port>
  ```

- [ ] 5.1.5.2 Test unauthorized traffic is blocked
  ```bash
  # From one namespace, try to reach another namespace's DB
  kubectl-homelab run test --rm -it --image=curlimages/curl -n home -- \
    nc -zv postgresql.invoicetron-prod.svc 5432 -w 5
  # Should timeout
  ```

- [ ] 5.1.5.3 Force ESO re-sync after all policies applied
  ```bash
  kubectl-homelab annotate externalsecret ghost-mysql -n ghost-prod \
    force-sync=$(date +%s) --overwrite
  kubectl-homelab get externalsecret -A | grep -v True
  # Should return nothing (all synced)
  ```

---

## 5.1.6 CiliumNetworkPolicy Follow-Up

Standard Kubernetes NetworkPolicy cannot target the kube-apiserver cleanly (it runs on the host network, not in a namespace). For Phase 5.1, we use `ipBlock` with node CIDR as a workaround.

Future improvement: replace apiserver rules with CiliumNetworkPolicy:
```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-apiserver
  namespace: external-secrets
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

This is not in scope for Phase 5.1 but is noted for future refinement.

---

## 5.1.7 Documentation

- [ ] 5.1.7.1 Update `docs/context/Security.md` with NetworkPolicy strategy
- [ ] 5.1.7.2 Update `docs/reference/CHANGELOG.md`

---

## Verification Checklist

- [ ] Every namespace with workloads has a default-deny (ingress + egress)
- [ ] Every namespace has DNS egress allowed
- [ ] external-secrets can ONLY reach Vault + kube-apiserver
- [ ] vault ingress limited to ESO + Prometheus + Gateway + unsealer
- [ ] monitoring egress allows Prometheus scraping + Alertmanager notifications
- [ ] cert-manager egress allows Let's Encrypt + Cloudflare only
- [ ] App databases reachable only from their own app pods
- [ ] Cross-namespace DB access blocked (tested)
- [ ] All HTTPRoutes still serve traffic via Gateway
- [ ] All 30 ExternalSecrets still synced
- [ ] Alertmanager can still send Discord + email notifications

---

## Rollback

NetworkPolicies take effect immediately. If something breaks:

```bash
# 1. Identify which policy broke things
kubectl-homelab get networkpolicy -n <namespace>

# 2. Delete the problematic policy — connectivity restores instantly
kubectl-homelab delete networkpolicy <name> -n <namespace>

# 3. Fix the policy and re-apply
```

**Nuclear option (remove all policies from a namespace):**
```bash
kubectl-homelab delete networkpolicy --all -n <namespace>
```

---

## Final: Commit and Release

- [ ] `/audit-security` then `/commit`
- [ ] `/release v0.31.0 "Network Policies"`
- [ ] `mv docs/todo/phase-5.1-network-policies.md docs/todo/completed/`
