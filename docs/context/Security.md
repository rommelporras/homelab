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
| cert-expiry-check CronJob | Reads hostPath `/etc/kubernetes/pki` (root-owned mode 600) |
| pki-backup CronJob | Reads hostPath `/etc/kubernetes/pki` + `admin.conf` (root-owned) |

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
| monitoring | version-check-cronjob | Nova reads Helm release Secrets (`helm.sh/release.v1`) cluster-wide for chart drift |
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

## RBAC Hardening (Phase 5.2)

### Audit Results (2026-03-15)

| Binding | Subjects | Verdict |
|---------|----------|---------|
| `cluster-admin` → `Group/system:masters` | kubeadm bootstrap | ✅ Expected |
| `kubeadm:cluster-admins` → `Group/kubeadm:cluster-admins` | kubeadm bootstrap | ✅ Expected |
| `longhorn-support-bundle` → `SA/longhorn-system/longhorn-support-bundle` | Longhorn support bundle collection | ✅ Accepted — see below |

### Decisions

| Decision | Rationale |
|----------|-----------|
| longhorn-support-bundle cluster-admin accepted | Required for bundle collection across all namespaces. Only one manual CRD triggers it; no continuous privilege. Longhorn upstream — not fixable without forking. Documented as known exception. |
| GitLab Runner `clusterWideAccess: false` | Runner was using a ClusterRole with `resources: ["*"], verbs: ["*"]` on core API. All job pods run in `gitlab-runner` namespace; cross-namespace deploys use `gitlab-deploy` SA (separate namespace Roles). Changed to namespace-scoped Role in Helm values. Helm upgrade applied (rev 5), ClusterRole deleted. |
| version-check-cronjob `automountServiceAccountToken` restored | Phase 5.0 hardening set this to `false` on the CronJob pod spec. Nova (Fairwinds) requires in-cluster API access to read Helm release Secrets (`type: helm.sh/release.v1`) across all namespaces for chart drift detection. Removing the flag restored Nova auth. |

### RBAC Trust Boundaries

```
cluster-admin
    ├── system:masters (kubeadm bootstrap — cluster-admin)
    ├── kubeadm:cluster-admins (kubeadm bootstrap — cluster-admin)
    └── longhorn-support-bundle (Longhorn SA — cluster-admin, manual trigger only)

Read-only (restricted)
    └── claude-code SA (kube-system)
            ClusterRole: get/list/watch all resources EXCEPT secrets
            Secrets: list only (names/metadata — no values)
            Enforced by: RBAC + protect-sensitive.sh hook
```

## etcd Encryption at Rest (Phase 5.2)

Enabled 2026-03-15 on all 3 control plane nodes.

| Setting | Value |
|---------|-------|
| Provider | `secretbox` (XSalsa20-Poly1305) |
| Key name | `key1` |
| Config path | `/etc/kubernetes/encryption-config.yaml` (mode 600, root:root) |
| Key backup | 1Password "etcd Encryption Key" in Kubernetes vault |
| Resources encrypted | `secrets` only |
| Identity fallback | `identity: {}` as second provider (read existing unencrypted data) |

### Why secretbox over aescbc

k8s docs: aescbc is "not recommended due to CBC's vulnerability to padding oracle attacks." secretbox uses XSalsa20-Poly1305 — AEAD cipher with authentication. Verified from k8s GitHub source.

### Verification

etcd raw prefix on all secrets: `k8s:enc:secretbox:v1:key1:` — confirmed via `etcdctl get --print-value-only | head -c 30 | cat -v` on cp1.

All pre-existing secrets re-encrypted 2026-03-15 via `kubectl get secrets -A -o json | kubectl replace -f -`.

### Rebuild

Key passed at Ansible runtime: `--extra-vars "etcd_encryption_key=$(op read 'op://Kubernetes/etcd Encryption Key/password')"`. Baked into `ansible/playbooks/03-init-cluster.yml` (deploy task + extraArg + extraVolume).

### Key Rotation

To rotate: add new key as first entry in EncryptionConfiguration, rolling-restart API servers, re-encrypt all secrets, remove old key, restart again. Update 1Password item.

## Claude Code Access Restrictions (Phase 5.2)

Defense in depth — two independent layers prevent Claude Code from reading secret values.

### Layer 1: Restricted Kubeconfig (RBAC)

| Resource | `kubectl-homelab` access |
|----------|--------------------------|
| All resources (pods, services, nodes, etc.) | `get`, `list`, `watch` |
| Secrets | `list` only (table format — names/metadata, not values) |
| Secrets (`get` individual) | **Forbidden** (API server rejects) |

ServiceAccount: `claude-code` in `kube-system`. Permanent token in `claude-code-token` Secret.
Kubeconfigs: both admin and restricted saved to 1Password "Kubeconfig" (fields: `admin-kubeconfig`, `claude-kubeconfig`).

```bash
# Sync to new device
op item get 'Kubeconfig' --vault=Kubernetes --fields admin-kubeconfig > ~/.kube/homelab.yaml
op item get 'Kubeconfig' --vault=Kubernetes --fields claude-kubeconfig > ~/.kube/homelab-claude.yaml
```

### Layer 2: Hook Blocking (protect-sensitive.sh)

Even if RBAC were misconfigured, the PreToolUse hook blocks the Bash command before it reaches the cluster:

| Command pattern | Action |
|----------------|--------|
| `kubectl get secret[s] -o json/yaml/jsonpath` | Blocked (exit 2) |
| `kubectl describe secret[s]` | Blocked (exit 2) |

### Alias Mapping

| Alias | Kubeconfig | Access |
|-------|-----------|--------|
| `kubectl-homelab` | `~/.kube/homelab-claude.yaml` | Restricted (Claude Code) |
| `kubectl-admin` | `~/.kube/homelab.yaml` | Full cluster-admin (user only) |
| `helm-homelab` | `~/.kube/homelab.yaml` | Full (Helm needs admin for installs) |

### Token Rotation

If `claude-code` token is compromised: delete `claude-code-token` Secret in kube-system (k8s immediately revokes it), create new Secret, rebuild `homelab-claude.yaml`, update 1Password "Kubeconfig" item.
