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

## Audit Findings (2026-03-21 cluster verification)

> This section records bugs and issues found during the live cluster audit that produced
> the gap analysis below. These must be fixed first (Phase A0) since they represent
> broken monitoring that exists TODAY - not gaps in coverage.

### Bug 1: ClusterJanitorFailing alert uses inconsistent metric name

**File:** `manifests/monitoring/alerts/cluster-janitor-alerts.yaml`
**Expression:** `kube_job_failed{namespace="kube-system", job_name=~"cluster-janitor-.*"} > 0`

Both `kube_job_failed` and `kube_job_status_failed` exist in Prometheus (kube-state-metrics
exposes both). However, `backup-alerts.yaml` and `vault-alerts.yaml` both use
`kube_job_status_failed`. The cluster janitor alert uses `kube_job_failed` (different metric).

**Impact:** These are different metrics tracking different things:
- `kube_job_failed` = gauge counting pods that reached Failed phase
- `kube_job_status_failed` = gauge from the Job's `.status.failed` field

Need to verify which metric correctly detects janitor failures and standardize across
all alert files. If `kube_job_failed` doesn't populate for CronJob-spawned jobs,
this alert silently never fires.

### Bug 2: audit-alerts.yaml is not a valid PrometheusRule

**File:** `manifests/monitoring/alerts/audit-alerts.yaml`

This file has no `apiVersion` or `kind` header and uses LogQL (Loki query language), not
PromQL. It is NOT deployed as a PrometheusRule - the cluster has no `audit-alerts` resource.
File header documents this: "TODO: Enable Loki ruler and deploy these rules when ready."

**Impact:** 4 security audit alerts (AuditSecretAccessByNonSystem, AuditPodExec,
AuditRBACChange, AuditHighAuthFailureRate) exist in the repo but never fire.
This is a known limitation (no Loki Ruler), but the file sitting in the alerts directory
alongside valid PrometheusRules is misleading.

**Decision needed:** Either:
1. Move to a `drafts/` or `disabled/` subdirectory with a clear naming convention
2. Add Loki Ruler to the stack (increases complexity, resource usage)
3. Convert to PromQL using kube-audit-rest or audit2rbac metrics (if available)

### Bug 3: LonghornBackupFailed misrouted to #apps

**File:** `manifests/monitoring/alerts/backup-alerts.yaml`

The alert `LonghornBackupFailed` (severity: warning) is not matched by the infra regex
pattern `Longhorn.*` because... wait, it IS matched by `Longhorn.*`. But audit shows
the alertname is `LonghornBackupFailed` which starts with "Longhorn" - so it DOES match
the existing infra regex. Original plan missed this - it's correctly routed.

**Correction:** Remove LonghornBackupFailed from the misrouted list. The `Longhorn.*`
pattern in the infra regex already catches it.

### Bug 4: PodStuckInInit CrashLoopBackOff branch uses wrong metric name

**File:** `manifests/monitoring/alerts/stuck-pod-alerts.yaml`
**Expression:** `kube_pod_init_container_status_waiting{reason="CrashLoopBackOff"} == 1`

The metric `kube_pod_init_container_status_waiting` has no `reason` label (confirmed from
live Prometheus - labels are `container`, `namespace`, `pod`, `uid` only). The correct
metric with the reason label is `kube_pod_init_container_status_waiting_reason`.

**Impact:** The second branch (`kube_pod_init_container_status_running == 1 and Pending`)
still works, so stuck-running init containers are caught. But CrashLoopBackOff init
containers are silently missed.

### Bug 5: AlloyHighMemory uses removed cAdvisor metric

**File:** `manifests/monitoring/alerts/logging-alerts.yaml`
**Expression:** `container_memory_working_set_bytes{container="alloy"} / container_spec_memory_limit_bytes{container="alloy"} > 0.8`

`container_spec_memory_limit_bytes` does not exist in this Prometheus - the cAdvisor metric
was removed from kube-prometheus-stack. The correct metric is
`kube_pod_container_resource_limits{resource="memory"}` (same pattern used by the working
`OllamaMemoryHigh` alert).

### Bug 6: NVMe alert annotations reference empty `$labels.node`

**Alerts:** `NVMeMediaErrors`, `NVMeSpareWarning`, `NVMeWearHigh` in `storage-alerts.yaml`

smartctl_device_* metrics have no populated `node` label. The annotations reference
`$labels.node` which renders as empty string in Discord notifications. Alerts fire
correctly but with degraded description text.

**Fix:** Change `$labels.node` to `$labels.pod` (which is populated), or add relabeling
to the smartctl-exporter ServiceMonitor to copy node name into the metric.

### Finding: Orphan file in dashboards directory

**File:** `manifests/monitoring/dashboards/ups-monitoring.json`

Raw JSON file without ConfigMap wrapper. The actual UPS dashboard is deployed via
`ups-dashboard-configmap.yaml`. This orphan file should be deleted.

---

## Gap Analysis (2026-03-21 audit - verified against live cluster)

### Observability Gaps

#### Dashboard Coverage

**14 custom Grafana dashboards** exist in `manifests/monitoring/dashboards/`:

| # | Dashboard | Covers | Convention Compliant |
|---|-----------|--------|---------------------|
| 1 | arr-stack | ARR core apps (15 deployments) | YES - but missing dashed request/limit lines |
| 2 | atuin | atuin namespace | YES - fully compliant |
| 3 | claude-code | Claude Code OTel metrics (not K8s workload) | NO - missing `app.kubernetes.io/name: grafana` label, 5/17 panels described, no row descriptions |
| 4 | dotctl | dotctl OTel metrics (not K8s workload) | NO - missing `app.kubernetes.io/name: grafana` label |
| 5 | jellyfin | arr-stack/jellyfin + GPU | YES - fully compliant |
| 6 | kube-vip | kube-system/kube-vip | PARTIAL - no CPU/Memory dashed lines |
| 7 | longhorn | longhorn-system storage health | N/A - storage-specific (no pod resource rows) |
| 8 | network | Cluster-wide NIC utilization | N/A - infrastructure-specific |
| 9 | scraparr | ARR app metrics via Scraparr exporter | PARTIAL - no Network Traffic row |
| 10 | service-health | Cross-cutting blackbox probe status | N/A - probe dashboard |
| 11 | tailscale | tailscale namespace | YES - but Pod Status row missing description |
| 12 | ups | UPS NUT monitoring (community import) | NO - 0/15 panels described, no row descriptions |
| 13 | vault | vault namespace + ESO sync | YES - fully compliant |
| 14 | version-checker | Cluster-wide image version table | N/A - single table panel (community import) |

**Namespaces with NO dedicated dashboard (need new dashboards):**

| Priority | Namespace | Workloads | Existing Coverage |
|----------|-----------|-----------|-------------------|
| Critical | gitlab | 8 deploys + 3 statefulsets | NONE (entire GitLab instance unmonitored) |
| Critical | cert-manager | 3 (controller, cainjector, webhook) | Has ServiceMonitor, no dashboard |
| Critical | external-secrets | 3 (operator, webhook, cert-controller) | Has 3 ServiceMonitors (Helm auto-created), no dashboard |
| Critical | velero | 2 (velero, garage) | Has 2 ServiceMonitors (recently added), no dashboard |
| High | ghost-prod | 3 (ghost, ghost-analytics, ghost-mysql) | Has probe + alert, no dashboard |
| High | invoicetron-prod | 2 (app, db) | Has probe + alert, no dashboard |
| High | home | 3 (adguard, homepage, myspeed) | DNS probe only, no dashboard |
| High | uptime-kuma | 1 | Has probe + alert, no dashboard |
| Medium | karakeep | 3 (karakeep, chrome, meilisearch) | Has probe + alert, no dashboard |
| Medium | ai | 1 (ollama) | Has probe + alert, no dashboard |
| Low | ghost-dev, portfolio-dev/staging, invoicetron-dev | dev/staging envs | Skip |
| Low | browser, cloudflare, gitlab-runner, intel-device-plugins, nfd | system/utility | Skip |

