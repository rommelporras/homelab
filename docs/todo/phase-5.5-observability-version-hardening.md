# Phase 5.5: Observability & Version Hardening

> **Status:** Planned
> **Target:** v0.35.0
> **Prerequisite:** Phase 5.4 (v0.34.0 - resilience and backup in place)
> **DevOps Topics:** Prometheus metrics, Grafana dashboards, version management, upgrade planning
> **CKA Topics:** Monitoring, observability, cluster maintenance

> **Purpose:** Ensure every service is monitored and every image is at latest version before
> handing cluster management to a GitOps controller. ArgoCD should inherit a clean, observable cluster.
>
> **Why before Pre-GitOps Validation?** Phase 5.6 (was 5.5) validates security controls.
> This phase ensures you can SEE problems when they happen. Without complete observability,
> ArgoCD could deploy broken configs and you wouldn't know until users report it.

---

## Gap Analysis (2026-03-21 audit)

### Observability Gaps

**Dashboards:** 18/27 namespaces have NO Grafana dashboard.

| Priority | Namespace | Workloads | Dashboard |
|----------|-----------|-----------|-----------|
| Critical | gitlab | 11 (webservice, gitaly, postgres, redis, registry, kas, etc.) | NONE |
| Critical | cert-manager | 3 (controller, cainjector, webhook) | NONE |
| Critical | external-secrets | 3 (operator, webhook, cert-controller) | NONE |
| Critical | velero | 2 (velero, garage) | NONE |
| High | ghost-prod | 2 (ghost, mysql) | NONE |
| High | invoicetron-prod | 2 (app, db) | NONE |
| High | home | 3 (adguard, homepage, myspeed) | NONE |
| High | uptime-kuma | 1 | NONE |
| Medium | karakeep | 1 | NONE |
| Medium | ai | 1 (ollama) | NONE |
| Low | ghost-dev, portfolio-dev/staging, invoicetron-dev | dev/staging | NONE |
| Low | browser, cloudflare, gitlab-runner, intel-device-plugins, nfd | system/utility | NONE |

**Zero monitoring (no metrics, alerts, or probes):**
- browser/firefox, intel-device-plugins, node-feature-discovery, gitlab-runner
- GitLab itself (8 deploys + 3 statefulsets - entire instance unmonitored)

**8 databases with zero monitoring:**
- atuin/postgres, ghost-dev/ghost-mysql, ghost-prod/ghost-mysql
- invoicetron-dev/invoicetron-db, invoicetron-prod/invoicetron-db
- gitlab/postgresql, gitlab/redis-master, gitlab/gitaly

**Missing probes for infrastructure services:**
- cert-manager, velero, garage, external-secrets, longhorn-ui

### Alertmanager Routing Gap

New Phase 5.4 G alerts route to WRONG Discord channel:

| Alert | Severity | Expected Channel | Actual Channel |
|-------|----------|------------------|----------------|
| VeleroBackupFailed | critical | #incidents (correct) | #incidents (OK - severity match) |
| VeleroBackupStale | warning | #infra | **#apps** (wrong) |
| EtcdBackupStale | critical | #incidents (correct) | #incidents (OK - severity match) |
| ResourceQuotaNearLimit | warning | #infra | **#apps** (wrong) |
| CronJobFailed | warning | #infra | **#apps** (wrong) |
| CronJobNotScheduled | warning | #infra | **#apps** (wrong) |
| LonghornVolumeAllReplicasStopped | warning | #infra | #infra (OK - matches Longhorn.*) |
| PodStuckInInit | warning | #apps | #apps (OK) |
| PodStuckPending | warning | #apps | #apps (OK) |
| PodCrashLoopingExtended | critical | #incidents (correct) | #incidents (OK - severity match) |
| PodImagePullBackOff | warning | #apps | #apps (OK) |

**Fix:** Add `Velero.*|ResourceQuota.*|CronJob.*|Backup.*` to the infra route regex in
`helm/prometheus/values.yaml`.

### Version-Checker & Version-Check Gaps

**Problem 1: Two separate systems, neither complete.**
- `version-checker` (deployment) - monitors container IMAGE versions via registry tags.
  Exports Prometheus metrics. Alert: `ContainerImageOutdated` (7d threshold).
  No Discord notification. No release links. No patch/minor/major classification.
