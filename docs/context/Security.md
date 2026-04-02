---
tags: [homelab, kubernetes, security, pss, eso, vault, service-accounts, cis, hardening, network-policies, backup, resilience]
updated: 2026-04-01
---

# Security

Control plane hardening, pod security, secrets infrastructure, and service account hygiene.

## Control Plane Hardening (Phase 5.1)

### CIS Kubernetes Benchmark Scores

| Metric | Before (v0.30.0) | After (v0.31.0) | Phase 5.6 (v0.36.0) |
|--------|-------------------|------------------|----------------------|
| PASS | 51 | 58 | 69 |
| FAIL | 20 | 13 | 7 |
| WARN | 47 | 47 | 36 |

Phase 5.6 results are identical across all 3 CP nodes (kube-bench v0.10.6, targets: master,node,policies).

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

### Remaining FAIL Items (7 - all justified)

| CIS Check | Setting | Reason |
|-----------|---------|--------|
| 1.1.12 | etcd data dir `etcd:etcd` ownership | Architectural: kubeadm stacked etcd runs as root in static pod. No etcd user. |
| 1.2.6 | kubelet-certificate-authority not set | By design: kubeadm uses TLS bootstrapping with auto-rotating certs. Modern approach, functionally equivalent. |
| 1.2.16 | PodSecurityPolicy admission plugin | Stale CIS check: PSP removed in K8s 1.25. Replaced with PSS via namespace labels (Phase 5.0). |
| 1.2.19 | insecure-port not set to 0 | Stale CIS check: `--insecure-port` flag removed in K8s 1.24+. |
| 1.3.7 | controller-manager bind-address not 127.0.0.1 | Intentional: `0.0.0.0` for Prometheus ServiceMonitor scraping. |
| 1.4.2 | scheduler bind-address not 127.0.0.1 | Intentional: `0.0.0.0` for Prometheus ServiceMonitor scraping. |
| 4.1.1 | kubelet service file permissions | False positive: kube-bench checks `/etc/systemd/system/kubelet.service.d/` but Ubuntu 24.04 places file at `/usr/lib/systemd/system/kubelet.service.d/` with correct 644 permissions. |

### Regression Detection

kube-bench runs weekly as a CronJob (`kube-bench-weekly` in kube-system). Alerts to Discord #infra if FAIL count exceeds threshold (7 baseline + 3 buffer = 10). Schedule: Sunday 20:00 Manila time.

### Audit Logging

API server audit logs write to `/var/log/kubernetes/audit/audit.log` on all 3 CP nodes. Policy excludes health probes, watch requests, and controller-manager/scheduler leader election. Secrets logged at Metadata level (who, not what). RBAC changes logged at RequestResponse level.

Logs shipped to Loki via Alloy DaemonSet hostPath mount. Query with `{source="audit_log"}` in Grafana.

### Certificate Lifecycle

All kubeadm certs expire ~Jan 2027 (307 days from Phase 5.1 execution). CAs expire 2036. Weekly CronJob (`cert-expiry-check`) monitors expiry and alerts via Discord when <30 days remaining. PKI backed up weekly to NFS (`/Kubernetes/Backups/pki/`).

Renewal: `sudo kubeadm certs renew all` on each CP node, followed by kubelet restart.

## Image Registry Restriction (Phase 5.6)

ValidatingAdmissionPolicy (VAP) restricts container images to trusted registries. Native K8s admission control (GA since v1.30), no third-party dependencies.

### Trusted Registries

| Registry | Examples |
|----------|----------|
| `docker.io/` | Docker Hub explicit prefix |
| `ghcr.io/` | GitHub Container Registry |
| `registry.k8s.io/` | Kubernetes official images |
| `quay.io/` | Red Hat Quay (ArgoCD) |
| `registry.k8s.rommelporras.com/` | Self-hosted GitLab container registry |
| `registry.gitlab.com/` | GitLab upstream (GitLab CE components) |
| `lscr.io/` | LinuxServer.io (arr-stack apps) |
| `gcr.io/` | Google Container Registry |
| `public.ecr.aws/` | AWS ECR Public (ArgoCD Redis) |
| Docker Hub short names | `org/image` (no dot before first slash) |
| Bare library images | `alpine`, `redis` (no slash) |