> Note: ghost-prod has 3 workloads (ghost, ghost-analytics, ghost-mysql), not 2 as previously claimed.
> karakeep has 3 workloads (karakeep, chrome, meilisearch), not 1.

#### Monitoring Coverage Matrix (verified)

```
NAMESPACE               WORKLOADS  SERVICEMONITOR  ALERTS         PROBE
---                     ---        ---             ---            ---
+ monitoring            10         13 SMs          60 rules       N/A (self)
+ arr-stack             15         3 SMs (qbit,    arr-alerts     8 probes
                                   tdarr, scraparr)
+ vault                 2          1 SM            vault-alerts   1 probe
+ velero                2          2 SMs (NEW)     backup-alerts  NONE
+ cert-manager          3          1 SM            cert-alerts    NONE
+ external-secrets      3          3 SMs (Helm)    via vault-alerts NONE
+ cloudflare            1          1 SM            cloudflare-alerts NONE
+ longhorn-system       6+         1 SM            2x alerts      NONE
+ kube-system           3+         9 SMs (built-in) various       N/A
~ ai (Ollama)           1          NONE            alert          probe
~ atuin                 2          NONE            alert          probe
~ ghost-prod            3          NONE            alert          probe (ghost only)
~ ghost-dev             2          NONE            alert          NONE
~ home                  3          NONE            adguard only   DNS probe only
~ invoicetron-prod      2          NONE            alert          probe
~ invoicetron-dev       2          NONE            alert          NONE
~ karakeep              3          NONE            alert          probe (karakeep only)
~ portfolio-prod        1          NONE            alert          probe
~ portfolio-dev/staging 2          NONE            alert          NONE
~ uptime-kuma           1          NONE            alert          probe
~ tailscale             2          NONE            alert          NONE
- browser               1          NONE            NONE           NONE
- gitlab                11         NONE*           NONE           NONE
- gitlab-runner         1          NONE            NONE           NONE
- intel-device-plugins  1          NONE**          NONE           NONE
- node-feature-discovery 2         NONE            NONE           NONE

Legend: + = good coverage, ~ = partial (probe/alert but no metrics), - = zero monitoring
* GitLab has gitlab-exporter deploy + postgresql-metrics with prometheus.io/scrape annotation,
  but no ServiceMonitor picks them up (Prometheus uses SM-only discovery)
** intel-device-plugins has a metrics-service on port 8080 but no ServiceMonitor
```

#### Zero monitoring (no metrics, alerts, or probes)

- `browser/firefox` - headless browser, low value
- `intel-device-plugins` - has metrics service but no SM (easy win to add)
- `node-feature-discovery` - label manager only, no actionable metrics
- `gitlab-runner` - CI runner, low value for homelab
- **GitLab** (8 deploys + 3 statefulsets) - critical gap; gitlab-exporter exists but is not scraped

#### Missing probes (verified)

**Infrastructure services with no HTTP/health probe:**
- cert-manager webhook (critical - blocks certificate issuance)
- external-secrets webhook (critical - blocks secret sync)
- longhorn-ui (useful - dashboard availability)
- Garage S3 health endpoint (port 3903 `/health`)

**Application services with no probe:**
- `home/homepage` - has HTTPRoute but no blackbox probe
- `home/myspeed` - has HTTPRoute but no blackbox probe
- `ghost-prod/ghost-analytics` - separate deploy, not probed (only ghost main app is probed)
- `arr-stack/prowlarr` - **critical ARR dependency** (if down, all indexing stops silently)
- `arr-stack/sonarr` - has `/ping` endpoint but no blackbox probe
- `arr-stack/radarr` - has `/ping` endpoint but no blackbox probe
- `arr-stack/recommendarr` - no probe or monitoring of any kind
- `karakeep/meilisearch` - search dependency for karakeep, not probed

> Note: Prowlarr, Sonarr, and Radarr all expose `/ping` health endpoints on their main
> ports, making them easy blackbox probe targets.

#### 8 databases with zero monitoring (confirmed)

- atuin/postgres, ghost-dev/ghost-mysql, ghost-prod/ghost-mysql
- invoicetron-dev/invoicetron-db, invoicetron-prod/invoicetron-db
- gitlab/postgresql, gitlab/redis-master, gitlab/gitaly

> GitLab's bundled postgresql has a `gitlab-postgresql-metrics` service with
> `prometheus.io/scrape: true` annotation on port 9187, but Prometheus uses
> ServiceMonitor-only discovery (`serviceMonitorSelectorNilUsesHelmValues: false`)
> so this annotation is ignored. Adding a ServiceMonitor for port 9187 would
> immediately enable postgresql metrics without a sidecar.

### Alertmanager Routing Gap

Current infra route regex in `helm/prometheus/values.yaml` (line 242):
```
(Longhorn.*|NVMe.*|etcd.*|KubeVip.*|Certificate.*|Node.*|UPS.*|NetworkInterface.*|KubePersistent.*|SmartCTL.*|KubeApiserver.*|CPUThrottling.*|Alloy.*|Loki.*|ClusterJanitor.*|Vault.*|ESO.*|Audit.*)
```

Alerts that route to **WRONG** Discord channel:

| Alert | Severity | Expected | Actual | Why Wrong |
|-------|----------|----------|--------|-----------|
| VeleroBackupStale | warning | #infra | **#apps** | No `Velero.*` in infra regex |
| ResourceQuotaNearLimit | warning | #infra | **#apps** | No `ResourceQuota.*` in infra regex |
| CronJobFailed | warning | #infra | **#apps** | No `CronJob.*` in infra regex |
| CronJobNotScheduled | warning | #infra | **#apps** | No `CronJob.*` in infra regex |

Alerts that route CORRECTLY:

| Alert | Severity | Channel | Why |
|-------|----------|---------|-----|
| VeleroBackupFailed | critical | #incidents | Severity match (critical -> incidents) |
| EtcdBackupStale | critical | #incidents | Severity match |
| PodCrashLoopingExtended | critical | #incidents | Severity match |
| LonghornVolumeAllReplicasStopped | warning | #infra | Matches `Longhorn.*` |
| LonghornBackupFailed | warning | #infra | Matches `Longhorn.*` |
| PodStuckInInit | warning | #apps | Design choice (app-level investigation) |
| PodStuckPending | warning | #apps | Design choice (could be infra, but most causes are app config) |
| PodImagePullBackOff | warning | #apps | Design choice (usually wrong image tag) |

**Fix:** Add `Velero.*|Backup.*|ResourceQuota.*|CronJob.*|Garage.*` to the infra route regex.

Updated regex:
```
(Longhorn.*|NVMe.*|etcd.*|KubeVip.*|Certificate.*|Node.*|UPS.*|NetworkInterface.*|KubePersistent.*|SmartCTL.*|KubeApiserver.*|CPUThrottling.*|Alloy.*|Loki.*|ClusterJanitor.*|Vault.*|ESO.*|Audit.*|Velero.*|Backup.*|ResourceQuota.*|CronJob.*|Garage.*)
```

### Version-Checker & Version-Check Gaps

**Problem 1: Two separate systems, neither complete.**
- `version-checker` (deployment, `quay.io/jetstack/version-checker:v0.10.0`) - monitors
  container IMAGE versions via registry tags. Exports Prometheus metrics. Alert:
  `ContainerImageOutdated` (7d threshold). No Discord notification. No release links.
  No patch/minor/major classification.
- `version-check` (weekly CronJob, Nova `v3.11.10` + `alpine/k8s:1.35.0`) - runs Nova
  for HELM CHART drift only. Sends Discord digest to `#versions`. Does NOT cover
  manifest-deployed images (majority of the cluster).

