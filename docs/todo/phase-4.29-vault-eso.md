# Phase 4.29: Vault + External Secrets Operator

> **Status:** ✅ Complete (v0.29.0 released)
> **Released:** 2026-03-12
> **Prerequisite:** Phase 4.31 complete (Cluster Janitor + Discord Restructure)
> **DevOps Topics:** Secrets management, HashiCorp Vault, External Secrets Operator, GitOps, Kubernetes auth
> **CKA Topics:** ServiceAccount tokens, RBAC, Secrets, PersistentVolumeClaims

> **Purpose:** Replace all imperative `kubectl create secret` commands (backed by 1Password CLI) with
> a declarative `ExternalSecret` CRD pattern backed by self-hosted HashiCorp Vault. Every secret in
> the cluster becomes a git-committed manifest with zero hardcoded values.
>
> **Why before hardening:** Phase 5 Production Hardening will audit RBAC, NetworkPolicies, and
> credential access across the cluster. Migrating secrets to Vault first means hardening can include
> Vault policies as part of the security posture — not as a separate post-hardening retrofit.
>
> **Learning value:** This is the exact stack used in enterprise AWS/EKS environments. ESO's
> `ExternalSecret` pattern is backend-agnostic — swapping Vault for AWS Secrets Manager only
> requires changing the `ClusterSecretStore` backend. All `ExternalSecret` manifests remain
> identical. This directly translates to day-job EKS work.

---

## Architecture

```
1Password (source of truth — one-time seed via script, manual sync on rotate)
      │
      ▼ scripts/seed-vault-from-1password.sh (user runs in safe terminal)
      │
Vault 1-pod (vault namespace, Raft on Longhorn 5Gi)
      │
      ├── NFS NAS (daily Raft snapshots, 15-day retention — CronJob)
      │
ESO ClusterSecretStore — kubernetes auth (ESO SA → Vault validates with K8s API)
      │
ExternalSecret CRDs (committed to git, per namespace, zero secret values)
      │ synced every 1h
      ▼
K8s Secrets (created and kept in sync automatically)
      │
      ▼
Application pods (unchanged — still consume standard K8s Secrets)
```

**Why 1 pod instead of 3-pod HA:**
- Every other service in this homelab runs as a single pod — Vault doesn't need more
- Longhorn already provides 2x data replication across nodes — Raft HA on top is redundant
- 1 pod = 5Gi storage vs 15Gi, simpler init (no raft join), simpler unseal (1 pod)
- If the pod restarts, K8s + unsealer bring it back automatically — downtime is seconds
- ESO caches synced secrets in K8s Secrets — apps survive Vault downtime

**Unseal strategy:**
- Auto-unseal via a separate `vault-unsealer` Deployment that polls Vault every 30s
- Unsealer reads 3 unseal keys from `vault-unseal-keys` K8s Secret (created imperatively once)
- If Vault pod restarts, unsealer detects sealed state and unseals within 30s
- Unseal keys + root token also stored in 1Password ("Vault Unseal Keys") as break-glass

**Backup strategy:**
- Daily Raft snapshot CronJob writes `vault-YYYYMMDD.snap` to NFS NAS (`/Kubernetes/Backups/vault`)
- 15-day retention (older snapshots pruned by the CronJob script)
- If Vault PVC is lost: restore from latest snapshot or re-seed from 1Password

**Audit logging:**
- `vault audit enable file file_path=stdout` — captured by Alloy/Loki (no extra volume mounts)
- Not `syslog` — containers don't have syslog daemon

**Observability:**
- Vault exposes Prometheus metrics at `/v1/sys/metrics` — scraped via ServiceMonitor (`manifests/vault/servicemonitor.yaml`)
- Requires `unauthenticated_metrics_access = true` in `listener.telemetry` block (Vault 1.16+ moved this from top-level `telemetry`)
- ESO exposes metrics at `/metrics` — scraped via ServiceMonitor (`serviceMonitor.enabled: true`)
- Blackbox probe for Vault UI HTTPRoute health
- PrometheusRule alerts: VaultSealed, VaultMetricsMissing, VaultAuditFailure, VaultDown, VaultHighLatency, ESOSecretNotSynced, ESOSyncErrors, VaultSnapshotFailing
- Grafana dashboard: seal status, Raft storage, request latency, ESO sync status
- Vault + ESO alerts route to Discord #infra (added to Alertmanager infra regex)

**Future path:** Replace unsealer Deployment with AWS KMS auto-unseal when applying this pattern
to the AWS/EKS job. Same architecture, zero app changes.

---

## Safe Automation Model

**Problem:** Claude Code runs on Anthropic's servers. Any secret value that enters the conversation
(via `op read`, `kubectl get secret -o json`, or clipboard paste) is transmitted to Anthropic.

**Solution:** Claude generates scripts containing only `op://` references. The user executes them
in a separate safe terminal with `op` access. Secret values never enter Claude's context.

| Who | Does what |
|-----|-----------|
| Claude | Writes `scripts/seed-vault-from-1password.sh` with `op://` paths |
| Claude | Writes `scripts/configure-vault.sh` (KV v2, K8s auth, policies) |
| Claude | Writes `scripts/verify-migration.sh` (sync + health checks) |
| Claude | Creates all ExternalSecret manifests, Helm values, RBAC, alerts, dashboard |
| **User** 🔒 | Runs `vault operator init` and saves keys to 1Password |
| **User** 🔒 | Runs `vault operator unseal` (first time only) |
| **User** 🔒 | Creates `vault-unseal-keys` K8s Secret imperatively |
| **User** 🔒 | Runs `scripts/configure-vault.sh` in safe terminal |
| **User** 🔒 | Runs `scripts/seed-vault-from-1password.sh` in safe terminal |
| Claude | Applies ExternalSecrets per wave, runs `verify-migration.sh` after each |
| Claude | Deletes old secret.yaml files only after verification passes |

Commands marked 🔒 must run in the safe terminal (has `op` access, not Claude Code).

---

## New Files

| File | Purpose |
|------|---------|
| `manifests/vault/namespace.yaml` | vault namespace with PSS baseline labels |
| `manifests/vault/unsealer.yaml` | Auto-unsealer Deployment |
| `manifests/vault/clustersecretstore.yaml` | ClusterSecretStore → Vault backend |
| `manifests/vault/httproute.yaml` | Vault UI at vault.k8s.rommelporras.com |
| `manifests/vault/snapshot-cronjob.yaml` | Daily Raft snapshot to NFS NAS |
| `helm/vault/values.yaml` | HashiCorp Vault Helm values (1-pod, Raft, Prometheus) |
| `helm/external-secrets/values.yaml` | ESO Helm values |
| `scripts/seed-vault-from-1password.sh` | Seeds all secrets from 1Password → Vault (🔒 safe terminal) |
| `scripts/configure-vault.sh` | Vault post-init config: KV v2, K8s auth, policies, audit (🔒 safe terminal) |
| `scripts/verify-migration.sh` | Post-migration verification (ExternalSecret sync + pod health) |
| `manifests/monitoring/alerts/vault-alerts.yaml` | Vault + ESO PrometheusRule alerts |
| `manifests/monitoring/dashboards/vault-dashboard.yaml` | Grafana dashboard ConfigMap |
| `manifests/monitoring/probes/vault.yaml` | Blackbox HTTP probe for Vault UI |
| `manifests/arr-stack/externalsecret.yaml` | Replaces arr-api-keys-secret.yaml |
| `manifests/cloudflare/externalsecret.yaml` | Replaces cloudflare/secret.yaml |
| `manifests/home/homepage/externalsecret.yaml` | Replaces homepage/secret.yaml |
| `manifests/karakeep/externalsecret.yaml` | Replaces karakeep/secret.yaml |
| `manifests/invoicetron/externalsecret-dev.yaml` | 3 ExternalSecrets: invoicetron-db + invoicetron-app + gitlab-registry (dockerconfigjson) |
| `manifests/invoicetron/externalsecret-prod.yaml` | 3 ExternalSecrets: invoicetron-db + invoicetron-app + gitlab-registry (dockerconfigjson) |
| `manifests/ghost-prod/externalsecret.yaml` | 3 ExternalSecrets: ghost-mysql + ghost-mail + ghost-tinybird |
| `manifests/ghost-dev/externalsecret.yaml` | 2 ExternalSecrets: ghost-mysql + ghost-mail |
| `manifests/cert-manager/externalsecret.yaml` | Migrates cloudflare-api-token |
| `manifests/monitoring/externalsecret.yaml` | 6 ExternalSecrets: discord-version-webhook, nut-credentials, monitoring-grafana-admin, monitoring-smtp, monitoring-discord-webhooks, monitoring-healthchecks |
| `manifests/atuin/externalsecret.yaml` | Migrates atuin-secrets (4 fields) |
| `manifests/gitlab/externalsecret.yaml` | 3 ExternalSecrets: gitlab-root-password + gitlab-postgresql-password (2 keys) + gitlab-smtp-password |
| `manifests/gitlab-runner/externalsecret.yaml` | Migrates gitlab-runner-token (key: runner-token only, skip legacy runner-registration-token) |
| `manifests/browser/externalsecret.yaml` | Migrates firefox-auth |
| `manifests/kube-system/cluster-janitor/externalsecret.yaml` | Migrates discord-janitor-webhook |