### Design Decisions

- CEL expression `!c.image.split('/')[0].contains('.')` allows all Docker Hub orgs without maintaining a list
- `object.spec.?containers.orValue([])` is vacuously true for Deployments/StatefulSets (containers at `spec.template.spec`). Pod-level admission is the real enforcement gate.
- kube-system, kube-node-lease, kube-public exempted from policy
- Covers containers, initContainers, and ephemeralContainers
- Deployed in Warn mode initially; switch to Deny after 1 week of clean operation

### Manifest

`manifests/kube-system/image-registry-policy.yaml` - ValidatingAdmissionPolicy + Binding

## Pod Security Standards (PSS)

Every namespace has an `enforce` level plus `audit: restricted` and `warn: restricted` for visibility.

| Level | Namespaces |
|-------|------------|
| **restricted** | cloudflare |
| **baseline** | ai, argocd, arr-stack, atuin, browser, cert-manager, external-secrets, ghost-dev, ghost-prod, gitlab, home, invoicetron-dev, invoicetron-prod, karakeep, portfolio-dev, portfolio-prod, portfolio-staging, uptime-kuma, vault, velero |
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
| Homepage | Upstream image runs as root, no non-root option |
| cert-expiry-check CronJob | Reads hostPath `/etc/kubernetes/pki` (root-owned mode 600) |
| pki-backup CronJob | Reads hostPath `/etc/kubernetes/pki` + `admin.conf` (root-owned) |
| Grafana backup CronJob | grafana.db is mode 660 owned by uid 472; needs root + DAC_OVERRIDE to read |
| Backup CronJobs (adguard, myspeed, uptime-kuma, arr-stack) | App config files owned by root or app-specific UIDs with no world-read |

## Network Policy Strategy (Phase 5.3)

All network policies use **CiliumNetworkPolicy only** - no Kubernetes NetworkPolicy except those bundled by Helm (e.g., gitlab-redis). This approach enables identity-based access control and FQDN filtering unavailable in vanilla K8s NetworkPolicy.

### Cilium enable-policy=default Mode

Cilium runs with `enable-policy=default`, which means:
- Endpoints without any matching policy allow all ingress/egress traffic
- Once any policy selects an endpoint, default-deny activates for that direction
- Policies are additive (unioned if multiple policies select the same endpoint)

### Cilium Identity Reference

Cilium assigns identities to different network entities. Using the wrong rule type silently fails.

| Destination | Cilium Identity | Correct Egress Rule |
|-------------|----------------|-------------------|
| Pods (managed endpoints) | identity-based | `toEndpoints` or `toEntities: [cluster]` |
| Local node (where pod runs) | `reserved:host` | `toEntities: [host]` |
| Other cluster nodes | `remote-node` | `toEntities: [remote-node]` |
| kube-apiserver | `reserved:kube-apiserver` | `toEntities: [kube-apiserver]` |
| Gateway proxy | `reserved:ingress` | `fromEntities: [ingress]` (ingress rules) |
| External IPs (internet, NAS, LAN devices) | `world` | `toCIDR` / `toCIDRSet` |

**Common mistakes:**
- `toCIDR` with node IPs (10.10.30.11-13) silently fails - nodes have `remote-node` identity
- `toCIDR` with pod CIDR (10.244.0.0/16) silently fails - pods have managed identity
- `toCIDR` with Gateway LB VIP (10.10.30.20) silently fails - service has its own identity
- `fromCIDRSet` alone on LoadBalancer ingress silently fails - Cilium LB rewrites source identity to `host`/`remote-node`/`world`. Appears to work for ~34h (conntrack from before the policy), then new connections drop. Must add `fromEntities: [host, remote-node, world]` alongside `fromCIDRSet`. Affected: AdGuard DNS (10.10.30.53), GitLab SSH (10.10.30.21), OTel Collector (10.10.30.22).