**Problem 2: False positives pollute the signal.**
- cert-manager: Quay returns build numbers ("608111629") instead of semver. Already excluded
  from `ContainerImageOutdated` alert via `image!~"quay.io/jetstack/cert-manager.*"`,
  but the metric still shows as outdated in Grafana dashboard.
- grafana: Current image is `grafana/grafana:12.3.1` (standard semver). Verify if
  version-checker correctly parses this - the original claim of tag parsing issues needs
  re-verification since Grafana uses clean semver tags from Docker Hub.
- Only 4 deployments have `match-regex` annotations (bazarr, radarr, sonarr, firefox -
  all LSIO images with `-ls<N>` suffix tags). Zero deployments use `pin-major`.
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

**Current tasks (3, not 2 as previously documented):**
1. Delete Failed pods (`status.phase=Failed`)
2. Delete stopped Longhorn replicas (safety: skip if 0 running replicas for volume)
3. Delete stale Failed jobs (older than 1 hour, gives time to inspect logs first)

> The janitor already handles 3 cleanup tasks. Task 3 (Failed job cleanup) was added
> in Phase 5.4 but wasn't reflected in the original gap analysis.

**Potentially missing cleanup tasks:**
- Evicted pods (`status.reason=Evicted`) - BUT these typically show as `status.phase=Failed`,
  so Task 1 likely already catches them. **Verify before adding.**
- Old ReplicaSets with 0 replicas - evaluate if this is actually a problem in this cluster.
  Kubernetes keeps `revisionHistoryLimit` (default 10) per Deployment. **Check count first.**

**Discord message is minimal:**
- Current format: `**Cluster Janitor cleaned X failed pod(s), Y stopped replica(s), Z failed job(s)** at HH:MMam PHT`
- Plain text (not Discord embed), only sent when `TOTAL > 0`
- No detail on WHAT was cleaned, which namespaces, or failure reasons

### Missing Garage Health Alert

Velero and Garage both have ServiceMonitors now (added recently), but there is NO alert
for Garage S3 going down. If Garage fails:
- No immediate alert fires
- `VeleroBackupStale` fires after 36 hours (next missed backup window)
- That's a 36-hour detection gap for backup infrastructure failure

Need: `up{job="garage"} == 0` alert with 5-minute `for:` threshold.

### No Backup Health Dashboard

Phase 5.4 added 13 alert rules for backups, but there's no Grafana dashboard to visualize:
- Longhorn backup status (last success time, error count)
- Velero backup status (success/failure counters, schedule health)
- CronJob backup status (all backup CronJobs in one view)
- etcd backup age
- Off-site backup status (manual/WSL2 - may need a push metric)

### Existing Dashboard Quality Issues (audited)

> Previous plan claimed "41 dashboards" - actual count is **14 custom dashboards** in the
> repo. The 41 number likely included Helm-managed dashboards from kube-prometheus-stack
> (not in our repo, not worth auditing). Focus on the 14 we control.

**Issues found per dashboard:**

| Dashboard | Issue | Severity |
|-----------|-------|----------|
| arr-stack | No dashed request/limit lines on CPU/Memory panels | Medium |
| claude-code | Missing `app.kubernetes.io/name: grafana` label | Low |
| claude-code | Only 5/17 panels have descriptions | Medium |
| claude-code | None of 8 rows have descriptions | Medium |
| dotctl | Missing `app.kubernetes.io/name: grafana` label | Low |
| kube-vip | No dashed request/limit lines (no CPU/Memory timeseries) | Low |
| tailscale | Pod Status row missing description | Low |
| ups | Community import - 0/15 panels described | Low |
| ups | UPS Status row has no description | Low |

> dashboards marked N/A for convention (longhorn, network, service-health, version-checker)
> are domain-specific and don't need Pod Status/Network/Resource rows.
>
> claude-code and dotctl are OTel-push dashboards (not K8s workload monitoring) - lower
> priority for convention fixes.

### Version Gaps (2026-03-21 snapshot)

> NOTE: version-checker has tag parsing false positives (cert-manager reports nonsense
> "latest" versions). Grafana false positive needs re-verification. Fix these first
> so the signal is clean.

| Category | Image | Current | Latest |
|----------|-------|---------|--------|
| CNI | Cilium | v1.18.6 | v1.19.1 |
| Storage | Longhorn | v1.10.1 | v1.11.1 |
| Monitoring | Prometheus | v3.9.1 | v3.10.0 |
| Monitoring | Alertmanager | v0.30.1 | v0.31.1 |
| Monitoring | Grafana | 12.3.1 | (verify) |
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
Phase A0 -- Fix Broken Alerts & Bugs (pre-work)
   |        A0.1: Fix ClusterJanitorFailing metric (kube_job_status_failed)
   |        A0.2: Fix PodStuckInInit CrashLoop branch (wrong metric name)
   |        A0.3: Fix AlloyHighMemory (removed cAdvisor metric)
   |        A0.4: Fix NVMe alert annotations ($labels.node -> $labels.pod)
   |        A0.5: Handle audit-alerts.yaml (move to disabled/)
   |        A0.6: Delete orphan ups-monitoring.json
   v
   GATE: All existing alerts verified firing correctly against live Prometheus
   v
Phase S --- Monitoring Standardization Sweep
   |        S1: Create runbook markdown files (extract from inline content)
   |        S2: Rename 4 inconsistent alert names (with impact verification)
   |        S3: Standardize annotations (summary + description + runbook_url on all 96 alerts)
   |        S4: Standardize metadata labels (PrometheusRules, Probes, Dashboards)
   |        S5: Standardize group names (remove .rules suffix)
   |        S6: Fix dashboard JSON conventions (uid, timezone, data key)
   |        S7: Update Alertmanager infra regex for any renamed alerts
   v
   GATE: All alerts evaluating, all dashboards loading, routing verified
   v
Phase A --- Version-Checker & Alertmanager Fixes
   |        A1: Verify Alertmanager routing (fix deployed in Phase S)
   |        A2: Fix version-checker false positives (match-regex annotations)
   |        A3: Enhance version-check Discord digest (add image drift, release links)
   |        A4: Improve ContainerImageOutdated alert annotations
   v
   GATE: version-checker signal clean, alerts route to correct channels
   v
Phase B --- Cluster Janitor & Operational Improvements
   |        B1: Verify Evicted pod handling (may be no-op)
   |        B2: Evaluate old ReplicaSet cleanup (may be no-op)
   |        B3: Improve Discord messages (context, links)
   |        B4: Create backup health Grafana dashboard
   v
Phase C --- Fill Monitoring Gaps
   |        C0: CiliumNP + blackbox prerequisites for blocked probes
   |        C1: Missing probes (Prowlarr, homepage, myspeed, infra webhooks)
   |        C2: Add Garage health alert + GitLab ServiceMonitors (3 services)
   |        C3: Database monitoring (postgres, mysql, redis)
   |        C4: Missing Grafana dashboards (critical/high priority)
   |        C5: Fix existing dashboard quality issues
   |        C6: Audit existing alert metric accuracy
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

## 5.5.0 Fix Broken Alerts & Bugs (Phase A0)

> **Why first?** These are broken things in the current cluster - not new features.
> Fixing them first ensures the monitoring we already have is actually working.
> After fixes, verify each alert against live Prometheus before proceeding.

- [ ] 5.5.0.1 Fix ClusterJanitorFailing metric name
  **File:** `manifests/monitoring/alerts/cluster-janitor-alerts.yaml`
  Change `kube_job_failed` to `kube_job_status_failed` (confirmed: `kube_job_failed` returns
  0 active series for janitor jobs; `kube_job_status_failed` returns 1 active series).
  Verify: query both metrics in Prometheus UI, confirm the fix populates.

