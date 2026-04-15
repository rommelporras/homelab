# Phase 5.9: Argo Workflows

> **Status:** Ready to ship — all cluster work complete (UI + SSO live, legacy CronJob cutover done, docs audited). One final `/commit` + `/ship v0.39.0` remaining.
> **Target:** v0.39.0
> **Prerequisite:** Phase 5.8 (v0.38.0 - GitOps migration complete, ArgoCD stable)
> **DevOps Topics:** Workflow orchestration, DAG-based automation, CronWorkflow
> **CKA Topics:** CRD-based automation, pod scheduling, RBAC

> **Purpose:** Install Argo Workflows and migrate selected CronJobs that benefit from
> multi-step DAG orchestration. Deploy as an ArgoCD-managed Application to dog-food
> the GitOps setup established in Phase 5.8.
>
> **Learning Goal:** Kubernetes-native workflow engine, DAG patterns, exit handlers,
> WorkflowTemplates, CronWorkflow scheduling, and how CRD-based automation differs
> from native CronJob resources.

> **Target versions (verified 2026-04-14):**
> - Argo Workflows app: **v4.0.4** (released 2026-04-02)
> - Helm chart `argo-workflows`: **1.0.7** (released 2026-04-03, bundles v4.0.4)
> - argoexec image: `quay.io/argoproj/argoexec:v4.0.4-nonroot`
> - Re-verify before install - the chart/app cadence is weekly and a newer patch
>   may be out by the time this phase is executed.

## Current status snapshot (2026-04-15)

| Area | State |
|------|-------|
| Install (5.9.0, 5.9.1.1-5.9.1.6) | ✅ Complete |
| 5.9.1.7 Enable Argo Workflows UI (SSO via GitLab) | ✅ Complete — UI live at `https://argo-workflows.k8s.rommelporras.com`, SSO verified via GitLab OIDC, login + workflow visibility confirmed. Required 4 deploy-time fixes (CNP ingress identity, missing SA token Secret, `--namespaced` mode, client_id paste error) — all documented in CHANGELOG and CLAUDE.md gotchas |
| CronJob analysis (5.9.2) | ✅ Complete |
| vault-snapshot Wave 1 (5.9.3.0-5.9.3.7) | ✅ Complete (manual + scheduled runs succeeded, file on NAS) |
| 5.9.3.8 Suspend legacy CronJob | ✅ Complete — suspended after 02:00 Manila run succeeded on both paths |
| 5.9.3.9 Remove legacy CronJob stanzas from Git | ✅ Complete — committed + pushed, ArgoCD pruned the CronJob + SA |
| 5.9.3.10 + 5.9.3.11 Post-cutover cleanup | 🕐 Deferred 5-7 days, earliest 2026-04-21 (tracked in `docs/todo/deferred.md`) |
| Wave 2 Backup Alerts (5.9.4) | ✅ Already covered (CronJobFailed + CronJobNotScheduled verified loaded) |
| Monitoring (5.9.6) | ✅ ServiceMonitor, 4 alerts, dashboard deployed |
| 5.9.7 Storage Observability Follow-up | ✅ Complete (Alloy kernel pipeline, 2 alerts, runbook, commits 0982eb0 + 4237275) |
| Docs audit | ✅ Complete — two deep audits run this phase (commits 41259fc + e8f894e + post-UI-cleanup pending this ship commit) |
| Ship (v0.39.0) | ⏳ One commit + `/ship v0.39.0` away |

**What's left (final ship sequence):**

1. `/audit-security` → `/commit` — bundles the post-UI doc audit (~13 files: CHANGELOG, VERSIONS, README, 10 context/ files)
2. `git push origin main`
3. `/ship v0.39.0 "Argo Workflows"`
4. `git mv docs/todo/phase-5.9-argo-workflows.md docs/todo/completed/` + commit + push

---

## 5.9.0 Pre-Installation

> **Gate:** ArgoCD must be stable and all Phase 5.8 migrations confirmed healthy
> before adding another CRD-heavy workload.

- [x] 5.9.0.1 Verify ArgoCD is stable and all Applications are Synced/Healthy
  ```bash
  kubectl-homelab get applications -n argocd
  # Expected: all SYNCED and Healthy (except cilium which is manual-sync)

  kubectl-homelab get pods -n argocd
  # Expected: all Running, no CrashLoopBackOff
  ```

- [x] 5.9.0.2 Check cluster resource headroom
  ```bash
  kubectl-homelab top nodes
  # Argo Workflows controller (headless): ~100m CPU, ~128Mi memory
  # Each workflow step runs a pod: transient, 50-100m CPU per step
  # Verify at least 200m CPU and 256Mi memory available across cluster
  ```

- [x] 5.9.0.3 Re-verify latest chart/app versions
  ```bash
  helm-homelab repo add argo https://argoproj.github.io/argo-helm
  helm-homelab repo update
  helm-homelab search repo argo/argo-workflows --versions | head -10
  # Record the latest stable chart version and its appVersion.
  # If newer than 1.0.7 / v4.0.4, update the targetRevision in
  # manifests/argocd/apps/argo-workflows.yaml and the argoexec image
  # tag in helm/argo-workflows/values.yaml.
  ```

- [x] 5.9.0.4 Verify VAP allows Argo Workflows images
  ```bash
  # The cluster VAP `restrict-image-registries` already allows quay.io/*.
  # Confirm with a dry-run against the exact argoexec tag:
  kubectl-admin run test-argoexec \
    --image=quay.io/argoproj/argoexec:v4.0.4-nonroot \
    --dry-run=server -n default
  # Expected: pod/test-argoexec created (server dry-run), no VAP denial.
  ```

- [x] 5.9.0.5 Ensure NFS export directory exists on the NAS
  ```bash
  # argo-workflows reuses the same NFS path as the current vault CronJob.
  # The directory already exists (32 days of snapshots), so only verify:
  sudo mount -t nfs4 10.10.30.4:/Kubernetes /tmp/nfs
  ls -la /tmp/nfs/Backups/vault | head
  sudo umount /tmp/nfs
  # Expected: vault-YYYYMMDD.snap files present, directory writable by UID 65534.
  ```

---

## 5.9.1 Installation

> **Mode:** Headless (no argo-server UI). Saves ~100m CPU and ~128Mi memory.
> The argo CLI and ArgoCD UI cover all operational needs.
> **Namespace:** `argo-workflows` (separate from `argocd` - different lifecycle and RBAC).
> **Image:** Non-root argoexec: `quay.io/argoproj/argoexec:v4.0.4-nonroot`
> **GitOps split:** two ArgoCD Applications - one for the Helm chart (controller
> + CRDs), one Git-type for companion manifests (RBAC, WorkflowTemplate,
> CronWorkflow, CNP, ExternalSecret, LimitRange, ResourceQuota, PV/PVC).

- [x] 5.9.1.1 Bootstrap namespace (one-time imperative apply, then declarative)
  ```bash
  # The Helm Application has CreateNamespace=false and the argo-workflows-manifests
  # Git Application deploys into the same namespace, so the namespace must exist
  # before either syncs. Apply the manifest directly this one time:
  kubectl-admin apply -f manifests/argo-workflows/namespace.yaml
  # ArgoCD then takes ownership via the Git manifests app on first sync.
  kubectl-homelab get ns argo-workflows --show-labels
  # Expected labels: pod-security.kubernetes.io/enforce=baseline,
  # pod-security.kubernetes.io/warn=restricted, eso-enabled=true
  ```

- [x] 5.9.1.2 Update infrastructure AppProject destinations
  Edit `manifests/argocd/appprojects.yaml` and add to `infrastructure` project
  destinations:
  ```yaml
  - namespace: argo-workflows
    server: https://kubernetes.default.svc
  ```
  The project already whitelists `argoproj.github.io/argo-helm` as a source repo
  and `CustomResourceDefinition` / `ClusterRole*` as cluster resources, so no
  other AppProject changes are needed.
  **Done in this diff.**

