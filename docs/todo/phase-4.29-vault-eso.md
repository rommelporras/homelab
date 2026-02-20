# Phase 4.29: Vault + External Secrets Operator

> **Status:** ⬜ Planned
> **Target:** v0.28.0
> **Prerequisite:** Phase 4.28 complete (Alerting & Observability)
> **Priority:** High (replaces all imperative `kubectl create secret` workflows before hardening)
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
1Password (cloud backup — manual sync when values rotate)
      ↕
Vault 3-pod HA (vault namespace, Raft on Longhorn 5Gi per pod)
      ↑
ESO ClusterSecretStore — kubernetes auth (ESO ServiceAccount → Vault validates with K8s API)
      ↑
ExternalSecret CRDs (committed to git, per namespace, zero secret values)
      ↓ synced every 1h
K8s Secrets (created and kept in sync automatically)
      ↓
Application pods (unchanged — still consume standard K8s Secrets)
```

**Unseal strategy:**
- Auto-unseal via a separate `vault-unsealer` Deployment that polls Vault every 30s
- Unsealer reads 3 unseal keys from `vault-unseal-keys` K8s Secret (created imperatively once)
- If any of the 3 Vault pods restarts, unsealer detects sealed state and unseals within 30s
- Unseal keys + root token also stored in 1Password ("Vault Unseal Keys") as break-glass

**Future path:** Replace init-container unseal with AWS KMS auto-unseal when applying this pattern
to the AWS/EKS job. Same architecture, zero app changes.

---

## New Files

| File | Purpose |
|------|---------|
| `manifests/vault/namespace.yaml` | vault namespace with PSS labels |
| `manifests/vault/unsealer.yaml` | Auto-unsealer Deployment |
| `manifests/vault/unseal-keys-secret.yaml` | Placeholder (created imperatively) |
| `manifests/vault/clustersecretstore.yaml` | ClusterSecretStore → Vault backend |
| `manifests/vault/httproute.yaml` | Vault UI at vault.k8s.rommelporras.com |
| `helm/vault/values.yaml` | HashiCorp Vault Helm values (3-pod HA, Raft) |
| `helm/external-secrets/values.yaml` | ESO Helm values |
| `manifests/arr-stack/externalsecret.yaml` | Replaces arr-api-keys-secret.yaml |
| `manifests/cloudflare/externalsecret.yaml` | Replaces cloudflare/secret.yaml |
| `manifests/home/homepage/externalsecret.yaml` | Replaces homepage/secret.yaml |
| `manifests/karakeep/externalsecret.yaml` | Replaces karakeep/secret.yaml |
| `manifests/invoicetron/externalsecret.yaml` | Replaces invoicetron/secret.yaml |
| `manifests/ghost-prod/externalsecret.yaml` | Replaces ghost-prod/secret.yaml |
| `manifests/ghost-dev/externalsecret.yaml` | Replaces ghost-dev/secret.yaml |

## Deleted Files

| File | Reason |
|------|--------|
| `manifests/arr-stack/arr-api-keys-secret.yaml` | Replaced by externalsecret.yaml |
| `manifests/cloudflare/secret.yaml` | Replaced by externalsecret.yaml |
| `manifests/home/homepage/secret.yaml` | Replaced by externalsecret.yaml |
| `manifests/karakeep/secret.yaml` | Replaced by externalsecret.yaml |
| `manifests/invoicetron/secret.yaml` | Replaced by externalsecret.yaml |
| `manifests/ghost-prod/secret.yaml` | Replaced by externalsecret.yaml |
| `manifests/ghost-dev/secret.yaml` | Replaced by externalsecret.yaml |
| `scripts/apply-arr-secrets.sh` | Replaced by ExternalSecret CRD |

---

## Vault KV Structure

KV v2 engine at `secret/`. One path per logical secret group:

```
secret/
  cloudflare/
    cloudflared-token        → token
  ghost-prod/
    mysql                    → root-password, user-password
    mail                     → smtp-host, smtp-user, smtp-password, from-address
    tinybird                 → api-url, admin-token, workspace-id, tracker-token
  ghost-dev/
    mysql                    → root-password, user-password
    mail                     → smtp-host, smtp-user, smtp-password, from-address
  homepage/
    secrets                  → HOMEPAGE_VAR_* (17 fields)
  invoicetron-dev/
    db                       → postgres-password
    app                      → database-url, better-auth-secret
  invoicetron-prod/
    db                       → postgres-password
    app                      → database-url, better-auth-secret
  karakeep/
    secrets                  → nextauth-secret, meili-master-key
  arr-stack/
    api-keys                 → PROWLARR_API_KEY, SONARR_API_KEY, RADARR_API_KEY,
                               BAZARR_API_KEY, TDARR_API_KEY
    qbittorrent              → password