- `version-check` (weekly CronJob) - runs Nova for HELM CHART drift only.
  Sends Discord digest. Does NOT cover manifest-deployed images (majority of the cluster).

**Problem 2: False positives pollute the signal.**
- cert-manager: Quay returns build numbers ("608111629") instead of semver. Already excluded
  from alert via regex, but metric still shows as outdated.
- grafana: similar tag parsing issue ("9799770991").
- Only 4 deployments have `match-regex` annotations (bazarr, radarr, sonarr, firefox).
  The rest rely on default tag parsing which breaks for non-standard registries.

**Problem 3: Alert message is not actionable.**
- `ContainerImageOutdated` says "Running X, latest is Y" - but doesn't tell you:
  - Is this a patch, minor, or major bump?
  - Where are the release notes? (GitHub releases URL)
  - What's the upgrade method? (Helm upgrade? Edit manifest? kubeadm upgrade?)
  - Are there breaking changes?

**Problem 4: No unified upgrade digest.**
- Helm chart drift goes to Discord weekly (Nova).
- Container image drift only shows in Prometheus alerts (no Discord).
- No single place to see "here's everything that needs updating and how."

### Cluster Janitor Gaps

**Current tasks (2):**
1. Delete Failed pods
2. Delete stopped Longhorn replicas (safety: skip last replica)

**Missing cleanup tasks:**
- Evicted pods (status.reason=Evicted) - accumulate after node pressure events
- Completed Jobs past `ttlSecondsAfterFinished` that controllers haven't cleaned
- Old ReplicaSets with 0 replicas (Deployment rollout leftovers)

**Missing reporting:**
- No periodic health summary (resource usage trends, upcoming quota issues)
- Discord message is minimal ("cleaned X pods, Y replicas") - no context about what was cleaned

### No Backup Health Dashboard

Phase 5.4 G added 13 alert rules for backups, but there's no Grafana dashboard to visualize:
- Longhorn backup status (last success time, error count)
- Velero backup status (success/failure counters, schedule health)
- CronJob backup status (all backup CronJobs in one view)
- etcd backup age
- Off-site backup status (manual/WSL2 - may need a push metric)

### Existing Dashboard Quality

No audit of whether existing 41 dashboards follow conventions:
- Pod Status row -> Network Traffic row -> Resource Usage row
- Descriptions on every panel and row
- CPU/Memory with dashed request/limit lines
- ConfigMap: `grafana_dashboard: "1"` label, `grafana_folder: "Homelab"` annotation

### Version Gaps (2026-03-21 snapshot)

> NOTE: version-checker has tag parsing false positives (cert-manager, grafana report
> nonsense "latest" versions). Fix these first so the signal is clean.

| Category | Image | Current | Latest |
|----------|-------|---------|--------|
| CNI | Cilium | v1.18.6 | v1.19.1 |
| Storage | Longhorn | v1.10.1 | v1.11.1 |
| Monitoring | Prometheus | v3.9.1 | v3.10.0 |
| Monitoring | Alertmanager | v0.30.1 | v0.31.1 |
| Monitoring | Alloy | v1.12.2 | v1.14.1 |
| Monitoring | Loki | 3.6.3 | 3.6.7 |
| Secrets | Vault | 1.21.2 | 1.21.4 |
| DNS | CoreDNS | v1.13.1 | v1.14.2 |
| Apps | Ghost | 6.14.0 | 6.22.0 |
| Apps | Ollama | 0.15.6 | 0.18.2 |
| Apps | MeiliSearch | v1.13.3 | v1.39.0 |

---

## Execution Order