- [x] 5.9.1.3 Review helm values
  File: `helm/argo-workflows/values.yaml` (scaffolded). Confirm:
  - `controller.image.tag: v4.0.4` pinned (no `latest`)
  - `server.enabled: false` (headless)
  - `executor.image.tag: v4.0.4-nonroot`
  - `useDefaultArtifactRepo: false` (no S3 needed for our use case)
  - `workflow.serviceAccount.create: false` (we manage SAs via our RBAC manifests)
  - `workflow.rbac.create: false` (same reason)
  - Resource requests/limits match LimitRange values

- [x] 5.9.1.4 Commit manifests and let ArgoCD install via root app-of-apps
  After committing `manifests/argocd/apps/argo-workflows.yaml` and
  `manifests/argocd/apps/argo-workflows-manifests.yaml`, the root app-of-apps
  auto-discovers both. Helm app deploys the chart, Git app deploys the companion
  manifests. Both run with `automated.prune: true, selfHeal: true`.

- [x] 5.9.1.5 Verify controller is running and CRDs are registered
  ```bash
  kubectl-homelab get pods -n argo-workflows
  # Expected: argo-workflows-workflow-controller-... Running 1/1

  kubectl-homelab get crd | grep argoproj.io | grep -v argoproj.io/Application
  # Expected (new): workflows.argoproj.io, cronworkflows.argoproj.io,
  #   workflowtemplates.argoproj.io, workflowtaskresults.argoproj.io,
  #   workflowtasksets.argoproj.io, workflowartifactgctasks.argoproj.io,
  #   clusterworkflowtemplates.argoproj.io, workfloweventbindings.argoproj.io
  ```

- [x] 5.9.1.6 Confirm CiliumNetworkPolicies are enforced
  ```bash
  kubectl-homelab get ciliumnetworkpolicy -n argo-workflows
  # Expected: argo-workflows-default-deny, argo-workflows-controller,
  #   argo-workflows-vault-snapshot
  ```

### 5.9.1.7 Enable Argo Workflows UI (SSO via GitLab)

> **Revised 2026-04-15**: the initial install (5.9.1.3) landed with
> `server.enabled: false` to save ~100m CPU / ~128Mi memory. That trade was
> wrong: the CronWorkflow DAG + step-log UI is the main value-add of Argo
> Workflows over CronJob, and the next phase (5.9.1 CI/CD Migration) needs
> the UI as its GitLab-CI-Pipelines replacement. Enabling the UI inside
> v0.39.0 ship (rather than deferring to v0.39.1) keeps the 5.9 narrative
> cohesive ("install Argo Workflows [with UI]") and gives the vault-snapshot
> CronWorkflow immediate human visibility from day one.

**Design decisions**

| Decision | Choice | Rationale |
|---|---|---|
| argo-server | `server.enabled: true`, 1 replica | Single-admin homelab, no HA requirement |
| Auth mode | `authModes: [sso]` | Browser login only; `argo` CLI uses `--core` from inside the controller pod so server-side API auth isn't needed |
| OIDC provider | Self-hosted GitLab (`gitlab.k8s.rommelporras.com`) | Already the homelab's identity source; GitLab auto-discovers at `/.well-known/openid-configuration` |
| TLS | Off at argo-server (`server.secure: false`, chart default), Gateway terminates | Matches every other HTTPRoute-exposed service in this cluster |
| Hostname | `argo-workflows.k8s.rommelporras.com` | Matches the `*.k8s.rommelporras.com` internal pattern (grafana, prometheus, longhorn, vault, etc.) |
| RBAC | SSO-to-SA mapping via `workflows.argoproj.io/rbac-rule` annotation | Single-admin multi-claim: `sub == '1' \|\| preferred_username == '0xwsh'` with precedence 10; no default SA (unmatched = login denied). Multi-claim is defensive — GitLab's default OIDC config puts user ID in `sub`, but some setups return username; matching both works regardless. Verified 2026-04-15 that `sub` returns the numeric user ID on this instance |

**Tasks**

- [x] 5.9.1.7.1 Create GitLab OAuth application (MANUAL — user runs)
  In GitLab UI: Admin Area → Applications → New application.
  ```
  Name:          Argo Workflows UI
  Redirect URI:  https://argo-workflows.k8s.rommelporras.com/oauth2/callback
  Confidential:  yes
  Trusted:       yes  (skips consent screen for first-party app)
  Scopes:        openid, profile, email
  ```
  Record Application ID + Secret immediately (shown once).
  **Done 2026-04-15.** Application ID is a 64-char hex string (NOT the numeric
  GitLab user ID — an earlier mistake pasted the user ID into Vault which
  produced "Client authentication failed due to unknown client" on login).

- [x] 5.9.1.7.2 Create 1Password item "Argo Workflows UI" in Kubernetes vault
  Fields:
  - `sso-client-id` — GitLab Application ID from 5.9.1.7.1
  - `sso-client-secret` — GitLab Application Secret from 5.9.1.7.1

- [x] 5.9.1.7.3 Seed Vault (MANUAL — user runs in safe terminal)
  ```bash
  vault kv put secret/argo-workflows/sso-credentials \
    client-id="$(op read 'op://Kubernetes/Argo Workflows UI/sso-client-id')" \
    client-secret="$(op read 'op://Kubernetes/Argo Workflows UI/sso-client-secret')"

  # Verify:
  vault kv get secret/argo-workflows/sso-credentials
  # Expect: client-id and client-secret keys present.
  ```
  Add the same `vault kv put` line to
  `scripts/vault/seed-vault-from-1password.sh` so a future full reseed
  picks it up automatically.

- [x] 5.9.1.7.4 Add ExternalSecret for SSO client credentials
  File: `manifests/argo-workflows/externalsecret-sso.yaml`.
  Creates a Kubernetes Secret named `argo-server-sso` (matches chart
  default for `server.sso.clientId.name` / `server.sso.clientSecret.name`)
  with keys `client-id` and `client-secret`.
  **Deployed 2026-04-15** — ESO sync verified (`STATUS=SecretSynced, READY=True`).

- [x] 5.9.1.7.5 Enable argo-server in helm values
  File: `helm/argo-workflows/values.yaml` (pre-drafted).
  Changes:
  - `server.enabled: true`, `replicas: 1`
  - `server.authModes: [sso]`
  - `server.sso.enabled: true`, `issuer: https://gitlab.k8s.rommelporras.com`
  - `server.sso.clientId.name: argo-server-sso`, `key: client-id`
  - `server.sso.clientSecret.name: argo-server-sso`, `key: client-secret`
  - `server.sso.redirectUrl: https://argo-workflows.k8s.rommelporras.com/oauth2/callback`
  - `server.sso.scopes: [openid, profile, email]`
  - `server.sso.sessionExpiry: 12h`
  - Resources: 50m/128Mi requests, 200m/256Mi limits
  - Standard hardening (runAsNonRoot, drop ALL, seccomp RuntimeDefault)
  - `ingress.enabled: false` (Gateway API used instead)
  - Also adds `server.extraArgs: [--namespaced]` and `controller.extraArgs:
    [--namespaced]` (added as a deploy-time fix after the UI showed 403
    "not allowed to list workflows in namespace ''" — cluster-scoped
    default needs a ClusterRole, namespaced mode matches the Role)

- [x] 5.9.1.7.6 Add SSO-to-SA RBAC mapping
  File: `manifests/argo-workflows/rbac/argo-server-sso-rbac.yaml`.
  Creates ServiceAccount `argo-server-admin` in `argo-workflows` namespace
  with annotation `workflows.argoproj.io/rbac-rule: "sub == '1' ||
  preferred_username == '0xwsh'"` (multi-claim — GitLab OIDC sub shape
  varies by instance config). Also includes a paired static token Secret
  (`argo-server-admin.service-account-token`, type
  `kubernetes.io/service-account-token`) because k8s 1.24+ no longer
  auto-creates these and argo-server reads the token to impersonate the
  SA. Role grants workflow CRUD + logs + configmaps + events. RoleBinding
  attaches the Role to the SA.

