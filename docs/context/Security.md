---
tags: [homelab, kubernetes, security, pss, eso, vault, service-accounts, cis, hardening]
updated: 2026-03-15
---

# Security

Control plane hardening, pod security, secrets infrastructure, and service account hygiene.

## Control Plane Hardening (Phase 5.1)

### CIS Kubernetes Benchmark Scores

| Metric | Before (v0.30.0) | After (v0.31.0) |
|--------|-------------------|------------------|
| PASS | 51 | 58 |
| FAIL | 20 | 13 |
| WARN | 47 | 47 |

### Applied Hardening

| Component | Setting | CIS Check |
|-----------|---------|-----------|
| Kubelet | `readOnlyPort: 0` | 4.2.4 |
| Kubelet | `protectKernelDefaults: true` | 4.2.6 |
| Kubelet | `eventRecordQPS: 5` | 4.2.8 |
| API server | `--profiling=false` | 1.2.18 |
| API server | `--audit-log-path`, `--audit-policy-file`, `--audit-log-max*` | 1.2.16–1.2.19 |
| Controller-manager | `--profiling=false` | 1.3.2 |
| Scheduler | `--profiling=false` | 1.4.1 |

### Intentionally Excluded

| Setting | CIS Check | Reason |
|---------|-----------|--------|
| `--anonymous-auth=false` | 1.2.1 (WARN/Manual) | Breaks kubelet startup probes in k8s 1.35 — `/livez` returns 401 for unauthenticated requests. RBAC blocks `system:anonymous` (403) instead. Security posture equivalent. |
| `--bind-address=127.0.0.1` (CM/scheduler) | 1.3.7, 1.4.2 | Intentionally `0.0.0.0` for Prometheus scraping. |
| etcd data dir `etcd:etcd` ownership | 1.1.12 | etcd runs as static pod (root). Expected with kubeadm. |

### Audit Logging

API server audit logs write to `/var/log/kubernetes/audit/audit.log` on all 3 CP nodes. Policy excludes health probes, watch requests, and controller-manager/scheduler leader election. Secrets logged at Metadata level (who, not what). RBAC changes logged at RequestResponse level.

Logs shipped to Loki via Alloy DaemonSet hostPath mount. Query with `{source="audit_log"}` in Grafana.

### Certificate Lifecycle

All kubeadm certs expire ~Jan 2027 (307 days from Phase 5.1 execution). CAs expire 2036. Weekly CronJob (`cert-expiry-check`) monitors expiry and alerts via Discord when <30 days remaining. PKI backed up weekly to NFS (`/Kubernetes/Backups/pki/`).

Renewal: `sudo kubeadm certs renew all` on each CP node, followed by kubelet restart.

## Pod Security Standards (PSS)

Every namespace has an `enforce` level plus `audit: restricted` and `warn: restricted` for visibility.

| Level | Namespaces |
|-------|------------|
| **restricted** | cloudflare |
| **baseline** | ai, arr-stack, atuin, browser, cert-manager, external-secrets, ghost-dev, ghost-prod, gitlab, home, invoicetron-dev, invoicetron-prod, karakeep, portfolio-dev, portfolio-prod, portfolio-staging, uptime-kuma, vault |
| **privileged** | gitlab-runner, intel-device-plugins, kube-system, longhorn-system, monitoring, node-feature-discovery, tailscale |
| **no labels** | cilium-secrets, default, kube-node-lease, kube-public |

### Privileged Justifications

| Namespace | Reason |
|-----------|--------|
| gitlab-runner | Build pods may need elevated permissions |
| intel-device-plugins | hostPath volumes for GPU device access |
| kube-system | System components (Cilium, coredns, kube-proxy) |
| longhorn-system | Host-level storage operations, hostPath volumes |
| monitoring | node-exporter hostNetwork/hostPID, Alloy hostPath |
| node-feature-discovery | hostPath volumes for hardware detection |
| tailscale | Subnet router needs NET_RAW, NET_ADMIN |

### Unlabeled Namespaces

| Namespace | Reason |
|-----------|--------|
| cilium-secrets | Cilium-managed, no user pods |
| default | Unused |
| kube-node-lease | System lease objects only, no pods |
| kube-public | System namespace, no pods |

### Known Non-Root Exceptions

These pods run as root due to upstream image constraints (baseline PSS allows this):