- [ ] 5.5.0.2 Fix PodStuckInInit CrashLoopBackOff branch
  **File:** `manifests/monitoring/alerts/stuck-pod-alerts.yaml`
  Change `kube_pod_init_container_status_waiting{reason="CrashLoopBackOff"}`
  to `kube_pod_init_container_status_waiting_reason{reason="CrashLoopBackOff"}`.
  The `_waiting` metric has no `reason` label; `_waiting_reason` does.

- [ ] 5.5.0.3 Fix AlloyHighMemory removed metric
  **File:** `manifests/monitoring/alerts/logging-alerts.yaml`
  Replace `container_spec_memory_limit_bytes{container="alloy"}` with
  `kube_pod_container_resource_limits{container="alloy", resource="memory"}`.
  Requires adding a join: use same pattern as working `OllamaMemoryHigh` alert.

- [ ] 5.5.0.4 Fix NVMe alert annotations
  **File:** `manifests/monitoring/alerts/storage-alerts.yaml`
  Alerts `NVMeMediaErrors`, `NVMeSpareWarning`, `NVMeWearHigh` use `$labels.node`
  but smartctl metrics have no populated `node` label.
  Fix: change to `$labels.pod` or add relabeling in smartctl-exporter ServiceMonitor.

- [ ] 5.5.0.5 Move audit-alerts.yaml to disabled
  **File:** `manifests/monitoring/alerts/audit-alerts.yaml`
  Not a valid PrometheusRule (no apiVersion/kind, uses LogQL).
  Move to `manifests/monitoring/alerts/disabled/audit-alerts.yaml.disabled`.
  Preserves LogQL queries for future Loki Ruler enablement.

- [ ] 5.5.0.6 Delete orphan `manifests/monitoring/dashboards/ups-monitoring.json`
  Raw JSON duplicate of `ups-dashboard-configmap.yaml`. Not deployed. Safe to delete.

- [ ] 5.5.0.7 Verify all fixes
  After applying A0.1-A0.4, verify each alert expression returns data in Prometheus UI.
  Confirm no alerts broke by checking Alertmanager for unexpected firings.

---

## 5.5.S Monitoring Standardization Sweep (Phase S)

> **Why now?** After fixing bugs, standardize ALL monitoring resources before adding new ones.
> New probes, dashboards, and alerts (Phase A-C) should follow the conventions from day one.
> Doing this after bug fixes but before new work avoids double-touching files.
>
> **Research basis:** Prometheus official docs, kube-prometheus-stack conventions,
> Grafana Mimir patterns, kubernetes-mixin standards (2026-03-21 research).

### Conventions (reference for all phases)

#### Alert Naming

- **Format:** CamelCase `<Domain><Condition>`
- **Patterns:** `<Service>Down`, `<Service>High<Resource>`, `<Service><StateProblem>`,
  `<Service><ActionFailed>`, `<Service><ThingStale>`
- All alerts in the same PrometheusRule file share a domain prefix

#### Annotations (required on every alert)

```yaml
annotations:
  summary: "One-line with {{ $labels.x }} template vars"
  description: "Detailed explanation. Value: {{ $value }}. Affected: {{ $labels.namespace }}/{{ $labels.pod }}"
  runbook_url: "https://github.com/rommelporras/homelab/blob/main/docs/runbooks/<domain>.md#<AlertName>"
```

- Key is `runbook_url` (industry standard), NOT `runbook` (non-standard inline text)
- Every alert gets a runbook entry, even low-severity ones (minimal: severity + meaning + first step)

#### Runbook Files

```
docs/runbooks/
  storage.md      # Longhorn*, NVMe*
  backup.md       # Velero*, Etcd*, CronJob*, LonghornBackup*
  networking.md   # Network*, Cloudflare*, Tailscale*, KubeVip*
  logging.md      # Loki*, Alloy*
  vault.md        # Vault*, ESO*
  certificates.md # Certificate*
  arr-stack.md    # Arr*, Sonarr*, Radarr*, Jellyfin*, Tdarr*, QBittorrent*, Seerr*, Byparr*, Bazarr*
  apps.md         # Ghost*, Invoicetron*, Portfolio*, Karakeep*, Ollama*, Atuin*, UptimeKuma*
  cluster.md      # Pod*, ClusterJanitor*, CPUThrottling*, Node*, KubeApiserver*, VersionChecker*
  ups.md          # UPS*
  otel.md         # ClaudeCode*, Dotctl*, OTelCollector*
```

Each alert gets an `## AlertName` heading. Existing inline `runbook:` content is migrated as-is.

#### PrometheusRule Metadata Labels

```yaml
metadata:
  labels:
    release: prometheus                          # REQUIRED - Prometheus discovery
    app.kubernetes.io/part-of: kube-prometheus-stack  # organizational
```

#### Probe Labels

```yaml
metadata:
  labels:
    release: prometheus    # insurance against future selector changes
    app: <service>-probe   # existing convention
```

#### Dashboard ConfigMap Labels

```yaml
metadata:
  labels:
    grafana_dashboard: "1"                       # REQUIRED - sidecar pickup
    app.kubernetes.io/name: grafana              # organizational
    app.kubernetes.io/part-of: kube-prometheus-stack
  annotations:
    grafana_folder: "Homelab"
```

Dashboard JSON: `uid` as kebab-case slug, `timezone: "Asia/Manila"`, data key as `<service>.json`.

#### Group Names

Plain kebab-case, no `.rules` suffix: `backup`, `cronjob`, `longhorn` (not `backup.rules`).

---

### S1: Create Runbook Files

- [ ] 5.5.S.1 Create 11 runbook markdown files in `docs/runbooks/`
  Extract existing inline `runbook:` content from 57 alerts into grouped files.
  For each alert: `## AlertName` heading + severity + description + triage steps.
  39 alerts without existing runbook content get minimal entries.

### S2: Rename Inconsistent Alert Names

> **CRITICAL:** Before renaming, verify no external references exist.
> For each rename: grep all dashboard JSON, check Alertmanager route regex,
> check recording rules.

- [ ] 5.5.S.2 Rename `AdGuardDNSUnreachable` -> `AdGuardDNSDown`
  **File:** `manifests/monitoring/alerts/adguard-dns-alert.yaml`
  **Impact check:**
  - Alertmanager: routes by `severity: critical` -> #incidents. No regex match needed. SAFE.
  - Dashboards: grep `AdGuardDNSUnreachable` in `manifests/monitoring/dashboards/`. NOT REFERENCED.
  - Probes: unrelated. SAFE.

- [ ] 5.5.S.3 Rename `ContainerImageOutdated` -> `VersionCheckerImageOutdated`
  **File:** `manifests/monitoring/alerts/version-checker-alerts.yaml`
  **Impact check:**
  - Alertmanager: routes as warning to #apps (no regex). SAFE - no routing change.
  - Dashboards: verified - NOT referenced in any dashboard JSON (including version-checker).
  - Alert exclusion in cert-manager: `image!~"quay.io/jetstack/cert-manager.*"` is in the
    PromQL expression, not the alert name. SAFE.
  **Routing decision (required before S.15):** Version-checker alerts stay in #apps.
  Rationale: image drift is operational awareness, not infrastructure failure.
  Do NOT add `VersionChecker.*` to the infra regex.

- [ ] 5.5.S.4 Rename `KubernetesVersionOutdated` -> `VersionCheckerKubeOutdated`
  **File:** `manifests/monitoring/alerts/version-checker-alerts.yaml`
  **Impact check:** Same as above. Routes as info -> null. SAFE.

- [ ] 5.5.S.5 Rename `OllamaMemoryHigh` -> `OllamaHighMemory`
  **File:** `manifests/monitoring/alerts/ollama-alerts.yaml`
  **Impact check:**
  - Alertmanager: routes as warning to #apps. No regex. SAFE.
  - Dashboards: NOT REFERENCED.