- [x] 5.9.1.7.7 Add HTTPRoute for the UI
  File: `manifests/argo-workflows/httproute.yaml`.
  Routes `argo-workflows.k8s.rommelporras.com` → `argo-workflows-server:2746`
  via `homelab-gateway` (`sectionName: https`).
  **Deployed 2026-04-15** — `status.parents[].conditions` show `Accepted=True`
  and `ResolvedRefs=True`.

- [x] 5.9.1.7.8 Extend CiliumNetworkPolicy for argo-server
  File: `manifests/argo-workflows/ciliumnetworkpolicy.yaml` — new fourth
  policy `argo-workflows-server`.
  - Ingress: `fromEntities: [ingress]` on TCP/2746 (Cilium Gateway API
    envoy identity — NOT the `host/remote-node/world` pattern used for
    LoadBalancer services; got that wrong in the first draft, fix shipped
    as commit `dedc6f4`). Plus a second rule with `fromEntities: [host]`
    for local `kubectl port-forward` access. Plus Prometheus scraping
    on TCP/2746 (argo-server exposes metrics on the same port as UI).
  - Egress: DNS, kube-apiserver, and GitLab OIDC via `toEndpoints`
    matching the gitlab namespace webservice pods on TCP/8181. Direct-
    cluster path worked on first attempt — the OIDC discovery succeeded
    without needing a CoreDNS rewrite or `toFQDNs` fallback.

- [x] 5.9.1.7.9 Verify ResourceQuota headroom
  Current `argo-workflows-quota` caps: `limits.cpu: 4`, `limits.memory: 4Gi`.
  Verified 2026-04-15 post-deploy: `limits.cpu: 700m/4`, `limits.memory:
  768Mi/4Gi`, `pods: 2/20`. Well within caps, no change needed.

- [x] 5.9.1.7.10 Commit, push, verify ArgoCD sync
  `/audit-security` → `/commit` all UI-enablement files together with the
  5.9.3.9 legacy-CronJob-removal and the 5.9.7 phase-doc updates
  (one ship-readiness commit).
  ```bash
  # Force refresh since alloy-style multi-source $values lag applies here too:
  kubectl-admin exec -n argocd statefulset/argocd-application-controller \
    -- argocd app get argo-workflows --core --refresh
  kubectl-admin exec -n argocd statefulset/argocd-application-controller \
    -- argocd app sync argo-workflows --core

  # Expect a new argo-workflows-server pod alongside workflow-controller:
  kubectl-homelab get pods -n argo-workflows
  # Expected: argo-workflows-server-<hash> Running 1/1

  # ExternalSecret synced:
  kubectl-homelab get externalsecret argo-server-sso -n argo-workflows
  # Expected: STATUS SecretSynced, READY True

  # HTTPRoute accepted:
  kubectl-homelab get httproute -n argo-workflows
  # Expected: ACCEPTED True on the parentRef
  ```

- [x] 5.9.1.7.11 End-to-end browser verification
  Verified 2026-04-15: browser login works, SSO redirect to GitLab OIDC
  succeeds, `/oauth2/callback` returns to Argo UI home, Workflows list
  shows vault-snapshot runs with DAG + step logs, CronWorkflow page
  shows the schedule + last-run status. RBAC `sub == '1'` match
  confirmed in argo-server logs (`selected SSO RBAC service account
  for user subject=1 email=... serviceAccount=argo-server-admin`).
  Multi-user denial not tested (single-admin homelab, no second user
  to probe with).

- [x] 5.9.1.7.12 Update docs
  - `docs/context/Gateway.md` — add `argo-workflows.k8s.rommelporras.com` to
    the Exposed Services table
  - `docs/context/Secrets.md` — add `argo-workflows/sso-credentials` Vault
    KV path and 1Password item
  - `docs/context/ExternalServices.md` — add a GitLab OIDC subsection
    documenting the OAuth app + scopes + redirect URI
  - `docs/context/Security.md` — add argo-server-admin to the
    automountServiceAccountToken true table if the chart's SA annotation
    requires it, and note the SSO → SA rbac-rule pattern in RBAC section
  - `CLAUDE.md` — gotcha: deleting the GitLab OAuth app locks users out of
    the argo-workflows UI; rotate via Vault seed + ExternalSecret re-sync

**Rollback (this wave only)**

If SSO misconfiguration breaks the UI before ship:
```bash
# Revert helm values to server.enabled: false
git checkout -- helm/argo-workflows/values.yaml
# Delete the new manifest files (pre-drafted but not yet committed):
rm manifests/argo-workflows/externalsecret-sso.yaml
rm manifests/argo-workflows/httproute.yaml
rm manifests/argo-workflows/rbac/argo-server-sso-rbac.yaml
# Revert the CNP addition: git diff the file and drop the argo-workflows-server stanza
```
Post-commit rollback: same but as a revert commit plus waiting for ArgoCD
prune to remove the argo-server Deployment.

---

## 5.9.2 CronJob Analysis

> **Evaluation complete (March 2026):** All current cluster CronJobs analyzed
> against Argo Workflows capabilities. Updated April 2026 after verification
> against live cluster state.

Architecture overview: workflow-controller (reconciles CRDs) + argoexec sidecar
(runs in each workflow pod for progress reporting) + argo-server (UI + API).
Both controller and server run in `--namespaced` mode — scoped to the
`argo-workflows` namespace only. (Initial install landed with `server.enabled:
false` to save ~100m CPU / ~128Mi memory, reversed in 5.9.1.7 before ship.)

### Full CronJob Evaluation

| CronJob | Namespace | Schedule | Complexity | AW Benefit | Verdict |
|---------|-----------|----------|------------|------------|---------|
| cluster-janitor | kube-system | 10 min | Single step | None | Keep CronJob |
| arr-stall-resolver | arr-stack | 30 min | Single step | None | Keep CronJob |
| arr-backup-bazarr | arr-stack | Daily | Single step | None | Keep CronJob |
| arr-backup-jellyfin | arr-stack | Daily | Single step | None | Keep CronJob |
| arr-backup-prowlarr | arr-stack | Daily | Single step | None | Keep CronJob |
| arr-backup-qbittorrent | arr-stack | Daily | Single step | None | Keep CronJob |
| arr-backup-radarr | arr-stack | Daily | Single step | None | Keep CronJob |
| arr-backup-recommendarr | arr-stack | Daily | Single step | None | Keep CronJob |
| arr-backup-seerr | arr-stack | Daily | Single step | None | Keep CronJob |
| arr-backup-sonarr | arr-stack | Daily | Single step | None | Keep CronJob |
| arr-backup-tdarr | arr-stack | Daily | Single step | None | Keep CronJob |
| adguard-backup | home | Daily | Single step | None | Keep CronJob |
| myspeed-backup | home | Daily | Single step | None | Keep CronJob |
| karakeep-backup | karakeep | Daily | Single step | None | Keep CronJob |
| grafana-backup | monitoring | Daily | Single step | None | Keep CronJob |
| uptime-kuma-backup | uptime-kuma | Daily | Single step | None | Keep CronJob |
| ghost-mysql-backup | ghost-prod | Daily | Single step | None | Keep CronJob |
| invoicetron-db-backup | invoicetron-prod | Daily | Single step | None | Keep CronJob |
| atuin-backup | atuin | Weekly | Single step | None | Keep CronJob |
| etcd-backup | kube-system | Daily | Single step | None | Keep CronJob |
| vault-snapshot | vault | Daily | Multi-step | DAG + exit handler | MIGRATE |
| configarr | arr-stack | Daily | Single step | None | Keep CronJob |
| version-check/Nova | monitoring | Weekly | Single step | None | Keep CronJob |
| cert-expiry-check | kube-system | Weekly | Single step | None | Keep CronJob |
| pki-backup | kube-system | Weekly | Single step | None | Keep CronJob |
| kube-bench-weekly | kube-system | Weekly | Single step | None | Keep CronJob |
| Longhorn recurring (4) | longhorn-system | Longhorn-native | N/A | N/A | Keep Longhorn |