```

---

## Task List

### Phase 1: Vault Infrastructure

- [ ] **4.29.1** Create `manifests/vault/namespace.yaml` and `helm/vault/values.yaml`
- [ ] **4.29.2** Deploy Vault 3-pod HA via Helm (`hashicorp/vault` chart v0.29.1 / app v1.19.0)
- [ ] **4.29.3** Initialize Vault — save keys to `~/.vault-keys` + 1Password "Vault Unseal Keys"
- [ ] **4.29.4** Manually unseal all 3 pods (first time only — unsealer handles future restarts)
- [ ] **4.29.5** Configure Vault: enable KV v2, Kubernetes auth, ESO policy + role
- [ ] **4.29.6** Create auto-unsealer Deployment + `vault-unseal-keys` K8s Secret
- [ ] **4.29.7** Test auto-unseal: delete vault-0, confirm it recovers Ready within 60s
- [ ] **4.29.8** Expose Vault UI via HTTPRoute at `vault.k8s.rommelporras.com`

### Phase 2: External Secrets Operator

- [ ] **4.29.9** Deploy ESO via Helm (`external-secrets/external-secrets` chart v0.14.4)
- [ ] **4.29.10** Create `ClusterSecretStore` pointing to Vault with Kubernetes auth
- [ ] **4.29.11** Verify `ClusterSecretStore` status is `READY=True`

### Phase 3: Secret Migration

For each namespace: seed values into Vault UI → create ExternalSecret → apply → verify
`STATUS=SecretSynced` → delete old `secret.yaml` → commit.

- [ ] **4.29.12** Migrate `arr-stack` (arr-api-keys, qbittorrent-exporter-secret)
- [ ] **4.29.13** Migrate `cloudflare` (cloudflared-token)
- [ ] **4.29.14** Migrate `home` (homepage-secrets — 17 fields, use `dataFrom.extract`)
- [ ] **4.29.15** Migrate `karakeep` (karakeep-secrets)
- [ ] **4.29.16** Migrate `invoicetron-dev` + `invoicetron-prod` (db + app each)
- [ ] **4.29.17** Migrate `ghost-prod` + `ghost-dev` (mysql + mail + tinybird)
- [ ] **4.29.18** Delete `scripts/apply-arr-secrets.sh`

### Phase 4: Cleanup & Docs

- [ ] **4.29.19** Update `VERSIONS.md` with Vault v1.19.0 and ESO v0.14.4
- [ ] **4.29.20** Update `MEMORY.md` with Vault/ESO lessons learned
- [ ] **4.29.21** `/audit-security` → `/commit` → `/release v0.28.0`

---

## Verification Checklist

- [ ] `kubectl get pods -n vault` — 3 Vault pods + unsealer all Running/Ready
- [ ] `kubectl get pods -n external-secrets` — 3 ESO pods Running
- [ ] `kubectl get clustersecretstores` — `vault-backend` READY=True
- [ ] `kubectl get externalsecrets -A` — all SecretSynced, READY=True
- [ ] Delete vault-0 → auto-unseals within 60s without manual intervention
- [ ] `https://vault.k8s.rommelporras.com` loads Vault UI
- [ ] All apps still running after migration (`kubectl get pods -A`)
- [ ] No `secret.yaml` placeholder files remain (all replaced by `externalsecret.yaml`)
- [ ] `scripts/apply-arr-secrets.sh` deleted

---

## Secret Rotation Procedure (steady state)

1. Open `https://vault.k8s.rommelporras.com`
2. Navigate to secret path → update value
3. ESO syncs within 1h automatically (or trigger manual refresh via `kubectl annotate`)
4. Update same value in 1Password manually (cloud backup)

No `kubectl create secret`. No `op read`. No scripts.

---

## Implementation Plan

Full step-by-step plan with exact commands and file contents:
`docs/plans/2026-02-20-phase-4.29-vault-eso.md` (local only, gitignored)
