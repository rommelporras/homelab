# Phase 5.8.2: Version Maintenance - Image Upgrades

> **Status:** In Progress
> **Target:** v0.38.2
> **Fits:** Between v0.38.1 (current) and v0.39.0 (Phase 5.9 - Argo Workflows)
> **DevOps Topics:** Image patching, version-checker tuning, false positive suppression
> **Effort:** ~45 minutes

> **Purpose:** Clear the April 2026 VersionCheckerImageOutdated alert backlog and fix
> the noisy version-checker Discord setup. Most images are already updated in manifests -
> the running pods just haven't cycled yet. This phase fixes 2 remaining manifest gaps,
> suppresses persistent false positives, and fixes the duplicate Discord notifications.
>
> **Do this before Phase 5.9** - clean alert baseline before adding Argo Workflows.

---

## Background: The Two Discord Channels

The user sees version alerts in two channels because there are two separate systems:

| Channel | Source | Format | Last active |
|---------|--------|--------|-------------|
| `#versions` | `version-check` CronJob -> Prometheus API + Nova -> Discord | Nice weekly digest (Helm + images grouped) | 3/29/26 (stale - see below) |
| `#apps` | Alertmanager `VersionCheckerImageOutdated` -> `discord-versions` receiver -> Discord | One message per image per version gap (noisy) | Active |

**Root cause of duplication:** The `discord-versions` Alertmanager receiver
(`manifests/monitoring/externalsecret.yaml`) used `{{ .discordApps }}` - the same
webhook URL as `discord-apps`. So Alertmanager sent version alerts to `#apps`, and the
CronJob also sent its weekly digest to `#apps` (via `key: apps`). Both went to the same
webhook, cluttering `#apps` with two different formats.

**Root cause of `#versions` staleness (stopped at 3/29/26):** The version-check CronJob
ran on 4/5 (LAST SCHEDULE: 29h ago) but the 4/5 pod is gone - only the 8d-old (3/29)
successful pod is visible. The 4/5 run silently failed and cluster-janitor cleaned the
failed pod. There is no alert for CronJob failure (VersionCheckerDown only monitors the
*deployment*, not the CronJob).

**Fix approach:** Instead of silencing version alerts entirely (routing to null), we
re-route both systems to `#versions` via a dedicated `versions` webhook:
- Alertmanager `discord-versions` receiver -> `{{ .discordVersions }}` (was `{{ .discordApps }}`)
- CronJob `secretKeyRef.key: versions` (was `apps`)

This keeps visibility in a dedicated channel instead of going blind.

---

## What the April 2026 Alerts Actually Are

### Already Updated in Manifests (stale running pods - no action needed)

Alerts will clear once ArgoCD syncs and pods cycle.

| Image | Manifest version | Alert was showing |
|-------|-----------------|-------------------|
| hashicorp/vault | 1.21.4 | 1.21.2 -> 1.21.4 |
| cloudflare/cloudflared | 2026.3.0 | 2026.1.1 -> 2026.3.0 |
| louislam/uptime-kuma | 2.2.1-rootless | 2.0.2-rootless -> 2.2.1 |
| alpine/k8s | 1.35.3 (all CronJobs) | 1.35.0 -> 1.35.3 |
| intel-device-plugins-operator | 0.35.0 | 0.34.1 -> 0.35.0 |
| intel-device-plugins-gpu | 0.35.0 | 0.34.1 -> 0.35.0 |
| python | 3.14.3-alpine | 3.12-alpine |
| alpine | 3.23 | 3.21 |
| adguard/adguardhome | v0.107.73 | v0.107.71 |
| ghost | 6.22.1 | 6.14.0 |
| getmeili/meilisearch | v1.39.0 | v1.13.3 |
| cilium | ArgoCD app at 1.19.1 (manual sync) | v1.18.6 |
| longhorn | ArgoCD app at 1.11.1 (manual sync) | v1.10.1 |

### False Positives (wrong tag format comparison)

| Image | Running | "Latest" | Root cause | Fix |
|-------|---------|----------|-----------|-----|
| jellyfin/jellyfin | 10.11.6 | 2026030905 | Date nightly tag | match-regex already in manifest |
| grafana/grafana | 12.3.1 | 9799770991 | Build ID | match-regex in prometheus values, metric stale |
| cert-manager | v1.19.2 | 608111629 | Build ID | Alert rule excludes `quay.io/jetstack/cert-manager.*` |
| longhornio/longhorn-engine | v1.10.1 | 4408836 | Commit SHA | Cannot annotate (dynamic DaemonSet) - add to alert exclusion |
| postgres 18.3 (Atuin) | 18.3 | 18.3@new-sha | Digest rebuilt | Needs match-regex annotation |
| postgres 18.3-alpine (Invoicetron) | 18.3-alpine | 18.3 | Tag format | match-regex already in manifest |
| bitnamilegacy/redis | 7.2.4 -> 8.2.1 | Major version | Deferred |