## Deleted Files

| File | Reason |
|------|--------|
| `manifests/arr-stack/arr-api-keys-secret.yaml` | Replaced by externalsecret.yaml |
| `manifests/cloudflare/secret.yaml` | Replaced by externalsecret.yaml |
| `manifests/home/homepage/secret.yaml` | Replaced by externalsecret.yaml |
| `manifests/karakeep/secret.yaml` | Replaced by externalsecret.yaml |
| `manifests/invoicetron/secret.yaml` | Replaced by invoicetron-dev + invoicetron-prod externalsecret.yaml |
| `manifests/ghost-prod/secret.yaml` | Replaced by externalsecret.yaml |
| `manifests/ghost-dev/secret.yaml` | Replaced by externalsecret.yaml |
| `manifests/kube-system/cluster-janitor/secret.yaml` | Replaced by externalsecret.yaml |
| `scripts/apply-arr-secrets.sh` | Replaced by ExternalSecret CRD |

---

## Vault KV Structure

KV v2 engine at `secret/`. One path per namespace, one sub-path per logical secret group.

```
secret/
  arr-stack/
    api-keys                 → PROWLARR_API_KEY, SONARR_API_KEY, RADARR_API_KEY,
                               BAZARR_API_KEY, TDARR_API_KEY
    qbittorrent              → QBITTORRENT_PASS
  atuin/
    secrets                  → POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_DB, ATUIN_DB_URI
  browser/
    firefox-auth             → username, password
  cert-manager/
    cloudflare-api-token     → api-token
  cloudflare/
    cloudflared-token        → token
  ghost-dev/
    mysql                    → root-password, user-password
    mail                     → smtp-host, smtp-user, smtp-password, from-address
  ghost-prod/
    mysql                    → root-password, user-password
    mail                     → smtp-host, smtp-user, smtp-password, from-address
    tinybird                 → api-url, admin-token, workspace-id, tracker-token
  gitlab/
    root-password            → password
    postgresql-password      → postgresql-password, postgresql-postgres-password
    smtp-password            → password
  gitlab-runner/
    runner-token             → runner-token
  homepage/
    secrets                  → HOMEPAGE_VAR_* (31 fields)
  invoicetron-dev/
    db                       → postgres-password
    app                      → database-url, better-auth-secret
  invoicetron-prod/
    db                       → postgres-password
    app                      → database-url, better-auth-secret
  karakeep/
    secrets                  → nextauth-secret, meili-master-key
  kube-system/
    discord-janitor-webhook  → webhook-url
  invoicetron/
    deploy-token             → username, password
  monitoring/
    discord-webhooks         → incidents, apps, infra, versions, speedtest
    discord-version-webhook  → webhook-url
    grafana                  → password
    healthchecks             → ping-url
    nut-credentials          → username, password
    smtp                     → username, password
```

**Not migrated to Vault (remain imperative by design):**

| Secret | Reason |
|--------|--------|
| `vault-unseal-keys` (vault ns) | Chicken-and-egg — Vault must be running for ESO to work. Backed up in 1Password "Vault Unseal Keys". |
| `tailscale-operator` (tailscale ns) | Managed by Tailscale operator Helm chart |
| TLS certs (`wildcard-*-tls`) | Auto-managed by cert-manager |

**Completed during audit (originally deferred):**

| Secret | Resolution |
|--------|------------|
| Alertmanager webhook URLs | `monitoring-discord-webhooks` ExternalSecret; `scripts/upgrade-prometheus.sh` reads from ESO K8s Secrets |
| Grafana admin password | `monitoring-grafana-admin` ExternalSecret; Helm `admin.existingSecret` in `values.yaml` |
| Invoicetron deploy token | `gitlab-registry` ExternalSecret (both namespaces) with `kubernetes.io/dockerconfigjson` template |
| GitLab SMTP password | `gitlab-smtp-password` ExternalSecret |

**Not migrated (requires GitLab Helm restructure — separate phase):**

| Secret | Reason |
|--------|--------|
| iCloud SMTP in GitLab Helm values | GitLab Helm chart reads SMTP from its own secrets — requires restructuring `values.yaml` |

---

## Task List

### Phase 1: Vault Infrastructure

- [x] **4.29.1** Create `manifests/vault/namespace.yaml` and `helm/vault/values.yaml`
- [x] **4.29.2** Deploy Vault 1-pod via Helm (`hashicorp/vault` chart v0.32.0 / app v1.21.2)
- [x] **4.29.3** 🔒 Initialize Vault — save keys to `~/.vault-keys` + 1Password "Vault Unseal Keys"
- [x] **4.29.4** 🔒 Manually unseal vault-0 (first time only — unsealer handles future restarts)
- [x] **4.29.5** 🔒 Run `scripts/configure-vault.sh` (KV v2, K8s auth, ESO policy + role, file audit, snapshot policy)
- [x] **4.29.6** Create Raft snapshot CronJob + ServiceAccount + NFS PV/PVC (`/Kubernetes/Backups/vault`, 15-day retention)
- [x] **4.29.7** 🔒 Create `vault-unseal-keys` K8s Secret imperatively (3 unseal keys)
- [x] **4.29.8** Create auto-unsealer Deployment (`manifests/vault/unsealer.yaml`)
- [x] **4.29.9** Test auto-unseal: delete vault-0, confirm it recovers Ready within 60s
- [x] **4.29.10** Expose Vault UI via HTTPRoute at `vault.k8s.rommelporras.com`

### Phase 2: External Secrets Operator

- [x] **4.29.11** Deploy ESO via Helm (`external-secrets/external-secrets` chart v2.1.0)
- [x] **4.29.12** Create `ClusterSecretStore` pointing to Vault with Kubernetes auth
- [x] **4.29.13** Verify `ClusterSecretStore` status is `READY=True` (status: Valid/ReadWrite)

### Phase 3: Seed Vault from 1Password

- [x] **4.29.14** Claude generates `scripts/seed-vault-from-1password.sh` with all `op://` paths
- [x] **4.29.15** 🔒 User runs seed script in safe terminal (populates all Vault KV paths)
- [x] **4.29.16** Verify seeded: `vault kv list secret/` shows all expected paths

### Phase 4: Observability