### FQDN Egress Rules

FQDN-based egress requires a DNS inspection rule (`rules.dns`) in the **same policy** as the `toFQDNs` rules - a cluster-wide DNS allow in a separate policy does NOT work.

| Namespace | FQDNs | Ports |
|-----------|-------|-------|
| monitoring (Alertmanager) | smtp.mail.me.com, discord.com, healthchecks.io, hc-ping.com | 587, 443 |
| cert-manager | acme-v02.api.letsencrypt.org, api.cloudflare.com | 443 |
| ghost-dev, ghost-prod | smtp.mail.me.com | 587 |

### Cross-Namespace Ingress Patterns

Destination pods must explicitly allow ingress from these namespaces:
- `monitoring` - blackbox probes, Prometheus scraping
- `cloudflare` - Cloudflare tunnel proxying to portfolio, ghost, invoicetron, uptime-kuma
- `uptime-kuma` - health monitoring (home namespace pods)
- `home` - Homepage Vault widget (direct API access on port 8200)

### Known Limitations

**L7 envoy proxy interference:** Pods with `toPorts` rules in their egress policy trigger Cilium's L7 envoy proxy interception. This causes two known issues:
- **Gateway LB hairpin:** L7 proxy returns HTTP 403 "Access denied" for traffic hairpinning through the Gateway LoadBalancer VIP.
- **Upstream DNS forwarding:** L7 proxy intermittently disrupts DNS forwarding, causing network-wide DNS failures when AdGuard is the primary resolver.

Workaround: use L4-only policy (no `toPorts`) for critical pods that need reliable external connectivity. Currently applied to: Homepage (Gateway widgets), AdGuard Home (DNS forwarding).

### Coverage

25 namespaces with CiliumNetworkPolicy + 1 CiliumClusterwideNetworkPolicy (Gateway `reserved:ingress` identity).

Covered: ai, argocd, arr-stack, atuin, browser, cert-manager, cloudflare, external-secrets, ghost-dev, ghost-prod, gitlab, gitlab-runner, home, invoicetron-dev, invoicetron-prod, karakeep, kube-system, monitoring, portfolio-dev, portfolio-prod, portfolio-staging, tailscale, uptime-kuma, vault, velero

Deferred: longhorn-system, intel-device-plugins, node-feature-discovery (high breakage risk, low attack surface)

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
| home | homepage | Kubernetes cluster/node widgets + Longhorn storage widget |
| vault | snapshot (CronJob) | Reads SA token for Vault Kubernetes auth login |

Helm-managed workloads (Cilium, cert-manager, Longhorn, Vault, NFD, Intel device plugins) control their own `automountServiceAccountToken` via chart defaults.

## ESO Hardening

### Applied Measures

| Measure | Details |
|---------|---------|
| Resource limits | Controller 50m/128Mi–200m/256Mi, webhook/cert-controller 25m/64Mi–100m/128Mi |
| Disabled CRD reconcilers | `ClusterExternalSecret`, `PushSecret`, `ClusterPushSecret` (0 references in codebase) |
| Webhook TLS ciphers | `TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256`, `TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256` |
| ClusterSecretStore namespaceSelector | Only namespaces with `eso-enabled: "true"` can sync secrets |

### ESO-Enabled Namespaces (18)

argocd, arr-stack, atuin, browser, cert-manager, cloudflare, ghost-dev, ghost-prod, gitlab, gitlab-runner, home, invoicetron-dev, invoicetron-prod, karakeep, kube-system, monitoring, tailscale, velero

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
| `longhorn-support-bundle` → `SA/longhorn-system/longhorn-support-bundle` | Longhorn support bundle collection | ✅ Accepted - see below |
| `velero-server` → `SA/velero/velero-server` | Cross-namespace backup/restore | ✅ Accepted - see below |

### Decisions