### Deferred (major versions or Helm chart upgrades)

| Item | Current | Latest | Reason |
|------|---------|--------|--------|
| bitnamilegacy/postgresql | 16.6.0 | 17.6.0 | Major version: pg_upgrade required |
| bitnamilegacy/redis | 7.2.4 | 8.2.1 | Major version |
| mysql | 8.4.8 | 9.6.0 | Major version (ghost-prod DB!) |
| Helm chart drift | various | various | Separate Helm upgrade phase |
| kube-prometheus-stack | 82.13.1 | 82.15.1 | Helm chart (k8s-sidecar, alertmanager, etc.) |
| loki chart | 6.55.0 | ? | Helm chart |
| coredns | v1.13.1 | v1.14.1 | K8s-managed (kubeadm) |

---

## 5.8.2.1 Fix Version-Checker Discord Routing (commit 1 - push and verify)

> **Goal:** Route ALL version-related notifications to `#versions`. Stop cluttering
> `#apps`. Verify the pipeline works end-to-end before doing anything else.

### Gate: Vault secret must exist first

> **CRITICAL:** The `versions` property must exist in Vault at `monitoring/discord-webhooks`
> BEFORE pushing these changes. If it's missing, the `monitoring-discord-webhooks`
> ExternalSecret fails entirely (ESO doesn't partial-sync), which cascades to
> `alertmanager-config` failing to render `{{ .discordVersions }}`. Result: ALL Discord
> alerting breaks (incidents, infra, apps - everything).
>
> **Pre-flight check:**
> ```bash
> # Verify the versions key already exists in the synced secret:
> kubectl-admin get secret monitoring-discord-webhooks -n monitoring -o jsonpath='{.data}' | jq -r 'keys[]'
> # Expected output should include: apps, incidents, infra, versions
> # If "versions" is missing: seed it from 1Password to Vault first.
> ```
>
> **Rollback if broken:** Revert the ExternalSecret change (remove `versions` key and
> `discordVersions` template var), push, wait for ESO 1h refresh or restart ESO pod.

- [x] 5.8.2.1.1 Add `versions` key to the monitoring ExternalSecret
  ```yaml
  # manifests/monitoring/externalsecret.yaml - monitoring-discord-webhooks ExternalSecret
  # Added: secretKey: versions -> monitoring/discord-webhooks -> versions
  ```
  **Done** - already in working tree.

- [x] 5.8.2.1.2 Re-route Alertmanager `discord-versions` receiver to `#versions` webhook
  ```yaml
  # manifests/monitoring/externalsecret.yaml - alertmanager config template
  # Changed: discord-versions receiver webhook_url from {{ .discordApps }} to {{ .discordVersions }}
  # Added: discordVersions secret key mapping in alertmanager-config ESO data section
  # Route config: VersionCheckerImageOutdated -> discord-versions (group_by: alertname, 24h repeat)
  ```
  **Done** - already in working tree.

- [x] 5.8.2.1.3 Update version-check CronJob to use `versions` key
  ```yaml
  # manifests/monitoring/version-checker/version-check-cronjob.yaml
  # Changed: secretKeyRef.key from apps to versions
  ```
  **Done** - already in working tree.

- [ ] 5.8.2.1.4 Commit, push, and wait for ArgoCD sync
  ```bash
  # Commit only the version-checker routing files:
  # - manifests/monitoring/externalsecret.yaml
  # - manifests/monitoring/version-checker/version-check-cronjob.yaml
  # Push to main. ArgoCD auto-syncs monitoring-manifests within 3 minutes.
  # ESO refreshes alertmanager-config within 1h (or restart alertmanager pod to force).
  ```

- [ ] 5.8.2.1.5 Trigger manual CronJob run and verify `#versions`
  ```bash
  # Wait for ArgoCD sync to complete first:
  kubectl-homelab get applications -n argocd | grep monitoring

  # Trigger a manual run:
  kubectl-admin create job --from=cronjob/version-check version-check-test -n monitoring
  kubectl-admin wait --for=condition=complete job/version-check-test -n monitoring --timeout=120s
  kubectl-admin logs job/version-check-test -n monitoring

  # Check #versions Discord channel for the formatted embed.
  # Expected: Helm chart drift + image drift summary with Discord embed.
  # Verify #apps did NOT receive the same message.

  # Clean up:
  kubectl-admin delete job version-check-test -n monitoring
  ```

---

## 5.8.2.2 Image Bumps (commit 2)

> **Goal:** Apply the 2 remaining manifest image gaps. Both are stateless - no data loss risk.

- [x] 5.8.2.2.1 Bump ghost/traffic-analytics: 1.0.153 -> 1.0.164
  ```
  # File: manifests/ghost-prod/analytics-deployment.yaml
  ```
  **Done** - already in working tree.

- [x] 5.8.2.2.2 Bump esanchezm/prometheus-qbittorrent-exporter: sha-2fcca94 -> v1.6.0
  ```
  # File: manifests/arr-stack/qbittorrent/qbittorrent-exporter.yaml
  # Also added match-regex annotation: ^v\d+\.\d+\.\d+$ to filter SHA tags.
  ```
  **Done** - already in working tree.

---

## 5.8.2.3 False Positive Suppression (commit 2, same batch)

- [ ] 5.8.2.3.1 Add longhornio/longhorn-engine to PrometheusRule exclusion
  ```yaml
  # manifests/monitoring/alerts/version-checker-alerts.yaml
  # longhorn-engine is a DYNAMIC DaemonSet created by Longhorn's engine image upgrader.
  # There is no static manifest to annotate with match-regex. Phase 5.5 confirmed this.
  # Fix: add to the image exclusion regex in VersionCheckerImageOutdated alert rule:
  #   image!~"quay.io/jetstack/cert-manager.*|longhornio/longhorn-engine.*"
  ```

- [ ] 5.8.2.3.2 Add match-regex for Atuin postgres (digest rebuild false positives)
  ```yaml
  # manifests/atuin/postgres-deployment.yaml
  # Image: docker.io/library/postgres:18.3 (no annotations on pod template currently)
  # Add to pod template metadata.annotations:
  #   match-regex.version-checker.io/postgres: '^\d+\.\d+$'
  # Note: Invoicetron postgres (18.3-alpine) already has match-regex - no action needed.
  ```

---

## 5.8.2.4 Deferred Items

- [ ] 5.8.2.4.1 Add to docs/todo/deferred.md
  ```
  ## PostgreSQL 16 -> 17 Major Version Migration
  Running: bitnamilegacy/postgresql 16.6.0. Latest: 17.6.0
  Requires: pg_upgrade or dump/restore. Identify all affected StatefulSets first.
  grep -rn "bitnamilegacy/postgresql" manifests/ helm/ to find owners.

  ## MySQL 8 -> 9 Major Version Migration
  Running: mysql:8.4.8. Latest: 9.6.0. Affects ghost-prod (blog database).
  Requires: dump/restore. Plan separately with ghost-prod downtime window.

  ## Redis 7 -> 8 Major Version Migration
  Running: bitnamilegacy/redis 7.2.4. Latest: 8.2.1. Likely Helm-chart managed.
  Requires: compatibility check, possible data migration.

  ## Helm Chart Upgrades (monitoring stack)
  kube-prometheus-stack 82.13.1 -> 82.15.1 (includes k8s-sidecar, alertmanager, node-exporter)
  loki chart 6.55.0 -> latest
  These update bundled images (k8s-sidecar 2.5.0, loki 3.6.7, alloy v1.14.0) automatically.
  Plan as a single maintenance window - prometheus chart upgrades need Grafana RWO PVC care.
  ```

---

## Verification

```bash
# 1. version-check CronJob test job sends to #versions (not #apps)
# 2. #apps no longer receives VersionCheckerImageOutdated alerts (routed to #versions now)
# 3. Updated pods running new images
kubectl-homelab get pods -n ghost-prod | grep analytics   # 1.0.164
kubectl-homelab get pods -n arr-stack | grep qbittorrent  # v1.6.0

# 4. False positives suppressed
# - longhornio/longhorn-engine excluded from alert rule
# - Atuin postgres has match-regex annotation

# 5. ArgoCD all Synced/Healthy
kubectl-homelab get applications -n argocd
```

---

## Final: Commit and Release

- [ ] `/audit-security` then `/commit`
- [ ] `/audit-docs` then `/commit` (includes VERSIONS.md update for analytics + qbit-exporter)
- [ ] `/release v0.38.2 "Version Maintenance - Image Upgrades"`
- [ ] `mv docs/todo/phase-5.8.2-version-maintenance.md docs/todo/completed/`