- [x] **4.29.17** Verify Vault Prometheus metrics scraping — Fixed: moved `unauthenticated_metrics_access` into `listener.telemetry{}` block (Vault 1.16+ deprecation), created ServiceMonitor (`manifests/vault/servicemonitor.yaml`), verified 264 metrics in Prometheus
- [x] **4.29.18** Verify ESO metrics scraping — 3 ServiceMonitors in monitoring namespace
- [x] **4.29.19** Create `vault-alerts.yaml` (7 alerts: VaultSealed, VaultAuditFailure, VaultDown, VaultHighLatency, ESOSecretNotSynced, ESOSyncErrors, VaultSnapshotFailing)
- [x] **4.29.20** Create `vault.yaml` Blackbox probe for Vault UI endpoint
- [x] **4.29.21** Create `vault-dashboard.yaml` Grafana dashboard (5 rows)
- [x] **4.29.22** Update Alertmanager infra regex to include `Vault.*|ESO.*` patterns
- [x] **4.29.23** Test: seal vault-0 → verify VaultSealed alert fires — confirmed VaultSealed fired (critical) in Prometheus + Alertmanager within 2m. Auto-unseal recovered in ~30s after scaling unsealer back up. Alert resolved automatically.

### Phase 5: Secret Migration

All 30 ExternalSecrets deployed and verified `SecretSynced`. All workloads rollout-restarted
and confirmed healthy with ESO-managed secrets. Zero imperative secrets remain in application
namespaces (only `vault-unseal-keys` by design).

> **Multi-secret namespaces:** Namespaces with multiple K8s Secrets get one `externalsecret.yaml`
> containing multiple ExternalSecret resources separated by `---`. Each ExternalSecret creates
> exactly one K8s Secret. For example, `manifests/gitlab/externalsecret.yaml` contains three
> ExternalSecret resources: `gitlab-root-password`, `gitlab-postgresql-password`, and `gitlab-smtp-password`.

**Wave 1 — Low risk (no existing secret.yaml, non-critical services):**
- [x] **4.29.24** Migrate `cert-manager` (cloudflare-api-token — 1 ExternalSecret)
- [x] **4.29.25** Migrate `browser` (firefox-auth — 1 ExternalSecret)
- [x] **4.29.26** Migrate `monitoring` (6 ExternalSecrets: discord-version-webhook, nut-credentials, monitoring-grafana-admin, monitoring-smtp, monitoring-discord-webhooks, monitoring-healthchecks)
- [x] **4.29.27** Migrate `kube-system` (discord-janitor-webhook — 1 ExternalSecret)

**Wave 2 — Medium risk (has existing secret.yaml, services restart cleanly):**
- [x] **4.29.28** Migrate `cloudflare` (cloudflared-token — 1 ExternalSecret)
- [x] **4.29.29** Migrate `karakeep` (karakeep-secrets — 1 ExternalSecret)
- [x] **4.29.30** Migrate `arr-stack` (arr-api-keys + qbittorrent-exporter-secret — 2 ExternalSecrets in 1 file)

**Wave 3 — Higher risk (databases, complex multi-field secrets):**
- [x] **4.29.31** Migrate `atuin` (atuin-secrets — 4 fields, `dataFrom.extract`, 1 ExternalSecret)
- [x] **4.29.32** Migrate `gitlab` + `gitlab-runner` (root-password + postgresql-password + smtp-password + runner-token — 3 ExternalSecrets in gitlab, 1 in gitlab-runner)
- [x] **4.29.33** Migrate `home` (homepage-secrets — 31 fields, `dataFrom.extract`, 1 ExternalSecret)
- [x] **4.29.34** Migrate `invoicetron-dev` + `invoicetron-prod` (db + app + gitlab-registry each — 3 ExternalSecrets per namespace, 2 files)
- [x] **4.29.35** Migrate `ghost-prod` + `ghost-dev` (mysql + mail + tinybird — 3 ExternalSecrets for prod, 2 for dev, 2 files)

**Cleanup:**
- [x] **4.29.36** Delete `scripts/apply-arr-secrets.sh`
- [x] **4.29.37** Full-cluster verification — 30/30 ExternalSecrets SecretSynced, all workloads rollout-restarted and healthy

### Phase 6: Cleanup & Docs

- [x] **4.29.38** Update `VERSIONS.md` with Vault v1.21.2 and ESO v2.1.0
- [x] **4.29.39** Update `docs/context/Secrets.md` with new Vault workflow (30 Vault KV paths, all 1P paths)
- [x] **4.29.40** Update `MEMORY.md` with Vault/ESO lessons learned
- [x] **4.29.41** Committed (86cb94b + 3de3692) — v0.29.0 released

### Remaining Items