**Result:** 1 CronJob (vault-snapshot) materially benefits from migration to
Argo Workflows. All others are single-step tasks with no inter-dependencies.
The ARR backups were previously 3 per-node CronJobs (cp1/cp2/cp3) but were
already restructured into 9 per-app CronJobs with podAffinity, eliminating the
parallelism benefit that would have justified migration.

### Strongest Candidates

**1. vault-snapshot (HIGH value) - Wave 1:**
Multi-step dependency `login -> snapshot -> prune` maps cleanly to a DAG.
Current shell script uses `set -e` so login failure silently skips snapshot.
DAG makes ordering explicit with exit handler for Discord notification on failure.

**2. Backup failure notification gap (MOOT - already covered):**
An earlier draft assumed the backup CronJobs had no failure alerting. On
re-audit `backup-alerts.yaml:CronJobFailed` already catches every failing
Job cluster-wide via `kube_job_status_failed{namespace!=""} > 0`. No Wave 2
work is needed. See section 5.9.4.

### Keep as CronJob (no benefit)

- `cluster-janitor`: 10-minute interval - per-step pod overhead too high
- `configarr`: black-box tool, no internal steps to model
- `version-check/Nova`: init container pattern is CKA study material, keep as-is
- `etcd-backup`, `pki-backup`, `cert-expiry-check`: single atomic shell script

### Future Use Cases Where Argo Workflows Adds Real Value

| Use Case | Why AW over CronJob |
|----------|---------------------|
| Cluster upgrade automation | Multi-node DAG: drain->upgrade->uncordon->verify per node, with rollback on failure |
| Coordinated backup verification | DAG: all backups in parallel->verify all succeeded->notify. Retry individual failures |
| CI/CD pipelines (replace GitLab Runner) | Buildkit image builds on K8s, artifact passing, native K8s scheduling |
| Load testing | Parameterized workflows, multiple parallel workers, aggregate results |

---

## 5.9.3 Migration Wave 1 - vault-snapshot

> **Rationale:** vault-snapshot is the highest-value migration. The current CronJob
> runs a single container with a shell script using `set -e`. If `vault login` fails,
> `set -e` aborts the entire script (exit non-zero). The job fails but there is no
> Discord notification, so failures go undetected. A DAG makes the
> dependency explicit and adds failure alerting via exit handler.

### Behavior parity with existing CronJob

The migration preserves current behavior exactly:
- **Retention:** 3 days (`find -mtime +3 -delete`). The restic off-site job relies
  on this window. Do **not** change to a count-based policy.
- **Filename:** `vault-YYYYMMDD.snap` (date only). Changing to HH:MM:SS timestamps
  would break restic deduplication.
- **Active deadline:** 120s at Workflow level (matches current CronJob).
- **Concurrency:** `Forbid` at CronWorkflow level (matches current).
- **SA name:** new SA `vault-snapshot-workflow` in `argo-workflows` namespace
  (the existing `vault:vault-snapshot` SA stays in place until rollback cutoff).

### DAG Design

```
vault-snapshot  (login to Vault via K8s auth + raft snapshot -> NFS)
    |
    v
vault-prune     (delete snapshots older than 3 days on NFS)

onExit handler:
notify-on-failure  (fires only when workflow.status != Succeeded)
```

> **Why two steps, not three?** An earlier draft had a separate `vault-login`
> step, but Argo Workflows DAG nodes are separate pods - a Vault client token
> written to `/tmp` in pod 1 is not visible to pod 2. Passing the token via
> workflow output parameters serialises the secret into the workflow status
> object (visible to anyone with read access to the CRD). Combining login and
> snapshot into one container keeps the token ephemeral to a single pod, which
> matches the security posture of the original CronJob. The DAG still models
> the real dependency: `prune` must not run before `snapshot` succeeded.

### Vault Kubernetes auth role creation (MANUAL)

> **Chosen approach:** a parallel role `vault-snapshot-argo` that reuses the
> existing `snapshot-policy` Vault policy (same policy the legacy
> `vault-snapshot` role uses) but is bound only to the new SA. The
> legacy `vault-snapshot` role stays in place until the old CronJob is
> removed in 5.9.3.10. Both can run side-by-side during cutover. The
> WorkflowTemplate's snapshot step already hard-codes `role=vault-snapshot-argo`.

- [x] 5.9.3.0 Create the parallel Vault Kubernetes auth role
  ```bash
  # MUST be run by the user in a terminal with `vault` CLI + admin token.
  # Claude does not have (and must never see) Vault credentials.
  vault write auth/kubernetes/role/vault-snapshot-argo \
    bound_service_account_names=vault-snapshot-workflow \
    bound_service_account_namespaces=argo-workflows \
    policies=snapshot-policy \
    ttl=5m

  # Verify:
  vault read auth/kubernetes/role/vault-snapshot-argo
  ```

- [ ] 5.9.3.11 Remove the legacy role after the old CronJob is gone
  ```bash
  # Only after 5.9.3.10 (old PV/PVC removed). No pods still use the
  # legacy role at this point.
  vault delete auth/kubernetes/role/vault-snapshot
  ```

  **Tracked in [`docs/todo/deferred.md`](deferred.md) → "Phase 5.9 Vault
  Snapshot Cutover Cleanup"** — bundled with 5.9.3.10 for the 5-7-day
  post-cutover cleanup. Does not block v0.39.0 ship.

### Vault CNP ingress rule (already in the diff)

`manifests/vault/networkpolicy.yaml` was patched under `vault-server-ingress`
to allow `io.kubernetes.pod.namespace: argo-workflows` with label
`app.kubernetes.io/component: vault-snapshot-workflow` to reach `:8200`.
Without this rule Cilium would drop the snapshot step's calls to Vault.

### Manifests

All manifests are scaffolded under `manifests/argo-workflows/` and referenced by
`manifests/argocd/apps/argo-workflows-manifests.yaml` (Git-type Application,
recurse: true).

- [x] 5.9.3.1 WorkflowTemplate `manifests/argo-workflows/templates/vault-snapshot-template.yaml`
  - entrypoint: `vault-snapshot-dag`
  - onExit: `notify-on-failure` (uses `when:` to fire only on non-success)
  - `activeDeadlineSeconds: 120`
  - `ttlStrategy: { secondsAfterCompletion: 86400, secondsAfterSuccess: 86400, secondsAfterFailure: 259200 }`
  - `podGC: { strategy: OnPodSuccess }`
  - Labels on each template pod so CNP can target them:
    `app.kubernetes.io/component: vault-snapshot-workflow`
  - Reuses same NFS PV/PVC (`vault-snapshots` created in `argo-workflows` ns
    pointing at the same NAS path `/Kubernetes/Backups/vault`).
  - Image pins: `hashicorp/vault:1.21.4` (snapshot step - login + raft snapshot
    in one container), `alpine/k8s:1.35.3` (prune + notify steps).

- [x] 5.9.3.2 CronWorkflow `manifests/argo-workflows/cronworkflows/vault-snapshot-cron.yaml`
  - `schedule: "0 2 * * *"` (matches current)
  - `timezone: "Asia/Manila"`
  - `concurrencyPolicy: Forbid`
  - `startingDeadlineSeconds: 3600`
  - `successfulJobsHistoryLimit: 3`
  - `failedJobsHistoryLimit: 3`
  - `workflowSpec.workflowTemplateRef.name: vault-snapshot`