```
Phase A --- Version-Checker & Alertmanager Fixes
   |        A1: Fix Alertmanager routing for new backup/infra alerts
   |        A2: Fix version-checker false positives (match-regex annotations)
   |        A3: Enhance version-check Discord digest (add image drift, release links)
   |        A4: Improve ContainerImageOutdated alert annotations
   v
   GATE: version-checker signal clean, alerts route to correct channels
   v
Phase B --- Cluster Janitor & Operational Improvements
   |        B1: Add Evicted pod cleanup
   |        B2: Add old ReplicaSet cleanup
   |        B3: Improve Discord messages (context, links)
   |        B4: Create backup health Grafana dashboard
   v
Phase C --- Fill Monitoring Gaps
   |        C1: Missing ServiceMonitors + probes (infrastructure)
   |        C2: Database monitoring (postgres, mysql, redis)
   |        C3: Missing Grafana dashboards (critical/high priority)
   |        C4: Missing PrometheusRules for uncovered services
   |        C5: Audit existing dashboards for convention compliance
   v
   GATE: All production services have metrics + alerts + probes. Clean Grafana.
   v
Phase D --- Infrastructure Version Updates (careful order)
   |        D1: Vault (patch - low risk)
   |        D2: Loki (patch - low risk)
   |        D3: Prometheus stack (minor - medium risk)
   |        D4: Alloy (minor - medium risk)
   |        D5: Longhorn (minor - HIGH risk, storage layer)
   |        D6: Cilium (minor - HIGH risk, CNI)
   |        D7: CoreDNS (minor - medium risk, DNS)
   v
   GATE: Cluster healthy after infra upgrades. All alerts inactive.
   v
Phase E --- Application Version Updates
   |        Ghost, Ollama, MeiliSearch, etc.
   |        Lower risk - app-level, no cluster impact
   v
Phase F --- Documentation
   |        VERSIONS.md, CHANGELOG.md, Upgrades.md, Monitoring.md
   v
Done --- All services monitored, all images current, clean signal.
```

---

## 5.5.1 Version-Checker & Alertmanager Fixes (Phase A)

> **Why first?** If alerts route to the wrong channel, you miss critical notifications.
> If version-checker reports false positives, you can't trust the upgrade list.

### A1: Fix Alertmanager Routing

- [ ] 5.5.1.1 Update infra route regex in `helm/prometheus/values.yaml`
  Current regex misses: Velero, Backup, ResourceQuota, CronJob alerts.
  Add to the `match_re.alertname` pattern:
  ```
  |Velero.*|Backup.*|ResourceQuota.*|CronJob.*|Garage.*
  ```
  Full updated regex:
  ```
  (Longhorn.*|NVMe.*|etcd.*|KubeVip.*|Certificate.*|Node.*|UPS.*|NetworkInterface.*|KubePersistent.*|SmartCTL.*|KubeApiserver.*|CPUThrottling.*|Alloy.*|Loki.*|ClusterJanitor.*|Vault.*|ESO.*|Audit.*|Velero.*|Backup.*|ResourceQuota.*|CronJob.*|Garage.*)
  ```
  Run Prometheus stack Helm upgrade. Verify routing with `amtool` or Alertmanager UI.

### A2: Fix Version-Checker False Positives

- [ ] 5.5.1.2 Audit all images for tag parsing issues
  Query `version_checker_is_latest_version == 0` and identify which "latest" values are
  nonsense (build numbers, digests, timestamps instead of semver).

- [ ] 5.5.1.3 Add `match-regex` annotations to deployments with bad tag parsing
  Currently only 4 deployments have `match-regex.version-checker.io/CONTAINER`:
  bazarr, radarr, sonarr, firefox. Add for all images with non-standard tags.
  ```yaml
  # Example: cert-manager
  annotations:
    match-regex.version-checker.io/cert-manager-controller: "^v\\d+\\.\\d+\\.\\d+$"
  ```

- [ ] 5.5.1.4 Add `pin-major.version-checker.io/CONTAINER` where appropriate
  For images where you don't want to track major version bumps (e.g., PostgreSQL 16->17
  is a major migration, not an auto-update). Pin major to current.

- [ ] 5.5.1.5 Verify clean signal
  After fixes: `version_checker_is_latest_version == 0` should only show genuinely
  outdated images. No false positives. Alert `ContainerImageOutdated` fires only for real drift.

### A3: Enhance Version-Check Discord Digest