### S3: Standardize Annotations on All Alerts

- [ ] 5.5.S.6 Replace `runbook:` key with `runbook_url:` on 57 alerts
  For each alert that has inline `runbook:` annotation:
  1. Content was already extracted to runbook files in S1
  2. Replace `runbook: |` block with single-line
     `runbook_url: "https://github.com/rommelporras/homelab/blob/main/docs/runbooks/<domain>.md#<AlertName>"`
  3. Verify the anchor link matches the heading in the runbook file

- [ ] 5.5.S.7 Add `runbook_url:` to 39 alerts that have no runbook
  Files affected: logging-alerts, ups-alerts, kube-vip-alerts, node-alerts,
  cpu-throttling-alerts, dotctl-alerts, version-checker-alerts, claude-alerts,
  cluster-janitor-alerts, test-alert, stuck-pod-alerts (PodStuckInInit),
  backup-alerts (ResourceQuotaNearLimit, CronJobFailed).

- [ ] 5.5.S.8 Add missing `description:` annotations where absent
  Only `test-alert.yaml` alerts may be missing descriptions. Verify and fix.

### S4: Standardize Metadata Labels

- [ ] 5.5.S.9 Add `app.kubernetes.io/part-of: kube-prometheus-stack` to PrometheusRules
  **Files:** `cluster-janitor-alerts.yaml`, `version-checker-alerts.yaml`
  (Only 2 files missing this label. All already have `release: prometheus`.)

- [ ] 5.5.S.10 Add `release: prometheus` to all 14 Probes
  **Files:** all files in `manifests/monitoring/probes/`
  Currently probes only have `app: <service>-probe`. Adding `release: prometheus`
  provides insurance if `probeSelectorNilUsesHelmValues` ever changes to `true`.
  Zero functional change today.

- [ ] 5.5.S.11 Add missing labels to 2 dashboard ConfigMaps
  - `claude-dashboard-configmap.yaml`: add `app.kubernetes.io/name: grafana` +
    `app.kubernetes.io/part-of: kube-prometheus-stack`
  - `dotctl-dashboard-configmap.yaml`: same

### S5: Standardize Group Names

- [ ] 5.5.S.12 Rename group names with `.rules` suffix
  **Files:**
  - `backup-alerts.yaml`: `backup.rules` -> `backup`, `cronjob.rules` -> `cronjob`
  - `longhorn-alerts.yaml`: `longhorn.rules` -> `longhorn`
  Impact: group names are internal to Prometheus rules UI. Not referenced by
  Alertmanager, dashboards, or any external system. SAFE.

### S6: Fix Dashboard JSON Conventions

- [ ] 5.5.S.13 Fix version-checker dashboard uid and timezone
  **File:** `manifests/monitoring/dashboards/version-checker-dashboard-configmap.yaml`
  - Change uid from `Awr5zZ4Gk` to `version-checker`
  - Change timezone from `""` to `"Asia/Manila"`
  Impact: any saved Grafana bookmarks to the old uid will break. Acceptable.

- [ ] 5.5.S.14 Fix dotctl dashboard data key name
  **File:** `manifests/monitoring/dashboards/dotctl-dashboard-configmap.yaml`
  Change data key from `dotctl-dashboard.json` to `dotctl.json` (matches convention).
  Impact: Grafana sidecar reloads from the new key. Old dashboard auto-removed. SAFE.

### S7: Update Alertmanager Routing (combines Phase S renames + routing gap fix)

- [ ] 5.5.S.15 Update infra route regex + Discord template in `helm/prometheus/values.yaml`
  This is the SINGLE Helm upgrade that fixes:
  1. **Routing gap** (from Gap Analysis): add `Velero.*|Backup.*|ResourceQuota.*|CronJob.*|Garage.*`
  2. **Discord template** (from S3): add `runbook_url` rendering to all 3 Discord receivers:
     ```
     {{ if .Annotations.runbook_url }}Runbook: {{ .Annotations.runbook_url }}{{ end }}
     ```
     Without this template update, `runbook_url` annotations will exist on alerts but
     never appear in Discord notifications.
  3. `VersionChecker.*` stays OUT of infra regex (decision from S.3: routes to #apps).
  > This replaces Phase A task 5.5.1.1 - routing fix is now handled here.
  > The Discord template change must also be added to `scripts/monitoring/upgrade-prometheus.sh`
  > since it injects the Alertmanager config at Helm upgrade time.

- [ ] 5.5.S.16 Full verification pass
  1. Apply all standardization changes
  2. Verify all 96 alerts are evaluating in Prometheus (no broken expressions)
  3. Verify all 14 dashboards load in Grafana (no missing ConfigMaps)
  4. Verify Alertmanager routing: trigger a test alert, confirm correct channel
  5. Check Discord message rendering with new `runbook_url` annotation

---

## 5.5.1 Version-Checker & Alertmanager Fixes (Phase A)

> **Why first?** If alerts route to the wrong channel, you miss critical notifications.
> If version-checker reports false positives, you can't trust the upgrade list.

### A1: Fix Alertmanager Routing

> Note: The base regex update (adding Velero/Backup/ResourceQuota/CronJob/Garage patterns)
> is done in Phase S task 5.5.S.15 to combine with alert rename routing changes in a single
> Helm upgrade. By this phase, the routing fix is already deployed. Verify it works:

- [ ] 5.5.1.1 Verify Alertmanager routing for backup/infra alerts
  Confirm these alerts now route to #infra (not #apps):
  - `VeleroBackupStale` (warning) -> #infra
  - `ResourceQuotaNearLimit` (warning) -> #infra
  - `CronJobFailed` (warning) -> #infra
  - `CronJobNotScheduled` (warning) -> #infra
  Check via Alertmanager UI routing tree or `amtool config routes test`.

### A2: Fix Version-Checker False Positives

- [ ] 5.5.1.2 Audit all images for tag parsing issues
  Query `version_checker_is_latest_version == 0` and identify which "latest" values are
  nonsense (build numbers, digests, timestamps instead of semver).
  Specifically verify:
  - cert-manager (known false positive - Quay build numbers)
  - Grafana 12.3.1 (verify if this is actually a false positive or was fixed)
  - Any other images reporting non-semver "latest" values

- [ ] 5.5.1.3 Add `match-regex` annotations to deployments with bad tag parsing
  Currently only 4 deployments have `match-regex.version-checker.io/CONTAINER`:
  bazarr, radarr, sonarr, firefox (all LSIO images with `-ls<N>` suffix).
  Add for all images with non-standard tags.
  ```yaml
  # Example: cert-manager
  annotations:
    match-regex.version-checker.io/cert-manager-controller: "^v\\d+\\.\\d+\\.\\d+$"
  ```

- [ ] 5.5.1.4 Add `pin-major.version-checker.io/CONTAINER` where appropriate
  For images where you don't want to track major version bumps (e.g., PostgreSQL 16->17
  is a major migration, not an auto-update). Pin major to current.
  Zero deployments currently use pin-major.

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