| Decision | Rationale |
|----------|-----------|
| longhorn-support-bundle cluster-admin accepted | Required for bundle collection across all namespaces. Only one manual CRD triggers it; no continuous privilege. Longhorn upstream - not fixable without forking. Documented as known exception. |
| velero-server cluster-admin accepted | Velero needs cross-namespace access for backup/restore of all K8s resources. Helm chart creates the binding. Required for Velero's core functionality. Single admin homelab - acceptable risk. |
| GitLab Runner `clusterWideAccess: false` | Runner was using a ClusterRole with `resources: ["*"], verbs: ["*"]` on core API. All job pods run in `gitlab-runner` namespace; cross-namespace deploys use `gitlab-deploy` SA (separate namespace Roles). Changed to namespace-scoped Role in Helm values. Helm upgrade applied (rev 5), ClusterRole deleted. |
| version-check-cronjob `automountServiceAccountToken` restored | Phase 5.0 hardening set this to `false` on the CronJob pod spec. Nova (Fairwinds) requires in-cluster API access to read Helm release Secrets (`type: helm.sh/release.v1`) across all namespaces for chart drift detection. Removing the flag restored Nova auth. |

### RBAC Trust Boundaries

```
cluster-admin
    ├── system:masters (kubeadm bootstrap - cluster-admin)
    ├── kubeadm:cluster-admins (kubeadm bootstrap - cluster-admin)
    ├── longhorn-support-bundle (Longhorn SA - cluster-admin, manual trigger only)
    └── velero-server (Velero SA - cross-namespace backup/restore)

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

## Resource Management (Phase 5.4)

### LimitRange

All application namespaces have a LimitRange that sets default requests/limits for pods without explicit values. This prevents unbounded resource consumption and ensures the ResourceQuota admission controller accepts all pods.

### ResourceQuota

15 namespaces have ResourceQuota enforcing CPU, memory, PVC, and pod count limits:

| Namespace | Purpose |
|-----------|---------|
| ai, argocd, arr-stack, atuin, ghost-dev, ghost-prod, home, invoicetron-dev, invoicetron-prod, karakeep, portfolio-dev, portfolio-prod, portfolio-staging, uptime-kuma, velero | Prevent resource exhaustion |

System namespaces (kube-system, monitoring, longhorn-system, gitlab) are excluded - their resource needs are variable and operator-managed.

## Backup Architecture (Phase 5.4)

### Three-Layer Strategy

| Layer | Tool | What It Backs Up | Where | Retention |
|-------|------|-----------------|-------|-----------|
| Volume snapshots | Longhorn RecurringJobs | All Longhorn PVCs (block-level) | NFS NAS `/Kubernetes/Backups/longhorn/` | Critical: 14 daily + 4 weekly, Important: 7 daily + 2 weekly |
| K8s resources | Velero + Garage S3 | Namespace manifests, ConfigMaps, CRDs (excludes Secrets) | In-cluster Garage S3 (Longhorn PVC) | 30 days |
| Database dumps | CronJob (per-app) | SQLite `.backup`, PostgreSQL `pg_dump`, MySQL `mysqldump`, etcd `etcdctl snapshot` | NFS NAS `/Kubernetes/Backups/<app>/` | 3 days (NAS staging) |

**Off-site:** restic on WSL2 pulls all NAS backups via SSH, encrypts with AES-256, stores in OneDrive sync folder. Retention: 7 daily + 4 weekly + 6 monthly.

### Backup Schedule (Asia/Manila)

| Time | CronJob | Target |
|------|---------|--------|
| 02:00 | vault-snapshot | Vault Raft snapshot |
| 02:00 | ghost-mysql-backup | Ghost MySQL |
| 02:00 (Sun) | atuin-backup | Atuin PostgreSQL (pg_dump) |
| 02:05 | adguard-backup | AdGuard SQLite |
| 02:10 | uptime-kuma-backup | Uptime Kuma SQLite |
| 02:15 | karakeep-backup | Karakeep SQLite |
| 02:20 | grafana-backup | Grafana SQLite |
| 02:25 | arr-backup-{prowlarr,sonarr,...} | ARR config SQLite (per-app) |
| 02:30 | myspeed-backup | MySpeed SQLite |
| 03:00 | Longhorn daily critical | Block-level volume snapshots |
| 03:00 | configarr | TRaSH Guide sync (not a backup) |
| 03:30 | etcd-backup | etcd snapshot |
| 04:00 | Longhorn daily important | Block-level volume snapshots |
| 09:00 | invoicetron-db-backup | Invoicetron PostgreSQL (pg_dump) |

### etcd Backup Security

**Architecture:** etcd backup CronJob runs with `hostNetwork: true` and `hostPID: false` on a control plane node. It uses an initContainer with the distroless etcd image to copy `etcdctl` to a shared emptyDir, then `alpine/k8s` runs the snapshot and copies to NFS.

**Encryption decision:** Accept NAS trust (no additional encryption on NAS). Rationale:
- NAS is on the same trusted VLAN (30) as cluster nodes - NAS compromise implies network compromise
- Off-site copy via restic is encrypted (AES-256) - covers the external threat model
- Adding GPG/OpenSSL to the backup CronJob adds a failure mode (key unavailable = silent backup failure)
- NAS retention is 3 days - short exposure window
- Homelab single-admin environment - threat model does not include insider attacks

**Accepted risk:** etcd snapshots on NAS contain the secretbox encryption key and encrypted secret data. A NAS-only compromise (without node access) could extract secrets. Mitigated by VLAN isolation and short retention.

### Grafana Backup - CAP_DAC_OVERRIDE

The Grafana backup CronJob adds `CAP_DAC_OVERRIDE` capability. `grafana.db` has mode 660 owned by uid 472 (grafana user). The backup container runs as root (`runAsUser: 0`) with `readOnlyRootFilesystem: true` and all capabilities dropped except `DAC_OVERRIDE`. Note: `drop: [ALL]` removes `DAC_OVERRIDE` even from root, so it must be explicitly re-added for the sqlite3 `.backup` command to open the file.

**Accepted risk:** `DAC_OVERRIDE` allows the container to bypass file permission checks. Scope is limited to the Grafana PVC mount. The container has no network access (CiliumNetworkPolicy restricts to NFS only), `readOnlyRootFilesystem`, and drops all other capabilities.

### Off-Site Backup Workflow

```
NAS (NFS)                    WSL2                         OneDrive
Backups/<app>/  ──rsync──>  staging/YYYY-MM-DD/  ──restic──>  Homelab/Backup/
                  (SSH)       /mnt/c/rcporras/              (synced to cloud)
                              homelab/backup/