- [ ] 5.5.1.6 Add container image drift section to weekly Discord digest
  Currently the version-check CronJob only runs Nova (Helm charts). Add a section that
  queries version-checker Prometheus metrics for outdated container images.

  Two approaches:
  1. **Query Prometheus API from the CronJob** - curl the Prometheus API for
     `version_checker_is_latest_version == 0`, format as Discord embed.
     Requires: CiliumNP egress to prometheus service, ServiceAccount with prometheus access.
  2. **Separate CronJob** - new lightweight CronJob that only queries Prometheus and posts.
     Simpler CiliumNP, single responsibility.

  Evaluate and choose. The digest should show:
  - Image name
  - Current version -> Latest version
  - Bump type: PATCH / MINOR / MAJOR (parse semver diff)
  - GitHub release link (construct from image registry: `ghcr.io/org/repo` -> `github.com/org/repo/releases`)
  - Upgrade method: "Helm upgrade" or "Edit manifest" or "kubeadm upgrade"

- [ ] 5.5.1.7 Add release notes URL mapping
  Create a ConfigMap with image-to-release-URL mapping for images that can't be auto-derived:
  ```yaml
  data:
    release-urls: |
      registry.k8s.io/etcd=https://github.com/etcd-io/etcd/releases
      registry.k8s.io/coredns/coredns=https://github.com/coredns/coredns/releases
      docker.io/library/postgres=https://www.postgresql.org/docs/release/
      ghcr.io/immich-app/immich-server=https://github.com/immich-app/immich/releases
      # For ghcr.io/org/repo -> auto-derive https://github.com/org/repo/releases
      # For docker.io/library/X -> link to Docker Hub
      # For quay.io/org/repo -> link to Quay.io tags page
  ```

- [ ] 5.5.1.8 Add upgrade method classification
  Tag each image source in the ConfigMap:
  - `helm`: Helm-managed (use `helm-homelab upgrade`)
  - `manifest`: manifest-managed (edit deployment, `kubectl-admin apply`)
  - `kubeadm`: kubeadm-managed (requires `kubeadm upgrade` procedure)
  - `system`: system-level (Cilium, CoreDNS - special upgrade procedures)

### A4: Improve Alert Annotations

- [ ] 5.5.1.9 Add release URL to ContainerImageOutdated alert annotation
  ```yaml
  annotations:
    summary: "{{ $labels.image }} in {{ $labels.namespace }} is outdated"
    description: "Running {{ $labels.current_version }}, latest is {{ $labels.latest_version }}"
    release_url: "https://github.com/{{ $labels.image | reReplaceAll `(ghcr.io|docker.io)/` `` }}/releases"
  ```
  > Note: Prometheus template functions are limited. The URL may need to be a best-effort
  > guess. Complex mappings should be in the Discord digest, not the alert.

- [ ] 5.5.1.10 Add bump type to alert description
  Use Prometheus label math or recording rules to classify patch/minor/major:
  ```yaml
  # Recording rule approach
  - record: version_checker:bump_type
    expr: |
      # If major version differs -> "major"
      # If minor version differs -> "minor"
      # Otherwise -> "patch"
  ```
  > Evaluate feasibility. Semver parsing in PromQL is limited. May be better handled
  > in the Discord digest script where jq/shell can parse versions properly.

---

## 5.5.2 Cluster Janitor & Operational Improvements (Phase B)

### B1: Janitor Cleanup Improvements

- [ ] 5.5.2.1 Add Evicted pod cleanup to cluster janitor
  Evicted pods accumulate after node memory/disk pressure events. They're terminal state
  (like Failed) but have `status.reason=Evicted` not `status.phase=Failed`.
  ```bash
  # Add after Task 1 in janitor script
  EVICTED_PODS=$(kubectl get pods -A --field-selector=status.phase=Failed \
    -o jsonpath='{range .items[?(@.status.reason=="Evicted")]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' \
    2>/dev/null | wc -l)
  ```
  > Actually verify: do Evicted pods show as `status.phase=Failed`? If so, Task 1 already
  > catches them. Test by checking `kubectl get pods -A --field-selector=status.phase=Failed`
  > output for any Evicted pods. If they're already caught, skip this task.

- [ ] 5.5.2.2 Add old ReplicaSet cleanup (0 replicas, age > 7 days)
  Deployment rollouts leave old ReplicaSets with 0 replicas. Kubernetes keeps
  `revisionHistoryLimit` (default 10) but they accumulate.
  ```bash
  # Only delete ReplicaSets with 0 desired, 0 ready, older than 7 days
  # Safety: never delete if it's the only ReplicaSet for a Deployment
  ```
  > Evaluate: is this actually a problem? Check `kubectl get rs -A | grep "0  0  0"` count.
  > If only a handful, not worth the complexity. Document decision.