| App | Reason |
|-----|--------|
| Karakeep | s6-overlay requires root for init |
| Meilisearch | Image runs as root (upstream) |
| Ollama | Upstream PR #8259 not merged |
| Tdarr | Expects root init, drops privileges |
| Ghost MySQL / Invoicetron PostgreSQL | gosu/su-exec entrypoint needs privilege escalation |
| Portfolio (nginx) | Needs CHOWN, SETUID, SETGID, NET_BIND_SERVICE — root required for port 80 bind and file ownership |
| MySpeed | Upstream image runs as root, no non-root option |
| version-check CronJob | Main container uses `apk` which needs write access to `/lib/apk/db` |

## automountServiceAccountToken

Most app pods have `automountServiceAccountToken: false` — they don't call the Kubernetes API.

### Pods That Need API Access (true)

| Namespace | Workload | Reason |
|-----------|----------|--------|
| external-secrets | controller, webhook, cert-controller | Reads/writes K8s Secrets |
| kube-system | cilium-operator | CNI management |
| kube-system | cluster-janitor (CronJob) | Deletes failed pods, stopped replicas |
| monitoring | prometheus, alertmanager, grafana | Scrapes cluster, service discovery |
| monitoring | kube-prometheus-operator | Manages Prometheus CRDs |
| monitoring | kube-state-metrics | Reads cluster state |
| monitoring | loki | Log ingestion |
| monitoring | version-checker | Queries container image versions |
| vault | snapshot (CronJob) | Reads SA token for Vault Kubernetes auth login |

Helm-managed workloads (Cilium, cert-manager, Longhorn, Vault, NFD, Intel device plugins) control their own `automountServiceAccountToken` via chart defaults.

### Deferred

- `invoicetron/deployment.yaml` — image not in registry. Change commented out; apply when image is fixed.

## ESO Hardening

### Applied Measures

| Measure | Details |
|---------|---------|
| Resource limits | Controller 50m/128Mi–200m/256Mi, webhook/cert-controller 25m/64Mi–100m/128Mi |
| Disabled CRD reconcilers | `ClusterExternalSecret`, `PushSecret`, `ClusterPushSecret` (0 references in codebase) |
| Webhook TLS ciphers | `TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256`, `TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256` |
| ClusterSecretStore namespaceSelector | Only namespaces with `eso-enabled: "true"` can sync secrets |

### ESO-Enabled Namespaces (15)

arr-stack, atuin, browser, cert-manager, cloudflare, ghost-dev, ghost-prod, gitlab, gitlab-runner, home, invoicetron-dev, invoicetron-prod, karakeep, kube-system, monitoring

### Known Trade-offs

| Decision | Rationale |
|----------|-----------|
| HTTP Vault connection (not HTTPS) | In-cluster only, no external exposure. mTLS adds cert overhead for minimal gain. |
| Single ClusterSecretStore | Simpler ops. Acceptable for single admin. Revisit if adding untrusted tenants. |
| Broad `eso-policy` (`secret/data/*`) | ESO is the only Vault consumer. Per-namespace policies = 15 roles, significant rework. |
| No policy engine (Kyverno/OPA) | Overkill for single-admin. `namespaceSelector` provides sufficient restriction. |

## Vault + ESO Trust Boundaries

```
1Password (source of truth)
    │
    ▼ (seed script — user runs in safe terminal)
HashiCorp Vault (secret/data/*)
    │
    ▼ (Kubernetes auth — ESO ServiceAccount token)
ClusterSecretStore "vault-backend"
    │
    ▼ (namespaceSelector: eso-enabled=true)
ExternalSecret CRDs (per namespace)
    │
    ▼ (ESO controller creates/updates)
Kubernetes Secrets (consumed by pods)
```

| Boundary | Control |
|----------|---------|
| 1Password → Vault | Seed script with `op://` references; values never in git or Claude context |
| Vault → ESO | Kubernetes auth (SA token validation), `eso` role bound to `external-secrets` SA |
| ESO → Namespaces | `namespaceSelector` on ClusterSecretStore; unlabeled namespaces are blocked |
| Vault bootstrap | `vault-unseal-keys` is the only imperative secret (chicken-and-egg) |
| Vault access | `eso-policy` grants read on `secret/data/*`, list on `secret/metadata/*` |