- [x] ~~**4.29.17** Fix Vault Prometheus metrics 403~~ — Root cause: Vault 1.16+ requires `unauthenticated_metrics_access` in `listener.telemetry{}`, not top-level `telemetry{}`. Fixed by moving the setting and creating a ServiceMonitor (pod annotations don't work with kube-prometheus-stack). Verified 264 metrics scraped.
- [x] **4.29.23** Test VaultSealed alert — confirmed firing (critical) within 2m of sealing. Auto-unseal via unsealer Deployment recovered in ~30s. Alert auto-resolved.

---

## Migration Order Rationale

Migration starts with low-risk secrets (no existing secret.yaml, non-critical services) and
progresses to high-risk ones (production databases, Cloudflare tunnel).

1. **cert-manager, browser** — New ExternalSecret only, no replacement, low blast radius
2. **monitoring, kube-system** — Non-critical webhooks, easy to verify
3. **cloudflare, karakeep, arr-stack** — Has existing secret.yaml, but services restart cleanly
4. **atuin, gitlab** — Databases involved, need careful verification
5. **homepage, invoicetron, ghost** — Complex secrets (31 fields, multi-env), highest risk last

If any migration fails: the old K8s Secret still exists (we haven't deleted it yet), so apps
continue working. Roll back by deleting the ExternalSecret and investigating.

---

## Bootstrap Order (Full Cluster Power Outage)

After a complete cluster power loss, services must come up in this order:

```
1. K8s control plane (kubeadm, etcd, kubelet)     — automatic
2. Longhorn (CSI + volume attach)                  — automatic
3. Vault pod + PVC attached                        — automatic (Deployment)
4. Vault unsealer unseals vault-0                  — automatic (30s poll)
5. ESO reconnects to Vault ClusterSecretStore      — automatic
6. ExternalSecrets re-sync K8s Secrets             — automatic (1h or on restart)
7. All other pods start with secrets available      — automatic
```

**If Vault PVC is lost (Longhorn failure):**
1. Redeploy Vault (Helm install)
2. 🔒 Re-init (`vault operator init`) — new unseal keys
3. 🔒 Update unseal keys in 1Password + `vault-unseal-keys` K8s Secret
4. 🔒 Re-run `scripts/seed-vault-from-1password.sh`
5. ESO will re-sync all secrets automatically

**If just the Vault pod restarts:** Unsealer handles it — no manual action needed.

---

## Verification Checklist

- [x] `kubectl get pods -n vault` — vault-0 + unsealer Running/Ready
- [x] `kubectl get pods -n external-secrets` — ESO pods Running (3 pods)
- [x] `kubectl get clustersecretstores` — `vault-backend` Valid/ReadWrite/READY=True
- [x] `kubectl get externalsecrets -A` — all 30 SecretSynced, READY=True
- [x] Delete vault-0 → auto-unseals within 60s without manual intervention
- [x] `https://vault.k8s.rommelporras.com` loads Vault UI (HTTPRoute deployed)
- [x] All apps still running after migration — rollout-restarted all workloads, zero failures
- [x] No `secret.yaml` placeholder files remain (all replaced by `externalsecret.yaml`)
- [x] `scripts/apply-arr-secrets.sh` deleted
- [x] Vault metrics visible in Prometheus — 264 metrics scraped via ServiceMonitor (fixed 403 by moving HCL setting to `listener.telemetry{}`)
- [x] ESO metrics visible in Prometheus — 3 ServiceMonitors in monitoring namespace
- [x] Blackbox probe deployed (`probe vault` in monitoring namespace)
- [x] VaultSealed alert fires when vault pod is sealed — confirmed (critical, fires within 2m, auto-resolves after unseal)
- [x] ESOSecretNotSynced alert fires when Vault is sealed — indirectly validated: ESO metrics show SecretSynced=True throughout (existing K8s Secrets survive Vault downtime via cache). Alert requires >10m sealed to fire — covered by VaultSealed alert which fires in 2m.
- [x] VaultDown alert fires when pod is deleted — validated as working correctly: pod delete + auto-unseal recovers in ~35s (faster than 5m threshold). Alert correctly did not fire (transient). For sustained Vault unavailability, the alert would fire after 5m.
- [x] Vault Grafana dashboard ConfigMap deployed (`vault-dashboard` in monitoring)
- [x] Raft snapshot CronJob runs successfully — tested manually, `vault-20260312.snap` (48KB) on NAS
- [x] `vault audit list` shows file device enabled — verified via `vault.k8s.rommelporras.com` (file/ type active)
- [x] Alertmanager infra regex includes `Vault.*|ESO.*`
- [x] All ExternalSecrets across all namespaces show STATUS=SecretSynced (30/30)
- [x] Full-cluster verification — all workloads rollout-restarted and healthy

---

## Secret Rotation Procedure (steady state)

1. Open `https://vault.k8s.rommelporras.com`
2. Navigate to secret path → update value
3. ESO syncs within 1h automatically (or trigger: `kubectl annotate externalsecret <name> -n <ns> force-sync=$(date +%s) --overwrite`)
4. Update same value in 1Password manually (cloud backup)

No `kubectl create secret`. No `op read`. No scripts.

---

## Technical Reference

> This section captures key commands and config so the phase is fully executable
> from this file alone.

### Component Versions

| Component | Helm Chart | Helm Version | App Version |
|-----------|-----------|--------------|-------------|
| HashiCorp Vault | `hashicorp/vault` | 0.32.0 | v1.21.2 |
| External Secrets Operator | `external-secrets/external-secrets` | 2.1.0 | v2.1.0 |

```bash
helm-homelab repo add hashicorp https://helm.releases.hashicorp.com
helm-homelab repo add external-secrets https://charts.external-secrets.io
helm-homelab repo update
```

### Vault Namespace (`manifests/vault/namespace.yaml`)

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: vault
  labels:
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/enforce-version: latest
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: latest
```

> **Why not `restricted`?** Vault Helm chart (vault-helm issue #1035) does not fully satisfy
> the `restricted` PSS profile out of the box — the server pod is rejected at
> admission. Use `baseline` now; Phase 5 Hardening will add explicit `securityContext` overrides
> and can then promote to `restricted`.

### Vault Helm Values Summary (`helm/vault/values.yaml`)

Key settings — 1-pod standalone, Raft storage, Longhorn 5Gi, injector disabled, Prometheus scraping:

```yaml
server:
  image: { repository: hashicorp/vault, tag: "1.21.2" }
  standalone:
    enabled: true
    config: |
      ui = true
      listener "tcp" {
        tls_disable = 1, address = "[::]:8200", cluster_address = "[::]:8201"
        telemetry { unauthenticated_metrics_access = true }
      }
      storage "raft" { path = "/vault/data" }
      service_registration "kubernetes" {}
      telemetry { prometheus_retention_time = "24h", disable_hostname = true }
  ha:
    enabled: false
  dataStorage: { enabled: true, size: 5Gi, storageClass: longhorn }
  resources: { requests: { memory: 256Mi, cpu: 100m }, limits: { memory: 512Mi, cpu: 500m } }
ui:
  enabled: true
  serviceType: ClusterIP
  externalPort: 8200
  targetPort: 8200
injector:
  enabled: false
```

> **Vault 1.16+ breaking change:** `unauthenticated_metrics_access` must be in the `listener.telemetry{}`
> block, not the top-level `telemetry{}` block. Without this, `/v1/sys/metrics` returns 403.
> `prometheus_retention_time = "24h"` stays in top-level `telemetry{}`.
> Metrics are scraped via ServiceMonitor (`manifests/vault/servicemonitor.yaml`), not pod annotations
> (kube-prometheus-stack only uses ServiceMonitor/PodMonitor CRDs).

### Vault Initialization Commands (🔒 safe terminal)

```bash
# Option 1: Via HTTPRoute (recommended — add VAULT_ADDR to .zshrc)
export VAULT_ADDR=https://vault.k8s.rommelporras.com

# Option 2: Via port-forward (fallback if HTTPRoute is down)
# kubectl --kubeconfig ~/.kube/homelab.yaml port-forward -n vault vault-0 8200:8200
# export VAULT_ADDR=http://localhost:8200

# Initialize — output contains 5 unseal keys + root token
vault operator init > ~/.vault-keys && chmod 600 ~/.vault-keys

# 🔒 Save to 1Password as break-glass
op item create --category=login --title="Vault Unseal Keys" --vault=Kubernetes \
  "unseal-key-1=$(grep 'Unseal Key 1' ~/.vault-keys | awk '{print $NF}')" \
  "unseal-key-2=$(grep 'Unseal Key 2' ~/.vault-keys | awk '{print $NF}')" \
  "unseal-key-3=$(grep 'Unseal Key 3' ~/.vault-keys | awk '{print $NF}')" \
  "unseal-key-4=$(grep 'Unseal Key 4' ~/.vault-keys | awk '{print $NF}')" \
  "unseal-key-5=$(grep 'Unseal Key 5' ~/.vault-keys | awk '{print $NF}')" \
  "root-token=$(grep 'Initial Root Token' ~/.vault-keys | awk '{print $NF}')"

# Unseal vault-0 (need 3 of 5 keys — Shamir threshold)
vault operator unseal $(grep 'Unseal Key 1' ~/.vault-keys | awk '{print $NF}')
vault operator unseal $(grep 'Unseal Key 2' ~/.vault-keys | awk '{print $NF}')
vault operator unseal $(grep 'Unseal Key 3' ~/.vault-keys | awk '{print $NF}')
```

### Vault Configuration Commands (🔒 safe terminal, run after init)

Automated via `scripts/configure-vault.sh` — see Migration Automation section below.
The script enables KV v2, Kubernetes auth, ESO policy/role, file audit, and snapshot policy.

### Auto-unsealer K8s Secret (🔒 imperative — never commit values)

```bash
kubectl --kubeconfig ~/.kube/homelab.yaml create secret generic vault-unseal-keys \
  -n vault \
  --from-literal=key1="$(grep 'Unseal Key 1' ~/.vault-keys | awk '{print $NF}')" \
  --from-literal=key2="$(grep 'Unseal Key 2' ~/.vault-keys | awk '{print $NF}')" \
  --from-literal=key3="$(grep 'Unseal Key 3' ~/.vault-keys | awk '{print $NF}')"
```

Unsealer Deployment (`manifests/vault/unsealer.yaml`) loops every 30s, checks vault-0's
sealed status at `http://vault-0.vault-internal.vault.svc.cluster.local:8200`, and
runs `vault operator unseal $UNSEAL_KEY_{1,2,3}` if sealed. Uses `hashicorp/vault:1.21.2`
image so `vault` CLI is available.

Key security context for the unsealer pod:
```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 65534
  runAsGroup: 65534
  seccompProfile: { type: RuntimeDefault }
containers:
  - name: unsealer
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities: { drop: ["ALL"] }
    env:
      - name: UNSEAL_KEY_1
        valueFrom: { secretKeyRef: { name: vault-unseal-keys, key: key1 } }
      - name: UNSEAL_KEY_2
        valueFrom: { secretKeyRef: { name: vault-unseal-keys, key: key2 } }
      - name: UNSEAL_KEY_3
        valueFrom: { secretKeyRef: { name: vault-unseal-keys, key: key3 } }
```

### Seed Script Design (`scripts/seed-vault-from-1password.sh`)

Claude generates this script. The user runs it in the safe terminal. It:
1. Reads values from 1Password using `op read 'op://...'`
2. Writes them to Vault using `vault kv put secret/<path>`
3. Verifies each write succeeded

```bash
#!/usr/bin/env bash
# 🔒 Run in safe terminal only — requires op + vault CLI
# Seeds ALL Vault KV paths from 1Password source of truth
set -euo pipefail

export VAULT_ADDR=http://localhost:8200

echo "=== Seeding Vault from 1Password ==="
echo "Ensure you have: eval \$(op signin) && vault login"

# cert-manager
vault kv put secret/cert-manager/cloudflare-api-token \
  api-token="$(op read 'op://Kubernetes/Cloudflare DNS API Token/credential')"

# cloudflare
vault kv put secret/cloudflare/cloudflared-token \
  token="$(op read 'op://Kubernetes/Cloudflare Tunnel/token')"

# arr-stack
vault kv put secret/arr-stack/api-keys \
  PROWLARR_API_KEY="$(op read 'op://Kubernetes/ARR Stack/prowlarr-api-key')" \
  SONARR_API_KEY="$(op read 'op://Kubernetes/ARR Stack/sonarr-api-key')" \
  RADARR_API_KEY="$(op read 'op://Kubernetes/ARR Stack/radarr-api-key')" \
  BAZARR_API_KEY="$(op read 'op://Kubernetes/ARR Stack/bazarr-api-key')" \
  TDARR_API_KEY="$(op read 'op://Kubernetes/ARR Stack/tdarr-api-key')"

vault kv put secret/arr-stack/qbittorrent \
  QBITTORRENT_PASS="$(op read 'op://Kubernetes/ARR Stack/password')"

# atuin (Vault field names must match K8s Secret key names — NOT 1Password field names)
vault kv put secret/atuin/secrets \
  POSTGRES_USER="$(op read 'op://Kubernetes/Atuin/db-username')" \
  POSTGRES_PASSWORD="$(op read 'op://Kubernetes/Atuin/db-password')" \
  POSTGRES_DB="$(op read 'op://Kubernetes/Atuin/db-database')" \
  ATUIN_DB_URI="$(op read 'op://Kubernetes/Atuin/db-uri')"

# browser
vault kv put secret/browser/firefox-auth \
  username="$(op read 'op://Kubernetes/Firefox Browser/username')" \
  password="$(op read 'op://Kubernetes/Firefox Browser/password')"

# ghost-dev
vault kv put secret/ghost-dev/mysql \
  root-password="$(op read 'op://Kubernetes/Ghost Dev MySQL/root-password')" \
  user-password="$(op read 'op://Kubernetes/Ghost Dev MySQL/user-password')"

vault kv put secret/ghost-dev/mail \
  smtp-host="smtp.mail.me.com" \
  smtp-user="$(op read 'op://Kubernetes/iCloud SMTP/username')" \
  smtp-password="$(op read 'op://Kubernetes/iCloud SMTP/password')" \
  from-address="noreply@rommelporras.com"

# ghost-prod
vault kv put secret/ghost-prod/mysql \
  root-password="$(op read 'op://Kubernetes/Ghost Prod MySQL/root-password')" \
  user-password="$(op read 'op://Kubernetes/Ghost Prod MySQL/user-password')"

vault kv put secret/ghost-prod/mail \
  smtp-host="smtp.mail.me.com" \
  smtp-user="$(op read 'op://Kubernetes/iCloud SMTP/username')" \
  smtp-password="$(op read 'op://Kubernetes/iCloud SMTP/password')" \
  from-address="noreply@rommelporras.com"

vault kv put secret/ghost-prod/tinybird \
  api-url="$(op read 'op://Kubernetes/Ghost Tinybird/api-url')" \
  admin-token="$(op read 'op://Kubernetes/Ghost Tinybird/admin-token')" \
  workspace-id="$(op read 'op://Kubernetes/Ghost Tinybird/workspace-id')" \
  tracker-token="$(op read 'op://Kubernetes/Ghost Tinybird/tracker-token')"

# gitlab
vault kv put secret/gitlab/root-password \
  password="$(op read 'op://Kubernetes/GitLab/password')"

vault kv put secret/gitlab/postgresql-password \
  postgresql-password="$(op read 'op://Kubernetes/GitLab/postgresql-password')" \
  postgresql-postgres-password="$(op read 'op://Kubernetes/GitLab/postgresql-postgres-password')"

# gitlab-runner (runner-token is in the "GitLab" 1P item, not a separate "GitLab Runner" item)
vault kv put secret/gitlab/smtp-password \
  password="$(op read 'op://Kubernetes/iCloud SMTP/password')"

vault kv put secret/gitlab-runner/runner-token \
  runner-token="$(op read 'op://Kubernetes/GitLab/runner-token')"

# homepage (31 fields — widget credentials from Homepage + ARR Stack + Karakeep 1P items)
vault kv put secret/homepage/secrets \
  HOMEPAGE_VAR_ADGUARD_FW_PASS="$(op read 'op://Kubernetes/Homepage/adguard-fw-pass')" \
  HOMEPAGE_VAR_ADGUARD_FW_USER="$(op read 'op://Kubernetes/Homepage/adguard-fw-user')" \
  HOMEPAGE_VAR_ADGUARD_PASS="$(op read 'op://Kubernetes/Homepage/adguard-pass')" \
  HOMEPAGE_VAR_ADGUARD_USER="$(op read 'op://Kubernetes/Homepage/adguard-user')" \
  HOMEPAGE_VAR_BAZARR_API_KEY="$(op read 'op://Kubernetes/ARR Stack/bazarr-api-key')" \
  HOMEPAGE_VAR_GLANCES_PASS="$(op read 'op://Kubernetes/Homepage/glances-pass')" \
  HOMEPAGE_VAR_GLANCES_USER="glances" \
  HOMEPAGE_VAR_GRAFANA_PASS="$(op read 'op://Kubernetes/Homepage/grafana-pass')" \
  HOMEPAGE_VAR_GRAFANA_USER="$(op read 'op://Kubernetes/Homepage/grafana-user')" \
  HOMEPAGE_VAR_IMMICH_KEY="$(op read 'op://Kubernetes/Homepage/immich-key')" \
  HOMEPAGE_VAR_JELLYFIN_KEY="$(op read 'op://Kubernetes/ARR Stack/jellyfin-api-key')" \
  HOMEPAGE_VAR_KARAKEEP_KEY="$(op read 'op://Kubernetes/Karakeep/api-key')" \
  HOMEPAGE_VAR_OMV_PASS="$(op read 'op://Kubernetes/Homepage/omv-pass')" \
  HOMEPAGE_VAR_OMV_USER="$(op read 'op://Kubernetes/Homepage/omv-user')" \
  HOMEPAGE_VAR_OPENWRT_PASS="$(op read 'op://Kubernetes/Homepage/openwrt-pass')" \
  HOMEPAGE_VAR_OPENWRT_USER="$(op read 'op://Kubernetes/Homepage/openwrt-user')" \
  HOMEPAGE_VAR_OPNSENSE_KEY="$(op read 'op://Kubernetes/Homepage/opnsense-username')" \
  HOMEPAGE_VAR_OPNSENSE_SECRET="$(op read 'op://Kubernetes/Homepage/opnsense-password')" \
  HOMEPAGE_VAR_PROWLARR_API_KEY="$(op read 'op://Kubernetes/ARR Stack/prowlarr-api-key')" \
  HOMEPAGE_VAR_PROXMOX_FW_TOKEN="$(op read 'op://Kubernetes/Homepage/proxmox-fw-token')" \
  HOMEPAGE_VAR_PROXMOX_FW_USER="$(op read 'op://Kubernetes/Homepage/proxmox-fw-user')" \
  HOMEPAGE_VAR_PROXMOX_PVE_TOKEN="$(op read 'op://Kubernetes/Homepage/proxmox-pve-token')" \
  HOMEPAGE_VAR_PROXMOX_PVE_USER="$(op read 'op://Kubernetes/Homepage/proxmox-pve-user')" \
  HOMEPAGE_VAR_QBIT_PASS="$(op read 'op://Kubernetes/ARR Stack/password')" \
  HOMEPAGE_VAR_QBIT_USER="$(op read 'op://Kubernetes/ARR Stack/username')" \
  HOMEPAGE_VAR_RADARR_API_KEY="$(op read 'op://Kubernetes/ARR Stack/radarr-api-key')" \
  HOMEPAGE_VAR_SEERR_API_KEY="$(op read 'op://Kubernetes/Homepage/seerr-api-key')" \
  HOMEPAGE_VAR_SONARR_API_KEY="$(op read 'op://Kubernetes/ARR Stack/sonarr-api-key')" \
  HOMEPAGE_VAR_TAILSCALE_DEVICE="$(op read 'op://Kubernetes/Homepage/tailscale-device')" \
  HOMEPAGE_VAR_TAILSCALE_KEY="$(op read 'op://Kubernetes/Homepage/tailscale-key')" \
  HOMEPAGE_VAR_WEATHER_KEY="$(op read 'op://Kubernetes/Homepage/weather-key')"

# invoicetron-dev
vault kv put secret/invoicetron-dev/db \
  postgres-password="$(op read 'op://Kubernetes/Invoicetron Dev/postgres-password')"

vault kv put secret/invoicetron-dev/app \
  database-url="$(op read 'op://Kubernetes/Invoicetron Dev/database-url')" \
  better-auth-secret="$(op read 'op://Kubernetes/Invoicetron Dev/better-auth-secret')"

# invoicetron-prod
vault kv put secret/invoicetron-prod/db \
  postgres-password="$(op read 'op://Kubernetes/Invoicetron Prod/postgres-password')"

vault kv put secret/invoicetron-prod/app \
  database-url="$(op read 'op://Kubernetes/Invoicetron Prod/database-url')" \
  better-auth-secret="$(op read 'op://Kubernetes/Invoicetron Prod/better-auth-secret')"

# karakeep
vault kv put secret/karakeep/secrets \
  nextauth-secret="$(op read 'op://Kubernetes/Karakeep/nextauth-secret')" \
  meili-master-key="$(op read 'op://Kubernetes/Karakeep/meili-master-key')"

# kube-system (cluster janitor)
vault kv put secret/kube-system/discord-janitor-webhook \
  webhook-url="$(op read 'op://Kubernetes/Discord Webhooks/janitor')"

# monitoring
vault kv put secret/monitoring/discord-version-webhook \
  webhook-url="$(op read 'op://Kubernetes/Discord Webhooks/versions')"

vault kv put secret/monitoring/nut-credentials \
  username="upsmon" \
  password="$(op read 'op://Kubernetes/NUT Monitor/password')"

vault kv put secret/monitoring/grafana \
  password="$(op read 'op://Kubernetes/Grafana/password')"

vault kv put secret/monitoring/healthchecks \
  ping-url="$(op read 'op://Kubernetes/Healthchecks Ping URL/website')"

vault kv put secret/monitoring/smtp \
  username="$(op read 'op://Kubernetes/iCloud SMTP/username')" \
  password="$(op read 'op://Kubernetes/iCloud SMTP/password')"

# monitoring/discord-webhooks (Alertmanager channels)
vault kv put secret/monitoring/discord-webhooks \
  incidents="$(op read 'op://Kubernetes/Discord Webhooks/incidents')" \
  apps="$(op read 'op://Kubernetes/Discord Webhooks/apps')" \
  infra="$(op read 'op://Kubernetes/Discord Webhooks/infra')" \
  versions="$(op read 'op://Kubernetes/Discord Webhooks/versions')" \
  speedtest="$(op read 'op://Kubernetes/Discord Webhooks/speedtest')"

# invoicetron deploy token (gitlab-registry imagePullSecret — shared by both namespaces)
vault kv put secret/invoicetron/deploy-token \
  username="$(op read 'op://Kubernetes/Invoicetron Deploy Token/username')" \
  password="$(op read 'op://Kubernetes/Invoicetron Deploy Token/password')"

echo ""
echo "=== Verification ==="
vault kv list secret/
echo ""
echo "Seed complete. Verify paths above match expected structure."
```

### Raft Snapshot CronJob

`manifests/vault/snapshot-cronjob.yaml` — daily at 02:00 Asia/Manila, writes to NFS NAS.

Key design:
- Runs `vault login` using Kubernetes auth (ServiceAccount `vault-snapshot` in vault namespace)
- Saves snapshot to `/snapshots/vault-$(date +%Y%m%d).snap` (NFS PV mounted at `/snapshots`)
- Deletes snapshots older than 15 days
- Retention: ~15 files maximum

Requires:
- `ServiceAccount` in vault namespace (no K8s RBAC needed — Vault policy handles authorization)
- Vault `snapshot-policy` + role binding (configured in Task 4.29.5 above)
- NFS PV + PVC pointing to `10.10.30.4:/Kubernetes/Backups/vault`

### ClusterSecretStore (`manifests/vault/clustersecretstore.yaml`)

```yaml
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: vault-backend
spec:
  provider:
    vault:
      server: "http://vault.vault.svc.cluster.local:8200"
      path: "secret"
      version: "v2"
      auth:
        kubernetes:
          mountPath: "kubernetes"
          role: "eso"
          serviceAccountRef:
            name: external-secrets
            namespace: external-secrets
```

### ExternalSecret Patterns

**All ExternalSecrets use `apiVersion: external-secrets.io/v1` (stable, unchanged in ESO 2.x)**

**Single field:**
```yaml
spec:
  data:
    - secretKey: token          # K8s Secret key
      remoteRef:
        key: cloudflare/cloudflared-token   # Vault path (no "secret/" prefix)
        property: token         # Vault field name
```

**All fields from a path (use for secrets with many fields):**
```yaml
spec:
  dataFrom:
    - extract:
        key: homepage/secrets   # pulls ALL fields as K8s Secret keys
```

Use `dataFrom.extract` for homepage (31 fields), karakeep, atuin — where all Vault fields
map 1:1 to K8s Secret keys.
Use `data` with explicit field mapping for cloudflare, arr-stack, cert-manager, browser,
monitoring, kube-system, gitlab, gitlab-runner, invoicetron, and ghost — where field naming
needs control or multiple K8s Secrets are created from separate Vault paths.

> **Atuin note:** Vault field names must match K8s Secret key names exactly (`POSTGRES_USER`,
> `POSTGRES_PASSWORD`, `POSTGRES_DB`, `ATUIN_DB_URI`) because `dataFrom.extract` maps Vault
> field names 1:1 to K8s Secret keys. The 1Password field names differ (e.g., `db-username`)
> so the seed script translates them.

### Migration Sequence (per namespace)

```bash
# 1. Apply ExternalSecret (creates new K8s Secret from Vault)
kubectl --kubeconfig ~/.kube/homelab.yaml apply -f manifests/<ns>/externalsecret.yaml

# 2. Verify synced — MUST succeed before proceeding
kubectl --kubeconfig ~/.kube/homelab.yaml get externalsecrets -n <ns>
# Expected: STATUS=SecretSynced, READY=True

# 3. Verify app still works (check pods, logs, endpoints)
kubectl --kubeconfig ~/.kube/homelab.yaml get pods -n <ns>

# 4. ONLY AFTER verification: remove old placeholder
git rm manifests/<ns>/secret.yaml
git add manifests/<ns>/externalsecret.yaml
```

> **Important:** Never delete the old secret.yaml before confirming the ExternalSecret
> created a working K8s Secret. The old secret is your rollback path.
>
> **cert-manager, monitoring, browser, kube-system notes:** No existing `secret.yaml` to delete
> for some of these. Just add the new `externalsecret.yaml` and confirm the app picks up the
> ESO-created secret.

### Migration Automation (`scripts/verify-migration.sh`)

Claude generates this script. It runs after each migration wave to verify all ExternalSecrets
synced and all pods are still healthy. No secrets involved — safe for Claude to run directly.

```bash
#!/usr/bin/env bash
# Verifies ExternalSecret sync status and pod health across all namespaces
# Run after each migration wave to catch sync failures before proceeding
set -euo pipefail

KUBECONFIG=~/.kube/homelab.yaml
KUBECTL="kubectl --kubeconfig $KUBECONFIG"
FAILURES=0

echo "=== ExternalSecret Sync Status ==="
while IFS= read -r line; do
  ns=$(echo "$line" | awk '{print $1}')
  name=$(echo "$line" | awk '{print $2}')
  ready=$(echo "$line" | awk '{print $3}')
  status=$(echo "$line" | awk '{print $4}')

  if [[ "$ready" != "True" || "$status" != "SecretSynced" ]]; then
    echo "FAIL: $ns/$name — Ready=$ready Status=$status"
    FAILURES=$((FAILURES + 1))
  else
    echo "  OK: $ns/$name"
  fi
done <<< "$($KUBECTL get externalsecrets -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,READY:.status.conditions[0].status,STATUS:.status.conditions[0].reason' --no-headers 2>/dev/null)"

echo ""
echo "=== ClusterSecretStore Status ==="
$KUBECTL get clustersecretstores -o custom-columns='NAME:.metadata.name,READY:.status.conditions[0].status,MSG:.status.conditions[0].message'

echo ""
echo "=== Pod Health (non-Running pods) ==="
NOT_RUNNING=$($KUBECTL get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded --no-headers 2>/dev/null | grep -v Completed || true)
if [[ -n "$NOT_RUNNING" ]]; then
  echo "$NOT_RUNNING"
  FAILURES=$((FAILURES + $(echo "$NOT_RUNNING" | wc -l)))
else
  echo "  All pods Running or Completed"
fi

echo ""
echo "=== Vault Status ==="
$KUBECTL get pods -n vault -o wide
$KUBECTL exec -n vault vault-0 -- vault status -format=json 2>/dev/null | \
  jq '{sealed: .sealed, initialized: .initialized, version: .version}' || \
  echo "WARN: Could not query vault status (may need port-forward)"

echo ""
if [[ $FAILURES -gt 0 ]]; then
  echo "RESULT: $FAILURES failure(s) detected — investigate before proceeding"
  exit 1
else
  echo "RESULT: All checks passed"
fi
```

### Vault Configuration Script (`scripts/configure-vault.sh`)

Non-secret Vault configuration (KV engine, K8s auth, policies) can be scripted.
This runs via port-forward after init+unseal. The only secret-touching part is `vault login`.

```bash
#!/usr/bin/env bash
# 🔒 Run in safe terminal — requires vault CLI + port-forward to vault-0:8200
# Configures Vault after initialization: KV v2, K8s auth, policies, audit
set -euo pipefail

export VAULT_ADDR=http://localhost:8200

# Login (🔒 reads root token from local file)
vault login $(grep 'Initial Root Token' ~/.vault-keys | awk '{print $NF}')

echo "=== Enabling KV v2 ==="
vault secrets enable -path=secret kv-v2

echo "=== Enabling Kubernetes auth ==="
vault auth enable kubernetes
vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc.cluster.local"

echo "=== Creating ESO policy ==="
vault policy write eso-policy - <<'EOF'
path "secret/data/*" { capabilities = ["read"] }
path "secret/metadata/*" { capabilities = ["read", "list"] }
EOF

echo "=== Creating ESO role ==="
vault write auth/kubernetes/role/eso \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=eso-policy \
  ttl=24h

echo "=== Enabling audit (file → stdout) ==="
vault audit enable file file_path=stdout

echo "=== Creating snapshot policy ==="
vault policy write snapshot-policy - <<'EOF'
path "sys/storage/raft/snapshot" { capabilities = ["read"] }
EOF

vault write auth/kubernetes/role/vault-snapshot \
  bound_service_account_names=vault-snapshot \
  bound_service_account_namespaces=vault \
  policies=snapshot-policy \
  ttl=1h

echo ""
echo "=== Verification ==="
vault secrets list
vault auth list
vault policy list
vault audit list
echo ""
echo "Vault configuration complete. Next: run seed-vault-from-1password.sh"
```

### ESO Helm Values Summary (`helm/external-secrets/values.yaml`)

```yaml
installCRDs: true
serviceMonitor:
  enabled: true          # Enables Prometheus scraping of ESO metrics
  interval: 30s
  namespace: monitoring
webhook:
  create: true
certController:
  create: true
```

> **`serviceMonitor.enabled: true`** is critical — without it, ESO metrics
> (`externalsecret_sync_calls_total`, `externalsecret_status_condition`, etc.)
> are not scraped and the ESOSyncFailed/ESOSecretNotSynced alerts will never fire.

### Observability Reference

#### Vault Metrics (key metrics from `/v1/sys/metrics`)

| Metric | Type | What it tells you |
|--------|------|-------------------|
| `vault_core_unsealed` | Gauge | `1` = unsealed, `0` = sealed. **Disappears entirely** when sealed too long — must use `absent()` |
| `vault_core_active` | Gauge | `1` = active leader (always 1 for standalone) |
| `vault_audit_log_request_failure` | Counter | Audit failures — compliance risk, means events are not being logged |
| `vault_core_handle_request` | Summary | Request handling latency (with quantile labels) |
| `vault_raft_commitTime` | Histogram | Raft write commit latency |
| `vault_raft_apply` | Counter | Raft apply ops — write load indicator |
| `vault_expire_num_leases` | Gauge | Active lease count — leak detection |

> **Gotcha:** `unauthenticated_metrics_access = true` must be in the telemetry HCL block.
> Without it, Prometheus gets HTTP 403 and no metrics are scraped. The pod annotations
> (`prometheus.io/scrape: "true"`) only tell Prometheus where to scrape — they don't
> handle authentication.

> **Gotcha:** `prometheus_retention_time = "24h"` (not `"30s"`). Vault only exposes
> metrics that were recorded within this window. At `30s`, metrics expire before
> Prometheus's 15-30s scrape interval can collect them.

#### ESO Metrics (from `/metrics` via ServiceMonitor)

| Metric | Type | What it tells you |
|--------|------|-------------------|
| `externalsecret_sync_calls_total` | Counter | Total sync attempts (labels: name, namespace) |
| `externalsecret_sync_calls_error` | Counter | Failed sync attempts |
| `externalsecret_status_condition` | Gauge | `1` = condition met. Labels: `condition` (SecretSynced), `status` (True/False) |
| `externalsecret_reconcile_duration` | Gauge | Time taken for reconciliation |
| `controller_runtime_reconcile_total` | Counter | Controller reconciliation count (label: `result=error` for failures) |
| `controller_runtime_reconcile_errors_total` | Counter | Total reconciliation errors |

#### PrometheusRule Alerts (`manifests/monitoring/alerts/vault-alerts.yaml`)

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: vault-alerts
  namespace: monitoring
  labels:
    release: prometheus
    app.kubernetes.io/part-of: kube-prometheus-stack
spec:
  groups:
    - name: vault
      rules:
        # CRITICAL: Vault is sealed — all ESO syncs will fail, no new secrets
        - alert: VaultSealed
          expr: |
            vault_core_unsealed == 0
            or
            (
              absent(vault_core_unsealed{job="vault"})
              and
              probe_success{job="vault"} == 0
            )
          for: 2m
          labels:
            severity: critical
          annotations:
            summary: "Vault is sealed — ExternalSecrets cannot sync"
            description: "vault-0 has been sealed for >2m. Unsealer should auto-recover within 30s. If this alert fires, unsealer may be broken."
            runbook: |
              1. Check unsealer pod: kubectl-homelab get pods -n vault -l app=vault-unsealer
              2. Check unsealer logs: kubectl-homelab logs -n vault -l app=vault-unsealer --tail=50
              3. Check vault seal status: kubectl-homelab exec -n vault vault-0 -- vault status
              4. If unsealer is CrashLooping: check vault-unseal-keys secret exists
              5. Manual unseal (break-glass): get keys from 1Password "Vault Unseal Keys"

        # WARNING: Vault metrics not being scraped (alerting degraded)
        - alert: VaultMetricsMissing
          expr: absent(vault_core_unsealed{job="vault"}) and probe_success{job="vault"} == 1
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: "Vault metrics not being scraped — alerting is degraded"

        # CRITICAL: Vault audit log is failing — compliance violation
        - alert: VaultAuditFailure
          expr: increase(vault_audit_log_request_failure[5m]) > 0
          for: 1m
          labels:
            severity: critical
          annotations:
            summary: "Vault audit logging is failing"
            description: "Vault audit device has logged failures. All Vault operations should be audited — this is a compliance risk."
            runbook: |
              1. Check audit devices: kubectl-homelab exec -n vault vault-0 -- vault audit list
              2. Check pod logs for audit errors: kubectl-homelab logs -n vault vault-0 --tail=100 | grep audit
              3. Re-enable if needed: vault audit enable file file_path=stdout

        # WARNING: Vault UI/API is unreachable via Blackbox probe
        - alert: VaultDown
          expr: probe_success{job="vault"} == 0
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Vault is unreachable"
            description: "Blackbox probe to Vault UI has been failing for >5m. ESO may lose connectivity."
            runbook: |
              1. Check vault pod: kubectl-homelab get pods -n vault
              2. Check vault logs: kubectl-homelab logs -n vault vault-0 --tail=50
              3. Check HTTPRoute: kubectl-homelab get httproute -n vault
              4. Try port-forward: kubectl-homelab port-forward -n vault vault-0 8200:8200

        # WARNING: Vault request latency is high
        - alert: VaultHighLatency
          expr: vault_core_handle_request{quantile="0.5"} > 500
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "Vault median request latency >500ms"
            description: "Vault is responding slowly. Check Raft storage health and pod resources."
            runbook: |
              1. Check pod resources: kubectl-homelab top pods -n vault
              2. Check Longhorn volume: kubectl-homelab get volumes.longhorn.io -n longhorn-system | grep vault
              3. Check Raft state: kubectl-homelab exec -n vault vault-0 -- vault operator raft list-peers

    - name: external-secrets
      rules:
        # CRITICAL: ExternalSecret is stuck in not-synced state
        - alert: ESOSecretNotSynced
          expr: externalsecret_status_condition{condition="SecretSynced", status="False"} == 1
          for: 10m
          labels:
            severity: critical
          annotations:
            summary: "ExternalSecret {{ $labels.namespace }}/{{ $labels.name }} not synced"
            description: "An ExternalSecret has been in SecretSynced=False state for >10m. The K8s Secret may be stale or missing."
            runbook: |
              1. Describe the ES: kubectl-homelab describe externalsecret {{ $labels.name }} -n {{ $labels.namespace }}
              2. Check ESO logs: kubectl-homelab logs -n external-secrets -l app.kubernetes.io/name=external-secrets --tail=50
              3. Verify ClusterSecretStore: kubectl-homelab get clustersecretstores
              4. Verify Vault is unsealed: kubectl-homelab exec -n vault vault-0 -- vault status
              5. Check if Vault path exists: vault kv get secret/{{ $labels.namespace }}/...

        # WARNING: ESO sync errors are occurring
        - alert: ESOSyncErrors
          expr: increase(externalsecret_sync_calls_error[15m]) > 0
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "ExternalSecret sync errors in {{ $labels.namespace }}/{{ $labels.name }}"
            description: "ESO is failing to sync secrets from Vault. May be transient (Vault restart) or permanent (missing path)."
            runbook: |
              1. Check ESO pod logs: kubectl-homelab logs -n external-secrets -l app.kubernetes.io/name=external-secrets --tail=100
              2. Check if Vault is sealed: kubectl-homelab exec -n vault vault-0 -- vault status
              3. Verify Vault KV path exists: vault kv get secret/<path>
              4. Force re-sync: kubectl-homelab annotate externalsecret <name> -n <ns> force-sync=$(date +%s) --overwrite

        # WARNING: Raft snapshot CronJob is failing
        - alert: VaultSnapshotFailing
          expr: kube_job_status_failed{namespace="vault", job_name=~"vault-snapshot.*"} > 0
          for: 30m
          labels:
            severity: warning
          annotations:
            summary: "Vault Raft snapshot CronJob is failing"
            description: "Daily Vault backup has been failing for >30m. NFS NAS may be unreachable."
            runbook: |
              1. Check CronJob: kubectl-homelab get cronjobs -n vault
              2. Check latest job: kubectl-homelab get jobs -n vault --sort-by=.metadata.creationTimestamp
              3. Check pod logs: kubectl-homelab logs -n vault -l job-name=vault-snapshot-<date>
              4. Check NFS mount: verify 10.10.30.4:/Kubernetes/Backups/vault is accessible
```

#### Blackbox Probe (`manifests/monitoring/probes/vault.yaml`)

```yaml
apiVersion: monitoring.coreos.com/v1
kind: Probe
metadata:
  name: vault
  namespace: monitoring
  labels:
    app: vault-probe
spec:
  jobName: vault
  interval: 60s
  module: http_2xx
  prober:
    url: blackbox-exporter-prometheus-blackbox-exporter.monitoring.svc:9115
  targets:
    staticConfig:
      static:
        - http://vault.vault.svc.cluster.local:8200/v1/sys/health
      labels:
        target_name: vault
```

> **Why `/v1/sys/health` instead of `/`?** The health endpoint returns 200 when
> unsealed+initialized, 429 when standby, 472 when DR secondary, 473 when perf standby,
> 501 when uninitialized, 503 when sealed. The `http_2xx` module catches sealed/uninitialized
> states as probe failures — giving us a Blackbox-level seal detection independent of Vault's
> own metrics endpoint.

#### Alertmanager Routing Update

Add `Vault.*|ESO.*` to the infra regex in `helm/prometheus/values.yaml`:

```yaml
# Before:
match_re:
  alertname: '(Longhorn.*|NVMe.*|etcd.*|KubeVip.*|Certificate.*|Node.*|UPS.*|NetworkInterface.*|KubePersistent.*|SmartCTL.*|KubeApiserver.*|CPUThrottling.*|Alloy.*|Loki.*|ClusterJanitor.*)'

# After:
match_re:
  alertname: '(Longhorn.*|NVMe.*|etcd.*|KubeVip.*|Certificate.*|Node.*|UPS.*|NetworkInterface.*|KubePersistent.*|SmartCTL.*|KubeApiserver.*|CPUThrottling.*|Alloy.*|Loki.*|ClusterJanitor.*|Vault.*|ESO.*)'
```

#### Grafana Dashboard Spec (`manifests/monitoring/dashboards/vault-dashboard.yaml`)

Follows project dashboard convention. ConfigMap with `grafana_dashboard: "1"` label.

**Row 1 — Pod Status:**
- Vault pod UP/DOWN stat panel (`kube_pod_status_ready{namespace="vault", pod=~"vault-.*"}`)
- Vault Unsealer UP/DOWN stat panel
- ESO controller UP/DOWN stat panel
- Vault seal status stat panel (`vault_core_unsealed`)
- Active leader indicator (`vault_core_active`)

**Row 2 — ExternalSecret Sync Status:**
- Total ExternalSecrets count (`count(externalsecret_status_condition{condition="SecretSynced"})`)
- Synced vs Not-Synced pie chart
- Sync error rate time series (`rate(externalsecret_sync_calls_error[5m])`)
- Last successful sync per ExternalSecret table

**Row 3 — Vault Storage & Performance:**
- Raft commit latency histogram (`vault_raft_commitTime`)
- Request handling latency p50/p99 (`vault_core_handle_request`)
- Active leases gauge (`vault_expire_num_leases`)
- Audit log failure rate (`rate(vault_audit_log_request_failure[5m])`)

**Row 4 — Resource Usage:**
- CPU usage with request/limit dashed lines (vault-0 + unsealer)
- Memory usage with request/limit dashed lines
- Longhorn volume used/capacity for vault PVC

**Row 5 — Backup Status:**
- Snapshot CronJob last success time (`kube_job_status_completion_time{namespace="vault"}`)
- Snapshot CronJob success/failure history