### B2: Janitor Discord Message Improvements

- [ ] 5.5.2.3 Add context to janitor Discord messages
  Current message: `"Cluster Janitor cleaned 3 failed pod(s), 1 stopped replica(s)"`
  Improved: include which pods/replicas were cleaned, which namespaces affected.
  ```bash
  # Example: "Cleaned 3 failed pods: monitoring/prometheus-node-exporter-abc (OOMKilled),
  #           arr-stack/radarr-xyz (UnexpectedAdmissionError), ..."
  ```
  > Keep it concise. List up to 5 items, then "and N more" for the rest.

### B3: Backup Health Dashboard

- [ ] 5.5.2.4 Create `manifests/monitoring/dashboards/backup-dashboard-configmap.yaml`
  Single dashboard showing all backup health in one view:

  **Row 1: Backup Status Overview**
  - Stat panels: Velero last success age, etcd last success age, Longhorn backup errors
  - Table: all backup CronJobs with last success time, last failure, next run

  **Row 2: Velero Backups**
  - Time series: `velero_backup_success_total` and `velero_backup_failure_total`
  - Stat: backup duration, items backed up
  - Gauge: Garage S3 storage used

  **Row 3: Longhorn Backups**
  - Table: volumes with backup status (last backup time, size)
  - Stat: `longhorn_backup_state` distribution

  **Row 4: CronJob Backup Health**
  - Table: all backup CronJobs (vault-snapshot, atuin-backup, pki-backup, etcd-backup,
    ghost-mysql-backup, adguard-backup, etc.) with last success/failure timestamps
  - Alert panel: any backup-related alerts firing

  Follow convention: descriptions on every panel, `grafana_dashboard: "1"` label,
  `grafana_folder: "Homelab"` annotation.

---

## 5.5.3 Fill Monitoring Gaps (Phase C)

### C1: Infrastructure ServiceMonitors & Probes

- [ ] 5.5.3.1 Add Blackbox probes for cert-manager webhook, external-secrets webhook
  These webhooks are critical - if they fail, no certificates are issued and no secrets sync.
  Probe the webhook service HTTPS endpoints.

- [ ] 5.5.3.2 Add Blackbox probe for velero + garage health endpoint
  Garage: `GET /health` on port 3903 (admin API).
  Velero: check if the velero deployment is running (kube-state-metrics may suffice).

- [ ] 5.5.3.3 Add Blackbox probe for longhorn-ui
  Web UI availability - useful for knowing if you can access Longhorn dashboard.

- [ ] 5.5.3.4 Add ServiceMonitor for GitLab (uses built-in gitlab-exporter)
  GitLab Helm chart deploys `gitlab-exporter` and `gitlab-workhorse` with metrics endpoints.
  Check: `kubectl-homelab get svc -n gitlab` for metrics ports.
  May need to enable in GitLab Helm values if not already exposed.

- [ ] 5.5.3.5 Add PrometheusRules for GitLab health
  At minimum: webservice 5xx rate, Sidekiq queue depth, Gitaly errors,
  PostgreSQL connection pool usage, registry availability.

### C2: Database Monitoring

- [ ] 5.5.3.6 Evaluate database monitoring approach
  Options:
  1. **postgres-exporter sidecar** - add `prometheuscommunity/postgres-exporter` sidecar to
     each PostgreSQL StatefulSet. Gives: connections, query latency, replication lag, table sizes.
     Overhead: ~15MB RAM per sidecar. Requires PGPASSWORD from secret.
  2. **mysql-exporter sidecar** - add `prom/mysqld-exporter` sidecar to MySQL StatefulSets.
     Similar metrics. Requires MYSQL_PASSWORD from secret.
  3. **CronJob backup success as proxy** - if `pg_dump` succeeds, DB is healthy enough.
     Cheaper but misses: slow queries, connection exhaustion, replication issues.
  4. **Hybrid** - exporters for production DBs only, backup-as-proxy for dev/staging.

  Decide and document. Recommendation: option 4 (exporters for prod, skip dev).