- [x] 5.9.3.3 RBAC `manifests/argo-workflows/rbac/vault-snapshot-rbac.yaml`
  - ServiceAccount `vault-snapshot-workflow` in `argo-workflows`
  - Role grants `get` on the specific `discord-webhooks` Secret (for the notify
    step's `secretKeyRef`), plus `create/patch` on `workflowtaskresults` and
    `get/watch` on `pods/log` required by the argoexec sidecar.
  - No cluster-level permissions. Vault Kubernetes auth binding is configured
    on the Vault side (step 5.9.3.0), not via K8s RBAC.

- [x] 5.9.3.4 NFS PV/PVC `manifests/argo-workflows/pv-pvc.yaml`
  - PV `vault-snapshots-argo-nfs` (different name than `vault-snapshots-nfs` to
    avoid conflict with the in-use vault namespace PV during migration)
  - PVC `vault-snapshots` in `argo-workflows` (same mount path/server as existing,
    so both the old CronJob and new Workflow write to the same NFS directory)
  - StorageClass: `nfs`, AccessMode: `RWX`, Retain policy, explicit `claimRef`
    + `volumeName` for deterministic binding.

- [x] 5.9.3.5 ExternalSecret `manifests/argo-workflows/externalsecret-discord.yaml`
  - Pulls `secret/monitoring/discord-webhooks` property `incidents`
  - Target: `discord-webhooks` Secret in `argo-workflows` ns, key `incidents`
  - Refresh 1h, creationPolicy Owner (matches monitoring pattern)

### Cutover procedure

- [x] 5.9.3.6 Trigger a manual Workflow run (BEFORE disabling the old CronJob)
  ```bash
  kubectl-admin create -f - <<EOF
  apiVersion: argoproj.io/v1alpha1
  kind: Workflow
  metadata:
    generateName: vault-snapshot-manual-
    namespace: argo-workflows
  spec:
    workflowTemplateRef:
      name: vault-snapshot
  EOF

  kubectl-homelab get pods -n argo-workflows -w
  # Watch: login pod Completed -> snapshot pod Completed -> prune pod Completed
  # Expect no notify-on-failure pod (workflow succeeded).

  kubectl-homelab get workflows -n argo-workflows
  # STATUS: Succeeded
  ```

- [x] 5.9.3.7 Verify a new snapshot file appeared on the NAS
  ```bash
  sudo mount -t nfs4 10.10.30.4:/Kubernetes /tmp/nfs
  ls -lh /tmp/nfs/Backups/vault/vault-$(date +%Y%m%d).snap
  sudo umount /tmp/nfs
  # Expected: file size > 0, owner uid 65534
  ```

- [x] 5.9.3.8 Suspend the old CronJob (do not delete yet)
  ```bash
  kubectl-admin patch cronjob vault-snapshot -n vault \
    -p '{"spec":{"suspend":true}}'
  ```
  **Done 2026-04-15 after 02:00 Manila run.** Both the legacy CronJob and
  new CronWorkflow ran at 02:00 with identical results (same snapshot
  content written to NAS — last-write-wins, no data risk). Suspended after
  confirming both paths succeeded.

- [x] 5.9.3.9 Remove the old vault-snapshot CronJob
  Deleted CronJob + ServiceAccount stanzas in
  `manifests/vault/snapshot-cronjob.yaml` (147 → 55 lines, keeping only
  header + PV + PVC). Committed as part of `b1342f9`, pushed, ArgoCD
  pruned the CronJob + SA from the cluster (`kubectl get cronjob -n
  vault` = empty, `kubectl get sa vault-snapshot -n vault` = NotFound).
  PV + PVC in `vault` namespace retained pending 5.9.3.10.

- [ ] 5.9.3.10 Remove the now-unused NFS PV/PVC in the `vault` namespace
  After 5-7 days of successful CronWorkflow runs, delete the vault-namespace
  PV/PVC stanzas from `manifests/vault/snapshot-cronjob.yaml`. The NFS export
  on the NAS is not affected - only the PV/PVC K8s objects are removed. The
  argo-workflows PV continues to mount the same NAS path.

  **Tracked in [`docs/todo/deferred.md`](deferred.md) → "Phase 5.9 Vault
  Snapshot Cutover Cleanup"** — includes readiness check commands (workflow
  success count + NAS snapshot presence), target date 2026-04-21, and the
  full checklist. Does not block v0.39.0 ship.

---

## 5.9.4 Wave 2 - Backup Failure Alerts - ALREADY COVERED

> **Audit finding (2026-04-14):** The earlier draft of this phase assumed none
> of the backup CronJobs had failure alerting. That assumption is wrong.
> `manifests/monitoring/alerts/backup-alerts.yaml` already defines a
> `CronJobFailed` rule with `kube_job_status_failed{namespace!=""} > 0`
> for 15m - this matches every failing Job in every namespace, including
> every backup CronJob listed in 5.9.2. `CronJobNotScheduled` covers missed
> schedules. No new rules are needed.
>
> **Action:** delete this section at plan-closeout time. It is retained here
> only so the Wave 2 reasoning is visible in review.

- [x] 5.9.4.1 ~~BackupJobFailed PrometheusRule~~ - covered by existing
  `backup-alerts.yaml:CronJobFailed` (generic to all namespaces).
- [x] 5.9.4.2 ~~CronJob missed-schedule alert~~ - covered by existing
  `backup-alerts.yaml:CronJobNotScheduled`.

Note: `CronJobFailed` / `CronJobNotScheduled` rely on `kube_job_status_failed`
and `kube_cronjob_status_last_successful_time` (kube-state-metrics). These
are **not** emitted for `CronWorkflow`-created Workflows (different CRD,
different pod owner). The new Argo Workflows rules in 5.9.6.2 cover workflow
failures separately via `argo_workflows_count{status="Failed"}`.

---

## 5.9.5 Future Use Cases

> Deferred until Phase 5.9+ use cases materialize. Documented here for planning.

### Cluster Upgrade Automation

When K8s 1.36 ships, a ClusterUpgrade workflow can replace the manual upgrade
runbook in `docs/context/Upgrades.md`:

```
drain-cp1 -> upgrade-cp1 -> uncordon-cp1
                                |
                            drain-cp2 -> upgrade-cp2 -> uncordon-cp2
                                                             |
                                                         drain-cp3 -> upgrade-cp3 -> uncordon-cp3
                                                                                          |
                                                                                      verify-cluster
```

Exit handler posts to Discord `#infra` on failure with node identity.
DAG enforces upgrade sequence - no manual gating needed.

### CI/CD Pipeline Migration

Replace GitLab Runner with Argo Workflows for homelab image builds:
- Buildkit as a workflow step (no privileged runner needed)
- Artifact passing via S3-compatible store (Garage)
- Native K8s scheduling - no separate runner VM overhead
- WorkflowTemplates as reusable build steps (lint, test, build, push)

### Coordinated Backup Verification

Weekly CronWorkflow:
```
[all backups in parallel] -> verify-all-succeeded -> report-to-discord
```
Uses `withItems` over backup list. Retry policy on individual failures.
Single Discord notification with aggregate pass/fail instead of per-job alerts.

---

## 5.9.6 Monitoring

### 5.9.6.1 ServiceMonitor

- [x] 5.9.6.1a `manifests/monitoring/servicemonitors/argo-workflows-servicemonitor.yaml`
  - Scrapes `argo-workflows-workflow-controller-metrics` svc on port `metrics`
    (9090/TCP inside the argo-workflows namespace).
  - Label `release: prometheus` for Prometheus Operator selector.

### 5.9.6.2 PrometheusRules