- [ ] 5.5.1.9 Add release URL to VersionCheckerImageOutdated alert annotation
  > Note: alert was renamed from `ContainerImageOutdated` in Phase S.
  Add a `release_url:` annotation (separate from `runbook_url:` - this links to the
  upstream project releases, not our runbook):
  ```yaml
  annotations:
    summary: "{{ $labels.image }} in {{ $labels.namespace }} is outdated"
    description: "Running {{ $labels.current_version }}, latest is {{ $labels.latest_version }}"
    runbook_url: "https://github.com/rommelporras/homelab/blob/main/docs/runbooks/cluster.md#VersionCheckerImageOutdated"
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

### B1: Verify Janitor Cleanup Coverage

- [ ] 5.5.2.1 Verify Evicted pods are caught by existing Failed pod cleanup
  Evicted pods typically have `status.phase=Failed`. If Task 1 (`--field-selector=status.phase=Failed`)
  already catches them, no new code needed. Test:
  ```bash
  kubectl-homelab get pods -A --field-selector=status.phase=Failed -o json | \
    jq '.items[] | select(.status.reason=="Evicted") | .metadata.name'
  ```
  If Evicted pods appear in the Failed list -> skip. If not -> add explicit Evicted cleanup.
  **Document the finding either way.**

- [ ] 5.5.2.2 Evaluate old ReplicaSet cleanup need
  Check actual count: `kubectl-homelab get rs -A | grep "0  0  0" | wc -l`
  If < 20, not worth the complexity (Kubernetes `revisionHistoryLimit: 10` handles this).
  If > 50, add cleanup with safety checks (never delete sole RS for a Deployment).
  **Document the finding and decision.**

### B2: Janitor Discord Message Improvements

- [ ] 5.5.2.3 Improve janitor Discord messages with context and detail
  Current: plain text `**Cluster Janitor cleaned X ... Y ... Z ... at HH:MMam PHT**`

  Improvements:
  1. **List what was cleaned** - namespace/name for each item, up to 5 per category, then "and N more"
  2. **Include failure reason** - OOMKilled, ImagePullBackOff, etc.
  3. **Use Discord embeds** - color-coded (green=routine, yellow=unusual count)
  4. **Add failed job context** - show which CronJob owns the failed job
  5. Only post when something was actually cleaned (already done)

  Example improved message:
  ```
  Cluster Janitor - 07:16AM PHT

  Failed Jobs (6):
  - arr-stack/arr-backup-cp1 (CronJob: arr-backup-cp1, age: 12h)
  - arr-stack/arr-backup-cp2 (CronJob: arr-backup-cp2, age: 12h)
  - arr-stack/arr-backup-cp3 (CronJob: arr-backup-cp3, age: 12h)
  - home/adguard-backup (CronJob: adguard-backup, age: 13h)
  - home/myspeed-backup (CronJob: myspeed-backup, age: 12h)
  - monitoring/grafana-backup (CronJob: grafana-backup, age: 12h)

  Stopped Replicas: 0 | Failed Pods: 0
  ```

### B3: Backup Health Dashboard

- [ ] 5.5.2.4 Create `manifests/monitoring/dashboards/backup-dashboard-configmap.yaml`
  Single dashboard showing all backup health in one view:

  **Row 1: Backup Status Overview**
  - Stat panels: Velero last success age, etcd last success age, Longhorn backup errors
  - Table: all backup CronJobs with last success time, last failure, next run

  **Row 2: Velero Backups**
  - Time series: `velero_backup_success_total` and `velero_backup_failure_total`
  - Stat: backup duration, items backed up
  - Gauge: Garage S3 storage used (from Garage ServiceMonitor metrics)

  **Row 3: Longhorn Backups**
  - Table: volumes with backup status (last backup time, size)
  - Stat: `longhorn_backup_state` distribution

  **Row 4: CronJob Backup Health**
  - Table: all backup CronJobs (vault-snapshot, atuin-backup, pki-backup, etcd-backup,
    ghost-mysql-backup, adguard-backup, myspeed-backup, uptime-kuma-backup,
    karakeep-backup, grafana-backup, arr-backup-cp1/cp2/cp3, invoicetron-db-backup)
    with last success/failure timestamps
  - Alert panel: any backup-related alerts firing

  Follow convention: descriptions on every panel, `grafana_dashboard: "1"` label,
  `grafana_folder: "Homelab"` annotation.

---

## 5.5.3 Fill Monitoring Gaps (Phase C)

### C0: CiliumNP & Blackbox Prerequisites for New Probes

> These MUST be done before creating the probes in C1, or the probes will silently fail.

- [ ] 5.5.3.0a Update home namespace CiliumNPs for monitoring access
  `homepage-gateway-ingress` and `myspeed-gateway-ingress` don't allow monitoring namespace.
  Add `fromEndpoints` rule allowing `monitoring` namespace to each policy.
  **Without this, homepage and myspeed probes will silently return probe_success=0.**

- [ ] 5.5.3.0b Add blackbox `https_2xx_insecure` module for self-signed TLS
  Current `http_2xx` module has no `tls_config`. Probing cert-manager and ESO webhooks
  on port 443 will fail TLS verification (self-signed certs).
  Add to `helm/blackbox-exporter/values.yaml`:
  ```yaml
  modules:
    https_2xx_insecure:
      prober: http
      timeout: 5s
      http:
        preferred_ip_protocol: ip4
        valid_status_codes: []
        follow_redirects: true
        tls_config:
          insecure_skip_verify: true
  ```
  Requires blackbox-exporter Helm upgrade.
  **Alternative:** Probe non-TLS health ports instead (9402 for cert-manager, 8080 for ESO).

- [ ] 5.5.3.0c Update cert-manager CiliumNP for monitoring on webhook port
  Current policy allows monitoring namespace only on port 9402 (metrics), not 443.
  Either: add port 443 to the monitoring ingress rule, OR change the probe to target
  port 9402 instead and use `http_2xx` module (avoids TLS issue entirely).

- [ ] 5.5.3.0d Update external-secrets CiliumNP for monitoring on webhook port
  Current policy allows monitoring namespace only on port 8080, not 443.
  Same decision as cert-manager: add port 443, OR probe port 8080 with `http_2xx`.

### C1: Missing Probes

> Add blackbox probes for services that have HTTPRoutes or health endpoints but no monitoring.
> All new probes MUST follow Phase S conventions: `release: prometheus` + `app: <service>-probe`
> labels, 60s interval, same blackbox exporter endpoint as existing probes.
> **Prerequisite: C0 tasks must be completed first.**

- [ ] 5.5.3.1 Add probe for Prowlarr (`prowlarr.arr-stack.svc:9696/ping`)
  Critical ARR dependency - if Prowlarr goes down, all indexing stops and downloads
  dry up silently. The only current detection is `ArrQueueWarning` (60m stall).
  CiliumNP: arr-stack already allows monitoring namespace. SAFE.

- [ ] 5.5.3.2 Add probes for Sonarr (`sonarr.arr-stack.svc:8989/ping`) and
  Radarr (`radarr.arr-stack.svc:7878/ping`)
  Both expose `/ping` health endpoints. Currently only monitored indirectly via Scraparr.
  CiliumNP: arr-stack already allows monitoring namespace. SAFE.

- [ ] 5.5.3.3 Add probe for homepage (`homepage.home.svc:3000`)
  Has HTTPRoute at `portal.k8s.rommelporras.com` but no probe.
  **Requires C0 task 5.5.3.0a (CiliumNP update) first.**

- [ ] 5.5.3.4 Add probe for myspeed (`myspeed.home.svc:5216`)
  Has HTTPRoute at `myspeed.k8s.rommelporras.com` but no probe.
  **Requires C0 task 5.5.3.0a (CiliumNP update) first.**

- [ ] 5.5.3.5 Add probe for cert-manager webhook
  Use port 9402 (metrics, non-TLS) with `http_2xx` module if C0 chose the non-TLS approach.
  Or port 443 with `https_2xx_insecure` module if C0 added TLS support.
  **Requires C0 tasks 5.5.3.0b + 5.5.3.0c first.**

- [ ] 5.5.3.6 Add probe for external-secrets webhook
  Use port 8080 (non-TLS) with `http_2xx` module if C0 chose the non-TLS approach.
  Or port 443 with `https_2xx_insecure` module if C0 added TLS support.
  **Requires C0 task 5.5.3.0d first.**

- [ ] 5.5.3.7 Add probe for longhorn-ui (`longhorn-frontend.longhorn-system.svc:80`)
  Web UI availability check.

- [ ] 5.5.3.8 Add probe for Garage health endpoint (`garage.velero.svc:3903/health`)
  S3 backend health. Complements the `GarageDown` alert.

- [ ] 5.5.3.9 Add probe for Recommendarr (`recommendarr.arr-stack.svc:3000`)
  Currently has zero monitoring of any kind.

### C2: Missing ServiceMonitors & Alerts

> All new alerts MUST follow Phase S conventions: summary + description + runbook_url
> annotations, CamelCase `<Domain><Condition>` naming, `release: prometheus` +
> `app.kubernetes.io/part-of: kube-prometheus-stack` metadata labels.
> All new ServiceMonitors: `release: prometheus` label, kebab-case name.

- [ ] 5.5.3.10 Add `GarageDown` alert to `backup-alerts.yaml`
  Add to the existing `backup-alerts.yaml` file (same domain as VeleroBackupFailed/Stale),
  not a new standalone file. The Phase S group-name standardization already touches this file.
  ```yaml
  - alert: GarageDown
    expr: up{job="garage"} == 0
    for: 5m
    labels:
      severity: critical
    annotations:
      summary: "Garage S3 backend is down"
      description: "Velero backup target unreachable. Backups will fail."
      runbook_url: "https://github.com/rommelporras/homelab/blob/main/docs/runbooks/backup.md#GarageDown"
  ```
  Without this, Garage failure detection relies on `VeleroBackupStale` (36h delay).

- [ ] 5.5.3.11 Add ServiceMonitors for GitLab metrics (3 services)
  GitLab Helm chart deploys metrics services that are already allowed by CiliumNPs:
  - `gitlab-gitlab-exporter` port 9168 (CiliumNP `monitoring-metrics-ingress` allows it)
  - `gitlab-postgresql-metrics` port 9187 (CiliumNP `postgresql-monitoring-ingress` allows it)
  - `gitlab-redis-metrics` port 9121 (CiliumNP `redis-monitoring-ingress` allows it)
  All three are free wins - no CiliumNP changes needed, no sidecars needed.
  Create 3 ServiceMonitors (or 1 with multiple endpoints).

- [ ] 5.5.3.12 Add PrometheusRules for GitLab health
  At minimum: webservice 5xx rate, Sidekiq queue depth, Gitaly errors,
  PostgreSQL connection pool usage, registry availability.
  Depends on 5.5.3.11 (ServiceMonitor must exist first to populate metrics).

- [ ] 5.5.3.13 Add ServiceMonitor for intel-device-plugins
  `inteldeviceplugins-controller-manager` has a metrics-service on port 8080.
  Easy win - service exists, just needs a ServiceMonitor.

- [ ] 5.5.3.14 Evaluate cert-manager alerts coverage
  `cert-alerts.yaml` already has: CertificateExpiringSoon, CertificateExpiryCritical,
  CertificateNotReady. Evaluate if additional alerts are needed for:
  - cert-manager webhook failures (HTTP 500s on mutation/validation)
  - ACME challenge failures (if using Let's Encrypt)
  - High certificate renewal failure rate

- [ ] 5.5.3.15 Evaluate external-secrets alerts coverage
  `vault-alerts.yaml` already has: ESOSecretNotSynced, ESOSyncErrors.
  Evaluate if additional alerts are needed for:
  - ESO operator pod restarts
  - ESO webhook failures
  - ClusterSecretStore connectivity issues

### C3: Database Monitoring

- [ ] 5.5.3.16 Evaluate database monitoring approach
  Options:
  1. **postgres-exporter sidecar** - add `prometheuscommunity/postgres-exporter` sidecar to
     each PostgreSQL StatefulSet. Gives: connections, query latency, replication lag, table sizes.
     Overhead: ~15MB RAM per sidecar. Requires PGPASSWORD from secret.
  2. **mysql-exporter sidecar** - add `prom/mysqld-exporter` sidecar to MySQL StatefulSets.
     Similar metrics. Requires MYSQL_PASSWORD from secret.
  3. **CronJob backup success as proxy** - if `pg_dump` succeeds, DB is healthy enough.
     Cheaper but misses: slow queries, connection exhaustion, replication issues.
  4. **Hybrid** - exporters for production DBs only, backup-as-proxy for dev/staging.
  5. **GitLab postgresql - ServiceMonitor only** - `gitlab-postgresql-metrics` service already
     exposes port 9187. Just needs a ServiceMonitor. No sidecar required.

  Decide and document. Recommendation: option 4 (exporters for prod, skip dev) +
  option 5 for GitLab (free win).

- [ ] 5.5.3.17 Implement database monitoring for production databases
  At minimum: ghost-prod/mysql, invoicetron-prod/postgres, atuin/postgres.
  GitLab/postgresql via existing metrics service (no sidecar - covered in 5.5.3.11).

  **Prerequisites per database (do before adding sidecars):**
  1. **Take Longhorn snapshot** of each database PVC before modifying StatefulSets.
     Adding a sidecar container triggers a rolling restart of the StatefulSet pod.
  2. **Update CiliumNPs** to allow monitoring namespace on exporter ports:
     - ghost-prod: add monitoring -> ghost-mysql pod port 9104 (mysql-exporter)
     - invoicetron-prod: add monitoring -> invoicetron-db pod port 9187 (postgres-exporter)
     - atuin: add monitoring -> postgres pod port 9187 (postgres-exporter)
     Current CiliumNPs in these namespaces only allow app-to-db and backup-to-db traffic.
  3. Create ServiceMonitors for each exporter sidecar after the pods are running.

### C4: Grafana Dashboards (Critical + High Priority)

> Follow project convention: Pod Status row -> Network Traffic row -> Resource Usage row.
> Descriptions on every panel and row. ConfigMap with `grafana_dashboard: "1"` label,
> `grafana_folder: "Homelab"` annotation.

- [ ] 5.5.3.18 Create dashboard: cert-manager (certificate status, renewal rate, webhook latency)
  Metrics available from existing ServiceMonitor.

- [ ] 5.5.3.19 Create dashboard: external-secrets (sync status, error rate, webhook latency)
  Metrics available from 3 existing Helm-created ServiceMonitors.

- [ ] 5.5.3.20 Create dashboard: velero + garage (backup status, S3 storage, schedule health)
  Metrics available from 2 recently-added ServiceMonitors.

- [ ] 5.5.3.21 Create dashboard: GitLab (web requests, Sidekiq jobs, Gitaly, registry, Postgres)
  Depends on C2 task 5.5.3.11 (ServiceMonitor must exist first).

- [ ] 5.5.3.22 Create dashboard: ghost-prod (MySQL connections, request rate, memory)
  Depends on C3 (database exporter for MySQL metrics).

- [ ] 5.5.3.23 Create dashboard: invoicetron-prod (PostgreSQL connections, app health)
  Depends on C3 (database exporter for PostgreSQL metrics).

- [ ] 5.5.3.24 Create dashboard: home (AdGuard DNS queries, MySpeed results)
  AdGuard has DNS probe metrics. MySpeed may need a metrics endpoint check.

- [ ] 5.5.3.25 Create dashboard: uptime-kuma (monitor status, response times)
  Only kube-state-metrics available unless Uptime Kuma exposes Prometheus metrics.

> Skip dashboards for: dev/staging namespaces, browser, nfd, intel-device-plugins,
> gitlab-runner, cloudflare (low value, high effort).
> cloudflare has a ServiceMonitor but 1 deployment (cloudflared) - existing alerts suffice.

### C5: Fix Existing Dashboard Quality Issues

> Note: Dashboard label/JSON standardization (uid, timezone, data keys) is done in Phase S.
> This section covers content quality issues only.

- [ ] 5.5.3.26 Fix arr-stack dashboard: add dashed request/limit lines to CPU/Memory panels

- [ ] 5.5.3.27 Fix claude-code dashboard content quality
  - Add descriptions to all 17 panels (currently 5/17)
  - Add descriptions to all 8 rows (currently 0/8)
  (Label fixes done in Phase S task 5.5.S.11)

- [ ] 5.5.3.28 Fix tailscale dashboard: add description to Pod Status row

- [ ] 5.5.3.29 Evaluate ups dashboard improvements
  Community-imported dashboard (gnetId: 19308) - 0/15 panels described.
  Decision: either add descriptions or accept as-is (community import, low priority).

### C6: Verify Remaining Alert Metric Accuracy

> Note: The 4 confirmed broken alerts are fixed in Phase A0. The metric name inconsistency
> and annotation standardization are handled in Phase S. This section covers residual
> verification of alerts not yet confirmed broken but at risk.

- [ ] 5.5.3.30 Verify OTel push metric alerts
  - `DotctlCollectionStale` / `DotctlDriftDetected` - OTel push metrics, only exist when
    Aurora DX machine is running. Uses `absent_over_time()` which may not handle OTel
    Collector restarts correctly (in-memory metrics lost).
  - `ClaudeCodeNoActivity` / `ClaudeCodeHighDailySpend` - same OTel push caveat.
  - `OTelCollectorDown` - verify `up{job="otel-collector"}` populates.

- [ ] 5.5.3.31 Verify backup/storage metric alerts
  - `LonghornBackupFailed` uses `longhorn_backup_state` - verify this metric populates
    (may require an active backup to create the time series).
  - `VaultHighLatency` uses `vault_core_handle_request{quantile="0.5"}` - verify
    summary metric quantiles are being exported.
  - `GarageDown` (new from C2) - verify `up{job="garage"}` populates from Garage SM.

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
  Minor release - medium risk. Release notes: https://github.com/prometheus/prometheus/releases
  **Explicit steps (RWO PVC gotcha - `upgrade-prometheus.sh` does NOT handle this):**
  1. `kubectl-admin scale deployment/prometheus-grafana -n monitoring --replicas=0`
  2. Wait for Grafana pod to fully terminate (verify with `kubectl-admin get pods -n monitoring`)
  3. Update chart version in `scripts/monitoring/upgrade-prometheus.sh`
  4. Run `./scripts/monitoring/upgrade-prometheus.sh`
  5. `kubectl-admin scale deployment/prometheus-grafana -n monitoring --replicas=1`
  6. Verify: all alerts evaluating, dashboards loading, Alertmanager routing
  > Note: Phase S Helm upgrade does NOT need Grafana scale-down (config-only change,
  > Grafana pod is unaffected by Alertmanager config changes).

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
  **Method:** Direct image edit, NOT `kubeadm upgrade apply` (kubeadm would bump k8s version
  which is out of scope - k8s stays at 1.35.0). The CoreDNS deployment has been directly
  edited before (revision 3). Use:
  ```bash
  kubectl-admin set image deployment/coredns -n kube-system \
    coredns=registry.k8s.io/coredns/coredns:v1.14.2
  ```
  Verify: `nslookup kubernetes.default.svc.cluster.local` from a pod.

---

## 5.5.5 Application Version Updates (Phase E)

- [ ] 5.5.5.1 Update Ghost 6.14.0 -> latest 6.x
  Release notes: https://github.com/TryGhost/Ghost/releases
  Check for database migration requirements.

- [ ] 5.5.5.2 Update Ollama 0.15.6 -> latest
  Release notes: https://github.com/ollama/ollama/releases

- [ ] 5.5.5.3 Update MeiliSearch v1.13.3 -> latest
  Release notes: https://github.com/meilisearch/meilisearch/releases
  **WARNING: This is a 26-minor-version jump (v1.13 -> v1.39). NOT a simple image swap.**
  MeiliSearch requires dump export before upgrade and reimport after for cross-minor upgrades.
  Procedure:
  1. Create a dump: `curl -X POST http://meilisearch.karakeep.svc:7700/dumps`
  2. Wait for dump completion
  3. Take Longhorn snapshot of MeiliSearch PVC
  4. Update image tag in manifest
  5. Apply - MeiliSearch starts with the new version
  6. Import the dump if needed (check MeiliSearch migration docs per version)
  7. Verify Karakeep search functionality works
  **Karakeep search will be broken during this window.** Schedule during low-usage period.
  Check release notes for EACH minor version for breaking changes in the API.

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