- [ ] 5.5.3.7 Implement database monitoring for production databases
  At minimum: ghost-prod/mysql, invoicetron-prod/postgres, atuin/postgres, gitlab/postgresql.
  Create ServiceMonitors for each exporter sidecar.

### C3: Grafana Dashboards (Critical + High Priority)

> Follow project convention: Pod Status row -> Network Traffic row -> Resource Usage row.
> Descriptions on every panel and row. ConfigMap with `grafana_dashboard: "1"` label,
> `grafana_folder: "Homelab"` annotation.

- [ ] 5.5.3.8 Create dashboard: cert-manager (certificate status, renewal rate, webhook latency)
- [ ] 5.5.3.9 Create dashboard: external-secrets (sync status, error rate, webhook latency)
- [ ] 5.5.3.10 Create dashboard: velero + garage (backup status, S3 storage, schedule health)
- [ ] 5.5.3.11 Create dashboard: GitLab (web requests, Sidekiq jobs, Gitaly, registry, Postgres)
- [ ] 5.5.3.12 Create dashboard: ghost-prod (MySQL connections, request rate, memory)
- [ ] 5.5.3.13 Create dashboard: invoicetron-prod (PostgreSQL connections, app health)
- [ ] 5.5.3.14 Create dashboard: home (AdGuard DNS queries, MySpeed results)
- [ ] 5.5.3.15 Create dashboard: uptime-kuma (monitor status, response times)

> Skip dashboards for: dev/staging namespaces, browser, nfd, intel-device-plugins,
> gitlab-runner (low value, high effort).

### C4: Missing PrometheusRules

- [ ] 5.5.3.16 Add alerts for cert-manager (webhook failures, certificate renewal failures)
- [ ] 5.5.3.17 Add alerts for external-secrets (operator health, webhook failures)
- [ ] 5.5.3.18 Add alerts for velero + garage (garage down, S3 storage usage)
  > `up{job="garage"} == 0` for direct Garage health. Faster detection than waiting 36h
  > for VeleroBackupStale to fire.
- [ ] 5.5.3.19 Add alerts for GitLab (webservice 5xx, Sidekiq queue depth, Gitaly errors)

### C5: Existing Dashboard Quality Audit

- [ ] 5.5.3.20 Audit existing 41 dashboards for convention compliance
  Check each dashboard:
  - Row order: Pod Status -> Network Traffic -> Resource Usage
  - Descriptions on every panel and row
  - CPU/Memory panels have dashed request/limit lines
  - ConfigMap has `grafana_dashboard: "1"` label and `grafana_folder: "Homelab"` annotation
  Document which dashboards need fixing. Fix in a single batch.

- [ ] 5.5.3.21 Audit existing alerts for metric accuracy
  Same pattern as Longhorn numeric gauge bug from Phase 5.4 G - check all alert expressions
  against actual Prometheus metrics. Look for:
  - Label selectors that don't exist on the metric
  - Numeric values that don't match expected states
  - Metrics that return empty results (alert will never fire)

---

## 5.5.4 Infrastructure Version Updates (Phase D)

> **Order matters.** Update from lowest risk to highest risk. Verify cluster health
> between each upgrade. Never update two infrastructure components at once.
>
> **For each upgrade:**
> 1. Read release notes / changelog for breaking changes
> 2. Check upgrade guide if it's a minor version bump
> 3. Verify current cluster health (all alerts inactive)
> 4. Take Longhorn snapshot of any affected PVCs
> 5. Perform upgrade
> 6. Verify cluster health after upgrade
> 7. Update VERSIONS.md

- [ ] 5.5.4.1 Update Vault 1.21.2 -> latest patch
  Patch release - low risk. Helm upgrade with existing values.
  Release notes: https://github.com/hashicorp/vault/releases
  Verify: `vault status`, ESO sync, all ExternalSecrets healthy.

- [ ] 5.5.4.2 Update Loki 3.6.3 -> latest 3.6.x patch
  Patch release - low risk. Helm upgrade.
  Release notes: https://github.com/grafana/loki/releases
  Verify: Grafana log queries work, Alloy shipping logs.

- [ ] 5.5.4.3 Update Prometheus stack (Prometheus, Alertmanager, Grafana)
  Minor release - medium risk. Scale down Grafana first (RWO PVC gotcha).
  Release notes: https://github.com/prometheus/prometheus/releases
  Verify: all alerts evaluating, dashboards loading, Alertmanager routing.