```

1. `homelab-backup.sh pull` - SSH to cp1, NFS mount, rsync all backups to WSL2 staging
2. `homelab-backup.sh encrypt` - restic backup staging to OneDrive repo
3. `.offsite-manifest.json` written to NAS after each step (visibility, not consumed by automation)

**Key management:**
- Repository password in 1Password "Restic Backup Keys" item, seeded to Vault at `restic/backup-keys`
- Recovery key stored separately in 1Password (survives Vault loss)
- Password file at `scripts/backup/.password` (gitignored, caught by `*password*` glob)

### Recovery Procedures

| Scenario | Steps | RTO |
|----------|-------|-----|
| Single app corruption | Restore from NAS CronJob dump, or Longhorn snapshot, or restic | Minutes |
| NAS failure | Restore from restic (OneDrive), Longhorn volumes unaffected | Hours |
| Single node failure | Pods reschedule (60s stateless, 300s databases), Longhorn rebuilds replicas | ~7-11 min |
| Full cluster rebuild | restic restore etcd snapshot, rebuild with kubeadm, restore Longhorn volumes | Hours |

**Restore drill:** Quarterly on `portfolio-dev` namespace (manual only, never automated). Delete namespace, restore from Velero, restore PVC from Longhorn, verify.

### Velero Security

| Setting | Value | Reason |
|---------|-------|--------|
| `--exclude-resources` | `secrets` | Prevent vault-unseal-keys from being stored in Garage S3 |
| `deployNodeAgent` | `false` | Longhorn handles volume-level backups |
| Garage S3 credentials | ExternalSecret from Vault | No imperative `kubectl create secret` |
| PSS | baseline | Standard app-level security posture |

## PodDisruptionBudgets (Phase 5.4)

24 PDBs across the cluster. Strategy:

| Category | PDB Setting | Rationale |
|----------|-------------|-----------|
| Multi-replica (Homepage, Portfolio, cloudflared) | `minAvailable: 1` | At least 1 pod stays up during drain |
| Single-replica critical (Vault, Grafana, Prometheus, AdGuard) | `maxUnavailable: 1` | Allows drain to proceed (0 would block forever) |
| Helm-managed (GitLab, Longhorn) | Chart defaults | 7 GitLab + 8 Longhorn PDBs from Helm (6 instance-manager + csi-attacher + csi-provisioner) |

## Automation Hardening (Phase 5.4)

### version-checker

- Container image tag filter excludes init containers (Velero plugin init, etcd backup init) to reduce false-positive alerts
- `ContainerImageOutdated` alert filtered to `container_type="container"` only

### Renovate

Suspended (GitHub App). Decision: version-checker + Nova covers drift detection. Renovate PRs add noise without value in a single-admin homelab where upgrades are intentional.

### CronJob Monitoring

All CronJobs monitored by `KubeCronJobNotScheduled` and `KubeJobFailed` Prometheus alerts. Backup-specific: `VeleroBackupFailure`, `EtcdBackupStale`, `LonghornVolumeAllReplicasStopped`.

## GitOps Security Model (Phase 5.6)

Security controls for ArgoCD-managed cluster operations (Phase 5.7+).

| Layer | Control | Details |
|-------|---------|---------|
| Source | Self-hosted GitLab | Deploy token with `read_repository` scope |
| Admission | ValidatingAdmissionPolicy | Trusted image registries only (CEL-based) |
| Secrets | Vault + ESO | Never raw Secrets in Git. 31 ExternalSecrets from Vault (16 namespaces). |
| Network | CiliumNetworkPolicy | Default-deny on 25 namespaces (129 policies) |
| Drift | Auto-sync with selfHeal | ArgoCD auto-syncs from Git, reverts manual changes |
| Imperative exceptions | vault-unseal-keys | Bootstrap secret - ArgoCD must never prune vault namespace Secrets |

## Security Posture Summary (Phase 5.6)

| Control | Status | Coverage | Known Gaps |
|---------|--------|----------|------------|
| PSS | Enforced | 28/32 namespaces | 4 empty/system ns (cilium-secrets, default, kube-node-lease, kube-public) |
| CiliumNP | Default-deny | 25/32 namespaces (129 policies) | longhorn-system, NFD, intel-dp (privileged, low attack surface) |
| RBAC | Audited | 4 cluster-admin bindings | velero-server (accepted - cross-ns backup) |
| etcd encryption | Active (secretbox) | All secrets | |
| Audit logging | Active | All API calls | Audit alerts deferred (needs Loki Ruler) |
| Backup | 3-layer | Longhorn+Velero+etcd (24 CronJobs) | |
| CIS benchmark | 69 pass / 7 fail | All 3 CP nodes identical | 7 justified FAILs documented |
| Image restriction | VAP Warn mode | All non-system namespaces | Deny mode target: 2026-04-02 |
| ESO | Healthy | 31 ExternalSecrets (16 namespaces) | 4 manifests in Git not deployed (invoicetron - no ArgoCD app) |
| Supply chain | Tag pinning | All images except 1 | portfolio:latest (CI/CD pattern, Phase 5.8) |
| ResourceQuotas | Active | 15 namespaces | System ns excluded (variable needs) |
| PDBs | Active | 24 PDBs | |
| Vault | Healthy | Auto-unseal, daily snapshots | |