### Phase A0 - Bug Fixes
- [ ] ClusterJanitorFailing uses `kube_job_status_failed` (verified in Prometheus)
- [ ] PodStuckInInit CrashLoopBackOff branch uses `_waiting_reason` metric
- [ ] AlloyHighMemory uses `kube_pod_container_resource_limits` (not removed cAdvisor metric)
- [ ] NVMe alert annotations show correct node/pod identification
- [ ] audit-alerts.yaml moved to disabled/
- [ ] Orphan ups-monitoring.json deleted
- [ ] All 7 fixes verified against live Prometheus - no new broken alerts

### Phase S - Standardization
- [ ] 11 runbook markdown files created in docs/runbooks/
- [ ] Runbook URLs use `github.com/rommelporras/homelab` (NOT gitlab)
- [ ] 4 alert names renamed (AdGuardDNSDown, VersionCheckerImageOutdated, VersionCheckerKubeOutdated, OllamaHighMemory)
- [ ] All 96 alerts have summary + description + runbook_url annotations
- [ ] No alerts use the old `runbook:` key (all converted to `runbook_url:`)
- [ ] Discord message template renders `runbook_url` (added to all 3 receivers)
- [ ] 2 PrometheusRules have `app.kubernetes.io/part-of` label
- [ ] All 14 Probes have `release: prometheus` label
- [ ] 2 dashboard ConfigMaps have `app.kubernetes.io/name: grafana` label
- [ ] Group names standardized (no `.rules` suffix)
- [ ] version-checker dashboard uid is `version-checker`, timezone is `Asia/Manila`
- [ ] Alertmanager routing verified after renames (Velero/Backup/CronJob/Garage in #infra)
- [ ] All dashboards load in Grafana after changes

### Phase A - Alerting & Version Signal
- [ ] Alertmanager routes Velero/Backup/ResourceQuota/CronJob/Garage alerts to #infra
- [ ] version-checker signal clean (no false positives firing)
- [ ] Grafana version-checker false positive confirmed or denied
- [ ] Weekly Discord digest includes both Helm chart AND container image drift
- [ ] Discord digest includes release notes links and bump type classification

### Phase B - Operations
- [ ] Evicted pod handling verified (caught by existing cleanup or new task added)
- [ ] Old ReplicaSet cleanup evaluated and documented
- [ ] Janitor Discord messages include context (namespace/name, CronJob owner)
- [ ] Backup health dashboard deployed and showing all backup systems

### Phase C - Monitoring Coverage
- [ ] CiliumNPs updated for homepage, myspeed, cert-manager webhook, ESO webhook
- [ ] Blackbox exporter TLS module added (or non-TLS probe ports chosen)
- [ ] Prowlarr, Sonarr, Radarr have blackbox probes
- [ ] homepage, myspeed have blackbox probes (verified probe_success=1)
- [ ] cert-manager webhook, external-secrets webhook have probes
- [ ] Garage has health probe AND `GarageDown` alert in backup-alerts.yaml
- [ ] GitLab has ServiceMonitors for gitlab-exporter + postgresql-metrics + redis-metrics
- [ ] Database CiliumNPs updated before adding exporter sidecars
- [ ] Longhorn snapshots taken before StatefulSet sidecar additions
- [ ] All production databases monitored (exporter sidecars or equivalent)
- [ ] 8 new dashboards created (cert-manager, ESO, velero, GitLab, ghost, invoicetron, home, uptime-kuma)
- [ ] Dashboard quality issues fixed (arr-stack limits, claude-code descriptions, etc.)
- [ ] All alert expressions verified against actual Prometheus metrics

### Phase D/E - Version Updates
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