- [ ] 5.5.4.4 Update Alloy v1.12.2 -> latest
  Minor release - medium risk. Log collector - verify logs still flowing after.
  Release notes: https://github.com/grafana/alloy/releases

- [ ] 5.5.4.5 Update Longhorn v1.10.1 -> v1.11.x
  Minor release - HIGH risk (storage layer). Read upgrade notes carefully.
  Release notes: https://github.com/longhorn/longhorn/releases
  Upgrade guide: https://longhorn.io/docs/latest/deploy/upgrade/
  Pre-check: all volumes healthy, backups recent, no degraded volumes.
  Post-check: volume I/O works, all PVCs bound, replicas rebuilding.
  > May require its own dedicated session with rollback plan.

- [ ] 5.5.4.6 Update Cilium v1.18.6 -> v1.19.x
  Minor release - HIGH risk (CNI). Read upgrade notes.
  Release notes: https://github.com/cilium/cilium/releases
  Upgrade guide: https://docs.cilium.io/en/stable/operations/upgrade/
  Pre-check: all pods can communicate, cilium status healthy.
  Post-check: NetworkPolicies still enforced, HTTPRoutes working, no connectivity loss.
  > May require its own dedicated session with rollback plan.

- [ ] 5.5.4.7 Update CoreDNS v1.13.1 -> v1.14.x
  Minor release - medium risk. Test DNS resolution after.
  Release notes: https://github.com/coredns/coredns/releases
  > CoreDNS is managed by kubeadm. May need `kubeadm upgrade apply` or manual image edit.

---

## 5.5.5 Application Version Updates (Phase E)

- [ ] 5.5.5.1 Update Ghost 6.14.0 -> latest 6.x
  Release notes: https://github.com/TryGhost/Ghost/releases
  Check for database migration requirements.

- [ ] 5.5.5.2 Update Ollama 0.15.6 -> latest
  Release notes: https://github.com/ollama/ollama/releases

- [ ] 5.5.5.3 Update MeiliSearch v1.13.3 -> latest
  Release notes: https://github.com/meilisearch/meilisearch/releases
  Karakeep dependency - test search functionality after upgrade.
  > MeiliSearch major versions may require index rebuild.

- [ ] 5.5.5.4 Update remaining outdated application images
  Run version-checker audit, update images that are genuinely behind.
  For each: check release notes, pin exact version in manifest, verify after apply.

> Pin exact versions in manifests - no `:latest` tags. Update VERSIONS.md for each.

---

## 5.5.6 Documentation (Phase F)

- [ ] 5.5.6.1 Update VERSIONS.md with all new versions
- [ ] 5.5.6.2 Update docs/reference/CHANGELOG.md
- [ ] 5.5.6.3 Update docs/context/Monitoring.md with new dashboards/alerts/probes
- [ ] 5.5.6.4 Update docs/context/Upgrades.md with lessons learned from each upgrade

---

## Verification Checklist

- [ ] Alertmanager routes backup/infra alerts to #infra (not #apps)
- [ ] version-checker signal clean (no false positives firing)
- [ ] Weekly Discord digest includes both Helm chart AND container image drift
- [ ] Discord digest includes release notes links and bump type classification
- [ ] Cluster janitor handles Evicted pods (if applicable)
- [ ] Backup health dashboard deployed and showing all backup systems
- [ ] All production services have: ServiceMonitor OR probe, PrometheusRule, Grafana dashboard
- [ ] All production databases monitored (exporter sidecars or equivalent)
- [ ] Existing dashboards audited and fixed for convention compliance
- [ ] All alert expressions verified against actual Prometheus metrics
- [ ] All infrastructure images at latest stable version
- [ ] All application images at latest stable version
- [ ] No alerts firing except expected (Watchdog, etc.)
- [ ] VERSIONS.md current

---

## Final: Commit and Release

- [ ] `/audit-security` then `/commit`
- [ ] `/audit-docs` then `/commit`
- [ ] `/release v0.35.0 "Observability & Version Hardening"`
- [ ] `mv docs/todo/phase-5.5-observability-version-hardening.md docs/todo/completed/`