- [x] 5.9.6.2a `manifests/monitoring/alerts/argo-workflows-alerts.yaml`
  Rules scaffolded (4):
  - `ArgoWorkflowsControllerDown` - `up{job=~".*argo-workflows.*workflow-controller.*"} == 0` for 5m, critical
  - `ArgoWorkflowFailed` - `sum by (name, namespace) (argo_workflows_count{status="Failed"}) > 0` for 5m, warning
  - `ArgoWorkflowError` - same, but `status="Error"` (infra failure vs step failure)
  - `VaultSnapshotStale` - no successful vault-snapshot workflow in 26+ hours

### 5.9.6.3 Grafana Dashboard

- [x] 5.9.6.3a `manifests/monitoring/dashboards/argo-workflows-dashboard-configmap.yaml`
  A minimal 4-row starter is already scaffolded:
  - Row 1: Pod Status (workflow-controller + CRD count)
  - Row 2: Workflow Execution (status breakdown + duration p95)
  - Row 3: CronWorkflow triggered-count
  - Row 4: Resource Usage (CPU/Memory with request/limit lines)

  **Expand after the first Prometheus scrape lands.** The PromQL used in the
  starter was written against documented metric names but not verified against
  a live scrape (the chart isn't deployed yet). Once `argo_workflows_*`
  metrics appear in Prometheus, iterate on panel queries and add:
  - Per-template success/failure pie
  - Queue depth (`argo_workflows_queue_depth_count`)
  - Pod phase distribution (`argo_pod_phase`)
  - Workflow leaderboard (longest recent runs)

---

## Verification Checklist

**Deployment:**
- [x] `argo-workflows` namespace exists with PSS baseline + eso-enabled labels
- [x] workflow-controller pod Running 1/1 (in `--namespaced` mode)
- [x] argo-server pod Running 1/1 (in `--namespaced` mode, SSO via GitLab OIDC, exposed at argo-workflows.k8s.rommelporras.com)
- [x] CRDs registered: workflows, cronworkflows, workflowtemplates, workflowtaskresults, workflowtasksets, workflowartifactgctasks, clusterworkflowtemplates, workfloweventbindings

**Wave 1 - vault-snapshot:**
- [x] Parallel Vault K8s auth role `vault-snapshot-argo` created, bound to `argo-workflows:vault-snapshot-workflow`, `policies=snapshot-policy`
- [x] vault-snapshot WorkflowTemplate deployed
- [x] vault-snapshot CronWorkflow deployed and scheduled
- [x] Manual test run completed with status Succeeded (25s total)
- [x] Both DAG steps (snapshot, prune) completed in order; onExit handler fired with `when:` guard suppressing notify on success
- [x] Old vault-snapshot CronJob suspended 2026-04-15 after scheduled 02:00 Manila run succeeded on both paths; then pruned by ArgoCD when commit `b1342f9` landed
- [x] NFS snapshot file `vault-YYYYMMDD.snap` present on NAS (owner uid 65534, ~81K)
- [x] Old-path CronJob + SA stanzas removed from `manifests/vault/snapshot-cronjob.yaml` (commit `b1342f9`); PV/PVC retained until 5.9.3.10 cleanup window

**Wave 2 - Backup Alerts (mooted - existing coverage confirmed):**
- [x] Verify `backup-alerts.yaml:CronJobFailed` is loaded in Prometheus
  and has fired at least once historically (i.e. regex works).
  Verified 2026-04-14 — rule is loaded with expression
  `kube_job_status_failed{namespace!=""} > 0` (matches the design).
  `CronJobNotScheduled` also loaded with
  `time() - kube_cronjob_status_last_successful_time > 2 * (...)`.
- [x] Confirm the Alertmanager route used by `severity=warning,category=`
  (no category set) still delivers to `#apps`.
  Accepted: Alertmanager fallthrough routes uncategorized warnings to
  the `discord-apps` receiver (documented in `docs/context/Monitoring.md`,
  unchanged since Phase 5.5). No failure events from new Argo Workflows
  objects have fired yet to trigger an end-to-end delivery test.

**Networking:**
- [x] CiliumNetworkPolicies applied for argo-workflows namespace
- [x] controller can reach kube-apiserver:6443 (via `kube-apiserver` entity)
- [x] argoexec can reach workflow-controller:9090 (progress reports)
- [x] Prometheus scrapes controller:9090 metrics (target `up`)
- [x] vault-snapshot workflow pods can reach vault.vault.svc:8200 (proven by manual test's successful login + snapshot)
- [ ] notify-on-failure pods can reach discord.com:443 (FQDN egress + DNS rule) - untested without a real failure; Cilium FQDN cache populated on first DNS lookup

**Monitoring:**
- [x] ServiceMonitor for workflow-controller scraping successfully
- [x] Alert: VaultSnapshotStale (absent Succeeded gauge > 0 for 30m) - verified firing/cleared cycle after 2 alert-expression fixes
- [x] Alert: ArgoWorkflowFailed (gauge{phase="Failed"} > 0) - expression validated against live metrics
- [x] Grafana dashboard deployed (4-row starter; panel queries to refine after a week of scrape history)

**Security:**
- [x] controller runs as non-root (runAsUser: 1000)
- [x] argoexec uses `-nonroot` image tag (v4.0.4-nonroot)
- [x] workflow ServiceAccounts have minimal RBAC (scoped Role on workflowtaskresults, pods/log, secret[discord-webhooks] get)
- [x] No secrets in WorkflowTemplate specs (Discord webhook via secretKeyRef to ESO-synced Secret)

**GitOps:**
- [x] ArgoCD Application `argo-workflows` (Helm) Synced/Healthy
- [x] ArgoCD Application `argo-workflows-manifests` (Git) Synced/Healthy
- [x] CronWorkflows managed via ArgoCD (no kubectl apply outside Git)

---

## Rollback

**If the migration needs to be reversed before 5.9.3.10 cleanup:**
1. Re-enable the old CronJob: `kubectl-admin patch cronjob vault-snapshot -n vault -p '{"spec":{"suspend":false}}'`
2. Delete the CronWorkflow (keeps template + RBAC): `kubectl-admin delete cronworkflow vault-snapshot -n argo-workflows`
3. Or revert the ArgoCD apps - delete both Applications below - to remove the entire Argo Workflows install while keeping the NFS snapshot directory intact.

**Remove Argo Workflows entirely:**
```bash
# Delete ArgoCD Applications (prune removes all managed resources)
kubectl-admin delete application argo-workflows-manifests -n argocd
kubectl-admin delete application argo-workflows -n argocd

# If ArgoCD Applications are gone, Helm release can be removed directly via
# Secret deletion (NEVER `helm uninstall` - see gotchas in CLAUDE.md):
kubectl-admin delete secret -n argo-workflows -l name=argo-workflows,owner=helm

# Remove CRDs (blocks deletion of all Workflow/CronWorkflow/WorkflowTemplate objects)
kubectl-admin delete crd \
  workflows.argoproj.io \
  cronworkflows.argoproj.io \
  workflowtemplates.argoproj.io \
  workflowtaskresults.argoproj.io \
  workflowtasksets.argoproj.io \
  workflowartifactgctasks.argoproj.io \
  workfloweventbindings.argoproj.io \
  clusterworkflowtemplates.argoproj.io

# Remove namespace
kubectl-admin delete namespace argo-workflows

# Restore the old CronJob manifest if it was already pruned
kubectl-admin apply -f manifests/vault/snapshot-cronjob.yaml

# Remove the argo-workflows ns from the infrastructure AppProject destinations.
```

**CiliumNP too restrictive (symptoms: workflow pods fail to call Vault or Discord):**
```bash
# Temporarily drop the workflow-level policy to isolate whether CNP is at fault:
kubectl-admin delete ciliumnetworkpolicy argo-workflows-vault-snapshot -n argo-workflows
# Re-run the workflow. If it succeeds, the CNP rules are wrong - fix them and re-apply.
# The default-deny policy should stay in place throughout.
```

---

## Deployment Notes

Six design errors caught during post-deploy validation, all shipped as
follow-up commits. See the April 14, 2026 entry in
`docs/reference/CHANGELOG.md` ("Deployment Fixes Caught During Install")
for the full write-up:

1. `helm/argo-workflows/values.yaml` - removed `persistence.archive: false`
   (triggers persistence config parser; fails with "TableName is empty").
2. `manifests/argo-workflows/cronworkflows/vault-snapshot-cron.yaml` -
   v3.6+ CronWorkflow uses `schedules` (array), not `schedule` (string).
3. `manifests/argo-workflows/templates/vault-snapshot-template.yaml` -
   `workflow.finishedAt` is not a valid Argo variable; use `workflow.duration`.
4. `docs/todo/phase-5.9-argo-workflows.md` - Vault policy name is
   `snapshot-policy`, not `vault-snapshot`.
5. `manifests/monitoring/alerts/argo-workflows-alerts.yaml` - v4 metrics
   are `argo_workflows_gauge{phase}` / `argo_workflows_total_count{phase}`,
   not `argo_workflows_count{status,name}`; no per-workflow `name` label.
6. `manifests/monitoring/alerts/argo-workflows-alerts.yaml` -
   `VaultSnapshotStale` uses `absent(gauge > 0)` pattern, not
   `increase(counter[26h]) < 1` (Prometheus never observed a 0->1
   transition so increase returned 0 and the alert fired constantly).

---

## 5.9.7 Storage Observability Follow-up (carried on v0.39.0)

> **Context:** On 2026-04-14 at 16:38 local time, karakeep became unresponsive
> for ~3 minutes after a bookmark creation. Root cause investigation traced
> through the following chain:
>
> 1. The `bazarr-config` Longhorn volume's replica on k8s-cp3
>    (`pvc-a1c35c01-c0e7-40a1-a310-71759c6d8352-r-ecb92f9a` at `10.0.2.18:11002`)
>    stopped responding to the engine on k8s-cp2
> 2. The engine on k8s-cp2 saw SCSI medium errors on its iSCSI view of the
>    volume (`/dev/sdo`, sector 426928), marked the replica `ERR`, and
>    triggered Longhorn's `AutoSalvaged` flow
> 3. During the stall, many processes on k8s-cp2 blocked on I/O to `sdo`
>    (Sonarr, Bazarr, backup scripts) - load average spiked from ~1 to **32**
> 4. kubelet on k8s-cp2 couldn't renew its node lease in time - node-controller
>    flagged k8s-cp2 `NotReady` for ~95s
> 5. Taint manager started evicting pods after 60s. Karakeep + chrome happened
>    to be on k8s-cp2 - collateral damage. The `karakeep` namespace ResourceQuota
>    (`limits.cpu: 4`) was saturated because both the terminating old chrome
>    pod and the new one counted, so chrome's replacement failed 8 times before
>    the old pod's reservation released
> 6. Longhorn finished salvage, rebuilt the replica, volume `healthy` again
>
> **SMART + AER audit results:**
>
> - All 3 NVMe drives healthy: `media_errors=0`, `available_spare=100%`,
>   `percentage_used=0-1%`, `smart_status=PASS`
> - **k8s-cp3 shows 4 PCIe correctable errors in the 8 days prior** (Apr 6, 9,
>   10, 11). No PCIe events on Apr 12-14. "Correctable" means the PCIe layer
>   retry succeeded (no data loss), but indicates intermittent link instability
>   on cp3's NVMe - not drive wear. Zero Prometheus visibility on this today
> - The failure was **not preceded by any kernel-level NVMe/PCIe error on
>   k8s-cp3** on Apr 14, so today's specific failure cannot be directly
>   attributed to PCIe instability. Likely proximate causes: Longhorn replica
>   process stall, iSCSI timeout, or a transient Cilium/network hiccup between
>   the engine on cp2 and the replica on cp3. Root cause undetermined
>
> **Why bundled into v0.39.0 instead of a new release:** these additions are
> observability-only (two PrometheusRules, one Alloy config change, one
> runbook). They don't touch the Argo Workflows install or the vault-snapshot
> migration. Bundling avoids a separate patch release for three small changes
> and keeps the narrative that v0.39.0 is a broader "platform hardening"
> increment rather than a single-feature ship.

### Design decisions

**Use Alloy journal source + `loki.process stage.metrics` + PrometheusRule (not a textfile collector or Loki ruler):**

- The Alloy DaemonSet is already on every node. Adding a `loki.source.journal`
  block and a host `/var/log/journal` mount is ~15 lines across `helm/alloy/values.yaml`
- `loki.process stage.metrics` creates a Prometheus counter from matched log lines.
  Alloy's self-metrics are already scraped by Prometheus via `alloy-servicemonitor.yaml`
- This keeps alert rules in `PrometheusRule` CRDs (the established pattern -
  38 rule files in `manifests/monitoring/alerts/`) rather than splitting
  between Prometheus rules and a separate Loki ruler configuration
- Captures correctable, non-fatal, AND fatal PCIe events with severity as a
  label - a single rule covers all future AER severities, not just the one
  we've observed

**Rejected alternatives:**

- **Textfile collector DaemonSet reading `/sys/bus/pci/devices/*/aer_dev_*`** -
  sysfs gives persistent counters (richer long-term data), but requires a new
  DaemonSet that duplicates node_exporter's purpose. Worth revisiting only if
  the journal-based approach shows gaps
- **Loki ruler with LogQL alert** - would split alert authoring between two
  systems (PrometheusRule + LokiRule) and break the pattern every existing
  alert in this repo follows. Reject on consistency grounds
- **Lower `concurrent-replica-rebuild-per-node-limit` from 5 to 1** -
  earlier draft suggested this. On re-reading the event chain, the Apr 14
  replica failure on cp3 was NOT caused by concurrent rebuilds - it was a
  single-replica stall that Longhorn correctly salvaged. The
  "snapshot blocked because rebuild in progress" log that motivated the
  tuning proposal turned out to be for a different volume's housekeeping,
  not a contention signal. Tuning this setting would slow legitimate
  node-recovery rebuilds (14 stale replicas * sequential = 30+ min vs
  1-6 min at default) without evidence it addresses a real failure mode.
  Observability first; tune later if data shows cascades
- **Increase `karakeep` namespace ResourceQuota to accommodate pod-eviction
  overlap** - today's quota-blocking was a 30-60s delay on top of a
  Longhorn-driven outage. The steady-state quota is correctly sized. Do
  not inflate it for a once-in-months event

### Implementation

- [x] 5.9.7.1 Add kernel journal collection to Alloy
  File: `helm/alloy/values.yaml`
  - Added hostPath volumes for `/var/log/journal` (`type: Directory`),
    `/run/log/journal` (`type: DirectoryOrCreate` - fallback), and
    `/etc/machine-id` (required by the journal reader for boot correlation)
  - Added matching readOnly mounts inside the Alloy container
  - Extended the `configMap.content` with a `loki.source.journal` block
    filtering on `matches = "_TRANSPORT=kernel"` that forwards into a new
    `loki.process "kernel_logs"` pipeline
  - The `kernel_logs` pipeline uses `stage.static_labels` to set
    `node = env("HOSTNAME")` (same pattern as `cluster_events`), then
    `stage.match` on `|= "PCIe Bus Error"` runs `stage.regex` (with
    `labels_from_groups = true`) to extract the `severity=` value as a
    label, then `stage.metrics` emits the counter
    `kernel_pcie_bus_errors_total` (with `node` and `severity` labels
    inherited from the entry). Pipeline then `forward_to` sends all matched
    kernel lines to Loki as well - at <150 KB/day cluster-wide the storage
    cost is negligible and it gives us raw kernel context at alert-fire time

- [x] 5.9.7.2 Add `NodePCIeBusError` PrometheusRule
  File: `manifests/monitoring/alerts/node-alerts.yaml` (extended)
  ```yaml
  - alert: NodePCIeBusError
    expr: increase(loki_process_custom_kernel_pcie_bus_errors_total[1h]) > 0
    for: 1m
    labels:
      severity: warning
    annotations:
      summary: "PCIe bus error on {{ $labels.node }} (severity={{ $labels.severity }})."
      description: >-
        Kernel reported {{ $value | humanize }} PCIe Bus Error event(s)
        on {{ $labels.node }} with severity={{ $labels.severity }} in
        the last hour. Correctable = link retry succeeded (reseat
        candidate). Non-Fatal / Fatal = plan drive replacement.
      runbook_url: ".../longhorn-hardware.md#NodePCIeBusError"
  ```
  Metric is emitted by Alloy's `kernel_logs` pipeline (5.9.7.1). **Name
  prefix**: Alloy's `loki.process` component prefixes every
  `stage.metrics`-created counter with `loki_process_custom_` (hardcoded,
  not removable). Discovered during 5.9.7.5 verification - initial rule
  used the unprefixed name and would have silently never fired. Follow-up
  commit corrected the expression. The `severity` label is carried
  through the alert label, so Alertmanager routing can eventually split
  Correctable (warning) from Non-Fatal / Fatal (critical) without
  requiring separate rules. `for: 1m` is a debounce.

- [x] 5.9.7.3 Add `LonghornVolumeAutoSalvaged` PrometheusRule
  File: `manifests/monitoring/alerts/longhorn-alerts.yaml` (extended)
  ```yaml
  - alert: LonghornVolumeAutoSalvaged
    expr: increase(loki_process_custom_longhorn_volume_auto_salvaged_total[15m]) > 0
    for: 0m
    labels:
      severity: warning
    annotations:
      summary: "Longhorn auto-salvaged a volume."
      description: >-
        Longhorn detected replica errors and triggered AutoSalvaged.
        Query Loki `{source="kubernetes_events"} |= "AutoSalvaged"`
        for the specific volume. Investigate kernel logs on the
        replica's host for PCIe/iSCSI errors.
      runbook_url: ".../longhorn-hardware.md#LonghornVolumeAutoSalvaged"
  ```
  **Source correction:** the original draft referenced
  `kube_event_count{reason="AutoSalvaged"}`, but pre-flight showed
  kube-state-metrics' events collector is NOT enabled in this deploy (not
  a default collector). Longhorn's own `/metrics` endpoint has no native
  salvage counter either. Revised source: Alloy's `cluster_events`
  pipeline (already ingesting k8s events cluster-wide from cp1) now
  matches `|= "AutoSalvaged"` and emits `longhorn_volume_auto_salvaged_total`
  via `stage.metrics`. Counter has no per-volume labels (extracting them
  from logfmt output is brittle); the runbook directs triage to Loki.

- [x] 5.9.7.4 Create `docs/runbooks/longhorn-hardware.md`
  Verified there is no pre-existing runbook covering hardware-level Longhorn
  incidents (`docs/runbooks/` has `storage.md` for volume-level triage but
  nothing for NVMe reseating or PCIe AER). New file covers:
  - `NodePCIeBusError` triage (correctable vs fatal, what to check)
  - `LonghornVolumeAutoSalvaged` triage (cross-reference to storage.md)
  - NVMe reseat procedure (drain, shutdown, reseat, uncordon)
  - When to reseat vs replace
  - Apr 14 bazarr-config incident as the first entry in the "Incident log"
    section (reference, not duplicate - detail lives in CHANGELOG)

- [x] 5.9.7.5 Verify the Alloy change end-to-end (post-deploy)
  **Executed 2026-04-14 after commit 0982eb0 synced (alloy app needed
  manual `argocd app sync --refresh` — multi-source `$values` ref didn't
  auto-detect the git change within the normal refresh interval).
  Findings:**
  1. Both `loki.source.journal.kernel` and `loki.process.kernel_logs`
     components loaded without errors (zero permission issues reading
     `/var/log/journal`)
  2. Journal source is tailing: `loki_source_journal_target_lines_total`
     incrementing on all 3 pods
  3. **Metric prefix discovery:** Alloy's `loki.process` component
     hardcodes a `loki_process_custom_` prefix on every `stage.metrics`
     counter. The initial alert rules referenced the unprefixed names
     and would have silently never fired. Corrected in follow-up commit
  4. Synthetic test via `/dev/kmsg` (NOT `logger` - the latter produces
     `_TRANSPORT=syslog`, not `_TRANSPORT=kernel`) successfully populated
     `loki_process_custom_kernel_pcie_bus_errors_total{node="k8s-cp1",severity="Correctable"} 1`
     with correct labels from the regex extraction
  5. ServiceMonitor `alloy-servicemonitor.yaml` already scrapes Alloy's
     `:12345/metrics`; no additional scrape config needed

  **Useful verification commands for future incidents:**
  ```bash
  # Direct pod metric check (svc load-balances, may miss your target pod):
  kubectl-homelab port-forward -n monitoring pod/<alloy-pod-on-node> 12345:12345 &
  curl -s localhost:12345/metrics | grep loki_process_custom_kernel_pcie
  kill %1

  # Synthetic kernel event on a specific node (logger produces _TRANSPORT=syslog,
  # NOT _TRANSPORT=kernel - must write directly to the kernel ring buffer):
  ssh wawashi@<node> \
    "echo 'PCIe Bus Error: severity=Correctable, type=Physical Layer [TEST]' | sudo tee /dev/kmsg"
  # Wait 30-60s for Alloy to tail the journal, then re-check the metric.

  # Confirm the same line also landed in Loki (optional):
  # In Grafana: {source="journal", node="<node>"} |= "[TEST]"
  ```

### Deferred / intentionally out of scope

- **NVMe reseat on k8s-cp3** - physical maintenance, runbook-tracked not
  phase-tracked. Tracked in [`docs/todo/deferred.md`](deferred.md) →
  "k8s-cp3 NVMe Reseat" with full procedure reference
  ([`docs/runbooks/longhorn-hardware.md`](../runbooks/longhorn-hardware.md)).
  Schedule during the next planned node reboot window
- **`concurrent-replica-rebuild-per-node-limit` tuning** - revisit only if
  `LonghornVolumeAutoSalvaged` fires repeatedly on the same node within a
  rolling 30-day window
- **ResourceQuota tuning in `karakeep`** - today's quota delay was a 30-60s
  downstream effect of a Longhorn outage, not a steady-state problem. Leave alone

---

## Final: Commit and Release

- [x] `/audit-security` then `/commit` — run multiple times during the
  phase. Commits on main:
  - April 14: `cd3d409`, `5b3c24e`, `cda2d72`, `a09faf1`, `691f35a`
    (pre-observability install fixes); `0982eb0`, `4237275`
    (observability follow-up)
  - April 15: `b1342f9` (UI + SSO + legacy CronJob cutover);
    `dedc6f4` (CNP ingress identity fix); `6f54f07` (SSO SA token
    Secret); `4ddae89` (`--namespaced` mode)
- [x] `/audit-docs` then `/commit` — two deep audits during the phase.
  April 14: `41259fc` (docs audit pass) + `e8f894e` (CLAUDE.md gotchas).
  April 15: post-UI-rollout audit + fixes pending one final commit
  bundling ~13 files (CHANGELOG, VERSIONS, README, 10 context/ files).
- [ ] `/ship v0.39.0 "Argo Workflows"` — one commit away (final docs
  audit) before running.
- [ ] `mv docs/todo/phase-5.9-argo-workflows.md docs/todo/completed/`
