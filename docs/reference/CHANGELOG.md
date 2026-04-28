# Changelog

> Project decision history and revision tracking

---

## April 28, 2026 - Argo Events CI/CD migration (v0.39.2)

### Summary

Phase 5.9.1 Stage 2: replace GitLab CI's imperative `kubectl set image` deploy jobs with an event-driven Argo Events + Argo Workflows + ArgoCD pipeline for the two CI-managed apps (Portfolio + Invoicetron). GitLab webhooks hit per-project EventSources; Sensors branch on `body.ref` and create a Workflow in `argo-workflows` that runs the full DAG (clone, lint, type-check, test, build via BuildKit rootless, [migrate for Invoicetron], deploy via Git commit to the Kustomize overlay, verify). Stage 1 (v0.39.1) put the apps under ArgoCD management; Stage 2 closes the loop by making the image-tag commit automatic. Initial install on 2026-04-19 (`2bcce8d`); 4-day soak with iterative fixes (Apr 19-24); pre-ship cleanup audit on 2026-04-28. 75 commits total in this release window.

### Install (April 19, commit `2bcce8d`)

- **Argo Events install** - `argo-events` namespace with Helm chart 2.4.21 (controller-manager), 3-replica NATS JetStream EventBus (in-memory, event durability not critical - GitLab retries), two GitLab-type EventSources (invoicetron + portfolio) that auto-register their webhooks on GitLab via API token, one generic webhook EventSource for Portfolio staging promotion. Per-project webhook secrets (DR-4) to bound forgery blast radius.
- **Shared WorkflowTemplates** - extracted `notify-on-failure` from vault-snapshot into a standalone template (both vault-snapshot and CI workflows now `templateRef` it). Six new shared templates: `clone`, `lint`, `type-check`, `test-unit`, `test-e2e`, `build-image` (BuildKit rootless, replaces DinD), `deploy-image` (mutex + 5-attempt rebase-retry on Git push, per DR-7), `verify-health` (HTTP health check with retries). Every CI WorkflowTemplate pins `ttlStrategy: { secondsAfterSuccess: 86400, secondsAfterFailure: 604800 }` per DR-8.
- **Per-project pipelines** - `portfolio-pipeline` (clone → lint/type-check/unit/e2e parallel → build → deploy → verify), `invoicetron-pipeline` (no E2E, but has `migrate` step running `bunx prisma migrate deploy` against the env DB), `portfolio-staging-promote` (accepts `source_sha`, skips build, just deploy + verify - triggered by a GitLab manual job that POSTs to `/staging-promote`).
- **Git-based image promotion (DR-1)** - deploy step commits `newTag` into the Kustomize overlay via a scoped SSH deploy key (`rommelporras/homelab` only, DR-5). Author "Argo CI Bot <ci-bot@k8s.rommelporras.com>", message `chore(ci): update <project>/<env> image to <sha> [skip ci]`, `--signoff` for DCO audit trail. ArgoCD syncs the overlay within ~3 min.
- **Concurrency guard** - `synchronization.mutex: deploy-image-lock` at the `deploy-image` template level serialises all deploy steps cluster-wide. Inside the step, 5-attempt retry loop with `git pull --rebase` handles external writes (human committing to main during a deploy).
- **Cross-namespace RBAC** - `argo-events-sa` in `argo-events` binds a Role in `argo-workflows` granting `create workflows` (RoleBinding cross-namespace pattern - no ClusterRole needed). `ci-workflow-sa` in argo-workflows gets `get` on the four Secrets each pipeline uses (discord-webhooks, gitlab-registry, github-deploy-key, invoicetron-migrate-db-urls).
- **Network policies** - default-deny baseline in argo-events plus per-controller allow rules. Workflow pipeline pods labelled `app.kubernetes.io/component: ci-pipeline` get egress to GitLab (clone + registry), GitHub SSH (deploy), and HTTPS (verify). Invoicetron migrate pods labelled `app.kubernetes.io/component: invoicetron-migrate` get cross-namespace egress to the invoicetron-<env> PostgreSQL; the corresponding ingress on the invoicetron-db CNP in both overlays was updated to accept them.
- **VAP allowlist** - `mcr.microsoft.com/` added to `manifests/kube-system/image-registry-policy.yaml` for Playwright E2E.
- **LimitRange bump** - argo-workflows namespace container max memory raised from 1Gi to 2Gi for Playwright + BuildKit steps. Still under the 4Gi namespace quota ceiling.
- **Monitoring** - new PrometheusRule `argo-events-alerts.yaml` with 8 alerts (controller down, EventSource down, Sensor down, EventBus degraded, CI pipeline failed/stuck, deploy mutex held too long, webhook delivery failed). New Grafana dashboard `argo-cicd-dashboard-configmap.yaml` (5 rows: pod status, pipeline execution, webhook events, deploy mutex, resource usage). New blackbox probe `argo-events-probe.yaml` (rewritten 2026-04-28 - see Pre-Ship Audit).
- **Vault seeding** - 7 new Vault KV paths: `argo-events/gitlab-api-token`, `argo-events/invoicetron-webhook-secret`, `argo-events/portfolio-webhook-secret`, `argo-events/staging-promote-token`, `argo-workflows/gitlab-registry`, `argo-workflows/github-deploy-key`, `argo-workflows/gitlab-clone-token` (the last added during soak iteration when invoicetron's private repo clone failed without auth - commit `31966e9`). 1P item consolidation: renamed existing "Argo Workflows UI" → "Argo Workflows" (drops the now-misleading UI qualifier) and extended with new fields covering CI/CD (registry-username, registry-password, github-deploy-key) and Argo Events (gitlab-api-token + 3 webhook secrets). Rationale: Argo Events is an argoproj sibling project whose sole purpose here is triggering Argo Workflows, so all argo-* credentials are consolidated under one umbrella item.

### Soak-Window Fixes (April 19-24)

Real CI runs surfaced issues the install draft missed. 50+ follow-up commits, grouped by theme:

- **EventBus pinning (Apr 19, `bae726d` `da68905` `0a49b1e` `b048343`)** - chart default for `nats.image` was a non-existent tag; pinned NATS JetStream to `nats:2.10.10-alpine`. Dropped the `configs.jetstream.settings` string override (rejected as schema-incompatible). Bumped argo-events ResourceQuota to fit the 3-replica EventBus + Sensor fleet.
- **WorkflowTemplate v4.0.4 schema (Apr 19, `60474ad`)** - several template snippets used v3 DSL features removed in v4. Realigned per the v4 reference and CRD validation.
- **Pipeline workspace + parallelism (Apr 19, `c8a9e98` `337c289` `aa6a239` `13eff22` `27770ec` `fc40f0a` `c910e55` `4ff2c42`)** - shared workspace via `volumeClaimTemplates` (RWO with pod affinity, see below); fsGroup=1000 for write access; install-deps once before parallel lint/type-check/test-unit/test-e2e fan-out; namespace quota raised to fit the fan-out; CI pipeline HTTPS egress broadened to GitHub raw + npm registries; `verify-health` follows redirects; `app-url` hardcoded to actual HTTPRoute hostnames.
- **test-unit pinning (Apr 19, `ac08cd0` `0fdb33f` `37c0cf0`)** - portfolio test-unit pinned to `node:22-slim` (chart default was 20); npm-prefix workaround so non-root user can write to `node_modules`; install-deps memory limit raised to 2Gi.
- **BuildKit rootless tuning (Apr 19-20, `9344f29` `40f9eb1` `f5a2dc4` `48821c2` `aac5556` `a8aeecd`)** - argo-workflows namespace PSS relaxed to `privileged` (BuildKit needs `unconfined` AppArmor + UID 0 inside its userns); `allowPrivilegeEscalation: true` on build-image only; capabilities tuning; split build + push so push runs in a separate skopeo pod (rootful but tiny scope, no buildkitd state); `/var/tmp` emptyDir for skopeo's working area; CAPS/AppArmor pinned inside build-image.
- **CI pipeline egress iterations (Apr 20, `e3cabd7` `750aa57` `72f070a`)** - `host` + `remote-node` entities, then `ingress` entity for HTTPRoute-routed services. The single catch-all `ci-pipeline` CNP was eventually removed because Cilium kube-proxy-replacement rewrites HTTPRoute traffic at the syscall (CNP target was the wrong layer). Replaced with per-destination egress rules in the workflow templates.
- **deploy-image fixes (Apr 20, `dc5a64f` `9500687`)** - SSH key without trailing newline crashes OpenSSH libcrypto (`error in libcrypto`) - shell `( cat; echo )` workaround; `tar --no-same-owner` so the kustomize overlay extract doesn't try to chown to a non-existent UID.
- **Private clone auth (Apr 20, `31966e9` `90a9888`)** - invoicetron is a private GitLab project, plain `git clone` returned 403. Added `argo-workflows/gitlab-clone-token` Vault path with project-level deploy token (read_repository scope), injected via `https://oauth2:<token>@...` in the clone template. `umask 077` in the clone step needs subshell scoping or it propagates to subsequent steps and breaks file readability.
- **ArgoCD `$values` ref refresh lag (Apr 20-21, `f866986` → `443f2a5`)** - one of the smoke iterations left `argo-workflows-manifests` with auto-sync disabled to avoid fighting in-flight edits; restored after the dust settled. Documented as a CLAUDE.md gotcha (multi-source `$values` refresh lag).
- **Pod affinity on RWO PVC (Apr 21, `a3387cb`)** - parallel DAG steps with a single RWO `volumeClaimTemplate` hit `Multi-Attach error` when scheduled to different nodes. Added pod affinity at the workflow `spec` level matching `workflows.argoproj.io/workflow={{workflow.name}}` at `topologyKey: kubernetes.io/hostname`. Used `preferred` (not `required`) so the first pod isn't unschedulable. Documented as CLAUDE.md gotcha.
- **GitLab webhook egress carve-out (Apr 21, `f0bcfcf` `8bbbdc9`)** - GitLab webservice + sidekiq egress baseline blocks all RFC1918, but in-cluster webhook destinations like `argo-events.k8s.rommelporras.com` resolve to the LB VIP `10.10.30.20` ∈ `10.0.0.0/8`. Added `toEntities: [ingress]:443` AND a parallel `toEndpoints: {ns=argo-events, controller=eventsource-controller}:12000` rule (Cilium kube-proxy-replacement rewrites the LB-VIP at the syscall, so the in-cluster path goes direct to backend pod IP, never matches the 443 allow). Documented as CLAUDE.md gotcha.
- **Invoicetron Stage 2 smoke fixes (Apr 21, `40e6e9e`)** - per-template `metadata.labels` collisions with workflow-level `podMetadata.labels` made the migrate-step CNP selector miss; resolved by using a dedicated label key. Documented as CLAUDE.md gotcha (Argo Workflows v4.0.4 label override behavior).
- **Real webhook smoke runs (Apr 20-23)** - portfolio dev (`portfolio-dev-rsgw5`, then later runs `c4wl7`/`92cce83`/etc.), invoicetron dev (`2nxrl`), invoicetron prod (`jgw48`), portfolio prod via MR flow (`wtp7r` for SHA `db5f587c`). Portfolio `main` is `push_access_levels: "No one"` so direct push from operator returns `pre-receive hook declined`; resolved by glab MR-create + auto-merge. Documented as CLAUDE.md gotcha (MR-flow vs direct push asymmetry between portfolio and invoicetron `main`).
- **Staging-promote token validation (Apr 23-24, `b397e2e` `b5059cd`)** - sensor `data` filter path `headers.X-Token` failed silently because Argo Events v1.9.10 puts headers under `header.*` (singular). Then the `{{env.SECRET}}` templating in the filter `value` field doesn't actually substitute - it's compiled as a regex literal, so the token never matched. Three overlapping bugs in the v1.9.10 `data` filter pipeline. Final fix: rewrite as a `script:` filter using gopher-lua + `os.getenv` reading sensor-pod env, with the auth token in the request body (not header). Two CLAUDE.md gotchas added covering this trap.
- **Unrelated incident: AdGuard OOM (Apr 24, `15b24a3`)** - container was OOMKilled at 512Mi while a Longhorn RWO mount-deadlock kept the deployment 0/1 Available with `FailedMount` events firing every few minutes for 17h. Bumped memory limit to 1Gi; the mount-deadlock recovery (`kubectl-admin delete pod`) and OOM root-cause-vs-mount-deadlock distinction documented as a major CLAUDE.md gotcha (`a784ea0`). Same window also turned up the Cilium L2 lease pinning issue affecting AdGuard's external reachability (documented in `c2c3a44` 2026-04-28 with a long-term per-service `CiliumL2AnnouncementPolicy` plan in deferred.md).

### Credential Rotations (April 24, Phase 5.9.1 task #27)

A forensic grep of the pre-compact Claude Code transcript turned up 8 credentials whose values or hashes had passed through tool output during Phase 5.9.1 debugging. Internal-only attack surface (cluster LAN or host with WSL jsonl) so all 8 were rotated during the soak rather than blocking ship. Rotation pattern: new value created alongside old → 1Password update → `vault kv patch` → ESO force-sync → consumer pod restart → smoke verify → old value revoked. All 8 rotations completed 2026-04-24:

1. `staging-promote-token` (pre-ship, the leak was still active in this session)
2. `argo-events/invoicetron-webhook-secret` (Vault v6, EventSource redeployed, GitLab webhook id rotated 9→11)
3. `argo-workflows/github-deploy-key` (new ed25519 keypair, new GH deploy key id `149522582` alongside old `149092650`; write-path verified 2026-04-24 via `portfolio-dev-rsgw5` → CI-bot commit `0a26999` to `origin/main`)
4. `argo-workflows/gitlab-registry` (new GitLab group deploy token `argo-workflows-buildkit-2026-04-24`; write-path verified 2026-04-24 via skopeo push of image `:881f2309` to `registry.k8s.rommelporras.com`)
5. `Invoicetron Deploy Token` (clone + image-pull, one 1P item feeding two Vault paths; new project-level deploy token `k8s-ci-2026-04-24`)
6. `invoicetron-dev/app` + `invoicetron-dev/db` (new 24-byte hex Postgres password, applied via `ALTER USER invoicetron WITH PASSWORD` on `invoicetron-db-0`)
7. `invoicetron-prod/app` + `invoicetron-prod/db` (same procedure on prod namespace)
8. `ghost-dev/mysql` (root + ghost-user passwords, applied via `ALTER USER 'root'@'%'` + `ALTER USER 'ghost'@'%'` + `FLUSH PRIVILEGES`)

Cleanup of the old overlapping credentials (delete old GH deploy key id `149092650`, delete old GitLab project deploy tokens id 2 + id 3, revoke old GitLab group deploy token `argo-workflows-buildkit`) is staged as `scripts/phase-5.9.1-credential-cleanup.sh` for post-ship execution. Old keypair backup at `~/tmp/ae-rotate/` was shredded 2026-04-28.

### Pre-Ship Audit (April 28)

4-day soak window (2026-04-24 → 2026-04-28) was clean: 0 controller errors in 96h across argo-workflows + 5 sensors + 3 EventSources, 0 sensor restarts, all 56 ArgoCD apps Healthy + Synced. The audit (commits `0577a86`, `53d6440`) closed gaps surfaced by the soak:

- **Prometheus PVC resize 60Gi → 80Gi** (`helm/prometheus/values.yaml`) - was at 93% with `KubePersistentVolumeFillingUp` firing. Live PVC patched + `resize2fs` on pod restart; StatefulSet template synced via cascade-orphan delete. Required Longhorn `storage-over-provisioning-percentage` bump 100 → 150 to fit on cp3 (cp3 disk was at 311 GiB scheduled out of 325 GiB cap; bump raised cap to 488 GiB). Cluster-wide setting change, fully reversible; revert path tracked in `docs/todo/deferred.md` as gated on cp3 NVMe reseat or replica rebalance (cluster is severely imbalanced: cp1 has 10 GiB scheduled vs cp2/cp3 at ~301 GiB each).
- **Vault memory bump 256/512Mi → 384/768Mi** (`helm/vault/values.yaml`) - vault-0 OOMKilled once during soak (2026-04-25T00:31:50Z, exit 137). Steady-state usage 264 MiB was already over the old request.
- **argo-events-webhook probe rewrite** (`manifests/monitoring/probes/argo-events-probe.yaml`, `helm/blackbox-exporter/values.yaml`) - the original probe expected HTTP 2xx but EventSources return HTTP 400 to empty POST → permanent `probe_success=0`, masking any real outage. New `http_webhook_post` blackbox module accepts 2xx + 4xx (200/400/401/403/404/405); a 5xx or connection-refused now indicates a real failure. Probe targets expanded from 1 (`/gitlab/invoicetron`) to 3 (`/gitlab/invoicetron`, `/gitlab/portfolio`, `/staging-promote`) for symmetric coverage.
- **CLAUDE.md gotcha distillation** - 7 gotchas captured from soak debugging (`1c30202`, 2026-04-23): Alloy `stage.metrics` `loki_process_custom_` prefix; `/dev/kmsg` vs `logger -p kern.warn`; ArgoCD multi-source `$values` refresh lag; `kubectl-homelab logs` RBAC blocked; Cilium Gateway API HTTPRoute ingress identity (`reserved:ingress`); Argo SSO ServiceAccount static token Secret requirement; Argo server mode (`--namespaced`) must match SA RBAC scope. Plus 5 more added during soak: OOMKilled + Longhorn CSI mount-deadlock pattern (`a784ea0`), Argo Events `header.*` vs `headers.*` filter path, `{{env.X}}` templating not substituted in `data` filter values, Argo Workflows v4.0.4 `metadata.labels` override behavior, RWO PVC Multi-Attach across parallel steps, GitLab webhook egress carve-out for in-cluster destinations, Cilium kube-proxy-replacement LB-VIP syscall rewrite, cross-namespace DB consumers must use FQDN, GitLab `push_access_levels: "No one"` MR-flow requirement, Cilium L2 announcement lease pinning (post-soak, `c2c3a44`).
- **deferred.md follow-ups added** (`53d6440`) - v0.39.2 post-ship CI verification (~2026-05-12), PVC resize batch (gitlab-minio 20→40Gi, arr-data 2→3Ti remaining), revert Longhorn over-provisioning 150→100% gated on cp3 NVMe reseat.

### What Happens Next (Post-Ship)

- Run `scripts/phase-5.9.1-credential-cleanup.sh` from this WSL2 host to delete old GH deploy key + old GitLab project/group deploy tokens (write-paths verified 2026-04-24, safe to remove).
- Remove deploy stages from both projects' `.gitlab-ci.yml` (3-day soak window now satisfied).
- Archive Portfolio `kube-token-*` Vault entries (no longer used).
- Clean registry test tags `:skopeo-test*`, `:smoke-*` on `registry.k8s.rommelporras.com`.
- Resize gitlab-minio PVC 20 → 40 Gi (currently 92%) and arr-data PVC 2 → 3 Ti (currently 88%) per `docs/todo/deferred.md` "PVC resize batch".
- Revisit Longhorn over-provisioning 150 → 100 once cp3 NVMe is reseated/replaced (or replicas rebalanced off cp3).
- ~2 weeks post-ship: verify v0.39.2 had ≥1 real CI run per project per environment; induce empty-commit pushes if natural traffic was sparse.
- Consider removing the legacy `job-name: invoicetron-migrate` selector from `invoicetron-<env>/invoicetron-db-ingress` CNP once GitLab CI deploy is fully retired.

---

## April 16, 2026 - ArgoCD onboarding for Portfolio + Invoicetron (v0.39.1)

### Summary

Phase 5.9.1 Stage 1: restructure Portfolio and Invoicetron manifests from flat files into Kustomize base/ + overlays/ and onboard them to ArgoCD with auto-sync + selfHeal. GitLab CI deploy jobs flipped to `when: manual` (break-glass only). Separate fix: GitLab Runner `concurrent` capped at 4 with pod anti-affinity to prevent node OOM from simultaneous pipelines.

### Changes

- **Kustomize overlays** - `manifests/invoicetron/` restructured into `base/` (deployment, postgresql, rbac) + `overlays/{dev,prod}/` (namespace, externalsecret, networkpolicy, limitrange, resourcequota). `backup-cronjob.yaml` in prod overlay only. `manifests/portfolio/` restructured into `base/` (deployment, rbac, pdb) + `overlays/{dev,staging,prod}/`. Network policies per-overlay (dev/staging/prod differ on Cloudflare ingress rules). Image tags pinned to live-running images at cutover time - zero cluster drift on first sync.
- **5 ArgoCD Applications** - `invoicetron-dev`, `invoicetron-prod`, `portfolio-dev`, `portfolio-staging`, `portfolio-prod` in `cicd-apps` AppProject. Created with manual sync, verified zero diff (only tracking-id annotations), then enabled `syncPolicy.automated: { prune: true, selfHeal: true }`.
- **GitLab CI deploy jobs dormant** - `deploy:dev` + `deploy:prod` (invoicetron) and `deploy:development` + `deploy:production` (portfolio) flipped to `when: manual` inside `rules:` blocks. `deploy:staging` (portfolio) was already manual.
- **CLAUDE.md gotcha removed** - "Invoicetron manifest has CI/CD-managed image" no longer applies with Kustomize overlays enforcing per-env images.
- **GitLab Runner OOM fix** - `concurrent: 4` (was default 10) + pod anti-affinity (preferred, weight 100, spread by `kubernetes.io/hostname`). Two simultaneous pipelines had spawned 7 runner pods on cp2 (28Gi limit on 16Gi node), OOM-killing kubelet.

### Deployment Notes

- invoicetron-prod live deployment had strategy `RollingUpdate` (modified by CI), but manifest declares `Recreate` (ResourceQuota constraint). SSA field manager conflict required manual patch before first sync.
- ArgoCD application-controller OOMKilled repeatedly with 1Gi limit after onboarding 5 new apps (40+ total). Permanently bumped to 1Gi request / 2Gi limit in `helm/argocd/values.yaml`.
- Stage 2 (Argo Events CI/CD - v0.39.2) not started. Current deploy workflow: manually update overlay `newTag`, commit, push - ArgoCD syncs.

---

## April 15, 2026 - Argo Workflows + vault-snapshot migration + UI + storage observability (v0.39.0)

### Summary

Phase 5.9: install Argo Workflows v4.0.4 (chart 1.0.7) as a new platform component under the `argo-workflows` namespace, migrate the daily `vault-snapshot` CronJob to a CronWorkflow with a 2-step DAG (snapshot + prune) and a Discord-on-failure exit handler, and expose the argo-server UI at `argo-workflows.k8s.rommelporras.com` with SSO via self-hosted GitLab as the OIDC provider. Deployed via two ArgoCD Applications (Helm chart + Git manifests), dog-fooding the GitOps split established in Phase 5.8. Manual end-to-end test of the vault-snapshot DAG succeeded; cutover of the legacy CronJob is staged for the following night to de-risk the scheduled run. Same release bundles a storage observability follow-up (Phase 5.9.7) triggered by a k8s-cp2 `NotReady` incident the same day - see dedicated subsection below.

### Install & Migration

- **Argo Workflows v4.0.4** - controller + CRDs + argo-server UI via the official Helm chart 1.0.7. Initial install landed with `server.enabled: false` to save ~100m CPU / ~128Mi memory, but the decision was reversed inside the same release (Phase 5.9.1.7) before ship — the DAG execution + step-log UI is the main operator-visible value of Argo Workflows over plain CronJob, and the subsequent CI/CD migration phase (5.9.1) needs it as a GitLab-CI-Pipelines-page replacement. Bundling UI enablement into v0.39.0 keeps the 5.9 narrative cohesive ("install Argo Workflows [with UI]") and gives the vault-snapshot CronWorkflow human-inspectable execution history from day one.
- **argo-server UI + SSO via GitLab OIDC** - argo-server exposed at `https://argo-workflows.k8s.rommelporras.com` through an HTTPRoute on the Cilium Gateway (wildcard TLS via cert-manager). `authModes: [sso]` (no token-based API auth exposed; the `argo` CLI already runs inside the controller pod via `--core` mode). Both controller and server run with `--namespaced` — the entire install is scoped to the `argo-workflows` namespace, which matches the single-namespace reality of this homelab and lets the SSO SA use a namespace `Role` instead of a `ClusterRole`. Self-hosted GitLab serves as the OIDC provider (new OAuth application "Argo Workflows UI" in GitLab admin, scopes: openid/profile/email). OIDC client ID + secret live at Vault KV `secret/argo-workflows/sso-credentials`, synced into the cluster as the `argo-server-sso` Secret via ESO (key names `client-id` / `client-secret` match the Helm chart defaults for `server.sso.clientId.*`). RBAC: SSO-to-ServiceAccount mapping via `workflows.argoproj.io/rbac-rule` annotation — the `argo-server-admin` SA in `argo-workflows` matches by `sub == '1' || preferred_username == '0xwsh'` with precedence 10 (multi-claim rule as defense against GitLab OIDC config variance). The SA has a paired static token Secret (`argo-server-admin.service-account-token`, type `kubernetes.io/service-account-token`) because k8s 1.24+ no longer auto-creates these and argo-server reads the token for impersonation. No default SA means unmatched users get login denied rather than read-only fallthrough. CiliumNetworkPolicy `argo-workflows-server` allows Gateway→argo-server:2746 ingress via `fromEntities: [ingress]` (the Cilium Gateway API envoy identity, distinct from the `host/remote-node/world` pattern used for LoadBalancer-service ingress), plus Prometheus metrics scraping and GitLab OIDC egress. argo-server resource footprint: 50m/128Mi requests, 200m/256Mi limits — fits within the existing `argo-workflows-quota` without bumping caps.
- **Two ArgoCD Applications** - `argo-workflows` (Helm multi-source, chart 1.0.7 from `argoproj.github.io/argo-helm` + `$values` from this repo) and `argo-workflows-manifests` (Git-type, `recurse: true`). Matches the repo's existing `<name>` + `<name>-manifests` pattern (longhorn, monitoring, gitlab). Keeps chart-version bumps decoupled from in-repo manifest edits.
- **vault-snapshot WorkflowTemplate** - 2-step DAG: `snapshot` (login via K8s auth + `vault operator raft snapshot save`) -> `prune` (`find -mtime +3 -delete`). `onExit: notify-on-failure` wraps a `send-discord` step guarded by `when: "{{workflow.status}} != Succeeded"` so success runs create no notify pod. `activeDeadlineSeconds: 120`, `ttlStrategy.secondsAfterSuccess: 86400`, `podGC: OnPodSuccess`.
- **Why 2-step instead of 3** - an earlier draft separated `vault-login` as its own DAG node, but Argo Workflows DAG nodes are different pods. A Vault client token written to `/tmp` in pod 1 is not visible to pod 2, and passing it via workflow output parameters serialises the secret into the CRD `.status`. Combining login + raft snapshot in one pod keeps the token ephemeral and matches the old CronJob's security posture. The DAG still models the real dependency: `prune` must not run before `snapshot` succeeded.
- **NFS PV/PVC pattern** - new PV `vault-snapshots-argo-nfs` (distinct cluster-scoped name) and PVC `vault-snapshots` in the argo-workflows namespace, both pointing at the existing NAS path `10.10.30.4:/Kubernetes/Backups/vault`. Old CronJob PV/PVC kept in-place so both can write to the same directory during cutover - restic off-site job unaffected.
- **Vault Kubernetes auth role: parallel, not shared** - new role `vault-snapshot-argo` bound to `argo-workflows:vault-snapshot-workflow` SA with the existing `snapshot-policy`. Legacy role `vault-snapshot` stays bound to `vault:vault-snapshot` until the old CronJob is removed post-cutover. Avoids a brittle multi-SA binding during migration.
- **CiliumNetworkPolicy** - default-deny + controller policy (ingress from Prometheus on 9090, argoexec from same ns, egress to kube-apiserver + DNS) + vault-snapshot workflow policy (egress to vault-0:8200, Discord FQDN on 443, NFS 10.10.30.4:2049 defense-in-depth, apiserver for WorkflowTaskResult writes). Vault's own `vault-server-ingress` patched to accept `app.kubernetes.io/component=vault-snapshot-workflow` pods from `argo-workflows`.
- **ExternalSecret reuses `monitoring/discord-webhooks`** - the ESO `vault-backend` CSS proved broad enough to read `secret/monitoring/*` from the argo-workflows namespace; no new Vault policy needed. Only the `incidents` webhook is pulled.
- **Monitoring** - ServiceMonitor (scrape controller metrics port 9090 via the service's `metrics` port name), PrometheusRule with 4 alerts (controller down, Workflow Failed, Workflow Error, VaultSnapshotStale), and a 4-row starter Grafana dashboard. Dashboard panels use documented v4 metric names; panel queries to be refined after a week of live scrape history. New runbook at `docs/runbooks/argo-workflows.md`.

### Deployment Fixes Caught During Install

Ten design errors landed as follow-up commits during post-deploy validation — six during the initial install (April 14), four more during the UI + SSO rollout the next morning (April 15).

**April 14 — initial install / vault-snapshot migration:**

- **Helm `persistence.archive: false`** - setting this key enables the controller's persistence config parser which then fails with "TableName is empty" because no postgresql block is provided. Chart default is `persistence: {}` (empty) which is the correct way to disable archiving. Controller CrashLooped until the key was removed.
- **CronWorkflow v4 schema** - `spec.schedule` (string) was replaced by `spec.schedules` (array) in v3.6+. CRD OpenAPI validation rejected the old shape.
- **`workflow.finishedAt` is not a valid Argo variable** - spec validation failed with "failed to resolve". Use `workflow.duration` (seconds) instead; `workflow.status`, `workflow.name`, `workflow.namespace`, `workflow.failures` are the documented onExit-safe variables.
- **Vault policy name** - plan referenced `policies=vault-snapshot` but the actual policy name is `snapshot-policy` (carried over from the legacy role). A role referencing a non-existent policy silently falls back to `default`, which cannot read `sys/storage/raft/snapshot` (403). Discovered when the first real workflow hit the Vault API.
- **Alert metric names** - alerts referenced `argo_workflows_count{status,name}` from the v3 docs. v4.0.4 emits `argo_workflows_gauge{phase}` (current) and `argo_workflows_total_count{phase}` (cumulative), with no per-workflow `name` label. `absent()` always returned 1, firing `VaultSnapshotStale` as soon as Prometheus started scraping.
- **Counter increase over history Prometheus never observed** - first fix switched to `increase(argo_workflows_total_count{phase="Succeeded"}[26h]) < 1`, but Prometheus only observes the counter at value 1 (no 0->1 transition captured at controller startup), so `increase()` returns 0 for the first 26h. Final fix uses `absent(argo_workflows_gauge{phase="Succeeded"} > 0)` - paired with `ttlStrategy.secondsAfterSuccess: 86400`, a current value >= 1 means a successful workflow exists within the last 24h.

**April 15 — UI + SSO rollout:**

- **CiliumNetworkPolicy ingress identity** - initial draft used `fromEntities: [host, remote-node, world]` (the LoadBalancer-service pattern used by AdGuard DNS, GitLab SSH, OTel Collector). Cilium's Gateway API envoy traffic has identity `reserved:ingress` instead, so the envoy couldn't reach the backend and the browser got "upstream connect error ... reset reason: connection timeout" at `https://argo-workflows.k8s.rommelporras.com`. Fix: swap to `fromEntities: [ingress]` + a secondary `[host]` rule for local port-forward access. Commit `dedc6f4`. New CLAUDE.md gotcha documents the Gateway-API-vs-LoadBalancer-service identity split.
- **Wrong `client_id` in Vault KV** - initial Vault seed pasted the GitLab *user ID* (1) into `client-id` instead of the OAuth *Application ID* (64-char hex). GitLab rejected the OIDC authorize request with "Client authentication failed due to unknown client". Fix: re-seed with the correct Application ID from the GitLab admin Applications page, force-sync ESO, restart argo-server.
- **Missing ServiceAccount token Secret** - k8s 1.24+ no longer auto-creates token Secrets for ServiceAccounts. Argo Workflows' SSO flow impersonates the SA selected by `workflows.argoproj.io/rbac-rule` by reading a Secret named `<sa-name>.service-account-token`. Without it, SSO login succeeded but every API call returned 403 with `failed to get service account secret: secrets "argo-server-admin.service-account-token" not found`, and the browser showed "Failed to load version/info Error: Forbidden". Fix: explicit Secret resource of type `kubernetes.io/service-account-token` with `kubernetes.io/service-account.name` annotation — the k8s token controller auto-populates the token. Commit `6f54f07`. New CLAUDE.md gotcha for this class of issue.
- **Cluster-scoped install + namespace Role mismatch** - default Argo Workflows install is cluster-scoped, so the UI calls `GET /workflows?namespace=""` (cluster-wide list) which needs a ClusterRole. The SSO-mapped `argo-server-admin` SA only has a namespace `Role`. Browser showed "Forbidden: Permission denied, you are not allowed to list workflows in namespace """. Fix: add `--namespaced` to both `controller.extraArgs` and `server.extraArgs`. UI now scopes queries to the install namespace (matches the Role), controller only watches that namespace. Trade-off: ClusterWorkflowTemplates become unusable — verified no such resources exist and the CI/CD migration plan (Phase 5.9.1) lands all workflows in `argo-workflows` ns. Commit `4ddae89`. New CLAUDE.md gotcha for server-mode-vs-SA-RBAC-scope.

### Decisions

- **argo-server UI enabled in the same release as install** - an earlier draft of 5.9 shipped headless with "revisit later" framing. Reversed inside v0.39.0 before ship: the UI is the operator replacement for GitLab CI's Pipelines page that phase 5.9.1 (CI/CD migration) depends on, and the CronWorkflow install phase benefits from day-one DAG visibility for the vault-snapshot runs. The ~100m CPU + ~128Mi memory "savings" were never material for this cluster.
- **SSO via GitLab OIDC over token-based `server` auth** - browser login is the operator flow. argo CLI is already usable via `--core` mode from inside the controller pod (no API auth needed), so `authModes: [sso]` avoids the bearer-token rotation friction without losing CLI access.
- **GitLab OIDC over a dedicated IdP** - GitLab is already the homelab's source-of-truth identity (source repos, container registry). Reusing it as an OIDC provider avoided standing up a separate IdP (Dex, Keycloak) just for one app.
- **Single-admin SSO-to-SA mapping via `sub` match** - the `workflows.argoproj.io/rbac-rule` annotation uses `sub == '<gitlab-username>'` rather than `'group-name' in groups` for this single-admin homelab. Group-based mapping adds complexity (managing GitLab groups just for argo auth) with no benefit at n=1 user.
- **Two-app GitOps split over single-app Kustomize wrapper** - matches `longhorn` / `longhorn-manifests`, `monitoring` / `monitoring-manifests`, `gitlab` / `gitlab-manifests`. Separates upstream chart change drivers from in-repo manifest edits; independent sync state and cleaner rollback.
- **Parallel Vault role for cutover** - `vault-snapshot-argo` alongside `vault-snapshot` avoids a multi-SA binding that would have to be shrunk after cutover. Legacy role is deleted only after the old CronJob + PV/PVC are removed.
- **Dashboard written from docs, tuned later** - the starter dashboard's PromQL expressions were written against documented metric names without a live scrape. Panels to be refined once a week of actual `argo_workflows_*` metrics has accumulated.
- **Phase 5.9 originally scoped as "CI/CD Pipeline Migration"** - narrowed to "install Argo Workflows + migrate vault-snapshot". GitLab Runner replacement (Buildkit as a workflow step) deferred to Phase 5.10+.
- **Wave 2 backup-alerts work mooted** - the existing `backup-alerts.yaml:CronJobFailed` (generic `kube_job_status_failed{namespace!=""}`) already catches every backup CronJob failure. An earlier plan draft proposed a `BackupJobFailed` rule; audited away after reading the current rules.

### Storage Observability Follow-up (Phase 5.9.7, bundled on v0.39.0)

**Incident:** On 2026-04-14 at 16:38 local time, karakeep became unresponsive for ~3 minutes after a bookmark creation. Triaging the failure chain end-to-end revealed a gap in observability that the same release closes.

**Failure chain:**

1. Bazarr-config Longhorn replica on k8s-cp3 (`pvc-a1c35c01-...-r-ecb92f9a` at `10.0.2.18:11002`) stopped responding to the engine on k8s-cp2
2. The engine on k8s-cp2 saw SCSI medium errors on its iSCSI view (`/dev/sdo`, sector 426928), marked the replica `ERR`, triggered Longhorn's `AutoSalvaged` flow
3. Many processes on k8s-cp2 blocked on I/O to `sdo` during the stall - load average spiked from ~1 to **32**
4. kubelet on k8s-cp2 missed node-lease renewal; node-controller flagged k8s-cp2 `NotReady` for ~95s
5. Taint manager evicted karakeep + chrome (they happened to be on cp2). The `karakeep` namespace `ResourceQuota` was saturated during the overlap window (terminating chrome pod + replacement both counted), so chrome's replacement failed 8 times before the old pod's reservation released
6. Longhorn finished salvage, rebuilt the replica, volume `healthy` again

**Hardware audit:**

- All 3 NVMe drives clean: `media_errors=0`, `critical_warning=0`, `available_spare=100`, `percentage_used=0-1%`, `smart_status=PASS`
- **k8s-cp3 had 4 PCIe correctable errors in the 8 days prior** (Apr 6, 9, 10, 11). Zero Prometheus visibility. Correctable means the PCIe layer retry succeeded - indicates intermittent link instability, not drive wear. Today's specific Longhorn failure was NOT preceded by a kernel-level NVMe/PCIe event on Apr 14, so direct causation is unconfirmed

**Changes:**

- **Alloy kernel journal collection** - `helm/alloy/values.yaml` extended with a `loki.source.journal` block reading from `/var/log/journal` and `/run/log/journal` (new hostPath mounts). A new `loki.process "kernel_logs"` pipeline matches `PCIe Bus Error` lines and uses `stage.metrics` to emit a counter. Alloy's self-metrics are already scraped by the existing `alloy-servicemonitor.yaml`, so the counter lands in Prometheus with no new infrastructure. **Metric prefix gotcha:** Alloy's `loki.process` component hardcodes a `loki_process_custom_` prefix on every `stage.metrics`-created counter (undocumented prominently). Initial alert rules referenced the unprefixed names; end-to-end test via `/dev/kmsg` (note: `logger` produces `_TRANSPORT=syslog`, not `_TRANSPORT=kernel`, so it cannot be used to test a kernel-transport journal source) surfaced the real metric name `loki_process_custom_kernel_pcie_bus_errors_total{node,severity}`. Alerts corrected in a follow-up commit.
- **`NodePCIeBusError` PrometheusRule** - added to `manifests/monitoring/alerts/node-alerts.yaml`. Fires on any increase in `loki_process_custom_kernel_pcie_bus_errors_total` over a 1h window, with severity carried through as an alert label (so fatal/nonfatal events automatically page louder via the same rule).
- **`LonghornVolumeAutoSalvaged` PrometheusRule** - added to `manifests/monitoring/alerts/longhorn-alerts.yaml`. The initial draft assumed `kube_event_count{reason="AutoSalvaged"}` from kube-state-metrics, but pre-flight showed KSM's events collector is NOT enabled in this deploy (not a default collector) and Longhorn's own `/metrics` has no native salvage counter. Revised source: Alloy's existing `cluster_events` pipeline (already ingesting k8s events cluster-wide, cp1-only to avoid triplicates) now matches `|= "AutoSalvaged"` and emits `loki_process_custom_longhorn_volume_auto_salvaged_total` via `stage.metrics`. Counter has no per-volume labels; runbook directs triage to Loki. `for: 0m` because AutoSalvage is a discrete event, not a sustained condition.
- **New runbook** `docs/runbooks/longhorn-hardware.md` - triage procedures for both new alerts, NVMe reseat procedure for the M80q chassis, and the decision tree for reseat-vs-replace based on AER severity + SMART state. Includes the Apr 14 bazarr-config incident in the "Incident Log" section.

**Deliberately rejected:**

- **Textfile collector DaemonSet reading `/sys/bus/pci/devices/*/aer_dev_*`** - sysfs counters are richer (persistent across dmesg rotation) but adding a new DaemonSet duplicates node_exporter's job. Revisit only if the journal-based approach shows gaps.
- **Loki ruler with LogQL alerts** - would split alert authoring across two systems. Every existing alert in this repo is a `PrometheusRule`; keep the pattern.
- **Lowering `concurrent-replica-rebuild-per-node-limit` from 5 to 1** - earlier draft proposed this. On re-reading the event chain, the Apr 14 replica failure was NOT caused by concurrent rebuilds on cp3 - it was a single-replica stall Longhorn correctly salvaged. Tuning would slow legitimate node-recovery rebuilds (14 stale replicas * sequential = 30+ min vs 1-6 min at default) without evidence it prevents the actual failure mode. Observability first; tune on data.
- **Increasing `karakeep` namespace ResourceQuota** - the quota-blocking was a 30-60s delay on top of a Longhorn outage, not steady-state pressure. Don't inflate a correctly-sized quota for a once-in-months event.

**Deferred:**

- **NVMe reseat on k8s-cp3** - physical maintenance, tracked in `longhorn-hardware.md` not the phase plan. Schedule during the next planned node reboot.
- **Dashboard panel for `kernel_pcie_bus_errors_total`** - add after a week of scrape history confirms the metric cardinality stays sane.

---

## April 10, 2026 - Network Policy Fixes & Tooling (v0.38.4)

### Summary

Post-release network policy fixes: Tailscale DNS access broken since Phase 5.3 (connector pod identity not in AdGuard allow list), invoicetron dept lookup blocked (missing HTTPS egress to itsweb.ucsd.edu), and GitLab runner CI verify jobs failing (missing egress to invoicetron backends). Also fixes the `/ship` skill's git push step (always failed against bash-write-protect.sh) and allows read-only git commands through the block hook.

### Network Policy Fixes

- **Tailscale DNS broken since Phase 5.3** - connector pod forwards DNS via IP forwarding, so Cilium marks packets with the pod's identity (not `world`). AdGuard's DNS ingress only allowed `host/remote-node/world` + `10.10.0.0/16`. Added connector pod as allowed source (`tailscale.com/parent-resource-type: connector`). Root cause: remote devices got "DNS unavailable" from Tailscale; nothing resolved.
- **Invoicetron HTTPS egress to itsweb.ucsd.edu** - dept lookup feature POSTs to `itsweb.ucsd.edu`. Missing HTTPS egress in `invoicetron-prod` CiliumNetworkPolicy since service first deployed.
- **GitLab runner egress to invoicetron backends** - CI verify jobs call invoicetron API at both the Gateway VIP and direct pod IP. Missing egress rule in `gitlab-runner` namespace caused verify step failures.
- **Portfolio gitlab-deploy RBAC** - `pods/log` get verb missing from `gitlab-deploy` Role. CI deploy script's `kubectl logs` on rollout pods returned Forbidden in both dev and prod.

### Tooling

- **Git blocker hook** - original pattern `git\s+(add|commit|tag|push)` blocked read-only commands (`git tag -l`, `git log`, `git describe`). Split into separate per-command blocks; `tag` now only blocks annotated/signed creation (`-a`, `-s`) not listing.
- **`/ship` skill push step** - skill tried to run `git push` via Bash tool, which `bash-write-protect.sh` unconditionally blocks (no lock file bypass). Updated to tell user to run `! git push origin main` and `! git push origin v<VERSION>` manually, then waits for confirmation before creating GitHub release.
- **Stale `/release` references** - `block-git-operations.sh` error message for `gh release create` still said "Use /release". Updated to `/ship`.
- **Hook false positive on commit messages** - `bash-write-protect.sh` and `block-git-operations.sh` both matched `git push` anywhere in the command string, including inside heredoc commit message bodies. Changed pattern from `\bgit\s+push\b` to `(^|[;|&])\s*git\s+push\b` so only actual shell commands are blocked.

---

## April 7, 2026 - Monitoring Storage Fix & CI Pipeline Fix (v0.38.3)

### Summary

Two firing PVC alerts (Loki 91.6%, Prometheus 92.6%) and persistent GitLab CI pipeline failures (MinIO/registry timeout). Root causes: unfiltered audit logs consuming 72.5% of Loki volume, and missing CiliumNetworkPolicy rules blocking runner-to-MinIO connectivity since Phase 5.3.

### Monitoring Storage Fixes

- **API server audit policy tightened** - dropped `get`/`list` verbs from audit log on all 3 CP nodes (`level: None`). Only mutations (`create`/`update`/`patch`/`delete`) logged now. Saves ~90% of audit log disk writes, reduces NVMe wear.
- **Alloy log filtering** - added drop rules for GitLab Sidekiq INFO/DEBUG (17.7% of volume), version-checker info/debug (1.1%), and audit log get/list verbs (belt and suspenders).
- **Loki retention reduced** - 60 days -> 30 days. Post-filter ingestion ~300 MiB/day (down from 3.5 GiB/day). Steady-state ~9 GiB on 20Gi PVC.
- **Prometheus metricRelabelings** - dropped 5 high-cardinality apiserver histogram bucket metrics (~50k series, 18% of total). Kept `apiserver_request_duration_seconds_bucket` (SLI alerts) and `etcd_request_duration_seconds_bucket`.
- **Prometheus PVC expanded** - 50Gi -> 60Gi. Headroom while old high-cardinality data expires over 60-day retention.

### GitLab CI Pipeline Fix

- **Root cause** - CiliumNetworkPolicy `allow-gitlab-egress` in `gitlab-runner` namespace missing port 9000 (MinIO S3 cache). Also `allow-internet-egress` excluded `10.0.0.0/8` which includes the Gateway VIP `10.10.30.20` (registry push) and kube-vip API VIP `10.10.30.10` (deploy jobs). All missing since Phase 5.3 network policy creation.
- **Fix** - added port 9000 to `allow-gitlab-egress`, added VIPs `10.10.30.10/32` (API) + `10.10.30.20/32` (Gateway) with ports 443+6443 to internet egress, added `minio-runner-ingress` in gitlab namespace. All projects/pipelines affected.
- **`toEntities: kube-apiserver` doesn't cover kube-vip VIP** - Cilium's kube-apiserver entity matches the in-cluster service (10.96.0.1) and node IPs, but not the kube-vip VIP (10.10.30.10). Deploy jobs using `$KUBE_API_URL` (external VIP) need explicit CIDR egress.
- **Invoicetron RBAC** - `gitlab-deploy` Role missing `pods/log` get verb. CI deploy script's `kubectl logs` on failed migration pods got Forbidden. Added to both invoicetron-dev and invoicetron-prod.
- **Registry S3 redirect breaks image pulls** - GitLab registry redirects blob downloads to MinIO's in-cluster URL (`http://gitlab-minio-svc.gitlab.svc:9000/...`). Kubelet/containerd on nodes can't resolve `.svc` hostnames (nodes use systemd-resolved, not CoreDNS). Fix: `registry.storage.redirect.disable: true` in GitLab Helm values - makes registry proxy blobs instead of redirecting.
- **Deploy token credential mismatch** - Vault had username `gitlab+deploy-token-2` but GitLab UI showed `gitlab+deploy-token-1`. Corrected in Vault, ESO synced to both namespaces.
- **Migration job CiliumNP** - `invoicetron-migrate` job pods have no `app` label (only `job-name`), so existing policies blocked DNS and DB access. Added `invoicetron-migrate-egress` (DNS + DB) and updated `invoicetron-db-ingress` to allow from `job-name: invoicetron-migrate` in both dev and prod.
- **Deployment strategy** - changed invoicetron from RollingUpdate (`maxUnavailable: 0`) to Recreate. Single replica + ResourceQuota (4 CPU) can't fit old + new pod simultaneously, causing every rollout to fail with quota exceeded.

### Documentation

- **Deep audit** - 5-agent parallel verification of all docs against live cluster state. Fixed 29 stale/wrong claims across 13 files.
- Key fixes: CLAUDE.md gitlab gotcha (described old broken behavior), Upgrades.md (5 locations claiming prometheus still on Helm), Security.md ESO count (31->36), Monitoring.md (7 stale versions), README.md alert rules (127->277), _Index.md phase status.
- Phase 5.8.2 marked complete, moved to `completed/`.
- **`/release` renamed to `/ship`** - superpowers plugin registers a generic `/release` skill that shadowed the project's custom release workflow. Renamed command, updated lock file, hook, CLAUDE.md, README, SETUP, and all planned phase files. Completed phases left as historical.

### Decisions

- **Audit logs: drop get/list permanently** - never referenced for debugging in project history. Mutations are the 99% use case. Saves NVMe write wear at the source.
- **Loki 30-day retention sufficient** - with filtered logs, 30 days of mutations/errors is enough. Info-level context preserved for non-noisy apps.
- **Keep `apiserver_request_duration_seconds_bucket`** - needed for latency SLI alerts. Other apiserver histograms (`body_size`, `response_sizes`, `watch_*`) unused.

---

## April 7, 2026 - Version Maintenance & Digest Improvements (v0.38.2)

### Summary

Routine version maintenance release. Bumps metrics-server and Loki chart, migrates Loki Helm source to the grafana-community fork, improves the weekly version-check digest to filter false positives, and resolves three firing alerts (Grafana RWO deadlock, Vault stale revision, invoicetron-dev quota exceeded).

### Version Bumps

- **metrics-server** v0.8.0 -> v0.8.1 (image tag override, chart 3.13.0 hasn't released a new version yet)
- **Loki Helm chart** migrated from `ghcr.io/grafana/helm-charts` (frozen at 6.55.0) to `ghcr.io/grafana-community/helm-charts` 6.57.0 (March 2026 community fork). App version remains v3.6.7 - no chart ships 3.7.1 yet.
- **ArgoCD** 9.4.16 -> 9.4.17 (v3.3.5 -> v3.3.6, auto-synced)
- **traffic-analytics** 1.0.174 -> 1.0.175

### Version-Checker Digest Improvements

Weekly digest was reporting 13 images as outdated - 8 were false positives. Added filters:
- **longhornio/*** - stale post-upgrade engine/instance-manager pods (expanded from CSI-only filter)
- **postgres -alpine suffix** - `18-alpine` vs `18.3` is an intentional variant, not version drift
- **bitnamilegacy/*** - GitLab sub-chart managed images, not independently upgradeable
- **prometheus-config-reloader** - operator-injected sidecar, version locked to operator binary

Digest now reports 5 actionable items (down from 13). prometheus-operator stays visible so chart releases are not missed.

### Bug Fixes

- **Grafana RWO PVC multi-attach deadlock** - Helm upgrade created new pod on different node, old pod held RWO volume. Scaled deployment to 0, then back to 1.
- **Vault StatefulSet revision mismatch** - OnDelete strategy with stale `restartedAt` annotation from a previous `rollout restart`. Deleted pod to pick up new revision.
- **invoicetron-dev rollout stuck** - ResourceQuota exceeded (2 CPU limit requested, only 1.5 CPU remaining). Rolled back since new and old ReplicaSets had identical image.
- **Loki app Unknown/Unknown** - new `grafana-community` OCI URL missing from AppProject `infrastructure` sourceRepos. Added and force-synced.

### Documentation

- **VERSIONS.md** - fixed premature prometheus-operator version (v0.90.1 -> v0.89.0 actual), added Loki OCI migration note
- **README.md** - updated Cilium badge (1.19.2), ArgoCD version (v3.3.6), alert count (127), ExternalSecrets count (36), release count (64), rebuild guide count (31)

### Decisions

- **Longhorn 1.11.1 is latest stable** - version-checker flagged stale instance-manager v1.10.1 pods (normal post-upgrade artifact). No upgrade available until v1.11.2 or v1.12.0 (~May 2026).
- **Prometheus-operator v0.90.1 deferred** - no kube-prometheus-stack chart release bundles it yet. Chart 82.18.0 still ships v0.89.0.
- **bitnamilegacy images deferred** - redis, redis-exporter, postgres-exporter are GitLab sub-chart managed. Only upgradeable via GitLab chart bump.
- **MySQL 8.4 LTS stays** - MySQL 9.x major available but 8.4 is LTS, no reason to migrate.

---

## April 6, 2026 - ArgoCD Drift Recovery & OOM Detection (v0.38.1)

### Summary

Hotfix release between Phase 5.8 and Phase 5.9. Fixes three ArgoCD applications that silently drifted into Missing/Degraded/OutOfSync states and went unnoticed for 1 to 3 days, plus cert renewal, GitLab sync stability, and ArgoCD self-management cleanup. Adds cluster-wide OOMKilled detection and the /verify-sync slash command to prevent this class of bug in the future.

### Bug Fixes

**ArgoCD drift recovery (the three silently-degraded apps)**

- **gitlab app stuck Missing/OutOfSync for 36+ hours** - migrations container OOMKilled at 512Mi memory limit (Rails + bootsnap + ActiveRecord on GitLab 18.x needs ≥1.5Gi). Job's `restartPolicy: OnFailure` looped forever without ever reaching `.status.succeeded`, so ArgoCD reported Missing even though every other gitlab pod was Running. Raised `gitlab.migrations.resources.limits.memory` from 512Mi to 1536Mi, CPU limit from 500m to 1000m.
- **monitoring-manifests stuck Degraded for 17+ hours** - `version-check` CronJob referenced the `discord-version-webhook` Secret that was deleted by cd0beef without updating the consumer. Sunday schedule's Job failed with CreateContainerConfigError, was cleaned up by cluster-janitor, left the CronJob's `lastSuccessfulTime` stale and triggered ArgoCD's built-in CronJob health check. Pointed CronJob at `monitoring-discord-webhooks/apps` instead.
- **root app stuck in permanent OutOfSync drift loop** - `home-infra` Application manifest declared `directory.recurse: false` which is ArgoCD's default. API server stripped the field from the stored spec; git kept declaring it; root re-applied home-infra every reconcile with "spec.source differs". Removed the explicit default from the manifest.

**ArgoCD self-management and sync stability**

- **Cert renewal stuck for 26 hours** - cert-manager CiliumNetworkPolicy didn't allow egress to port 53 world, blocking DNS-01 propagation checks to Cloudflare authoritative nameservers (108.162.x.x, 162.159.x.x, 172.64.x.x). Three wildcard certs stuck pending past their May 3 expiry reminder.
- **ArgoCD notifications silently broken** - Helm was creating an empty `argocd-notifications-secret` via `notifications.secret.create=true`, racing with ESO and causing SharedResourceWarning plus empty webhook URL.
- **argocd-secret drift** - ESO Merge patches `admin.password` / `server.secretkey` but ArgoCD flagged them OutOfSync. Added `ignoreDifferences` on the targeted data paths.
- **Duplicated self-management Application** - `manifests/argocd/self-management.yaml` duplicated `apps/argocd.yaml`, causing root app SyncError and SharedResourceWarning. Removed the duplicate.
- **GitLab StatefulSet divisor drift** - `resourceFieldRef.divisor: '0'` is API-server-defaulted on fields not specified by the chart. Added `ignoreDifferences` with `group: apps` (without the group, the rule silently didn't match). Also removed `Replace=true` from syncOptions which was prompting delete-and-recreate of all 61 resources on every manual sync.

**Alert routing and noise**

- **VersionChecker alert batching truncated at Discord** - 161 `VersionCheckerImageOutdated` alerts batched every 4h were hitting Discord's 4096-char limit. Added dedicated `discord-versions` receiver with `group_by: [alertname]` and `repeat_interval: 24h` (one digest per day).
- **gitlab excluded from ArgocdAppOutOfSync alert** - the exclusion silenced gitlab health drift for 36+ hours during this incident. Removed `|gitlab` from the `name!~` regex. cilium stays excluded (genuine steady-state TLS cert rotation drift). 30m `for:` grace handles helm-hook cleanup transients.
- **Alertmanager routing by category label** - added `severity: warning, category: infra` match route alongside the existing alertname regex. Cleaner than hand-maintaining the regex for every new infra alert. Legacy regex stays as fallback during migration.
- **Stale test-alert PrometheusRule** - left from notification testing, removed.

### New Features (defensive)

- **Cluster-wide OOMKilled PrometheusRule** - `ContainerOOMKilled` (warning, any OOM in 10m, routed to #infra via the new category route) + `ContainerOOMKilledRepeat` (critical, 3+ OOMs in 1h, routed to discord-incidents-email). Closes the detection gap that left the GitLab migrations OOM loop invisible. Applies to every container cluster-wide, not just gitlab.
- **/verify-sync slash command** - auto-detects ArgoCD apps affected by the HEAD commit (via path mapping), triggers manual sync for manual-sync apps (gitlab), polls each target until Synced/Healthy or Failed with 10-minute timeout. Read-only except the one explicit sync trigger. Parallel polling with a summary table and next-step hints for Failed/Timeout rows.
- **oomkilled.md runbook** - triage steps for single OOMs and OOM loops, "stop the loop before fixing" procedure, homelab-specific common culprits (gitlab-migrations, karakeep, ollama, prometheus), cross-references to CLAUDE.md gotchas.

### Documentation

- **CLAUDE.md debugging gotchas (+8 entries)** - GitLab migrations memory limit, ArgoCD built-in CronJob health check, `directory.recurse: false` drift, stuck sync recovery via `terminate-op --core`, argocd CLI `--core` mode, Cilium HTTPRoute stale `status.parents`, gitlab manual-sync + alert exclusion blind spot, Secret rename grep-first workflow.
- **Phase 5.9/5.9.1/5.10 plans verified against live state** - CronJob count corrected (23 to 30 actual), ARR backup references updated (cp1/cp2/cp3 to 9 per-app), Wave 2 rewritten as Prometheus alerts, vault-snapshot auth switched from static token to K8s SA auth, 6 unpinned images added to 5.9.1 scope, portfolio preview targetPort fixed (80 not 3000), invoicetron-prod replica count fixed (1 not 2), missing eso-enabled label and AppProject whitelist tasks added to all three plans. Phase 5.8 closed.

### Decisions

- **v0.38.1 as patch release, not v0.39.0 minor** - primary content is reactive bug fixes; the new OOM alerts, category routing, and /verify-sync are defensive additions closing the gap that caused the drift. Phase 5.9 is still the next phase milestone and will get v0.39.0. First patch release in the project history.
- **Unexclude gitlab from ArgocdAppOutOfSync** - exclusion was over-corrective. The 30m `for:` grace is enough to ride through helm-hook cleanup transients without alerting on normal sync cycles. Keeping the exclusion created a 36-hour blind spot during this incident.
- **cd0beef regression fixed in the same release** - commit cd0beef removed the `discord-version-webhook` ExternalSecret but missed a consumer reference in the version-check CronJob. Net-zero across v0.38.1, but the bug existed on main for ~34 hours between cd0beef (Apr 5 01:27 UTC) and 807d9bf.
- **Category-label routing alongside legacy regex** - alertmanager migration path: add `category: infra` label to each PrometheusRule incrementally, drop the matching entry from the legacy alertname regex over time. Avoids a big-bang refactor while enabling correct routing for new alerts.

---

## April 1, 2026 - GitOps Migration (Phase 5.8)

### Session 1 - Waves 1-5 + App-of-Apps

Migrated 16 Helm releases and 27 manifest directories to ArgoCD declarative GitOps management. 43 ArgoCD Applications created via app-of-apps pattern.

- **Wave 1:** 6 simple manifest apps (ai, browser, uptime-kuma, atuin, cloudflare, tailscale)
- **Wave 2:** 11 complex manifest apps (home, arr-stack, ghost, karakeep, gateway, kube-system)
- **Wave 3:** 9 infrastructure Helm handovers (metrics-server, intel, tailscale-operator, cert-manager, external-secrets, vault, velero, longhorn, NFD)
- **Wave 4:** 4 monitoring Helm handovers (blackbox, smartctl, alloy, loki) via Secret deletion
- **Wave 5:** GitLab + GitLab Runner Helm handover
- CiliumNP simplified: FQDN rules replaced with toEntities:world for HTTPS (CDN anycast breaks per-domain rules)
- Backup CronJobs fixed: root access (PSS baseline), podAffinity (RWO scheduling), BoltDB detection (AdGuard)
- Tailscale ExternalSecret created (declarative replacement for lost --set Secret)
- GitLab registry storage Secret + SMTP username fix

### Session 2 - Self-Management + Operational Fixes

- ArgoCD self-management Helm handover via Secret deletion (8 Secrets, zero downtime)
- Only cilium and prometheus remain on direct Helm (17 releases handed over)
- Velero BSL: removed BackupStorageLocation from ArgoCD resource exclusions (was unmanaged, caused backup failures)
- Grafana backup CronJob: podAffinity + runAsUser:0 + DAC_OVERRIDE capability
- Homepage: added externalsecret.yaml to kustomization.yaml (Secret was missing)
- Tailscale: eso-enabled label + Vault seeding for operator-oauth ExternalSecret
- GitLab: reverted to manual sync (Helm hook RBAC conflicts with ArgoCD)
- ArgoCD dashboard: fixed 3 blank panels (wrong metric names, wrong container label filter)
- ArgoCD dashboard: added Git & Repository row + Notifications row (6 new panels)
- 4 new ArgoCD alerts: GitFetchFailed, ClusterConnectionLost, RepoServerPending, NotificationDeliveryFailed
- Alert exclusions: cilium + gitlab excluded from ArgocdAppOutOfSync
- ServiceMonitor nut-exporter: added explicit action:replace (CRD default drift)
- ARR backup CronJob rework added to deferred.md (per-PVC Jobs needed)
- Global hook: git push blocked in bash-write-protect.sh (no lock file bypass)

### Session 3 - Gap 4 Resolution + ARR Backup Rework (v0.38.0)

- Prometheus handed over to ArgoCD via ESO configSecret pattern
  - New ExternalSecret "alertmanager-config" assembles full alertmanager.yaml from Vault secrets
  - ESO template with escaped Go template syntax for alertmanager notification templates
  - configSecret replaces SET_VIA_HELM placeholders in Helm values
  - upgrade-prometheus.sh deleted (no more imperative upgrade script)
  - 10 Helm release Secrets deleted, 122 resources synced via ServerSideApply
- ARR backup CronJobs reworked: 3 node-grouped (cp1/cp2/cp3) replaced with 9 per-app
  - podAffinity instead of nodeSelector (follows app pod to any node)
  - Fixes broken backups when pods reschedule (radarr/bazarr moved to cp2)
  - Individual files in manifests/arr-stack/backup/ (one per app)
- Deep documentation audit: 37 findings fixed across 11 context docs
  - Counts, versions, stale references, broken links, missing alerts/probes
- Only cilium remains on direct Helm (1 release). All others ArgoCD-managed (46 Applications)

### Decisions

- **Secret deletion over helm uninstall** - helm uninstall deletes resources, causing outages. Secret deletion removes Helm tracking without touching resources. Zero downtime.
- **Cilium stays on Helm permanently** - CNI chicken-and-egg: helm uninstall breaks networking before ArgoCD can recreate it
- **ESO configSecret for alertmanager** - ESO template assembles full alertmanager.yaml from Vault secrets, eliminating the upgrade script. Go template escaping ({{ "{{" }}) handles alertmanager notification templates within ESO templates
- **Per-app backup CronJobs** - podAffinity over nodeSelector for RWO PVC co-location. More CronJob objects (9 vs 3) but each is independent and self-healing when pods reschedule
- **GitLab manual sync** - Helm pre-install/pre-upgrade hooks create RBAC that conflicts with ArgoCD sync apply

---

## March 28, 2026 - ArgoCD Installation & Bootstrap (v0.37.0)

### Summary

ArgoCD v3.3.5 (Helm chart 9.4.16) deployed as the GitOps engine. Non-HA with 6 pods (controller,
server, repo-server, applicationset, notifications, redis). Self-management Application tracks its
own Helm values from GitHub. Public GitHub repo - no deploy token needed.

### Components

- ArgoCD v3.3.5 (non-HA, chart 9.4.16) in argocd namespace
- 6 AppProjects (infrastructure, homelab-apps, arr-stack, gitlab, cicd-apps, argocd-self)
- Self-management Application (multi-source: Helm chart + GitHub values, manual sync)
- Discord notifications (sync succeeded/failed, health degraded) to #gitops channel
- CiliumNetworkPolicy (2 policies: ingress + egress, FQDN rules for GitHub + Discord)
- PrometheusRules (5 alerts), Grafana dashboard, blackbox probe
- LimitRange + ResourceQuota (2 CPU / 3Gi mem requests, 20 pods max)
- 2 ExternalSecrets (admin password, notifications webhook from Vault)

### Decisions

- **v3.3.5 not v3.4.0** - v3.4.0 not GA yet (rc3 as of March 25). v3.3.5 works on K8s 1.35
  despite official matrix covering 1.31-1.34. Upgrade deferred to ~May 2026.
- **Public GitHub repo** - no deploy token or repo-creds ExternalSecret needed. ArgoCD clones
  via HTTPS without authentication.
- **Redis image override** - chart default uses ecr-public.aws.com which triggers VAP warning.
  Overridden to public.ecr.aws (in allowed registry list).
- **DNS inspection for FQDN rules** - CiliumNP toFQDNs requires `rules: dns: matchPattern: "*"`
  in the same policy's DNS egress rule. Without it, FQDN-to-IP cache never populates.

---

## March 26, 2026 - Pre-GitOps Validation (v0.36.0)

### Summary

Final security validation and GitOps preparation. Verified all Phase 5.0-5.4 security controls
in place, deployed CIS benchmark regression detection, and added image registry admission control.
All 33 ExternalSecrets healthy, Vault unsealed, 24 CronJobs running. Security posture: 69 CIS
checks passing (7 justified FAILs), 127 CiliumNetworkPolicies across 24 namespaces, PSS enforced
on 27/31 namespaces.

### 5.6.0 - Prerequisites (Phase 5.5 Remediation)

- Applied 10 unapplied blackbox probes, 3 GitLab ServiceMonitors, 2 PrometheusRules, 8 Grafana dashboards
- Resolved 6 blocking GitOps gaps:
  - Gap 2: Created `helm/node-feature-discovery/values.yaml` (pure defaults)
  - Gap 6: Created `helm/intel-device-plugins-operator/values.yaml`, renamed `helm/intel-gpu-plugin/` to `helm/intel-device-plugins-gpu/` (matches Helm release name)
  - Gap 7: All 18/18 Helm releases now have matching `helm/<name>/values.yaml` directories
  - Gaps 1/3/4/5: Documented as Phase 5.8 work items (Invoicetron CI/CD, namespace-less manifests, Prometheus runtime secrets, vault-unseal-keys)

### 5.6.1 - CIS Benchmark Final Scan

- kube-bench v0.10.6 on all 3 CP nodes: 69 PASS, 7 FAIL, 36 WARN (identical across nodes)
- Delta from Phase 5.1: -6 FAIL (13 to 7), +11 PASS (58 to 69)
- All 7 FAIL items justified: stale CIS checks (PSP removed, insecure-port removed), architectural (stacked etcd), intentional (Prometheus scraping), false positive (Ubuntu 24.04 path)

### 5.6.2 - kube-bench Recurring CronJob

- Weekly Sunday 04:00 Manila time, Discord #infra alert if FAIL count exceeds 10 (7 baseline + 3 buffer)
- Reuses existing `discord-janitor-webhook` ExternalSecret
- Manifest: `manifests/kube-system/kube-bench-cronjob.yaml`

### 5.6.3 - Image Registry Restriction (ValidatingAdmissionPolicy)

- CEL-based VAP validates containers, initContainers, and ephemeralContainers
- Trusted registries: docker.io, ghcr.io, registry.k8s.io, quay.io, lscr.io, gcr.io, public.ecr.aws, self-hosted GitLab, registry.gitlab.com, all Docker Hub short names
- Deployed in Warn mode; kube-system/kube-node-lease/kube-public exempted
- Zero conflicts against 100+ running containers
- Deny mode scheduled for 2026-04-02
- Manifest: `manifests/kube-system/image-registry-policy.yaml`

### 5.6.4 - Full Cluster Security Audit

- Phase 5.0-5.4 controls verified: PSS (27/31 ns), CiliumNP (24/31 ns, 127 policies), RBAC (4 cluster-admin), etcd encryption (secretbox), audit logging (52MB active), 24 CronJobs, 14 ResourceQuotas, 24 PDBs
- All 33 ExternalSecrets in SecretSynced state
- Vault healthy: vault-0 + vault-unsealer Running, snapshots completing
- 1 `:latest` tag: portfolio (CI/CD pattern, Phase 5.8 remediation)
- Security posture summary: 13 control areas documented

### 5.6.5 - Documentation

- Security.md updated: Phase 5.6 CIS scores, 7 FAIL justifications, VAP section, GitOps security model, security posture summary table, velero-server cluster-admin documented
- VERSIONS.md updated: kube-bench CronJob added
- CHANGELOG.md updated (this entry)

---

## March 23, 2026 - Observability & Version Hardening (v0.35.0)

### Summary

Complete monitoring coverage, alert standardization, and cluster-wide version updates.
Every service now has metrics, alerts, probes, and a Grafana dashboard. All container
images updated to latest versions. Longhorn multipathd issue discovered and fixed during
upgrades. Loki PVC expanded to 20Gi. Invoicetron CI/CD image tag issue identified and
documented. 140+ files changed across 13 commits.

### Phase A0 - Bug Fixes

- Fixed 4 broken alert expressions: ClusterJanitorFailing (wrong metric name),
  PodStuckInInit CrashLoopBackOff (wrong waiting_reason metric), AlloyHighMemory
  (removed cAdvisor metric), NVMe alert annotations (wrong node/pod labels)
- Moved audit-alerts.yaml to disabled/ (LogQL rules, not deployable without Loki Ruler)
- Deleted orphan ups-monitoring.json dashboard (superseded by ups-dashboard-configmap.yaml)
- All 7 fixes verified against live Prometheus

### Phase S - Monitoring Standardization

- 11 runbook markdown files created in docs/runbooks/
- All 96 alerts standardized with summary + description + runbook_url annotations
- 4 alerts renamed for consistency (AdGuardDNSDown, VersionCheckerImageOutdated,
  VersionCheckerKubeOutdated, OllamaHighMemory)
- Discord templates updated to render runbook_url in all 3 receivers
- All 14 Probes given `release: prometheus` label (ServiceMonitor discovery)
- Dashboard ConfigMaps given `app.kubernetes.io/name: grafana` label
- Group names standardized (removed `.rules` suffix)

### Phase A - Alerting & Version Signal

- version-checker false positives fixed: match-regex annotations for Grafana (Docker Hub
  build numbers), Jellyfin (date-based tags), alpine (date-based releases), qBittorrent LSIO
- Pin-major annotations: bitnamilegacy/postgresql (16), bitnamilegacy/redis (7), mysql (8),
  kiwigrid/k8s-sidecar (2)
- Weekly Discord digest enhanced: both Helm chart AND container image drift, release notes
  links, patch/minor/major classification, color-coded embeds
- Renovate config fixed: proper packageRules for LSIO grouping, MySQL pin, infrastructure
  no-automerge, private registry skip, byparr skip

### Phase B - Operations

- Cluster janitor Discord messages: structured embeds with namespace, pod name, CronJob owner
- Backup health dashboard deployed: 6 panels covering Velero, Longhorn, etcd, CronJob backups
- Evicted pod handling verified (existing janitor cleanup covers it)
- Old ReplicaSet cleanup evaluated (Kubernetes handles automatically, no action needed)

### Phase C - Monitoring Coverage

- 10 new blackbox probes (24 total): cert-manager-webhook, ESO webhook, Garage, Homepage,
  Longhorn UI, MySpeed, Prowlarr, Radarr, Recommendarr, Sonarr
- 9 new Grafana dashboards (23 total): backup, cert-manager, ESO, ghost-prod, GitLab, home,
  invoicetron-prod, loki-storage, uptime-kuma
- 2 new alert files: gitlab-alerts.yaml, home-alerts.yaml
- GitLab ServiceMonitors: gitlab-exporter, postgresql-metrics, redis-metrics
- Loki compaction/retention alerts: LokiCompactionStalled, LokiRetentionNotRunning, LokiWALDiskFull
- CiliumNPs updated for homepage, myspeed, cert-manager webhook, ESO webhook (probe access)
- Dashboard quality fixes: arr-stack resource limit lines, panel descriptions on all rows

### Phase D - Infrastructure Version Updates

Ordered low-to-high risk, cluster health verified between each:

| Component | Old | New | Notes |
|-----------|-----|-----|-------|
| Vault | 1.21.2 | 1.21.4 | OnDelete strategy - pod delete to trigger |
| Loki | 6.49.0 | 6.55.0 | OCI chart upgrade |
| OTel Collector | 0.144.0 | 0.147.0 | Manifest image bump |
| Intel GPU Plugin | 0.34.1 | 0.35.0 | cert-manager webhook CiliumNP fix (remote-node) |
| cloudflared | 2026.1.1 | 2026.3.0 | Manifest image bump |
| kube-prometheus-stack | 81.0.0 | 82.13.1 | Grafana scale-down for RWO PVC, upgrade script refactored |
| Alloy | 1.5.2 | 1.6.2 | Helm chart upgrade |
| CoreDNS | v1.12.3 | v1.14.2 | Direct image edit (avoid kubeadm k8s bump) |
| Longhorn | 1.10.1 | 1.11.1 | v1.11.0 skipped (connection leak + webhook deadlock regressions) |
| Cilium | 1.18.6 | 1.19.1 | CiliumLoadBalancerIPPool v2alpha1->v2, upgradeCompatibility flag |

- cert-manager webhook CiliumNP: added remote-node entity (cross-node API server traffic)
- CiliumL2AnnouncementPolicy stays v2alpha1 (no v2 CRD yet in Cilium 1.19.1)
- upgrade-prometheus.sh refactored: CHART_VERSION and CHART_OCI variables (no hardcoded strings)

### Phase D+ - Longhorn multipathd Fix & Backup Audit

- **Root cause:** multipathd on all 3 nodes claims Longhorn iSCSI devices as "in use" from
  the CSI plugin's mount namespace. Latent since January, exposed by v1.11.1 upgrade when
  new volumes needed fresh mount cycles. Known issue: longhorn/longhorn#11411
- **Fix:** blacklisted `^sd[a-z0-9]+` in /etc/multipath.conf on all 3 nodes
- **ghost-dev content PVC lost** during debugging (deleted to "fix" mount error - wrong approach).
  Volume and replicas gone, no Longhorn backup existed. Content recovered from ghost-prod
  via kubectl cp (2GB images + themes). MySQL data intact (separate PVC).
- **Backup audit:** 11 volumes had no recurring Longhorn backup. 5 added:
  velero/garage-data (critical), prometheus-db, ghost-dev/mysql, loki-storage, atuin-config (important).
  6 intentionally skipped (ephemeral/regenerable: gitlab/redis, alertmanager, browser, ollama-models,
  invoicetron-dev/db, ghost-dev/content replacement).

### Phase E - Application Version Updates

20+ app images updated, all verified running:

| App | Old | New |
|-----|-----|-----|
| Ghost (dev+prod) | 6.14.0 | 6.22.1 |
| Ollama | 0.15.6 | 0.18.2 |
| MeiliSearch | v1.13.3 | v1.39.0 (dumpless upgrade) |
| Uptime Kuma | 2.0.2-rootless | 2.2.1-rootless |
| Traffic Analytics | 1.0.72 | 1.0.153 |
| Configarr | 1.20.0 | 1.24.0 |
| Seerr | v3.0.1 | v3.1.0 |
| Tdarr | 2.58.02 | 2.64.02 |
| Unpackerr | v0.14.5 | v0.15.2 |
| AdGuard | v0.107.71 | v0.107.73 |
| Homepage | v1.9.0 | v1.11.0 |
| Karakeep | 0.30.0 | 0.31.0 |
| nut-exporter | 3.1.1 | 3.2.5 |
| Nova | v3.11.10 | v3.11.13 |
| alpine/k8s | 1.35.0 | 1.35.3 (4 files, 5 refs) |
| busybox | 1.36 | 1.37 (5 files) |
| alpine | 3.21 | 3.23 (2 files) |
| python | 3.12-alpine | 3.14.3-alpine |

- PostgreSQL 18-alpine floating tag applied to cluster (manifests already pinned at 18.3-alpine)
- Docker Hub rate limit hit during bulk pulls - worked around with `ctr images tag` on nodes
- MeiliSearch 26-version jump used `--experimental-dumpless-upgrade` (removed after first boot)
- version-checker match-regex annotations added for postgres and python alpine suffix false positives
- Renovate pin-major added for postgres < 19.0.0
- Loki PVC expanded 12Gi -> 20Gi (KubePersistentVolumeFillingUp at 92.3% after Phase 5.5
  increased log volume). Third expansion: 10Gi -> 12Gi -> 20Gi.

### Bug Fixes

- Invoicetron-dev rollout stuck: `manifests/invoicetron/deployment.yaml` has CI/CD-managed
  prod image tag. Applying directly to invoicetron-dev pushed wrong image, combined with
  RollingUpdate maxUnavailable:0 + ResourceQuota = stuck rollout. Fixed by setting correct
  dev image tag and scale 0/1 cycle. Added CLAUDE.md gotcha to prevent recurrence.
- VeleroBackupStale false positive: manual backups (velero-cli-*) included in staleness
  check. Fixed alert expression to exclude manual backup names.

### Phase F - Documentation

- CHANGELOG entry for full Phase 5.5
- Monitoring.md: 6 versions updated, 10 probes + 9 dashboards + 2 alert files documented
- Storage.md: Longhorn 1.11.1, multipathd Known Issues section
- Upgrades.md: bulk upgrade considerations (Docker Hub rate limits, alpine suffix, PVC safety)
- Backups.md: 5 volumes moved from Excluded to backup groups
- _Index.md: Phase 5.5 status, Cilium 1.19.1, Longhorn 1.11.1
- README.md: 42 dashboards, 24 probes, 128 policies, Cilium 1.19.1, Vault 1.21.4
- docs/todo/README.md: v0.34.0 released, Phase 5.4 moved to Completed
- docs/rebuild/README.md: v0.34.0 timeline entry
- docs/todo/deferred.md: Loki PVC observation resolved, invoicetron CI/CD alignment added
- CLAUDE.md: Longhorn PVC Safety section, StatefulSet PVC expansion procedure,
  multipathd/Docker Hub/version-checker/invoicetron gotchas

### Lessons Learned

- **Never delete a PVC to fix mount errors.** Diagnose root cause first (multipathd, CSI plugin,
  stale mounts). Deleting destroys Longhorn volume + replicas permanently.
- **multipathd config survives reboots** but can be lost on OS upgrades. Added to CLAUDE.md gotchas.
- **Docker Hub rate limit is per-IP, not per-node.** All 3 nodes share one external IP = 100 pulls
  total per 6 hours. Plan bulk upgrades accordingly.
- **version-checker `-alpine` suffix** causes false positives. Images tagged `X.Y-alpine` get
  compared against `X.Y` (non-alpine). Fix: match-regex annotations.
- **Longhorn v1.11.0 had regressions** (connection leak, webhook deadlock). Always check patch
  releases before targeting `.0` versions.
- **StatefulSet volumeClaimTemplates are immutable.** Helm upgrade can't resize existing PVCs.
  Procedure: patch PVC, delete pod for filesystem resize, `--cascade=orphan` + helm upgrade
  to sync the template.
- **CI/CD-managed image tags in shared manifests** cause rollout issues when applied to the
  wrong namespace. Use generic placeholders (like portfolio) or per-env manifests.

---

## March 21, 2026 - Resilience & Backup (v0.34.0)

### Summary

Full backup infrastructure, resource management, resilience hardening, and automation improvements.
Three-layer backup strategy: Longhorn volume snapshots, Velero K8s resource backups, CronJob database
dumps. Off-site encrypted backup via restic to OneDrive. Resource limits, LimitRange, and ResourceQuota
on all application namespaces. PodDisruptionBudgets, pod eviction tuning, and automation hardening.

### Resource Management (Phase B)

- Resource limits set on all workload pods (Helm-managed and manifest workloads)
- LimitRange defaults deployed to all application namespaces (prevents quota rejection)
- ResourceQuota on 14 namespaces (CPU, memory, PVC, pod count limits)
- bazarr memory limit increased (256Mi -> 512Mi, OOMKill fix)
- Node memory overcommit documented (cp1 168%, cp2 99%, cp3 170% on limits; 58-66% actual usage)

### Scripts Reorg (Phase C)

- scripts/ reorganized into subdirectories: backup/, vault/, ghost/, monitoring/, test/
- .gitignore allowlist updated for new paths
- Active doc references updated (Architecture.md, Secrets.md, Monitoring.md, Conventions.md)
- CronJob timezones standardized: version-check (Etc/UTC -> Asia/Manila), configarr (added timeZone)

### Longhorn Volume Backups (Phase D1)

- NFS backup target configured via Helm `defaultBackupStore.backupTarget` -> `/Kubernetes/Backups/longhorn/`
- RecurringJobs: critical tier (14 daily + 4 weekly), important tier (7 daily + 2 weekly)
- Volume group assignments: 10 critical, 14 important volumes, rest excluded
- Backup and restore tested (myspeed-data)

### In-Cluster CronJob Backups (Phase D2)

- 10 new backup CronJobs: Ghost MySQL, AdGuard, UptimeKuma, Karakeep, Grafana, ARR (3 per-node), MySpeed, etcd
- Invoicetron backup migrated from Longhorn PVC to NFS (3-day retention)
- GitLab backup strategy evaluated (deferred native backup, covered by Longhorn + Velero)
- etcd backup CronJob: distroless initContainer + alpine/k8s, daily 03:30, hostNetwork for etcd access
- SQLite backups use `keinos/sqlite3:3.46.1` (secure: runAsNonRoot, readOnlyRootFilesystem, no internet)
- All CronJobs verified via manual trigger + NFS file check

### Velero + Garage S3 (Phase D3)

- Garage S3 deployed (dxflrs/garage:v2.2.0) as self-hosted S3 backend (replaces archived MinIO)
- Velero v1.18.0 (chart 12.0.0) with velero-plugin-for-aws v1.14.0
- Daily scheduled backup (30-day retention, Secrets excluded)
- Declarative manifests in manifests/velero/ (namespace, ESO, ConfigMap, StatefulSet, CiliumNP)
- velero-s3-credentials via ExternalSecret with template (not imperative kubectl)
- Backup tested on portfolio-dev (34 items, 0 errors)

### Off-Site Backup (Phase E)

- `scripts/backup/homelab-backup.sh` (6 subcommands: setup, pull, encrypt, status, prune, restore)
- Two-step WSL2 workflow: SSH rsync from NAS -> restic encrypt to OneDrive
- Restic repo initialized, first backup completed (426MB pull, encrypted snapshot)
- Recovery key stored separately in 1Password (survives Vault loss)
- .offsite-manifest.json written to NAS after pull/encrypt for visibility

### Retention Reductions (Phase F)

- Vault snapshot retention: 15 -> 3 days (off-site backup covers history)
- Atuin backup retention: 28 -> 3 days
- PKI backup retention: 90 -> 14 days

### Monitoring & Alerting (Phase G)

- 12 new Prometheus alert rules across 3 files (backup-alerts.yaml, longhorn-alerts.yaml, stuck-pod-alerts.yaml)
- Velero backup failure/staleness alerts (VeleroBackupFailed, VeleroBackupStale >36h)
- etcd backup staleness alert (>36h)
- CronJob failure and not-scheduled alerts (generic, covers all CronJobs)
- Stuck pod alerts (Init, Pending, CrashLoop >1h, ImagePull)
- ResourceQuota nearing limit alert (>85%)
- LonghornVolumeAllReplicasStopped (deduplicated LonghornVolumeDegraded - already in storage-alerts.yaml)
- Longhorn metric expressions fixed: numeric gauges, not label-based (robustness==0, state==3, backup_state==4)

### Resilience Hardening (Phase H)

- 28 deployments got 60s tolerationSeconds for not-ready/unreachable (faster pod rescheduling)
- 8 new PDBs (21 total): AdGuard, Homepage, Grafana, Prometheus, Portfolio (x3), Vault
- GitLab HA evaluation: skipped (170%+ memory overcommit, insufficient headroom for 2 replicas)
- Longhorn replica-soft-anti-affinity confirmed false
- Node failure recovery times documented in Architecture.md
- Stuck stopped replica recovery procedure documented in Storage.md

### Automation Hardening (Phase I)

- version-checker: ContainerImageOutdated alert filtered to container_type="container" (excludes init containers)
- version-check CronJob: switched from alpine+apk to alpine/k8s:1.35.0 (no network dependency)
- version-check CronJob: CiliumNetworkPolicy added (pre-existing bug from Phase 5.3)
- version-check CronJob: TZ fixed from Asia/Manila to UTC-8 (alpine/k8s has no tzdata)
- Renovate Bot suspended (version-checker + Nova sufficient for single-admin homelab)
- ARR stall resolver: Discord notification added (ExternalSecret + Vault seed completed)
- Cluster janitor: stuck volumes covered by LonghornVolumeAllReplicasStopped alert
- Cluster janitor: added Failed Job cleanup (Task 3, >1h age, clears CronJobFailed alerts automatically)
- Cluster janitor: timezone fix (TZ=Asia/Manila -> TZ=UTC-8, alpine/k8s has no tzdata)

### Bug Fixes

- CiliumNP prometheus-operator-ingress: added remote-node entity (cross-node webhook traffic in tunnel mode)
- CiliumNP ESO webhook-ingress: added remote-node entity (same cross-node SNAT issue)
- ESO webhook CiliumNP: port 443->10250 (container port vs service port) + host entity
- Grafana sidecar resources: set per-sidecar (dashboards + datasources), not shared sidecar.resources
- Loki sidecar CrashLoop: set sidecar.rules.enabled=false (rules sidecar crashes without Ruler)
- Invoicetron image tag: fixed from placeholder `:latest` to actual prod SHA
- SQLite backup CronJobs (8): added runAsUser/runAsGroup 65534 (keinos/sqlite3 uses non-numeric user `sqlite`, fails runAsNonRoot verification)
- Karakeep backup: cp -a -> cp -r (NFS as non-root), skip lost+found directory

### Documentation (Phase J)

- Stale /Kubernetes/vault-snapshots/ removed from NAS (superseded by Backups/vault/)
- etcd backup encryption: accept NAS trust (same VLAN, off-site copy encrypted, short retention)
- VERSIONS.md: added velero-plugin-for-aws, keinos/sqlite3, Velero CLI, restic
- Security.md: backup architecture, retention, recovery procedures, resource quotas, PDBs, automation hardening
- Architecture.md: three-layer backup strategy, Garage S3 decision, recovery times
- Storage.md: Longhorn RecurringJob tiers, NFS backup directories status updated to Deployed
- Secrets.md: Garage S3 and restic 1Password items, Vault KV paths

### Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| Garage over MinIO | MinIO repo archived Feb 2026. Garage: 21MB image, ~3MB idle RAM, actively maintained |
| SQLite .backup over raw cp | Raw cp corrupts WAL-mode databases. sqlite3 .backup is atomic |
| Per-node ARR backup CronJobs | RWO PVCs can't cross nodes. Each CronJob runs on the node hosting its PVC |
| Secrets excluded from Velero | vault-unseal-keys must not be stored in Garage S3 |
| etcd backup unencrypted on NAS | Same trusted VLAN, off-site copy encrypted via restic, short 3-day retention |
| 60s pod eviction for stateless | Faster recovery (7min vs 11min). Databases keep default 300s for consistency |
| GitLab HA deferred | Memory overcommit too high (170%). Would push nodes past safe limits |

---

## March 19, 2026 - Loki Storage Fix (v0.33.2)

### Bug Fixes
- Loki PVC filling up alert (KubePersistentVolumeFillingUp): original estimate of ~4MB/day was wrong -
  actual ingestion is ~147 MiB/day due to TSDB indexes, WAL, and compactor overhead. 90-day retention
  needs ~12.9 GiB, exceeding the 10Gi PVC. Reduced retention from 2160h (90 days) to 1440h (60 days)
  and expanded PVC from 10Gi to 12Gi. Steady-state at 60 days: ~8.6 GiB on 12Gi (~72%).

---

## March 17, 2026 - Network Policy Hotfix (v0.33.1)

### Bug Fixes
- AdGuard DNS LoadBalancer ingress (10.10.30.53): added `fromEntities: [host, remote-node, world]`
  alongside `fromCIDRSet`. Cilium LB rewrites source identity on incoming traffic - `fromCIDRSet`
  alone appeared to work because conntrack entries from before the policy carried existing flows
  through. After ~34h when conntrack expired, new DNS connections were silently dropped. Cascade:
  AdGuard down -> all `*.home.rommelporras.com` resolution failed -> NPM proxy timeouts -> 6
  services reported down by Uptime Kuma.
- GitLab SSH LoadBalancer ingress (10.10.30.21): same `fromEntities` fix applied preemptively
  (identical `fromCIDRSet`-only pattern).

### Documentation
- Networking.md: per-namespace traffic matrix (ingress/egress reference table), cross-namespace
  flow diagram, Cilium identity gotchas cheat sheet. Added critical warning about LoadBalancer
  ingress identity rewriting and conntrack masking behavior.
- Security.md: added LoadBalancer ingress identity gotcha to "Common mistakes" section.

---

## March 16, 2026 - Network Policies (v0.33.0)

### Network Policy Implementation
- 117 CiliumNetworkPolicies across 23 namespaces (implicit default-deny via enable-policy=default)
- 1 CiliumClusterwideNetworkPolicy for Gateway reserved:ingress identity
- FQDN egress for Alertmanager (Discord, SMTP, healthchecks.io) and cert-manager (Let's Encrypt, Cloudflare)
- LoadBalancer ingress for AdGuard DNS (53), GitLab SSH (22), OTel Collector (4317/4318)
- Cross-namespace ingress patterns: monitoring (blackbox probes), cloudflare (tunnel), uptime-kuma (health)
- Deferred: longhorn-system, intel-device-plugins, node-feature-discovery

### Bug Fixes
- invoicetron backup CronJob: added fsGroup: 70 (PVC write permissions after Phase 5.0 runAsUser change)
- ghost-analytics: memory limit 256Mi to 384Mi (OOMKilled 4x overnight)
- vault-unsealer: cpu limit 50m to 100m (73% CPU throttling)
- Homepage: automountServiceAccountToken restored (K8s/Longhorn widgets need metrics API)
- Homepage: L4-only egress policy (Cilium L7 envoy 403 on Gateway LB hairpin)
- DNS TCP/53 added to uptime-kuma, cloudflare, arr-stack egress policies
- nut-exporter/kube-vip: toCIDR changed to toEntities: [remote-node] (Cilium identity fix)
- Pinned cert-manager cainjector host ingress to port 9402 (had no probes, was unrestricted)
- invoicetron deployment: automountServiceAccountToken set to false (was deferred since Phase 5.0
  due to CI/CD placeholder image - fixed via kubectl patch to avoid image rollback)
- AdGuard Home: L4-only egress policy (L7 envoy proxy intermittently broke upstream DNS
  forwarding, causing network-wide DNS failures for *.home.rommelporras.com services)
- OTel Collector: added fromEntities: [world] to ingress (LoadBalancer external traffic
  needs world entity - fromCIDRSet doesn't match after Cilium LB DNAT processing)

### Cilium Discoveries
- toCIDR silently fails for cluster node IPs (remote-node identity) - use toEntities: [remote-node]
- toCIDR silently fails for Gateway LB VIP (service identity) - use L4-only policy (no toPorts)
- L7 envoy proxy (triggered by toPorts) returns 403 on Gateway hairpin traffic
- toServices with selectorless services converts to CIDR, which also fails for managed identities

### Documentation
- Security.md: Cilium identity reference table, Gateway hairpin limitation, non-root exceptions
- Deferred: NUT client setup for Proxmox PVE (graceful shutdown during power failure)

---

## March 15, 2026 - RBAC & Secrets Hardening (v0.32.0)

### Summary

RBAC audit across all 110 ServiceAccounts and 82 ClusterRoleBindings. GitLab Runner scoped from
cluster-wide ClusterRole to namespace-scoped Role. Nova auth bug fixed (version-check-cronjob).
etcd encryption at rest enabled on all 3 CP nodes (secretbox/XSalsa20-Poly1305), all existing secrets
re-encrypted. Claude Code access restricted via dedicated ServiceAccount + RBAC + hook-based blocking.

### Changes

| Change | Details |
|--------|---------|
| GitLab Runner RBAC | `clusterWideAccess: false` in Helm values - ClusterRole deleted, namespace-scoped Role created in `gitlab-runner`. Helm upgrade rev 5. |
| version-check-cronjob fix | Removed `automountServiceAccountToken: false` - Nova needs in-cluster API access to read Helm release secrets. Manual job confirmed: 11 outdated, 0 deprecated, 6 current. |
| etcd encryption | EncryptionConfiguration (secretbox) deployed to all 3 nodes. Rolling API server update: CP1 → soak → CP2 → soak → CP3. All servers Running 0 restarts post-update. |
| etcd re-encryption | All pre-existing secrets re-encrypted via `kubectl replace`. Verified: `k8s:enc:secretbox:v1:key1:` prefix on cert-manager and vault Helm release secrets. |
| Encryption key backup | "etcd Encryption Key" in 1Password Kubernetes vault. |
| Ansible rebuild | `03-init-cluster.yml` updated: deploy task + `encryption-provider-config` extraArg + extraVolume. Key via `--extra-vars "etcd_encryption_key=$(op read ...)"` at runtime. |
| claude-code SA | ClusterRole (read-only, no secret `get`), ClusterRoleBinding, permanent token Secret. `manifests/kube-system/claude-code-rbac.yaml`. |
| Restricted kubeconfig | `~/.kube/homelab-claude.yaml` - permanent token, embedded CA. Both kubeconfigs saved to 1Password "Kubeconfig" (fields: `admin-kubeconfig`, `claude-kubeconfig`). |
| Alias update | `kubectl-homelab` → restricted kubeconfig. `kubectl-admin` → admin kubeconfig. Updated in `~/.zshrc` and `CLAUDE.md`. |
| Hooks | `protect-sensitive.sh` extended: blocks `kubectl get secret -o json/yaml/jsonpath` and `kubectl describe secret`. |

### Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| secretbox over aescbc | k8s docs: aescbc not recommended due to CBC padding oracle vulnerability. secretbox uses XSalsa20-Poly1305 (AEAD). |
| Permanent SA token for claude-code | Time-limited tokens (1 year) expire and break all synced devices simultaneously. Restricted read-only SA is low-risk enough for permanent token. Rotation: delete Secret → k8s revokes immediately. |
| Both kubeconfigs in one 1Password item | Single `op item get` per file on new device. Fields `admin-kubeconfig` and `claude-kubeconfig` are self-documenting. |
| longhorn-support-bundle cluster-admin accepted | Manual trigger only, upstream constraint, no feasible alternative. Documented as known exception. |
| RBAC + hook = two independent layers | RBAC blocks `get` at API server. Hook blocks the command before it reaches the cluster. Either layer alone is insufficient (list verb exposes data with -o yaml). |

### Gotchas

| Gotcha | Detail |
|--------|--------|
| `list` verb on secrets still exposes data | `kubectl get secrets -o yaml` uses `list` and returns full data. RBAC `list`-only is not sufficient alone - hooks provide the second layer. |
| etcd:3.6.6-0 is distroless | No `sh`, no `hexdump`. Use `etcdctl` directly. No `sh -c` wrapper. |
| StorageVersionMigration not available | k8s 1.35 without feature gate. Re-encryption must use `kubectl get secrets -A -o json | kubectl replace -f -` (user runs manually - data must not flow through Claude). |
| kube-scheduler restarts during rolling update | When API server restarts, scheduler briefly loses connection and restarts once. Expected - resolves within ~60s. Not an error. |

---

## March 15, 2026 - Control Plane Hardening (v0.31.0)

### Summary

CIS Kubernetes Benchmark compliance for control plane. kube-bench FAIL count reduced from 20 to 13
(+7 PASS). Kubelet hardened on all 3 nodes, API server audit logging enabled, profiling disabled on
API server/controller-manager/scheduler. Certificate expiry monitoring and PKI backup CronJobs deployed.
Audit logs shipped to Loki via Alloy. All changes applied rolling (one node at a time) with lockout gates.

### Changes

| Change | Details |
|--------|---------|
| Kubelet hardening | `readOnlyPort: 0`, `protectKernelDefaults: true`, `eventRecordQPS: 5` on all 3 nodes |
| API server profiling | `--profiling=false` on all 3 nodes |
| API server audit logging | `--audit-log-path`, `--audit-policy-file`, `--audit-log-max*` on all 3 nodes |
| Controller-manager | `--profiling=false` on all 3 nodes |
| Scheduler | `--profiling=false` on all 3 nodes |
| Audit policy | Metadata-level catch-all, RequestResponse for RBAC, Request for exec/attach/portforward |
| Audit log shipping | Alloy DaemonSet hostPath mount → Loki (`{source="audit_log"}`) |
| Alertmanager silences | Removed etcd/scheduler/CM silences (targets now UP). KubeProxyDown kept (Cilium). |
| Audit alert routing | `Audit.*` added to discord-infra alertname regex |
| Cert expiry CronJob | Weekly check with `openssl x509 -checkend`, Discord alert when <30 days |
| PKI backup CronJob | Weekly backup to NFS (`/Kubernetes/Backups/pki/`), 90-day retention |
| kubeadm config | Hardening baked into `03-init-cluster.yml` (rebuild-safe) |
| Verification playbook | `09-verify-hardening.yml` for drift detection |
| Fix: invoicetron backup namespace | Added `namespace: invoicetron-prod` to manifest - duplicate CronJob was accidentally deployed to `default` during Phase 5.0 |

### Decisions

| Decision | Rationale |
|----------|-----------|
| Exclude `--anonymous-auth=false` | Breaks API server startup probes in k8s 1.35 (`/livez` returns 401). RBAC 403 is equivalent. CIS 1.2.1 is Manual/WARN. |
| Keep `--bind-address=0.0.0.0` on CM/scheduler | Required for Prometheus scraping. CIS 1.3.7/1.4.2 accepted as intentional FAIL. |
| Audit alerts as LogQL (not PromQL) | Requires Loki ruler (not yet enabled). Rules created, ready for deployment. |

---

## March 13, 2026 - Namespace & Pod Security (v0.30.0)

### Summary

Hardened all namespaces with Pod Security Standards, disabled unnecessary service account tokens,
locked down ESO infrastructure, and restricted ClusterSecretStore access to labeled namespaces.
9 new namespace manifests created, PSS labels applied to 26 namespaces (4 system namespaces intentionally unlabeled), `automountServiceAccountToken: false`
on 34 workloads, ESO Helm hardening (resource limits, disabled CRD reconcilers, TLS cipher restriction),
and ClusterSecretStore namespaceSelector restricting Vault access to 15 labeled namespaces.

### Changes

| Change | Details |
|--------|---------|
| 9 namespace manifests | cert-manager, cloudflare, gitlab, gitlab-runner, invoicetron-dev, invoicetron-prod, portfolio-dev, portfolio-prod, portfolio-staging |
| PSS enforce labels | baseline (18 ns), privileged (7 ns), restricted (1 ns - cloudflare) |
| PSS audit/warn | `audit: restricted` + `warn: restricted` on all labeled namespaces |
| eso-enabled labels | 15 namespaces labeled for ClusterSecretStore access |
| automountServiceAccountToken | `false` on 34 workloads, explicit `true` on cluster-janitor |
| ESO resource limits | Controller 50m–200m CPU, 128Mi–256Mi mem; webhook/cert-controller 25m–100m, 64Mi–128Mi |
| ESO CRD reconcilers | Disabled ClusterExternalSecret, PushSecret, ClusterPushSecret (unused) |
| ESO webhook TLS | Restricted to ChaCha20-Poly1305 cipher suites |
| ClusterSecretStore restriction | namespaceSelector requires `eso-enabled: "true"` |
| Vault on Homepage | customapi widget showing seal status, version, cluster name |
| SecurityContext fixes | portfolio (capabilities), nut-exporter (runAsNonRoot), invoicetron backup (capabilities) |
| Uptime Kuma NetworkPolicy | Added gateway VIP 10.10.30.20 to CiliumNetworkPolicy egress (was blocked by 10.0.0.0/8 exclusion) |
| Security.md | New context doc: PSS levels, ESO hardening, trust boundaries, SA token decisions |

### Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| baseline over restricted for most apps | Many images run as root (ARR stack, databases). Restricted would require upstream changes. Baseline + audit/warn=restricted gives visibility without breaking workloads. |
| privileged for intel-device-plugins, NFD | hostPath volumes violate baseline. Plan originally said baseline but cluster audit showed violations. |
| gitlab at baseline (downgraded from privileged) | Audit showed no baseline violations in running pods. gitlab-runner stays privileged for build pods. |
| namespaceSelector over Kyverno/OPA | Single-admin cluster. Label-based restriction is sufficient without a full policy engine. |
| HTTP Vault connection kept | In-cluster only. mTLS adds cert management overhead for minimal security gain. |

### Gotchas

- **Portfolio nginx needs CHOWN, SETUID, SETGID, NET_BIND_SERVICE capabilities** - dropping ALL capabilities without adding these back causes CrashLoopBackOff (chown fails, then bind port 80 fails).
- **NUT exporter CreateContainerConfigError** - image runs as root but `runAsNonRoot: true` was set. Fixed by adding `runAsUser: 65534` at container level.
- **PSS dry-run doesn't audit existing pods** - `kubectl label --dry-run=server` only checks the label change, not pod compliance. Must audit securityContext directly via `kubectl get pods -o json | jq`.
- **ESO disabling PushSecret requires also disabling ClusterPushSecret** - Helm upgrade fails if only `processPushSecret: false` is set without `processClusterPushSecret: false`.
- **Uptime Kuma 403 from CiliumNetworkPolicy** - egress rule excluded 10.0.0.0/8 but gateway VIP is 10.10.30.20. Envoy returns "Access denied" (not connection refused), making it look like an app-level issue.

---

## March 13, 2026 - Warning Event Fixes + Doc Sync (v0.29.1)

### Summary

Fixed 5 warning events surfaced in Headlamp (Ghost probe noise, GitLab runner FailedMount,
Grafana Init stuck, Byparr readiness timeouts) and synced all documentation to v0.29.0
cluster state.

### Changes

| Change | Details |
|--------|---------|
| Ghost dev/prod probes | Switched from `httpGet` to `tcpSocket` - Ghost redirects HTTP→HTTPS (301), generating ProbeWarning noise. Pods were healthy; warnings were cosmetic. |
| GitLab runner ESO template | Added empty `runner-registration-token` key - Helm chart projected volume expects both keys even when using GitLab 17.0+ auth flow |
| Grafana ESO template | Added static `admin-user: "admin"` key - kube-prometheus-stack 81.0.0+ requires it in `existingSecret` |
| Byparr image pin | `ghcr.io/thephaseless/byparr:latest` → `2.1.0` - pinned to specific version |
| Byparr probe tuning | Readiness timeout 10s→45s, liveness timeout 30s→60s, period 60s→120s - headless browser blocks `/health` during Cloudflare challenge solves |
| Documentation sync | 21 issues fixed across 8 doc files - VERSIONS.md, context docs, rebuild guide, TODO |

### Key Decisions

| Decision | Rationale |
|----------|-----------|
| tcpSocket over httpGet for Ghost | Ghost's 301 redirect is by design (HTTP→HTTPS). `scheme: HTTPS` in probes would work but adds TLS overhead for a health check. tcpSocket is simplest and matches prod probe pattern. |
| httpGet kept for Byparr (not tcpSocket) | tcpSocket would hide real failures - Byparr's `/health` endpoint reports browser engine status. Generous timeout with httpGet is the correct approach. |
| ESO templates for static keys | ESO `target.template.data` can mix Vault-fetched values with static strings in a single Secret, avoiding separate manual secrets. |

---

## March 12, 2026 - Vault + External Secrets Operator (v0.29.0)

### Summary

Replaced all imperative `kubectl create secret` commands with declarative `ExternalSecret` CRDs
backed by self-hosted HashiCorp Vault. 30 ExternalSecrets deployed across 15 namespaces. All
workloads rollout-restarted and confirmed healthy. Vault runs as a single pod with Raft storage
on Longhorn 5Gi, an auto-unsealer Deployment, and daily Raft snapshots to NFS NAS (15-day
retention). `vault-unseal-keys` is the only remaining imperative secret (bootstrap requirement).

Post-release fixes applied in same session: Vault metrics 403 (Vault 1.16+ breaking change
requiring `unauthenticated_metrics_access` in `listener.telemetry{}` block, not top-level),
ServiceMonitor for kube-prometheus-stack scraping, VaultSealed alert false-positive fix
(added `probe_success == 0` guard to prevent absent() firing when metrics never scraped),
`send_resolved: true` on all Discord receivers, `VAULT_ADDR` in `.zshrc`.

### Changes

| Change | Details |
|--------|---------|
| HashiCorp Vault 1.21.2 | Standalone, Raft on Longhorn 5Gi, `helm/vault/values.yaml` |
| Auto-unsealer Deployment | Polls vault-0 every 30s, unseals with 3 Shamir keys from `vault-unseal-keys` secret |
| ESO v2.1.0 | `ClusterSecretStore` via Kubernetes auth, `serviceMonitor.enabled: true` |
| 30 ExternalSecrets | Covers all 15 namespaces - all STATUS=SecretSynced |
| Vault HTTPRoute | `vault.k8s.rommelporras.com` via homelab-gateway |
| Vault ServiceMonitor | Prometheus scraping via ServiceMonitor CRD (pod annotations don't work with kube-prometheus-stack) |
| Snapshot CronJob | Daily 02:00 PHT to NFS `/Kubernetes/Backups/vault`, 15-day retention |
| 8 PrometheusRule alerts | VaultSealed (critical), VaultMetricsMissing (warning), VaultAuditFailure (critical), VaultDown (warning), VaultHighLatency (warning), ESOSecretNotSynced (critical), ESOSyncErrors (warning), VaultSnapshotFailing (warning) |
| VaultSealed alert fix | Added `probe_success{job="vault"} == 0` guard - prevents false positives when metrics aren't scraped yet |
| Blackbox probe | Probes `/v1/sys/health` - returns 503 when sealed (triggers VaultDown) |
| `VAULT_ADDR` in `.zshrc` | No more manual export or port-forward needed for vault CLI |
| `send_resolved: true` on Discord | All 3 Discord receivers now explicitly send resolved notifications |
| Alertmanager infra routing | `Vault.*` and `ESO.*` patterns added to `#infra` regex - ensures all 8 Vault/ESO alerts route to `#infra` instead of catch-all `#apps` |
| dotctl Observability | Loki HTTPRoute (`loki.k8s.rommelporras.com`), PrometheusRule for dotctl drift/staleness, Grafana dashboard |
| Scripts deleted | `scripts/apply-arr-secrets.sh` replaced by ExternalSecret CRDs |
| 8 secret.yaml files deleted | Replaced by `externalsecret.yaml` in each namespace |

### Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| 1-pod Vault (not HA 3-pod) | Longhorn already provides 2× data replication. HA adds 15Gi storage and complex Raft join/unseal. Unsealer recovers pod restarts in ~30s - downtime is minimal |
| Kubernetes auth (not token) | ESO uses its own ServiceAccount for Vault auth. No static tokens to rotate, no secrets in manifests |
| Seed script (not direct op read) | Secret values from 1Password never enter Claude Code context. Script runs in safe terminal; all manifests contain only `op://` references |
| `vault-unseal-keys` stays imperative | Vault must be running for ESO to work - chicken-and-egg. Only this one secret stays imperative by design |
| ServiceMonitor over pod annotations | kube-prometheus-stack 81.x ignores `prometheus.io/scrape` annotations on non-kube-state-metrics pods. ServiceMonitor CRD is the correct scrape mechanism |

### Gotchas

- **`unauthenticated_metrics_access` in `listener.telemetry{}`** - Vault 1.16+ moved this setting from top-level `telemetry{}`. Top-level placement causes 403 on `/v1/sys/metrics` despite no error in Vault logs.
- **Vault StatefulSet uses OnDelete** - `helm upgrade` doesn't restart vault-0. Must delete the pod manually after any HCL config change.
- **`upgrade-prometheus.sh` temp file overrides receivers entirely** - Any receiver setting in `values.yaml` (like `send_resolved`) must also be in the script's temp file or it will be silently dropped on upgrade.
- **ESO `externalsecret.yaml` filenames** - The pre-commit hook `protect-sensitive.sh` matches `*secret.yaml`. Write these files via bash heredoc if the hook blocks.

---

## March 11, 2026 - Cluster Janitor + Discord Notification Restructure (v0.28.2)

### Summary

Automated cluster self-healing CronJob and Discord notification restructure for signal over noise.
The cluster-janitor CronJob runs every 10 minutes, cleaning up Failed pods and stopped Longhorn
replicas (with a safety guard that never deletes the last replica). Discord notifications were
restructured from a single noisy `#status` channel into purpose-specific channels: `#infra` for
infrastructure warnings, `#apps` for application warnings, `#janitor` for cleanup summaries,
and `#speedtest` for MySpeed results. 1Password Discord webhook items consolidated from 3
separate items into 1 "Discord Webhooks" item with 6 fields.

### Changes

| Change | Details |
|--------|---------|
| Cluster Janitor CronJob | `kube-system/cluster-janitor` every 10 min - deletes Failed pods, cleans stopped Longhorn replicas (safety guard: skips last replica), posts summary to Discord `#janitor` |
| Image: `alpine/k8s:1.35.0` | `bitnami/kubectl` dropped version tags. `alpine/k8s` provides pinned kubectl + curl + bash |
| RBAC | ServiceAccount + ClusterRole (pods get/list/delete, replicas.longhorn.io get/list/delete, volumes.longhorn.io get/list) |
| PrometheusRule | `ClusterJanitorFailing` fires after 30m of CronJob failures (routes to `#infra`) |
| Discord channel restructure | `#status` renamed to `#apps`, new channels: `#infra`, `#janitor`, `#speedtest` |
| Alertmanager routing split | Infra warnings (Longhorn, NVMe, certs, nodes, UPS, logging) → `#infra`; app warnings (catch-all) → `#apps` |
| 1Password consolidation | 3 items → 1 "Discord Webhooks" item with 6 fields: incidents, apps, infra, versions, janitor, speedtest |
| Longhorn `node-down-pod-deletion-policy` | `do-nothing` → `delete-both-statefulset-and-deployment-pod` (faster pod rescheduling after node crash) |
| Longhorn `orphan-resource-auto-deletion` | Enabled with `replica-data;instance` (auto-clean orphaned data + runtime instances) |
| MySpeed webhook | Moved from `#status` to `#speedtest` channel in MySpeed web UI |
| Upgrade script | `scripts/upgrade-prometheus.sh` updated with consolidated `op://` paths and 5 receivers |

### Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| `alpine/k8s:1.35.0` over `bitnami/kubectl` | Bitnami only publishes `latest` + SHA digests - can't pin versions. `alpine/k8s` provides version tags matching cluster kubectl |
| Safety guard (skip last replica) | Never delete a stopped replica if it's the only one for a volume - data loss prevention |
| No `set -e` in janitor script | Tasks are independent - partial cleanup is better than aborting on first failure |
| `concurrencyPolicy: Forbid` | Prevents overlapping runs that could race on replica deletion |
| `timeZone: Asia/Manila` | Discord messages show PHT, matching user's timezone |
| Infra regex vs catch-all apps | First-match routing: specific infra patterns get `#infra`, everything else falls through to `#apps` |
| `orphan-resource-auto-deletion: "replica-data;instance"` | Not a boolean - semicolon-separated list of resource types. `replica-data` cleans orphaned data dirs, `instance` cleans orphaned engine/replica processes |
| Supersedes Phase 5.5.4.1 and 5.5.4.2 | Longhorn settings originally planned for Phase 5 - implemented early as part of crash recovery hardening |

### Gotchas

- **`orphan-resource-auto-deletion` is NOT a boolean** - value is `replica-data;instance` (semicolon-separated), not `true`/`false`
- **Helm YAML array merge** - `--values` files replace arrays entirely (not merge). The secrets temp file must define all 5 receivers since it replaces the receivers array from `values.yaml`
- **`bitnami/kubectl` dropped version tags** - only `latest` + SHA digests available. Switched to `alpine/k8s` which maintains version-pinned tags
- **Detached volumes have stopped replicas** - this is normal Longhorn behavior. The janitor correctly skips these (0 running replicas = last copy)

---

## March 9, 2026 - GitLab Minio + Atuin Backup + Runner OOM Fix (v0.28.1)

### Summary

Patch release fixing three infrastructure issues. (1) The GitLab Minio PVC (`gitlab-minio`,
10Gi) reached 89% capacity from orphaned container registry blobs (41 revisions, only 6
active tags for `0xwsh/portfolio`), causing `KubePersistentVolumeFillingUp` alert, registry
500 errors blocking CI/CD pushes (`XMinioStorageFull`), and runner job completion failures.
(2) The Atuin backup CronJob used the wrong NFS path format and the backup directory was
never created on the NAS. (3) A Next.js build OOM-killed k8s-cp3 - the 2Gi runner build pod
memory limit was insufficient for Docker-in-Docker builds, causing node-level memory pressure
that froze kubelet and required a power cycle.

### Fixes

| Fix | Details |
|-----|---------|
| Registry garbage collection | Ran `registry garbage-collect --delete-untagged` to remove orphaned blobs from 41→6 revisions |
| Minio PVC 10Gi → 20Gi | Longhorn online expansion. Added `minio.persistence` to `helm/gitlab/values.yaml` |
| Remove unused `registry.persistence` | Registry data goes through minio (S3 backend), not a local PVC. Config was inert and misleading |
| Atuin backup NFS path | Fixed `/export/Kubernetes/Backups/atuin` → `/Kubernetes/Backups/atuin` (NFSv4 pseudo-root format) |
| NAS backup directory | Created `/export/Kubernetes/Backups/atuin` on OMV NAS |
| Failed job cleanup | Deleted `atuin-backup-29548440` to clear `KubeJobFailed` alert |
| GitLab runner restart | Restarted runner deployment to drop stale job 872 connection |
| Runner build pod memory 2Gi → 4Gi | Next.js `bun run build` + TypeScript peaks at ~3Gi, OOM-killed node. Updated `helm/gitlab-runner/values.yaml` |

### Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| 20Gi for minio (not 15Gi or 30Gi) | 10Gi was too tight once CI/CD started pushing images. 20Gi gives comfortable headroom. Alert fires at ~85% (17Gi) for early warning |
| Remove `registry.persistence` from values | When `global.minio.enabled=true` (default), registry uses minio as S3 backend. `registry.persistence` created no PVC and was misleading |
| NFSv4 path format | Matches Immich (`/Kubernetes/Immich`) and arr-stack (`/Kubernetes/Media`). OMV has `/export` with `fsid=0` as NFSv4 pseudo-root |
| 4Gi runner memory (not 8Gi) | 3Gi peak + docker daemon overhead fits within 4Gi. 8Gi would consume half a 16GB node. Cluster-side limit, not app-side - Invoicetron should also add `NODE_OPTIONS="--max-old-space-size=2048"` as belt-and-suspenders |

### Gotchas

- **Helm does NOT resize existing PVCs** - Must `kubectl patch pvc` manually. Values file update is for future installs only
- **NFSv4 pseudo-root** - OMV filesystem path `/export/Kubernetes/X` becomes NFSv4 mount path `/Kubernetes/X`. The `/export` prefix must be stripped for K8s NFS volumes
- **Registry GC requires `--delete-untagged`** - Without this flag, only unreferenced blobs are deleted. Untagged manifests (the main space consumer) are kept
- **Minio pod restart needed for PVC resize** - Longhorn expands the block device online, but kubelet only triggers the filesystem resize (ext4 `resize2fs`) during the next mount phase. Restart the pod to trigger `FileSystemResizePending` → resize
- **Runner stuck loop** - Runner submits "job succeeded" but gets "accepted, but not yet completed" when minio is full. Runner restart + pipeline cancel/retry is the fix
- **DinD builds can OOM-kill nodes** - Docker-in-Docker spawns multiple processes (docker daemon + build + app) sharing one cgroup. A Next.js `bun run build` peaking at ~3Gi combined with docker daemon overhead exceeded the 2Gi pod memory limit, triggering kernel OOM killer (SIGKILL). Node-level memory pressure froze kubelet, requiring power cycle of k8s-cp3. Raised to 4Gi limit with 1Gi request

---

## March 1, 2026 - Atuin Self-Hosted Shell History (v0.28.0)

### Summary

Self-hosted Atuin sync server for E2E encrypted shell history synchronization across all machines
(WSL2, Aurora DX, Distrobox containers). Two accounts (`rommel-personal`, `rommel-eam`) provide
context isolation between personal and work shell history. Server runs in a dedicated `atuin`
namespace with its own PostgreSQL instance, CiliumNetworkPolicies (per-pod ingress + egress),
weekly pg_dump backup to NAS, and full observability stack.

### New Components

| Component | Version | Purpose |
|-----------|---------|---------|
| Atuin Server | `ghcr.io/atuinsh/atuin:18.12.0` | Sync server (E2E encrypted, /healthz, metrics on 9001) |
| PostgreSQL | `docker.io/library/postgres:18.3` | Dedicated database for Atuin |
| Backup CronJob | `postgres:18.3` | Weekly pg_dump to NAS NFS (Sunday 2AM Manila) |

### Manifests Created (12 files)

| File | Kind | Purpose |
|------|------|---------|
| `manifests/atuin/namespace.yaml` | Namespace | PSS enforce:baseline, audit+warn:restricted |
| `manifests/atuin/postgres-deployment.yaml` | Deployment + PVC | PostgreSQL 18.3, 5Gi Longhorn, Recreate strategy |
| `manifests/atuin/postgres-service.yaml` | Service | ClusterIP port 5432 |
| `manifests/atuin/server-deployment.yaml` | Deployment + PVC | Atuin 18.12.0, init container wait-for-db, 10Mi config PVC |
| `manifests/atuin/server-service.yaml` | Service | ClusterIP port 8888 |
| `manifests/atuin/httproute.yaml` | HTTPRoute | atuin.k8s.rommelporras.com via homelab-gateway |
| `manifests/atuin/networkpolicy-ingress.yaml` | CiliumNetworkPolicy (x2) | Per-pod ingress: server (gateway, monitoring, host) + postgres (server, backup, host) |
| `manifests/atuin/networkpolicy-egress.yaml` | CiliumNetworkPolicy (x3) | Per-pod egress: server (DNS, postgres), postgres (DNS), backup (DNS, postgres, NAS NFS) |
| `manifests/atuin/backup-cronjob.yaml` | CronJob | Weekly pg_dump, 28-day retention, NFS to NAS |
| `manifests/monitoring/dashboards/atuin-dashboard-configmap.yaml` | ConfigMap | Grafana dashboard (Pod Status, Network, Resources) |
| `manifests/monitoring/alerts/atuin-alerts.yaml` | PrometheusRule | 4 alerts: AtuinDown, AtuinPostgresDown, AtuinHighRestarts, AtuinHighMemory |
| `manifests/monitoring/probes/atuin-probe.yaml` | Probe | Blackbox HTTP probe on internal ClusterIP /healthz |

### Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| Deployment+Recreate over StatefulSet | Simpler, matches other homelab services. Single replica with RWO PVC - StatefulSet adds complexity with no benefit |
| `enforce: baseline` PSS (not restricted) | Backup CronJob uses NFS volume which violates restricted PSS profile |
| Shared encryption key across accounts | `atuin register` reuses `~/.local/share/atuin/key` by design. Server enforces user isolation. Separate key only needed for third-party users |
| `rommel-eam` naming (not `rommel-work`) | Department/company-specific naming scales to future employers (e.g. `rommel-freelance`, `rommel-acme`) |
| Internal Blackbox probe URL (not external) | External URL returns 403 from inside cluster (Cilium Gateway hairpin routing). Internal ClusterIP tests pod health directly |
| Uptime Kuma accepts 403 | In-cluster hairpin through Cilium Gateway returns 403 - same pattern as Karakeep. External URL with accepted status codes `200-299, 403` |

### Gotchas

- **Image tag `v18.12.1` does not exist on GHCR** - `v18.12.1` was a client-only patch. Server image is `18.12.0` (no `v` prefix)
- **Entrypoint is `atuin-server`, args `["start"]`** - NOT `atuin server start`. The container entrypoint is `/usr/local/bin/atuin-server`
- **`atuin register` password with special chars** - Wrap in single quotes in zsh. Characters like `*` trigger glob expansion
- **`atuin sync` requires `$ATUIN_SESSION`** - After `atuin import zsh`, run `exec zsh` to reload shell and set the session variable
- **Cilium Gateway HTTPRoute stall** - New HTTPRoute may not reconcile until `kubectl rollout restart deployment/cilium-operator -n kube-system`

---

## February 21, 2026 - ARR Stack Quality Profile & Tdarr Resolution Filter (v0.27.1)

### Summary

Two operational fixes. First: the TRaSH Guide quality profiles in Sonarr (WEB-1080p) and Radarr
(HD Bluray + WEB) are too restrictive for casual requests - Seerr requests that couldn't find any
release with the strict profile (WEBDL/WEBRip 1080p only) sat unfulfilled. A new "Relaxed WEB"
profile was created in both apps that adds HDTV-720p, WEB-720p, and HDTV-1080p as accepted
qualities, and Seerr was updated to use it as the default. The TRaSH profiles are untouched
(Configarr continues to manage them). Second: Tdarr's decision maker height filter was raised from
`min: 0` to `min: 1082`, preventing files at 1080p or below from entering the transcode pipeline.
1080p and below WEB content is already efficiently encoded and transcoding adds generation loss
with minimal space savings.

### ARR Stack Changes

| Change | Details |
|--------|---------|
| Add `Relaxed WEB` quality profile - Sonarr (id: 8) | Enables: HDTV-720p, WEBDL-720p, WEBRip-720p, HDTV-1080p, WEB 1080p group. Upgrades allowed, cutoff = WEB 1080p. TRaSH `WEB-1080p` profile untouched |
| Add `Relaxed WEB` quality profile - Radarr (id: 9) | Enables: WEBDL-720p, WEBRip-720p, HDTV-1080p, Bluray-720p, WEB 1080p group, Bluray-1080p. Upgrades allowed, cutoff = WEB 1080p. TRaSH `HD Bluray + WEB` profile untouched |
| Update Seerr default profile → `Relaxed WEB` | Both Radarr (id: 9) and Sonarr (id: 8) including anime profile. Changed via `settings.json` + pod restart |
| Backfill 5 stuck Radarr movies to `Relaxed WEB` | Cake, Network, Try Seventeen, Outlander, Parasite - added before profile fix, were on strict TRaSH profile with no grabs. Re-searched |
| Backfill 2 stuck Sonarr series to `Relaxed WEB` | The Flash (2014), Fallout - same issue. The Flash triggered full series search; Fallout already downloading |

### Tdarr Changes

| Change | Details |
|--------|---------|
| Raise `video_height_range_include.min` 0 → 1082 | Decision Maker height filter (API-level). Files with height ≤ 1080px no longer enter the transcode pipeline. 4K (2160p) content unaffected |
| Add `filterResolutionsSkip`: `480p,576p,720p,1080p` | Filters tab → Resolutions to skip (UI-level). Label-based companion filter - skips files Tdarr identifies as 480p, 576p, 720p, or 1080p from the transcode queue. Double protection alongside the height range filter |

### Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| New profile instead of editing TRaSH profile | Configarr (TRaSH Guide manager) runs on a schedule and would overwrite any edits to `WEB-1080p` / `HD Bluray + WEB`. Custom profile is invisible to Configarr |
| HDTV-720p/1080p enabled in Relaxed WEB | Most older broadcast TV (CW, NBC, etc.) only has HDTV rips on public indexers - the WEB release either never existed or is dead. HDTV-1080p from broadcast is comparable quality to WEB-720p |
| Tdarr height cutoff at 1082 not 2000 | Captures 1440p content (rare but valid) for transcoding while precisely excluding 1080p (height=1080). H264 content is already excluded at the codec level regardless of resolution |

---

## February 21, 2026 - Alert Quality Improvements (Pre-Release Fixes)

### Summary

Systematic review of overnight Discord alerts revealed 5 issues: 1 blocker (Alertmanager
reconcile broken since Feb 19), 2 noisy rules (CPUThrottlingHigh threshold too low, info severity
routed to Discord), 1 false positive (NodeMemoryMajorPagesFaults fired from NFS I/O not memory
exhaustion), and 1 dashboard/alert bug (KubeVipLeaseStale showing duplicate values and
susceptible to false positives during kube-state-metrics restarts).

### Root Cause: Alertmanager Broken Since Feb 19

The Feb 19 `helm upgrade` was run directly (without `./scripts/upgrade-prometheus.sh`), overwriting
the base alertmanager secret with literal `SET_VIA_HELM` placeholder strings. Go's URL parser
returned `scheme=""` for these values, causing the Prometheus Operator to fail every reconcile
attempt for 44+ hours. Alertmanager was still running on its last-known-good config, so alerts
continued firing - but new config changes were silently not applied. **Fix: always use
`./scripts/upgrade-prometheus.sh` for kube-prometheus-stack upgrades.**

### Alert Changes

| Change | File | Details |
|--------|------|---------|
| Fix `KubeVipLeaseStale` - add `max()` | `alerts/kube-vip-alerts.yaml` | `max()` collapses pod/instance labels from kube-state-metrics, prevents duplicate alert series during kube-state-metrics restarts (e.g. Helm upgrades) |
| Fix `KubeVipLeaseStale` - `for: 1m → 2m` | `alerts/kube-vip-alerts.yaml` | Absorbs transient API server load spikes during Helm upgrades (~90s blip) that caused false-positive firing |
| Disable built-in `CPUThrottlingHigh` | `helm/prometheus/values.yaml` | Replaced by custom rule at 50% threshold, arr-stack excluded |
| Add custom `CPUThrottlingHigh` | `alerts/cpu-throttling-alerts.yaml` (new) | Threshold raised 25% → 50%; arr-stack excluded (Tdarr transcoding + Byparr headless browser are always bursty) |
| Disable built-in `NodeMemoryMajorPagesFaults` | `helm/prometheus/values.yaml` | Replaced by compound condition rule |
| Add custom `NodeMemoryMajorPagesFaults` | `alerts/node-alerts.yaml` (new) | Now requires `rate(pgmajfault) > 2000` AND `MemAvailable < 15%` simultaneously - confirmed false positive: k8s-cp1 had 7.5GB free during original alert, caused by Tdarr NFS reads |
| Route `info` severity → `null` | `helm/prometheus/values.yaml` | Info alerts are non-actionable; visible in Alertmanager UI only, no Discord pings |
| Fix 🔴 on RESOLVED critical alerts | `helm/prometheus/values.yaml` | `discord-incidents-email` title was hardcoded 🔴; now uses `{{ if eq .Status "firing" }}🔴{{ else }}✅{{ end }}` |

### Dashboard Changes

| Dashboard | Change |
|-----------|--------|
| kube-vip | `Lease Age` panel query wrapped in `max()` - prevents two-box display during kube-state-metrics restarts |

### Prometheus Config Changes

| Change | Details |
|--------|---------|
| Add `externalLabels.cluster: homelab` | Fixes `on cluster .` (empty cluster name) shown in all CPUThrottlingHigh alert descriptions |

### Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| `info` → `null` routing | `info` severity is intentionally non-paging in Prometheus conventions. CPUThrottlingHigh is `info` severity - routing it to Discord caused midnight noise from Tdarr/Byparr/Ghost doing normal work |
| CPUThrottlingHigh 50% threshold | Three services crossed 25% during normal operation (tdarr 100%, byparr 28%, ghost 35%). None required action. 50% still catches truly saturated containers while ignoring bursty-by-design workloads |
| arr-stack excluded from CPUThrottlingHigh | Media transcoding (Tdarr) and headless browser (Byparr) are inherently bursty CPU workloads. 100% throttling during an encode run is expected and cannot be actioned |
| NodeMemoryMajorPagesFaults compound condition | Major page faults are generated by NFS reads (cold cache miss), not just memory exhaustion. Tdarr reading 20GB 4K files from NFS produces 1000+ faults/sec with 7.5GB free RAM. The compound condition ensures the alert only fires when memory is genuinely low |
| `KubeVipLeaseStale for: 2m` | kube-vip renews its lease every ~2.5s. Helm upgrades cause ~90s API server load spikes that stall renewal without indicating a real VIP failure. 2m `for` absorbs these transients while still catching genuine failures (node down, etcd issue) in reasonable time |

---

## February 21, 2026 - Phase 4.28 Pre-Release: Dashboard Alert Gaps + Tdarr/qBit Alerts

### Summary

Systematic audit of all 11 Grafana dashboards cross-referenced against existing PrometheusRule
files revealed 5 monitoring gaps. All 5 fixed pre-release. Additional operational alerts added for
Tdarr transcode/health check failures and qBittorrent stalled downloads.

### Alert Changes

| Change | File | Details |
|--------|------|---------|
| Fix `ClaudeCodeNoActivity` timezone bug | `alerts/claude-alerts.yaml` | `hour() >= 17` → `hour() >= 9` (was firing at 1-2am Manila, UTC+8) |
| Add `JellyfinHighMemory` | `alerts/arr-alerts.yaml` | Warn when memory > 3.5Gi (87% of 4Gi limit); QSV can spike ~500Mi/stream |
| Add `NVMeTemperatureHigh` | `alerts/storage-alerts.yaml` | `smartctl_device_temperature{temperature_type="current"} > 65` for 10m; SK Hynix max = 70°C, baseline = 46°C |
| Add `ServiceHighResponseTime` | `alerts/service-health-alerts.yaml` (new) | `probe_duration_seconds > 5s` on public services (ghost, invoicetron, portfolio, jellyfin, seerr, karakeep) |
| Add `BazarrDown` | `alerts/arr-alerts.yaml` | Blackbox probe failure on Bazarr subtitle downloader (arr-stack:6767) |
| Add `TdarrTranscodeErrors` | `alerts/arr-alerts.yaml` | `increase(tdarr_library_transcodes{status="error"}[1h]) > 2` for 15m - warning |
| Add `TdarrTranscodeErrorsBurst` | `alerts/arr-alerts.yaml` | `increase(...) > 15` for 0m - critical → #incidents + email |
| Add `TdarrHealthCheckErrors` | `alerts/arr-alerts.yaml` | `increase(tdarr_library_health_checks{status="error"}[1h]) > 5` for 15m - warning |
| Add `TdarrHealthCheckErrorsBurst` | `alerts/arr-alerts.yaml` | `increase(...) > 50` for 0m - critical → #incidents + email |
| Add `QBittorrentStalledDownloads` | `alerts/arr-alerts.yaml` | `sum(qbittorrent_torrents_count{status="stalledDL"}) > 0` for 45m - warning |

### New Probe

| File | Target | Notes |
|------|--------|-------|
| `probes/bazarr-probe.yaml` | `bazarr.arr-stack.svc:6767` | HTTP 2xx, interval 60s. `probe_success{job="bazarr"} = 1` confirmed UP. |

### Dashboard Changes

| Dashboard | Change |
|-----------|--------|
| Service Health | Added Bazarr stat panel (fills empty row 3 slot at y=9, x=18); added Bazarr to Uptime History and Response Time time series |
| ARR Stack | Added `instant: true` to pod status panel queries (prevents stale range data on stat panels) |

### Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| Use `increase()[1h]` for Tdarr alerts | Tdarr metrics are cumulative counters - 73+ health check errors already existed from historical runs. Using raw `> 0` would fire permanently and never auto-resolve. `increase()[1h]` measures new errors in a sliding 1h window; drops to 0 when errors stop → auto-resolves ~1h later. |
| Tdarr warning thresholds (>2 encode, >5 health) | Avoids false positives from occasional one-off plugin failures or minor file variance |
| Tdarr critical thresholds (>15 encode, >50 health) | Burst-level: 15 encode failures/hr = systematic plugin failure; 50 health/hr = likely NFS/storage issue affecting all files |
| qBittorrent `for: 45m` | `stalledDL` is briefly normal (peers connecting). 45m = stall-resolver CronJob has run 1-2 cycles and still couldn't clear it |
| Alert scope for `ServiceHighResponseTime` | Excludes internal tools (Tdarr, Byparr, AdGuard) - internal services often have slow initial responses. Only public/user-facing services alerted. |
| Auto-resolve is already built in | Alertmanager sends ✅ RESOLVED automatically when PromQL expr drops to 0 results. Discord #status title uses `{{ if eq .Status "firing" }}⚠️{{ else }}✅{{ end }}` - no extra config needed. |

---

## February 20, 2026 - Tdarr: Debugging, Worker Tuning & Phase 4.29 Planning

### Summary

Investigated 4 Tdarr transcode errors for Frieren episodes. Root cause: DASH-remuxed WEB-DL files
(mp41 container) lack per-stream video `BitRate` metadata, causing the Boosh-Transcode QSV plugin
to compute `undefined × 0.8 = NaN` → `-b:v NaNk` in the ffmpeg command (exit code 234). Partial
fix applied (min/max bitrate bounds set); 10 ToonsHub DASH-remuxed files added to Tdarr skip list.
Inception 3D SBS resolved by adding one CPU worker slot. Library at 100% Tdarr score with 0
errors. Phase 4.29 Vault + ESO design approved and 21-task plan committed to git.

### Tdarr Bug Investigation

| File Group | Root Cause |
|------------|-----------|
| Frieren S01E24–33 (10 files, ToonsHub) | DASH-remuxed WEB-DL (mp41 container). No per-stream `BitRate` field → `source_video_stream_bitrate × 0.8 = NaN`. ffmpeg args: `-b:v NaNk -minrate NaNk -maxrate NaNk -bufsize NaNk`. Exit code 234. |
| Inception 3D SBS HEVC (iFA-AI3D) | Lmg1 Reorder Streams plugin requires a CPU worker slot; internal node had 0 CPU workers. Status stuck at "Require CPU Worker". |

### Configuration Changes

| Item | Before | After | Rationale |
|------|--------|-------|-----------|
| Boosh-Transcode QSV: `min_average_bitrate` | 0 | 2000 | Overrides NaN `-minrate`; `max_average_bitrate` overrides NaN `-maxrate` |
| Boosh-Transcode QSV: `max_average_bitrate` | 0 | 8000 | Upper bound for files with no source bitrate metadata |
| Tdarr node: Transcode CPU workers | 1 | 1 | Kept - CPU transcode is slow; GPU is the correct tool |
| Tdarr node: Transcode GPU workers | 1 | 1 | Kept - one UHD 630 QSV session at a time is optimal |
| Tdarr node: Health Check CPU workers | 1 | 3 | Faster health check scans; ffprobe is I/O-bound and lightweight |
| Tdarr node: Health Check GPU workers | 1 | 0 | Health checks use ffprobe only - no GPU benefit; frees device slot |

### Tdarr Library State (end of session)

| Metric | Value |
|--------|-------|
| Files tracked | 90 |
| Tdarr score | 100% |
| Successfully transcoded | 41 |
| Transcode not required (already HEVC) | 49 |
| Transcode errors | 0 |
| Health check errors | 0 |
| Disk space saved | 14.1 GB |

### Phase 4.29 Planning

Design approved for Vault + ESO. Full 21-task plan committed to `docs/todo/phase-4.29-vault-eso.md`.
Targets v0.28.0. Production hardening shifted to v0.29.0.

| Component | Helm Chart Version | App Version | Purpose |
|-----------|-------------------|-------------|---------|
| HashiCorp Vault | 0.29.1 | v1.19.0 | 3-pod HA, Raft on Longhorn 5Gi/pod, auto-unseal via init container |
| External Secrets Operator | 0.14.4 | v0.14.4 | `ExternalSecret` CRD → K8s Secret sync via Kubernetes auth |

Migration scope: 7 namespaces, all `secret.yaml` placeholders → `externalsecret.yaml`. Every
secret in the cluster becomes a committed manifest with zero hardcoded values.

### Key Decisions

| Decision | Rationale |
|----------|-----------|
| Ignore DASH-remuxed files (skip list) | `extra_qsv_options` inserts BEFORE calculated values - cannot override NaN this way. No safe config-only fix. 10 files skipped permanently. |
| Keep Transcode GPU workers at 1 | Intel UHD 630 is one physical QSV device. Multiple simultaneous sessions compete for the same hardware and cause encode failures or slowdowns. NFS read is the real bottleneck. |
| Health Check CPU → 3 | ffprobe is I/O-bound and lightweight. 3 parallel probes finish 3× faster; pod's 2-core CPU limit gently throttles without failures. |
| Health Check GPU → 0 | Health checks use ffprobe only - no GPU acceleration. Setting to 0 frees the UHD 630 device slot for transcoding. |
| Add CPU worker for Inception 3D | Lmg1 Reorder Streams requires a CPU worker slot even in a GPU transcode pipeline. 3D SBS files need stream reordering before encode. One slot is sufficient. |
| Tdarr stats API caches state | Tdarr stats endpoint caches previous file states. `FileJSONDB` `HealthCheck` field is ground truth. Grafana exporter metrics lag until cache refreshes after scan completes. |

---

## February 19–20, 2026 - Phase 4.28 (Complete): Alerting & Observability

### Summary

Phase 4.28 complete - 20 new alerts + NVMe S.M.A.R.T. monitoring + ARR stall resolver + Tdarr and qBittorrent Prometheus exporters + 11 Grafana dashboards (6 new/rewritten, 5 updated). All 11 dashboards in "Homelab" folder. Control plane bind addresses fixed. kube-vip VIP loss root-caused and KubeApiserverFrequentRestarts alert added. kube-vip, Network, and Scraparr dashboards fully overhauled after initial standardization pass.

### Infrastructure Changes

| Change | Description |
|--------|-------------|
| monitoring/ reorganization | 55 flat files → 8 typed subdirectories (alerts/, dashboards/, exporters/, grafana/, otel/, probes/, servicemonitors/, version-checker/) |
| smartctl_exporter | DaemonSet on all 3 nodes for NVMe S.M.A.R.T. metrics. Pinned to `/dev/nvme0`, 5 Helm-provided PrometheusRules + 3 custom NVMe alerts |
| ARR stall resolver | CronJob (every 30 min) automates stuck torrent resolution - switches quality profile to Any and blocklists dead releases to trigger re-search |
| Grafana folder organization | Enable sidecar `folderAnnotation` in Prometheus Helm values; add `grafana_folder: "Homelab"` to all 11 dashboard ConfigMaps |
| Prometheus HTTPRoute | Exposed Prometheus UI at `prometheus.k8s.rommelporras.com` |
| Alertmanager HTTPRoute | Exposed Alertmanager UI at `alertmanager.k8s.rommelporras.com` |
| Homepage widgets | Prometheus targets count + Alertmanager firing count (excludes Watchdog) |
| kubeadm bind addresses | Fixed etcd/kube-controller-manager/kube-scheduler to `0.0.0.0` so Prometheus can scrape |
| kubeProxy disabled | `kubeProxy.enabled: false` in Helm values - Cilium replaces kube-proxy |
| version-checker memory | Memory request 64Mi→128Mi, limit 128Mi→256Mi (was OOMKilled scanning 137 pods) |
| tdarr-exporter | Deployment + Service (`homeylab/tdarr-exporter`, port 9090) + ServiceMonitor (60s). Exposes library stats: GB Saved, Tdarr Score %, Files, Transcodes by status, Health Check errors, codec/container/resolution breakdown |
| qbittorrent-exporter | Deployment + Service (`esanchezm/prometheus-qbittorrent-exporter`, port 8000) + ServiceMonitor (30s). Exposes torrent counts by status (downloading/seeding/stalled/paused) and transfer rates |

### Alerting Infrastructure Completed (Phase 4.28)

| Item | Files | Status |
|------|-------|--------|
| Jellyfin probe (fixes broken JellyfinDown) | `probes/jellyfin-probe.yaml` | Done |
| Ghost probe + alert | `probes/ghost-probe.yaml`, `alerts/ghost-alerts.yaml` | Done |
| Invoicetron probe + alert | `probes/invoicetron-probe.yaml`, `alerts/invoicetron-alerts.yaml` | Done |
| Portfolio probe + alert | `probes/portfolio-probe.yaml`, `alerts/portfolio-alerts.yaml` | Done |
| Seerr probe + alert | `probes/seerr-probe.yaml`, `alerts/arr-alerts.yaml` | Done |
| Tdarr probe + alert | `probes/tdarr-probe.yaml`, `alerts/arr-alerts.yaml` | Done |
| Byparr probe + alert | `probes/byparr-probe.yaml`, `alerts/arr-alerts.yaml` | Done |
| Uptime Kuma alert | `alerts/uptime-kuma-alerts.yaml` | Done |
| Longhorn ServiceMonitor + alerts | `servicemonitors/longhorn-servicemonitor.yaml`, `alerts/storage-alerts.yaml` | Done |
| cert-manager ServiceMonitor + alerts | `servicemonitors/certmanager-servicemonitor.yaml`, `alerts/cert-alerts.yaml` | Done |
| Cloudflare Tunnel alerts | `alerts/cloudflare-alerts.yaml` | Done |
| KubeApiserverFrequentRestarts | `alerts/apiserver-alerts.yaml` | Done |
| NVMe SMART alerts (3) | `alerts/storage-alerts.yaml` - NVMeMediaErrors (critical), NVMeSpareWarning, NVMeWearHigh | Done |
| ARR queue health alerts (2) | `alerts/arr-alerts.yaml` - ArrQueueWarning (60m stall), ArrQueueError (15m) | Done |
| AdGuard alert label fix | `alerts/adguard-dns-alert.yaml` | Done |
| LokiStorageLow removed | `alerts/logging-alerts.yaml` | Done |

### Dashboards Created/Updated

| Dashboard | Change |
|-----------|--------|
| Longhorn Storage (new) | Storage Health stats, NVMe S.M.A.R.T. section (6 stat panels: SMART status, temp, spare, wear, TBW, power-on - replaced initial table panel with single stat row saving 4 vertical rows, drive model/serial/firmware in row description hover), Node Disk Usage, Volume I/O Throughput + IOPS |
| Service Health (new) | 11 UP/DOWN probe stat panels, Uptime History + Response Time time series; `max()` on all queries to collapse stale TSDB series |
| kube-vip (full rewrite) | Fix Instance Health thresholds (red<2, yellow=2, green=3), per-node labels via `label_replace` (cp1/cp2/cp3), merge Process+Network into one collapsed row, multi-series tooltip, right-side table legend, 30s refresh. Remove non-existent `kube_lease_spec_lease_transitions` panel. |
| Network (full overhaul) | Per-node queries (cp1/cp2/cp3), deduplicate with `sum/max by()`, NIC Utilization % Over Time with 80% threshold line, multi-series tooltip, right-side table legend, per-node color overrides |
| Scraparr | Widen Service Health panels w=4→6, fix Prowlarr indexers query (`sum by type`), restructure Disk Usage to Library Size + Media Storage Free, improved descriptions |
| ARR Stack | Added Byparr companion panel, fixed Container Restarts to `increase()`, added Tdarr Library Stats row (GB Saved, Score%, Files, Transcodes Done/Queue/Errors, Health Check Errors), qBittorrent Download Activity row (Downloading/Seeding/Stalled/Paused/DL Speed/UL Speed), Recent Activity row (Loki log panels). Row order: Core → Companions → Tdarr → qBit → Network → Resources → Restarts → Activity. Fixed Configarr panel showing "configarr OK" → "OK". |
| Jellyfin | Standardized JSON formatting |
| Tailscale | Standardized JSON formatting |
| UPS | Added tags (`ups`, `power`, `infrastructure`) |
| Version Checker | Added tags (`version-checker`, `maintenance`, `upgrades`) |
| Claude | Simplified tags |
| All 11 dashboards | Added `grafana_folder: "Homelab"` annotation for Grafana folder organization |

### kube-vip VIP Loss Investigation

**Root cause chain:**
1. etcd had a transient blip → API server `/livez` returned HTTP 500
2. Kubelet killed the API server after 7 consecutive liveness probe failures
3. kube-vip on cp1 (the leader) could not renew its lease lock → dropped the VIP
4. ~2 min gap with no VIP → all `kubectl` calls timed out
5. cp2 won leader election → VIP restored

**Restart counts (34 days):** cp1=7, cp2=21, cp3=30 - cp3 averaging ~1 restart/day.

**Resolution:** Added `KubeApiserverFrequentRestarts` alert - fires when any kube-apiserver pod exceeds 5 restarts in 24h. Currently NOT firing (cp1=2, cp2=1, cp3=2 restarts/24h, all below threshold).

### Key Decisions

| Decision | Rationale |
|----------|-----------|
| smartctl_exporter pinned to `/dev/nvme0` | Avoids scraping Longhorn iSCSI virtual block devices that appear as `/dev/sd*` on each node |
| NVMe alerts in storage-alerts.yaml | Groups all storage alerting (Longhorn volumes + NVMe health) in one file |
| Stall resolver CronJob every 30 min | Two cycles (60 min) before ArrQueueWarning fires - gives automation time to resolve before alerting |
| Stall resolver skips importPending/importBlocked | Different root cause (NFS/disk issues) requires manual intervention, not blocklisting |
| `grafana_folder: "Homelab"` on all dashboards | Organizes custom dashboards into dedicated folder, separate from kube-prometheus-stack defaults |
| Longhorn NVMe table → 6 stat panels | Zero tables across all dashboards. Removed table panel, consolidated SMART/Temp/Spare/Wear/TBW/Power-On into one stat row. Drive model/serial/firmware moved to NVMe Health row description (hover) - static reference data, not monitoring. |
| `max()` on all probe stat panels | Prevents stale TSDB series from creating duplicate stat panels when probe targets change |
| `increase($__rate_interval)` for Container Restarts | Cumulative counter misleads at short time ranges; `increase()` shows new restarts per window |
| Expose Prometheus/Alertmanager via HTTPRoute | Needed for Homepage widgets and direct troubleshooting |
| Watchdog excluded from Homepage firing count | `alertname!="Watchdog"` - intentional dead man's switch, always fires |
| kube-vip Network panels show host traffic | `hostNetwork: true` means RX/TX panels show all host network I/O (~485 KB/s), not just kube-vip ARP traffic - documented in panel descriptions |
| qBittorrent torrent count uses `sum()` | Torrent metrics include `category` label - `sum()` aggregates across all categories to give total count |

---

## February 19, 2026 - v0.26.0: Version Automation & Upgrade Runbooks

### Summary

Phase 4.27 - three-tool automated version tracking covering container images, Helm charts, and Kubernetes version. Includes upgrade/rollback runbook for all component types.

### New Components

| Component | Version | Type | Purpose |
|-----------|---------|------|---------|
| version-checker | v0.10.0 | Deployment | Container + K8s version drift → Prometheus metrics |
| Nova CronJob | v3.11.10 | CronJob | Weekly Helm chart drift digest → Discord #versions |
| Renovate Bot | GitHub App | SaaS | Automated image update PRs with dependency dashboard |
| Nova CLI | v3.11.10 | Local binary | On-demand Helm chart analysis |

### Prerequisites Completed

| Image | Before | After |
|-------|--------|-------|
| bazarr | `:latest` | `v1.5.5-ls338` |
| radarr | `:latest` | `6.0.4.10291-ls293` |
| sonarr | `:latest` | `4.0.16.2944-ls303` |
| firefox | `:latest` | `1147.0.3build1-1xtradeb1.2404.1-ls69` |

All pinned images also got `match-regex` version-checker annotations for LinuxServer.io tag format and `imagePullPolicy: IfNotPresent`.

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Renovate over Dependabot | Renovate | Better K8s manifest support, weekly grouping, dependency dashboard |
| version-checker over custom | version-checker | Maintained project, Prometheus-native, includes K8s version tracking |
| `--test-all-containers` | Flag | Scans all pods without annotation opt-in |
| CronJob uses Nova | Nova JSON | Eliminates brittle bash semver parsing and API rate limits |
| Init container for Nova | Copy pattern | Avoids building custom image, CKA-relevant pattern |
| byparr cannot be pinned | Renovate ignore | Only publishes `latest`/`main`/`nightly` tags (no semver) |
| CronJob runs as root | Intentional | Alpine `apk` needs write access to `/lib/apk/db` |
| Nova CLI via tarball | GitHub release | Ubuntu WSL has no brew; installed to `~/.local/bin` |

### Files Created

| File | Purpose |
|------|---------|
| renovate.json | Renovate Bot configuration |
| manifests/monitoring/version-checker-rbac.yaml | ServiceAccount, ClusterRole, ClusterRoleBinding |
| manifests/monitoring/version-checker-deployment.yaml | Deployment + Service (port 8080) |
| manifests/monitoring/version-checker-servicemonitor.yaml | ServiceMonitor (1h scrape) |
| manifests/monitoring/version-checker-alerts.yaml | PrometheusRule (3 alerts) |
| manifests/monitoring/version-checker-dashboard-configmap.yaml | Grafana dashboard |
| manifests/monitoring/version-check-rbac.yaml | CronJob RBAC (secrets read) |
| manifests/monitoring/version-check-script.yaml | CronJob script ConfigMap |
| manifests/monitoring/version-check-cronjob.yaml | CronJob (Sunday 00:00 UTC) |
| docs/context/Upgrades.md | Upgrade/rollback runbook |

### Files Modified

| File | Change |
|------|--------|
| manifests/arr-stack/bazarr/deployment.yaml | Pin image, add match-regex annotation |
| manifests/arr-stack/radarr/deployment.yaml | Pin image, add match-regex annotation |
| manifests/arr-stack/sonarr/deployment.yaml | Pin image, add match-regex annotation |
| manifests/browser/deployment.yaml | Pin image, add match-regex annotation |
| docs/context/_Index.md | Add Upgrades.md to Quick Links |

---

## February 19, 2026 - v0.25.2: ARR Media Quality and Playback Fixes

### Summary

Fixed Italian-default audio in Jellyfin, added language release filtering, expanded Configarr quality profiles for better release availability, and raised minimum seeders to avoid stuck low-seed downloads.

### Bug Fixes

| Issue | Root Cause | Fix |
|-------|-----------|-----|
| Jellyfin defaulting to Italian audio on multi-language releases | Preferred Audio Language not set - Jellyfin respected MKV file's default track flag (Italian) over user preference | Set Preferred Audio Language to `Auto`, Subtitle Mode to `Smart`, Preferred Subtitle Language to `English` in Jellyfin user settings |
| Italian audio releases downloaded by Radarr/Sonarr | No language filtering - Italian-first multi-audio releases (e.g. `iTA-ENG`, CYBER/Licdom release groups) grabbed freely | Added Custom Format "Penalize Italian Dub" (Language = Italian, score -10000) to all quality profiles in both Radarr and Sonarr |
| K-pop Demon Hunters stuck on Italian 4K release | Movie assigned to unmanaged 4K profile, no replacement found at -10000 score | Changed quality profile to "HD Bluray + WEB", grabbed `KPop.Demon.Hunters.2025.1080p.WEB.h264-EDITH` |
| Mercy grabbed Italian release | `Mercy.2026.iTA-ENG.WEBDL.1080p.x264-CYBER.mkv` was the only available release | Penalize Italian Dub CF scored it -10000, triggered automatic search, grabbed `Mercy.Sotto.Accusa.2026.1080p.AMZN.WEB-DL.DDP5.1.H.264-FHC_CREW` |
| Konosuba episodes stuck downloading (<5 seeds) | minimumSeeders was 1 on all indexers - Sonarr grabbed the first available release regardless of seed count | Raised minimumSeeders from 1 → 10 on all Sonarr and Radarr indexers via API |
| No 4K quality profile in Radarr | Configarr only synced `radarr-quality-profile-hd-bluray-web` (1080p) | Added `radarr-quality-profile-uhd-bluray-web` + `radarr-custom-formats-uhd-bluray-web` templates to Configarr |
| Sonarr WEB-only releases (no BluRay sources) | Configarr only synced `sonarr-v4-quality-profile-web-1080p` | Added `sonarr-v4-quality-profile-hd-bluray-web` + `sonarr-v4-custom-formats-hd-bluray-web` templates to Configarr |

### Configuration Changes

| App | Setting | Before | After |
|-----|---------|--------|-------|
| Jellyfin | Preferred Audio Language | English | Auto (uses file default) |
| Jellyfin | Subtitle Mode | Default | Smart |
| Jellyfin | Preferred Subtitle Language | - | English |
| Radarr + Sonarr | All indexers minimumSeeders | 1 | 10 |
| Radarr | Quality profiles | HD Bluray + WEB only | + UHD Bluray + WEB |
| Sonarr | Quality profiles | WEB-1080p only | + HD Bluray + WEB |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Jellyfin audio preference | `Auto` (not `English`) | "English" would force English dub on Korean/Japanese movies; `Auto` respects original language when file is correctly flagged |
| Subtitle mode | `Smart` | Shows English subs only when audio is non-English - no subs on English content, subs on Korean/Japanese automatically |
| Language filter approach | Custom Format -10000 (not hard restriction) | Allows fallback to Italian release if no alternative exists; just heavily penalizes |
| minimumSeeders | 10 | Filters out sub-5-seed stuck torrents while still allowing niche content with moderate seeding |
| minimumSeeders set via API | Bulk API update | "Minimum Seeders" is a hidden field (requires "Show hidden" in UI) - API faster than editing 8 indexers manually |
| Configarr Custom Format scores | Manual per new profile | Configarr manages TRaSH CF scores but not user-added CFs - must manually set -10000 on each new profile Configarr creates |

### Files Modified

| File | Change |
|------|--------|
| manifests/arr-stack/configarr/configmap.yaml | Added UHD Bluray + WEB profile for Radarr; added HD Bluray + WEB profile for Sonarr |

---

## February 18, 2026 - v0.25.1: ARR Alert and Byparr Fixes

### Bug Fixes

| Issue | Root Cause | Fix |
|-------|-----------|-----|
| RadarrQueueStalled false positive (permanently firing) | Alert used `changes(radarr_movies_total[2h])` which tracks library size, not downloads - metric almost never changes | Rewrite to `radarr_queue_count > 0 and changes(radarr_missing_movies_total[2h]) == 0` - only fires when queue items exist but aren't completing |
| SonarrQueueStalled false positive (same issue) | Same flawed pattern using `sonarr_episodes_total` | Same fix using `sonarr_queue_count` and `sonarr_missing_episodes_total` |
| Byparr restart loop (16 restarts in 14h) | Liveness probe `/health` runs Playwright browser page load; 10s timeout too short when browser busy with real requests | Relaxed probe: 30s timeout, 60s period, 5 failures (5min grace vs 90s) |

### Files Modified

| File | Change |
|------|--------|
| manifests/monitoring/arr-alerts.yaml | Rewrite SonarrQueueStalled + RadarrQueueStalled expressions |
| manifests/arr-stack/byparr/deployment.yaml | Relax liveness probe timing |

---

## February 18, 2026 - Phase 4.26: ARR Companions

### Milestone: Complete Media Automation Platform

Deployed 7 companion apps to the ARR media stack: Seerr (media requests + discovery), Configarr (TRaSH Guide quality sync), Unpackerr (RAR extraction), Scraparr (Prometheus metrics), Tdarr (QSV library transcoding), Recommendarr (AI recommendations via Ollama), and Byparr (Cloudflare bypass for Prowlarr indexers). Added Grafana dashboards, alert rules, Homepage redesign, Discord notifications, and import list configuration.

| App | Version | Type | Purpose |
|-----|---------|------|---------|
| Seerr | v3.0.1 | Deployment | Media requests + discovery (replaces Jellyseerr/Overseerr) |
| Configarr | 1.20.0 | CronJob | TRaSH Guide quality profile sync (daily 3AM) |
| Unpackerr | v0.14.5 | Deployment | RAR archive extraction daemon |
| Scraparr | 3.0.3 | Deployment | Prometheus metrics exporter for all *ARR apps |
| Tdarr | 2.58.02 | Deployment | Library transcoding with Intel QSV (internal node) |
| Recommendarr | v1.4.4 | Deployment | AI recommendations via Ollama (qwen2.5:3b) |
| Byparr | latest (v2.1.0) | Deployment | Cloudflare bypass proxy (Camoufox/Firefox) |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Media requests | Seerr (not Overseerr/Jellyseerr) | Overseerr archived Feb 2026, Jellyseerr merged into Seerr |
| Quality sync | Configarr (not Recyclarr/Notifiarr) | Native K8s CronJob, no sidecar, Notifiarr is paid |
| Metrics exporter | Scraparr (not Exportarr) | Single deployment monitors all *ARR apps |
| Library transcoding | Tdarr (not manual) | QSV available on all nodes since Phase 4.25b |
| AI recommendations | Recommendarr | Reuses existing Ollama in `ai` namespace |
| Cloudflare bypass | Byparr (not FlareSolverr) | FlareSolverr dead, Byparr is active Camoufox replacement |
| Seeding policy | Ratio 0, auto-remove | NAS has single NVMe, no space for seeding |
| Import lists | TMDB Popular + Trakt Popular + AniList | MDBList skipped (user cancelled streaming subscriptions) |

### Integration Highlights

- **Homepage redesign:** 2-tab layout (Dashboard + Infrastructure), Seerr/Tdarr/Recommendarr widgets, Sonarr/Radarr calendar (agenda view)
- **Discord `#arr` channel:** Sonarr/Radarr webhook notifications (grab, import, health events)
- **NetworkPolicy:** arr-stack → ai namespace egress for Recommendarr → Ollama
- **NFS hardening:** Jellyfin mount set to `readOnly: true`
- **Tdarr QSV:** hevc_qsv encoding, 0.8 bitrate modifier, 2AM-8AM schedule, soft anti-affinity with Jellyfin

### Grafana Dashboards

| Dashboard | Purpose |
|-----------|---------|
| Scraparr ARR Metrics | Library size, queues, missing content, health per app |
| Network Throughput | 1GbE NIC utilization, saturation analysis (2.5GbE upgrade decision) |
| ARR Stack (updated) | Added companion app Pod Status panels + CPU/Memory queries |

### Files Added

| File | Purpose |
|------|---------|
| manifests/arr-stack/seerr/{deployment,service,httproute}.yaml | Seerr media requests |
| manifests/arr-stack/configarr/{cronjob,configmap}.yaml | Configarr TRaSH sync |
| manifests/arr-stack/unpackerr/deployment.yaml | Unpackerr extraction daemon |
| manifests/arr-stack/scraparr/{deployment,service,servicemonitor}.yaml | Scraparr metrics |
| manifests/arr-stack/tdarr/{deployment,service,httproute}.yaml | Tdarr transcoding |
| manifests/arr-stack/recommendarr/{deployment,service,httproute}.yaml | Recommendarr AI |
| manifests/arr-stack/byparr/{deployment,service}.yaml | Byparr Cloudflare bypass |
| manifests/monitoring/scraparr-dashboard-configmap.yaml | Scraparr Grafana dashboard |
| manifests/monitoring/network-dashboard-configmap.yaml | Network throughput dashboard |
| manifests/monitoring/arr-alerts.yaml | ARR PrometheusRule alerts |

### Files Modified

| File | Change |
|------|--------|
| manifests/arr-stack/networkpolicy.yaml | Added egress to ai namespace (Ollama port 11434) |
| manifests/ai/networkpolicy.yaml | Added ingress from arr-stack namespace |
| manifests/arr-stack/jellyfin/deployment.yaml | NFS mount set to readOnly |
| manifests/arr-stack/arr-api-keys-secret.yaml | Added TDARR_API_KEY field |
| scripts/apply-arr-secrets.sh | Added Tdarr API key injection |
| manifests/home/homepage/config/services.yaml | 2-tab redesign, companion widgets, calendar |
| manifests/home/homepage/config/settings.yaml | New layout with Calendar row |
| manifests/home/homepage/secret.yaml | Added SEERR_API_KEY to docs |
| manifests/monitoring/arr-stack-dashboard-configmap.yaml | Added companion pod status panels |

---

## February 17, 2026 - Phase 4.25b: Intel QSV Hardware Transcoding

### Milestone: GPU-Accelerated Media Streaming

Enabled Intel Quick Sync Video (QSV) hardware transcoding on all 3 cluster nodes for Jellyfin. Mobile streaming now transcodes via the UHD 630 iGPU with near-zero CPU impact. Deployed Node Feature Discovery, Intel Device Plugins Operator, and GPU Plugin to manage GPU resources through the Kubernetes device plugin API.

| Component | Version | Namespace | Status |
|-----------|---------|-----------|--------|
| Node Feature Discovery | 0.18.3 | node-feature-discovery | Running |
| Intel Device Plugins Operator | 0.34.1 | intel-device-plugins | Running |
| Intel GPU Plugin | 0.34.1 | intel-device-plugins | Running (DaemonSet) |
| intel-media-va-driver-non-free | 24.1.0 | (node packages) | Installed |

### Codec Support (UHD 630 / Comet Lake)

| Codec | HW Decode | HW Encode | Notes |
|-------|-----------|-----------|-------|
| H.264 8-bit | Yes | Yes | Most common format |
| HEVC 8/10-bit | Yes | Yes | Low-power encode via HuC firmware |
| VP9 8/10-bit | Yes | No | Decode only on Comet Lake |
| MPEG-2 | Yes | Yes | Legacy format |
| AV1 | No | No | Requires 11th gen+ |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| HW transcoding | Intel QSV (VA-API) | Built into existing CPUs, best quality-per-watt |
| Device access | Intel Device Plugin | PSS compatible, no privileged containers, proper scheduling |
| Node labeling | Node Feature Discovery | Auto-detects GPU, standard K8s ecosystem tool |
| GPU sharing | sharedDevNum: 3 | Allow 3 pods per node to share iGPU |
| HuC firmware | enable_guc=2 | Required for HEVC low-power encode on Comet Lake |
| Transcode cache | Disk-backed emptyDir | Avoids OOM/node crash risk vs tmpfs |
| Tone mapping | VPP (not OpenCL) | OpenCL broken in Jellyfin 10.11.x (#15576) |
| Ansible rolling reboot | serial: 1 | One node at a time, verify all gates before proceeding |

### Grafana Dashboards

| Dashboard | Panels | Highlights |
|-----------|--------|------------|
| Jellyfin Media Server | 11 | GPU allocation, Transcode I/O, Tailscale tunnel traffic |
| ARR Media Stack | 11 | All 6 services overview, merged Pod Status + node placement |

### Files Added

| File | Purpose |
|------|---------|
| ansible/playbooks/08-intel-gpu.yml | Intel GPU drivers + HuC firmware (rolling reboot) |
| helm/intel-gpu-plugin/values.yaml | Intel GPU Plugin configuration |
| manifests/monitoring/jellyfin-dashboard-configmap.yaml | Jellyfin + GPU Grafana dashboard |
| manifests/monitoring/arr-stack-dashboard-configmap.yaml | ARR Stack overview Grafana dashboard |

### Files Modified

| File | Change |
|------|--------|
| manifests/arr-stack/jellyfin/deployment.yaml | GPU resource, supplementalGroups, transcode emptyDir, 4Gi memory |

### Issues Discovered

| Issue | Impact | Fix |
|-------|--------|-----|
| Intel GPU Plugin inotify exhaustion (#2075) | Pod CrashLoopBackOff | `fs.inotify.max_user_instances=512` on all nodes |
| OPNsense stale firewall states after reboot | Cross-VLAN SSH blocked | Manual state clearing (documented for Phase 5 hardening) |
| Ansible `serial` resolves task names at parse time | Misleading task output | Use static task names, Ansible already prefixes with host |
| M80q BIOS POST takes 5-7 min | Ansible reboot timeout too short | Increased `reboot_timeout` to 600s |

---

## February 16, 2026 - Phase 4.25: ARR Media Stack

### Milestone: Self-Hosted Media Automation Platform

Deployed 6-app ARR media automation stack to `arr-stack` namespace: Prowlarr (indexer manager), Sonarr (TV), Radarr (movies), qBittorrent (download client), Jellyfin (media server), and Bazarr (subtitles). All apps share a single NFS PV mounted at `/data` for hardlink support between downloads and media library. App config stored on Longhorn PVCs (2-5Gi each) for fast I/O and HA.

| Component | Version | Image | Status |
|-----------|---------|-------|--------|
| Prowlarr | 2.3.0 | lscr.io/linuxserver/prowlarr:2.3.0 | Running |
| Sonarr | latest | lscr.io/linuxserver/sonarr:latest | Running |
| Radarr | latest | lscr.io/linuxserver/radarr:latest | Running |
| qBittorrent | 5.1.4 | lscr.io/linuxserver/qbittorrent:5.1.4 | Running |
| Jellyfin | 10.11.6 | jellyfin/jellyfin:10.11.6 | Running |
| Bazarr | latest | lscr.io/linuxserver/bazarr:latest | Running |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Namespace | `arr-stack` (not `media`) | `media` too generic - Immich is also media |
| Media storage | NFS on OMV NAS | Hardlinks require single filesystem; NAS has 2TB NVMe |
| Config storage | Longhorn PVCs | Fast SQLite I/O, 2x replicated, off the single-drive NAS |
| NFS mount | Single PV/PVC at `/data` for all pods | Required for hardlinks between torrents/ and media/ |
| Jellyfin image | Official (not LSIO) | Bundles jellyfin-ffmpeg with Intel iHD driver for QSV (Phase 4.25b). Also meets PSS restricted (no root) |
| LSIO apps | s6-overlay v3 with PUID/PGID | Requires CHOWN+SETUID+SETGID capabilities, runs as root |
| Sonarr/Radarr/Bazarr tags | `:latest` with `imagePullPolicy: Always` | Rapid release cycle, LSIO rebuilds frequently |
| Seeding | Disabled (ratio 0, Stop torrent) | NAS has single NVMe - preserve TBW |
| Subtitle provider | OpenSubtitles.com + Podnapisi | Free accounts, public providers |
| Prowlarr indexers | EZTV, YTS, Nyaa.si | All public, no account. Skipped: 1337x (Cloudflare blocks), TheRARBG (removed from Prowlarr) |
| Jellyfin Connect | Radarr + Sonarr → Jellyfin | Auto library scan on import (instead of 12h schedule) |

### Files Added

| File | Purpose |
|------|---------|
| manifests/arr-stack/namespace.yaml | Namespace (PSS baseline enforce, restricted audit/warn) |
| manifests/arr-stack/nfs-pv-pvc.yaml | NFS PV/PVC for shared media storage |
| manifests/arr-stack/networkpolicy.yaml | CiliumNetworkPolicy (intra-namespace, gateway, monitoring, NFS) |
| manifests/arr-stack/arr-api-keys-secret.yaml | Shared API keys placeholder for Phase 4.26 companions |
| manifests/arr-stack/prowlarr/ | Deployment, Service, HTTPRoute |
| manifests/arr-stack/sonarr/ | Deployment, Service, HTTPRoute |
| manifests/arr-stack/radarr/ | Deployment, Service, HTTPRoute |
| manifests/arr-stack/qbittorrent/ | Deployment, Service, HTTPRoute |
| manifests/arr-stack/jellyfin/ | Deployment, Service, HTTPRoute |
| manifests/arr-stack/bazarr/ | Deployment, Service, HTTPRoute |
| scripts/apply-arr-secrets.sh | 1Password → K8s Secret injection script |

### Files Modified

| File | Change |
|------|--------|
| manifests/home/homepage/config/services.yaml | Added Media section with 6 ARR widgets |
| .gitignore | Un-ignored apply-arr-secrets.sh and arr-api-keys-secret.yaml |
| CLAUDE.md | Added 1Password CLI limitation note |

### Critical Gotchas Discovered

1. **qBittorrent Torrent Management Mode** - Must be set to `Automatic` (not `Manual`) for category-based save paths to work. Default `Manual` saves to `/downloads` which doesn't exist in the container.
2. **qBittorrent CSRF on HTTP API** - Health endpoint returns 403 due to CSRF protection. Use `tcpSocket` probes on port 8080, not `httpGet`.
3. **Seeding disabled = no hardlinks** - With ratio 0 + "Remove Completed Downloads" in Radarr, source is deleted after import. File has link count 1 (effectively a move, not a hardlink). Expected behavior when seeding is disabled.
4. **Jellyfin no auto-scan on NFS** - NFS doesn't support inotify. Must add Jellyfin Connect integration in Radarr/Sonarr (Settings → Connect → Emby/Jellyfin) for automatic library refresh on import.
5. **NetworkPolicy blocks Uptime Kuma** - Internal K8s service URLs timeout from uptime-kuma namespace. Use HTTPS URLs with 403 accepted status codes for monitoring.
6. **`kubectl-homelab` alias unavailable in bash scripts** - Alias is zsh-only. Scripts must use `kubectl --kubeconfig ${HOME}/.kube/homelab.yaml`.
7. **1GbE NIC bottleneck** - K8s nodes have 1GbE NICs, NAS has 2.5GbE. Download speeds may be limited by node NIC (investigation deferred to Phase 4.26).

### 1Password Items

| Item | Vault | Fields |
|------|-------|--------|
| ARR Stack | Kubernetes | username, password, prowlarr-api-key, sonarr-api-key, radarr-api-key, bazarr-api-key, jellyfin-api-key |
| Opensubtitles | Kubernetes | username, user[password_confirmation] |

---

## February 13, 2026 - Phase 4.10: Tailscale Operator (Subnet Router)

### Milestone: Secure Remote Access via WireGuard Mesh VPN

Deployed Tailscale Kubernetes Operator v1.94.1 with a Connector CRD that advertises the entire 10.10.30.0/24 subnet to the tailnet. All existing K8s services are now accessible from any Tailscale-connected device (phone, laptop) via WireGuard tunnel - zero per-service manifests needed. AdGuard DNS set as global nameserver for ad-blocking on all tailnet devices.

| Component | Version | Status |
|-----------|---------|--------|
| Tailscale Operator | v1.94.1 | Running (tailscale namespace) |
| Tailscale Proxy (Connector) | v1.94.1 | Running (homelab-subnet, 100.109.196.53) |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Architecture | Connector (subnet router) over per-service Ingress | 1 pod for all services, zero per-service manifests, mirrors old Proxmox Tailscale pattern |
| DNS strategy | Global nameserver (not Split DNS) | All tailnet DNS through AdGuard for ad-blocking + custom rewrites on every device |
| PSS | Privileged enforce | Proxy pods require NET_ADMIN + NET_RAW for WireGuard tunnel (hard requirement) |
| Cilium fix | `socketLB.hostNamespaceOnly: true` | Cilium eBPF socket LB intercepts traffic in proxy pod netns, breaking WireGuard routing |
| Network policy | Operator-only (no connector proxy policy) | CiliumNetworkPolicy filters forwarded/routed packets, breaking subnet routing entirely |
| HTTPS certs | Existing Let's Encrypt (via Cilium Gateway) | Traffic enters through Gateway after subnet route - no Tailscale HTTPS certs needed |
| immich VM | Disabled Tailscale on VM | K8s subnet route (10.10.30.0/24) caused immich VM's Tailscale to intercept LAN traffic |

### Files Added

| File | Purpose |
|------|---------|
| manifests/tailscale/namespace.yaml | tailscale namespace (PSS privileged) |
| manifests/tailscale/connector.yaml | Connector CRD (subnet router, 10.10.30.0/24) |
| manifests/tailscale/networkpolicy.yaml | CiliumNetworkPolicy (operator ingress/egress only) |
| manifests/monitoring/tailscale-alerts.yaml | PrometheusRule (TailscaleConnectorDown, TailscaleOperatorDown) |
| manifests/monitoring/tailscale-dashboard-configmap.yaml | Grafana dashboard (pod status, VPN/pod traffic split by interface, resource usage with request/limit lines) |
| helm/tailscale-operator/values.yaml | Helm values (resources, tags, API proxy disabled) |

### Files Modified

| File | Change |
|------|--------|
| helm/cilium/values.yaml | Added `socketLB.hostNamespaceOnly: true` (Tailscale compatibility) |
| manifests/home/homepage/config/services.yaml | Added Tailscale widget with device status monitoring |

### Critical Gotchas Discovered

1. **Cilium socketLB breaks WireGuard** - Must add `socketLB.hostNamespaceOnly: true` BEFORE installing operator
2. **CiliumNetworkPolicy blocks subnet routing** - Connector forwards packets via IP forwarding; CNP filters forwarded packets, not just pod-originated traffic
3. **Operator uses ClusterIP (10.96.0.1)** - Egress policy needs `toEntities: kube-apiserver`, not CIDR-based node IP rules
4. **`proxyConfig.defaultTags` must be string** - YAML array causes `cannot unmarshal array into Go struct field EnvVar`
5. **immich VM routing conflict** - VM's Tailscale saw K8s subnet route and intercepted LAN traffic (TTL 64→61)
6. **OAuth clients renamed** - Now under `Settings → Trust credentials` in Tailscale admin console
7. **Connector is a StatefulSet, not Deployment** - Alerts/dashboard queries must use `kube_statefulset_status_replicas_ready`, not `kube_deployment_status_replicas_available`

---

## February 12, 2026 - Phase 4.24: Karakeep Migration

### Milestone: Bookmark Manager with AI Tagging

Migrated Karakeep 0.30.0 bookmark manager from Proxmox Docker to Kubernetes. Three-service deployment (Karakeep AIO + Chrome + Meilisearch) connected to Ollama in the `ai` namespace for AI-powered bookmark tagging using qwen2.5:3b (text) and moondream (vision). Migrated 119 bookmarks, 423 tags, and 17 lists from Proxmox using karakeep-cli.

| Component | Version | Status |
|-----------|---------|--------|
| Karakeep | 0.30.0 | Running (karakeep namespace) |
| Chrome | alpine-chrome:124 | Running (headless browser) |
| Meilisearch | v1.13.3 | Running (search engine) |
| qwen2.5:3b | Q4_K_M | Text tagging model (1.9 GB) |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Text model | qwen2.5:3b over qwen3:1.7b | qwen3 thinking mode breaks Ollama structured output ([#10538](https://github.com/ollama/ollama/issues/10538)) |
| Architecture | AIO image (not split web/workers) | SQLite = single writer, no benefit to splitting |
| Database | SQLite (embedded) | No Redis needed - liteque replaces Redis since v0.16.0 |
| Chrome security | `--no-sandbox` + CIDR egress restriction | Standard for containerized Chromium + blocks SSRF to internal networks |
| Crawler timeout | 120s (default 60s) | Content-type check + banner download needs headroom |
| Ollama probes | Widened timeouts (liveness 10s, readiness 5s) | CPU inference saturates cores, HTTP may be slow during active inference |
| Migration | karakeep-cli `migrate` subcommand | Server-to-server API migration preserves all data (bookmarks, tags, lists) |

### Files Added

| File | Purpose |
|------|---------|
| manifests/karakeep/namespace.yaml | karakeep namespace (PSS baseline enforce, restricted warn/audit) |
| manifests/karakeep/karakeep-deployment.yaml | Karakeep AIO Deployment + 2Gi PVC |
| manifests/karakeep/karakeep-service.yaml | ClusterIP on port 3000 |
| manifests/karakeep/httproute.yaml | HTTPRoute for karakeep.k8s.rommelporras.com |
| manifests/karakeep/chrome-deployment.yaml | Headless Chrome Deployment |
| manifests/karakeep/chrome-service.yaml | ClusterIP on port 9222 |
| manifests/karakeep/meilisearch-deployment.yaml | Meilisearch Deployment + 1Gi PVC |
| manifests/karakeep/meilisearch-service.yaml | ClusterIP on port 7700 |
| manifests/karakeep/networkpolicy.yaml | 6 CiliumNetworkPolicies (ingress/egress for all 3 services) |
| manifests/monitoring/karakeep-probe.yaml | Blackbox HTTP probe for /api/health |
| manifests/monitoring/karakeep-alerts.yaml | PrometheusRule (KarakeepDown, KarakeepHighRestarts) |

### Files Modified

| File | Change |
|------|--------|
| manifests/ai/ollama-deployment.yaml | Widened probe timeouts for CPU inference + updated model comment |
| manifests/home/homepage/config/services.yaml | Updated Karakeep widget URL to k8s.rommelporras.com |

### Network Policies (6 CiliumNetworkPolicies)

| Policy | Direction | Rules |
|--------|-----------|-------|
| karakeep-ingress | Ingress | Gateway (reserved:ingress) + host (probes) + monitoring |
| karakeep-egress | Egress | Chrome (9222) + Meilisearch (7700) + Ollama (11434) + external HTTPS + DNS |
| chrome-ingress | Ingress | Karakeep pods + host (probes) |
| chrome-egress | Egress | External internet only (CIDR blocks private networks for SSRF protection) + DNS |
| meilisearch-ingress | Ingress | Karakeep pods + host (probes) |
| meilisearch-egress | Egress | DNS only (defense-in-depth) |

### Lessons Learned

1. **qwen3 + structured output = broken** - Ollama's structured output suppresses the `<think>` token, breaking qwen3 models. Use qwen2.5:3b for Karakeep.
2. **Karakeep needs internet egress** - Content-type checks, banner image downloads, and favicon fetches all require outbound HTTPS from Karakeep pods (not just Chrome).
3. **Ollama probe timeouts matter during inference** - CPU inference saturates all cores (~4000m). HTTP health probes can time out during active inference, causing false restarts. Widened liveness to 10s timeout, readiness to 5s.
4. **karakeep-cli `migrate` needs `-it` flag** - Interactive confirmation prompt requires TTY allocation.
5. **s6-overlay requires root init** - Karakeep AIO uses s6-overlay which needs root during init (manages /run), then drops to app user. `runAsNonRoot: false` with `fsGroup: 0`.

---

## February 11, 2026 - Phase 4.23: Ollama Local AI

### Milestone: CPU-Only LLM Inference Server

Deployed Ollama 0.15.6 for local AI inference, primarily as foundation for Karakeep's AI-powered bookmark tagging (Phase 4.24). All inference runs on CPU (Intel i5-10400T, no GPU).

| Component | Version | Status |
|-----------|---------|--------|
| Ollama | 0.15.6 | Running (ai namespace) |
| qwen3:1.7b | Q4_K_M | Text model (1.4 GB) |
| moondream | Q4_K_M | Vision model (1.7 GB) |
| gemma3:1b | Q4_K_M | Fallback text (0.8 GB) |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Text model | qwen3:1.7b over qwen2.5:3b | Same quality (official Qwen benchmark), half the size, faster |
| Vision model | moondream (1.8B) over llava (7B) | 3x smaller - both loaded = 4.5 GB vs 8.5 GB (critical on 16GB nodes) |
| Quantization | Q4_K_M (Ollama default) | Classification/tagging retains 96-99% accuracy at 4-bit (Red Hat 500K evaluations) |
| Memory limit | 6Gi (not 3Gi) | Ollama mmap's models + kernel page cache fills cgroup - 3Gi caused OOM |
| Network policy | CiliumNetworkPolicy ingress | Only monitoring + karakeep namespaces can reach Ollama |
| Monitoring | Blackbox probe + PrometheusRule | No native /metrics endpoint; 3 alerts (Down, MemoryHigh, HighRestarts) |

### Files Added

| File | Purpose |
|------|---------|
| manifests/ai/namespace.yaml | ai namespace (PSS baseline enforce, restricted warn/audit) |
| manifests/ai/ollama-deployment.yaml | Deployment + 10Gi PVC for model storage |
| manifests/ai/ollama-service.yaml | ClusterIP on port 11434 |
| manifests/ai/networkpolicy.yaml | CiliumNetworkPolicy (ingress from monitoring + karakeep) |
| manifests/monitoring/ollama-probe.yaml | Blackbox HTTP probe (60s interval) |
| manifests/monitoring/ollama-alerts.yaml | 3 PrometheusRule alerts |

---

## February 11, 2026 - Phase 2.1: kube-vip Upgrade + Monitoring

### Milestone: kube-vip v1.0.4 + Prometheus Monitoring

Upgraded kube-vip from v1.0.3 to v1.0.4 across all 3 control plane nodes via rolling upgrade (non-leaders first, leader last). Fixed stalled leader election errors (PRs #1383, #1386) that caused cp3 to spam `Failed to update lock optimistically` every second with 19 container restarts. Added Prometheus monitoring using Headless Service + manual Endpoints + ServiceMonitor pattern (standard for static pods).

| Component | Version | Status |
|-----------|---------|--------|
| kube-vip | v1.0.4 | Running (all 3 nodes) |
| ServiceMonitor | kube-vip | monitoring namespace |
| PrometheusRule | 4 alerts | monitoring namespace |
| Grafana Dashboard | kube-vip VIP Health | ConfigMap auto-provisioned |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Upgrade strategy | Rolling (non-leaders first, leader last) | Maintains VIP availability throughout |
| Monitoring pattern | Headless Service + Endpoints + ServiceMonitor | Standard for static pods (no selector); Endpoints over EndpointSlice because Prometheus Operator uses Endpoints-based discovery |
| Leader monitoring | kube-state-metrics lease metrics | kube-vip has no custom Prometheus metrics; `kube_lease_owner` and `kube_lease_renew_time` provide leader identity |
| Alert routing | Existing convention (critical → #incidents + email, warning → #status) | Consistent with all other monitoring |

### Files Added

| File | Purpose |
|------|---------|
| manifests/monitoring/kube-vip-monitoring.yaml | Headless Service + Endpoints + ServiceMonitor |
| manifests/monitoring/kube-vip-alerts.yaml | PrometheusRule with 4 alerts |
| manifests/monitoring/kube-vip-dashboard-configmap.yaml | Grafana dashboard ConfigMap |

### Files Modified

| File | Change |
|------|--------|
| ansible/group_vars/all.yml | kubevip_version: v1.0.3 → v1.0.4 |

### Alerts

| Alert | Severity | Condition |
|-------|----------|-----------|
| KubeVipInstanceDown | warning | One instance unreachable for 2m |
| KubeVipAllDown | critical | All instances unreachable for 1m |
| KubeVipLeaseStale | critical | Lease not renewed in 30s for 1m |
| KubeVipHighRestarts | warning | >3 restarts in 1h for 5m |

### Lessons Learned

1. **kube-vip has no custom Prometheus metrics** (v1.0.3 and v1.0.4) - only Go runtime + process metrics. Monitor leader election via kube-state-metrics lease metrics instead.
2. **Prometheus Operator uses Endpoints, not EndpointSlice** - K8s 1.33+ deprecates v1 Endpoints, but the deprecation is cosmetic. The API still works and Prometheus Operator requires it for ServiceMonitor discovery.
3. **Optimistic lock errors don't mean VIP is down** - cp3 maintained the VIP despite constant lease update errors. The VIP worked fine; only log noise and wasted API server resources.
4. **Pre-pull images before static pod upgrades** - minimizes VIP downtime window during kubelet pod restart.

---

## February 9, 2026 - Phase 4.21: Containerized Firefox Browser

### Milestone: Persistent Browser Session via KasmVNC

Deployed containerized Firefox accessible from any LAN device via `browser.k8s.rommelporras.com`. Uses KasmVNC for WebSocket-based display streaming - close the tab on one device, open the URL on another, same session. Firefox profile (bookmarks, cookies, extensions, open tabs) persists on Longhorn PVC.

| Component | Version | Status |
|-----------|---------|--------|
| linuxserver/firefox | latest (lscr.io) | Running (browser namespace) |

### Key Decisions

- **`latest` tag instead of pinning** - Browser security patches are frequent; `imagePullPolicy: Always` ensures fresh pulls on restart
- **AdGuard DNS routing** - Pod uses `dnsPolicy: None` with AdGuard primary (10.10.30.53) + failover (10.10.30.54) for ad-blocking and privacy
- **LAN-only access** - NOT exposed via Cloudflare Tunnel (browser session = full machine access to logged-in accounts)
- **TCP probes instead of HTTP** - Basic auth returns 401 on unauthenticated requests, so HTTP probes would always fail
- **Least-privilege capabilities** - `drop: ALL` + add back only CHOWN, SETUID, SETGID, DAC_OVERRIDE, FOWNER (required by LinuxServer s6 init)

### Files Added

| File | Purpose |
|------|---------|
| manifests/browser/namespace.yaml | Browser namespace with baseline PSS (audit/warn restricted) |
| manifests/browser/deployment.yaml | Firefox Deployment with KasmVNC, AdGuard DNS, auth from Secret |
| manifests/browser/pvc.yaml | Longhorn PVC (2Gi) for Firefox profile persistence |
| manifests/browser/service.yaml | ClusterIP Service (port 3000) |
| manifests/browser/httproute.yaml | HTTPRoute for browser.k8s.rommelporras.com |

### Files Modified

| File | Change |
|------|--------|
| manifests/home/homepage/config/services.yaml | Added Firefox Browser to Apps, Uptime Kuma widget to Health section |

---

## February 9, 2026 - Phase 4.12.1: Ghost Web Analytics (Tinybird)

### Milestone: Native Web Analytics for Ghost Blog

Integrated Ghost's cookie-free, privacy-preserving web analytics powered by Tinybird. Deployed TrafficAnalytics proxy (`ghost/traffic-analytics:1.0.72`) that enriches page hit data (user agent parsing, referrer, privacy-preserving signatures) before forwarding to Tinybird's event ingestion API.

| Component | Version | Status |
|-----------|---------|--------|
| TrafficAnalytics | 1.0.72 | Running (ghost-prod namespace) |
| Tinybird | Free tier (us-east-1 AWS) | Active |

### Files Added

| File | Purpose |
|------|---------|
| manifests/ghost-prod/analytics-deployment.yaml | TrafficAnalytics proxy Deployment (Fastify/Node.js) |
| manifests/ghost-prod/analytics-service.yaml | ClusterIP Service for Ghost → TrafficAnalytics |

### Files Modified

| File | Change |
|------|--------|
| manifests/ghost-prod/ghost-deployment.yaml | Added Tinybird env vars (`analytics__*`, `tinybird__*`) using `__` nested config convention |
| manifests/cloudflare/networkpolicy.yaml | Added port 3000 (TrafficAnalytics) to ghost-prod egress rule for cloudflared |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Analytics provider | Tinybird (Ghost native) | Built-in admin dashboard, cookie-free, no additional Grafana dashboards needed |
| Tinybird region | US-East-1 (AWS) | No Asia-Pacific regions available; server pushes to Tinybird (not browser), latency acceptable |
| Proxy memory | 128Mi/256Mi | Container uses ~145MB idle; 128Mi causes OOM kill with zero logs |
| Public hostname | blog-api.rommelporras.com | Ad-blocker-friendly (avoids "analytics", "tracking", "stats" keywords) |
| Subdomain level | Single-level | Cloudflare free SSL covers `*.rommelporras.com` only; two-level (`*.blog.rommelporras.com`) fails TLS |
| Config convention | `tinybird__workspaceId` | Ghost maps `__` to nested config; flat env vars like `TINYBIRD_WORKSPACE_ID` don't work |

### Architecture

```
Browser (ghost-stats.js)
    │ POST page hit
    ▼
blog-api.rommelporras.com (Cloudflare Tunnel)
    │
    ▼
TrafficAnalytics proxy (ghost-prod:3000)
    │ Enriches: user agent, referrer, privacy signatures
    ▼
Tinybird Events API (us-east-1 AWS)
    │
    ▼
Ghost Admin Dashboard (reads Tinybird stats endpoint)
```

### CKA Learnings

| Topic | Concept |
|-------|---------|
| OOM debugging | Zero `kubectl logs` output = container OOM'd before writing stdout |
| Nested env vars | Ghost `__` convention maps `a__b__c` → `config.a.b.c` |
| CiliumNetworkPolicy | New services in existing namespaces need port additions to cloudflared egress |
| Cloudflare Tunnel | Each service needing browser-direct access needs its own public hostname |
| TLS wildcard scope | Free Cloudflare SSL covers one subdomain level only |

### Lessons Learned

1. **OOM kill produces zero logs** - A container that exceeds its memory limit before writing any stdout gives empty `kubectl logs`. Diagnose by running the image locally with `docker stats`.

2. **Ghost `__` config convention** - Ghost maps env vars with double-underscore to nested config objects. `tinybird__workspaceId` → `config.tinybird.workspaceId`. The `web_analytics_configured` field checks `_isValidTinybirdConfig()` which validates these nested values.

3. **Ghost does NOT proxy `/.ghost/analytics/`** - In Docker Compose, Caddy handles this routing. In Kubernetes without a reverse proxy, a separate Cloudflare Tunnel hostname is required for browser-facing POST requests.

4. **Cloudflare free SSL subdomain limit** - Universal SSL covers `*.rommelporras.com` but NOT `*.blog.rommelporras.com`. Two-level subdomains fail TLS handshake.

5. **Ad-blocker-friendly naming** - Browser ad blockers filter subdomains containing "analytics", "tracking", "stats". `blog-api` passes through ad blockers.

6. **CiliumNetworkPolicy port additions** - Adding TrafficAnalytics (port 3000) to ghost-prod required updating the cloudflared egress policy. Without it, Cloudflare Tunnel returned 502.

### 1Password Items

| Item | Vault | Fields |
|------|-------|--------|
| Ghost Tinybird | Kubernetes | workspace-id, admin-token, tracker-token, api-url |

---

## February 8, 2026 - Phase 4.20: MySpeed Migration

### Milestone: Internet Speed Tracker Migrated from Proxmox LXC to Kubernetes

Migrated MySpeed internet speed test tracker from Proxmox LXC (10.10.30.6) to Kubernetes cluster. Fresh start with no data migration - K8s instance builds its own speed test history.

| Component | Version | Status |
|-----------|---------|--------|
| MySpeed | 1.0.9 | Running (home namespace) |

### Files Added

| File | Purpose |
|------|---------|
| manifests/home/myspeed/deployment.yaml | Deployment with security context (seccomp, drop ALL) |
| manifests/home/myspeed/pvc.yaml | Longhorn PVC 1Gi for SQLite data |
| manifests/home/myspeed/service.yaml | ClusterIP Service with named port reference |
| manifests/home/myspeed/httproute.yaml | HTTPRoute for myspeed.k8s.rommelporras.com |

### Files Modified

| File | Change |
|------|--------|
| manifests/home/homepage/config/services.yaml | Updated Speed Test widget from LXC IP to K8s URL |
| manifests/uptime-kuma/networkpolicy.yaml | Added port 5216 to CiliumNetworkPolicy for MySpeed monitoring |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Image registry | Docker Hub (`germannewsmaker/myspeed`) | GHCR (`ghcr.io/gnmyt/myspeed`) returned 403 Forbidden |
| Data migration | Fresh start | SQLite history on LXC during soak period, K8s builds own |
| Security context | Partial restricted PSS | Image requires root - `runAsNonRoot` breaks data folder creation |
| Resource limits | 100m/500m CPU, 128Mi/256Mi memory | Peak observed at 78Mi during speed test |
| Named ports | `http` reference in probes + service | Single source of truth for port number |
| Uptime Kuma monitors | Standardized all to external URLs | Full chain testing (DNS → Gateway → TLS → Service) over internal URLs for consistency |

### CKA Learnings

| Topic | Concept |
|-------|---------|
| PVC access modes | RWO (Longhorn) vs RWX (NFS) - RWO requires Recreate strategy |
| Named ports | Reference `port: http` in probes/services instead of hardcoded numbers |
| Pod Security Standards | Not all images support restricted PSS - apply what you can |
| Kustomize | Homepage uses `-k` flag, not `-f` - `kubectl apply -f` overwrites imperative secrets |
| Resource right-sizing | Use Prometheus `max_over_time()` to measure peak usage before setting limits |

### Lessons Learned

1. **Always verify container registry** - The phase plan listed `ghcr.io/gnmyt/myspeed` but the image is actually on Docker Hub as `germannewsmaker/myspeed`. GHCR returned 403 Forbidden.

2. **runAsNonRoot breaks some images** - MySpeed needs root to create its `/myspeed/data` folder. Keep other security settings (seccomp, drop ALL, no privilege escalation) even when you can't run as non-root.

3. **kubectl apply -f on Kustomize directories overwrites secrets** - Homepage uses Kustomize with `configMapGenerator`. Running `kubectl apply -f` instead of `kubectl apply -k` applied the placeholder `secret.yaml`, overwriting real credentials. This caused all Homepage widgets to fail with 401 errors.

4. **Rate limiting from bad credentials** - When placeholder secrets triggered repeated 401s, AdGuard and OMV rate-limited the Homepage pod IP. Had to wait for lockout expiry and reset failed counters.

5. **Homepage rebuild guide was incomplete** - The v0.6.0 secret creation command was missing fields added in later phases (AdGuard failover, Karakeep, OpenWRT, Glances user). Also had wrong variable names for OPNsense (USER/PASS vs KEY/SECRET).

---

## February 6, 2026 - v0.15.1: Dashboard Fixes and Alert Tuning

### Claude Code Dashboard Query Fixes

Fixed broken PromQL queries for one-time counters (sessions, commits, PRs showed 0) and reorganized dashboard layout. Tuned alert thresholds based on real usage data.

### Dashboard Fixes

| Fix | Problem | Solution |
|-----|---------|----------|
| Sessions/Commits/PRs showing 0 | `increase()` on one-time counters always returns 0 | Use `last_over_time()` with `count by (session_id)` |
| Code Edit Decisions showing 0 | Same one-time counter pattern | Same fix |
| API Error Rate wrong grouping | Grouped by missing `status_code` field | Group by `error` field |
| Avg Session Length denominator | Incorrect calculation | Fixed denominator |

### Layout Changes

- Productivity and Performance sections open by default
- Token & Efficiency section auto-collapsed
- Cost Analysis tables side-by-side (w=8, h=5)

### Alert Threshold Tuning

Previous $25/$50 thresholds triggered on normal daily usage (~$52 avg, ~$78 peak observed).

| Alert | Before | After |
|-------|--------|-------|
| ClaudeCodeHighDailySpend | >$25/day | >$100/day |
| ClaudeCodeCriticalDailySpend | >$50/day | >$150/day |

### Configuration Change

- `OTEL_METRIC_EXPORT_INTERVAL` reduced from 60s to 5s to prevent one-time counter data loss when sessions end before next export

### Files Modified

| File | Change |
|------|--------|
| manifests/monitoring/claude-dashboard-configmap.yaml | Fixed PromQL queries, reorganized panel layout |
| manifests/monitoring/claude-alerts.yaml | Raised cost thresholds ($25/$50 → $100/$150) |

---

## February 5, 2026 - Phase 4.15: Claude Code Monitoring

### Milestone: Centralized Claude Code Telemetry on Kubernetes

Deployed OpenTelemetry Collector to receive Claude Code metrics and events via OTLP, exporting metrics to Prometheus and structured events to Loki. Grafana dashboard and cost alerts auto-provisioned via ConfigMap and PrometheusRule.

| Component | Version | Status |
|-----------|---------|--------|
| OTel Collector (contrib) | v0.144.0 | Running (monitoring namespace) |
| Grafana Dashboard | ConfigMap | 33 panels, 8 sections |
| PrometheusRule | claude-code-alerts | 4 rules (cost, availability) |

### Files Added

| File | Purpose |
|------|---------|
| manifests/monitoring/otel-collector-config.yaml | OTel pipeline config (OTLP → Prometheus + Loki) |
| manifests/monitoring/otel-collector.yaml | Deployment + LoadBalancer Service (VIP 10.10.30.22) |
| manifests/monitoring/otel-collector-servicemonitor.yaml | ServiceMonitor for Prometheus scraping |
| manifests/monitoring/claude-dashboard-configmap.yaml | Grafana dashboard (33 panels, 8 sections) |
| manifests/monitoring/claude-alerts.yaml | PrometheusRule (4 cost/availability alerts) |
| docs/rebuild/v0.15.0-claude-monitoring.md | Rebuild guide |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Service type | LoadBalancer (Cilium L2) | Stable VIP for any machine on trusted VLANs |
| VIP | 10.10.30.22 | Next free in Cilium IP pool |
| OTLP transport | Plain HTTP (no TLS) | Trusted LAN only, telemetry counters not credentials |
| Loki ingestion | Native OTLP (`otlphttp/loki`) | Not deprecated `loki` exporter |
| Alert thresholds | $25 warning, $50 critical | Tuned from real usage data |
| Machine identification | `OTEL_RESOURCE_ATTRIBUTES="machine.name=$HOST"` | Auto-resolves hostname |

### Architecture

```
Client Machines (TRUSTED_WIFI / LAN)
  Claude Code ──OTLP gRPC──→ 10.10.30.22:4317
                                    │
                              OTel Collector
                              ├──→ Prometheus (:8889)
                              └──→ Loki (:3100/otlp)
                                    │
                                 Grafana
                          Claude Code Dashboard
```

### Dashboard Sections (33 panels)

| Section | Panels | Datasource |
|---------|--------|------------|
| Overview | 6 | Prometheus |
| Productivity | 7 | Prometheus |
| Sessions & Activity | 4 | Prometheus |
| Trends | 2 | Prometheus |
| Cost Analysis | 3 | Prometheus |
| Performance (Events) | 2 | Loki |
| Token & Efficiency | 2 | Prometheus |
| Insights | 7 | Mixed |

### Alert Rules

| Alert | Severity | Condition |
|-------|----------|-----------|
| ClaudeCodeHighDailySpend | warning | >$100/day |
| ClaudeCodeCriticalDailySpend | critical | >$150/day |
| ClaudeCodeNoActivity | info | No usage at end of weekday (5-6pm) |
| OTelCollectorDown | critical | Collector unreachable for 2m |

### Security Hardening

OTel Collector fully hardened:
- `runAsNonRoot: true` (UID 10001)
- `readOnlyRootFilesystem: true`
- `allowPrivilegeEscalation: false`
- `capabilities.drop: ALL`
- `seccompProfile: RuntimeDefault`
- `automountServiceAccountToken: false`

### CKA Learnings

| Topic | Concept |
|-------|---------|
| ConfigMap | Dashboard JSON as ConfigMap with Grafana sidecar auto-provisioning |
| ServiceMonitor | Custom scrape targets for non-Helm workloads |
| PrometheusRule | Custom alert rules with PromQL time functions (`hour()`, `day_of_week()`) |
| LoadBalancer | Cilium L2 announcement with `lbipam.cilium.io/ips` annotation |
| Security context | Full pod hardening for non-root OTel Collector |

### Lessons Learned

1. **Loki OTLP native ingestion stores attributes as structured metadata** - Query with `| event_name="api_request"`, not `| json`. The `| json` parser is for unstructured log lines.

2. **OTel Collector memory limit must exceed memory_limiter** - Container limit (600Mi) must be higher than the `memory_limiter` processor setting (512 MiB) or the pod OOM-kills.

3. **OTLP metric names transform in Prometheus** - Dots become underscores, counters get `_total` suffix. Always verify after deployment.

4. **Grafana `joinByLabels` transformation fails with Loki metric queries** - Causes "Value label not found" error. Use bar charts with `sum by` instead of tables with join transformations for Loki data.

5. **One-time counters need `last_over_time()`, not `increase()`** - `session_count`, `commit_count`, and `pull_request_count` increment once and never change, so `increase()` always returns 0. Use `count(count by (session_id) (last_over_time(metric[$__range])))` for counts. Continuously-incrementing counters (cost, tokens, active_time) still use `increase()`.

6. **5s metric export interval prevents data loss** - The default 60s `OTEL_METRIC_EXPORT_INTERVAL` causes one-time counters (commits, PRs, sessions) to be lost if a session ends before the next export. Use 5000ms to match the logs interval.

### Open-Source Project

Dashboard and configs developed in parallel with [claude-code-monitoring](https://github.com/rommelporras/claude-code-monitoring) v2.0.0 (Loki events, updated dashboard, Docker version bumps).

---

## February 5, 2026 - Phase 4.9: Invoicetron Migration

### Milestone: Stateful Application with Database Migrated to Kubernetes

Migrated Invoicetron (Next.js 16 + Bun 1.3.4 + PostgreSQL 18 + Prisma 7.2.0 + Better Auth 1.4.7) from Docker Compose on reverse-mountain VM to Kubernetes. Two environments (dev + prod) with GitLab CI/CD pipeline, Cloudflare Tunnel public access, and Cloudflare Access email OTP protection.

| Component | Version | Status |
|-----------|---------|--------|
| Invoicetron | Next.js 16.1.0 | Running (invoicetron-dev, invoicetron-prod) |
| PostgreSQL | 18-alpine | Running (StatefulSet per environment) |

### Files Added

| File | Purpose |
|------|---------|
| manifests/invoicetron/deployment.yaml | App Deployment + ClusterIP Service |
| manifests/invoicetron/postgresql.yaml | PostgreSQL StatefulSet + headless Service |
| manifests/invoicetron/rbac.yaml | ServiceAccount, Role, RoleBinding for CI/CD |
| manifests/invoicetron/secret.yaml | Placeholder (1Password imperative) |
| manifests/invoicetron/backup-cronjob.yaml | Daily pg_dump CronJob + 2Gi PVC |
| manifests/gateway/routes/invoicetron-dev.yaml | HTTPRoute for dev (internal) |
| manifests/gateway/routes/invoicetron-prod.yaml | HTTPRoute for prod (internal) |

### Files Modified

| File | Change |
|------|--------|
| manifests/cloudflare/networkpolicy.yaml | Added invoicetron-prod egress on port 3000; removed temporary DMZ rule; fixed namespace from `invoicetron` to `invoicetron-prod` |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Per-environment builds | Separate Docker images | NEXT_PUBLIC_APP_URL baked at build time |
| Database passwords | Hex-only (`openssl rand -hex 20`) | Avoid URL-special characters breaking Prisma |
| Registry auth | Deploy token + imagePullSecrets | Private GitLab project = private container registry |
| Migration strategy | K8s Job before deploy | Prisma migrations run as one-shot Job in CI/CD |
| Auth client baseURL | `window.location.origin` fallback | Login works on any URL, not just build-time URL |
| Cloudflare Access | Reused "Allow Admin" policy | Email OTP gate, same policy as Uptime Kuma |
| Backup | Daily CronJob (9 AM, 30-day retention) | ~14MB database, lightweight pg_dump |

### Architecture

```
┌───────────────────────────────────────────────────────────────┐
│            invoicetron-prod namespace                         │
├───────────────────────────────────────────────────────────────┤
│                                                               │
│  PostgreSQL 18         Invoicetron App                        │
│  StatefulSet    ◄────  Deployment (1 replica)                 │
│  (10Gi Longhorn) SQL   Next.js 16 + Bun                      │
│                                                               │
│  Daily:                On deploy:                             │
│  pg_dump CronJob       Prisma Migrate Job                    │
│  → Longhorn PVC                                              │
│                                                               │
│  Secrets: database-url, better-auth-secret (1Password)       │
│  Registry: gitlab-registry imagePullSecret (deploy token)    │
└───────────────────────────────────────────────────────────────┘
```

### CI/CD Pipeline (GitLab)

```
develop → validate → test → build:dev → deploy:dev → verify:dev
main    → validate → test → build:prod → deploy:prod → verify:prod
```

- **validate:** type-check (tsc), lint, security-audit
- **test:** unit tests (vitest on node:22-slim)
- **build:** per-environment Docker image (NEXT_PUBLIC_APP_URL as build-arg)
- **deploy:** Prisma migration Job + kubectl set image
- **verify:** curl health check

### Access

| Environment | Internal URL | Public URL |
|-------------|-------------|------------|
| Dev | invoicetron.dev.k8s.rommelporras.com | - |
| Prod | invoicetron.k8s.rommelporras.com | invoicetron.rommelporras.com (Cloudflare) |

### Cloudflare Access

| Application | Policy | Authentication |
|-------------|--------|----------------|
| Invoicetron | Allow Admin (reused) | Email OTP (2 addresses) |

### CKA Learnings

| Topic | Concept |
|-------|---------|
| StatefulSet | PostgreSQL with volumeClaimTemplates, headless Service |
| Jobs | One-shot Prisma migration Job before deployment |
| CronJobs | Daily pg_dump backup with retention |
| Init containers | wait-for-db pattern with busybox nc |
| imagePullSecrets | Private registry auth with deploy tokens |
| Security context | runAsNonRoot, drop ALL, seccompProfile |
| RollingUpdate | maxSurge: 1, maxUnavailable: 0 |
| CiliumNetworkPolicy | Per-namespace egress with exact namespace names |

### Lessons Learned

1. **Private GitLab projects need imagePullSecrets** - Container registry inherits project visibility. Deploy token with `read_registry` scope + `docker-registry` secret in each namespace.

2. **envFrom injects hyphenated keys** - K8s secret keys like `database-url` become env vars with hyphens. Prisma expects `DATABASE_URL`. Use explicit `env` with `valueFrom.secretKeyRef`, not `envFrom`.

3. **PostgreSQL 18+ mount path** - Mount at `/var/lib/postgresql` (parent), not `/var/lib/postgresql/data`. PG creates the data subdirectory itself.

4. **DATABASE_URL passwords must avoid special chars** - Passwords with `/` break Prisma URL parsing. URL-encoding (`%2F`) works for CLI but not runtime. Use hex-only passwords.

5. **PostgreSQL only reads POSTGRES_PASSWORD on first init** - Changing the secret requires `ALTER USER` inside the running pod.

6. **kubectl apply reverts CI/CD image** - Manifest has placeholder image. CI/CD sets actual image via `kubectl set image`. Applying manifest reverts it. Use `kubectl set env` for runtime changes.

7. **CiliumNetworkPolicy needs exact namespace names** - `invoicetron` ≠ `invoicetron-prod`. Caused 502 through Cloudflare Tunnel until fixed.

8. **Better Auth client baseURL** - Hardcoded `NEXT_PUBLIC_APP_URL` means login only works on that domain. Removing baseURL lets Better Auth use `window.location.origin` automatically. Server-side `ADDITIONAL_TRUSTED_ORIGINS` validates allowed origins.

9. **1Password CLI session scope** - `op read` returns empty if session expired. Always `eval $(op signin)` before creating secrets. Verify secrets after creation.

### 1Password Items

| Item | Vault | Fields |
|------|-------|--------|
| Invoicetron Dev | Kubernetes | postgres-password, better-auth-secret, database-url |
| Invoicetron Prod | Kubernetes | postgres-password, better-auth-secret, database-url |

### DMZ Rule Removed

With both Portfolio and Invoicetron running in K8s, the temporary DMZ rule (`10.10.50.10/32`) in the cloudflared NetworkPolicy has been removed. Security validation: 35 passed, 0 failed.

---

## February 4, 2026 - Cloudflare WAF: RSS Feed Access

### Fix: GitHub Actions Blog RSS Fetch (403)

Added Cloudflare WAF skip rule and disabled Bot Fight Mode to allow the GitHub Profile README blog-post workflow to fetch the Ghost RSS feed from GitHub Actions.

| Component | Change |
|-----------|--------|
| Cloudflare WAF Rule 1 | New: Skip + Super Bot Fight Mode for `/rss/` |
| Cloudflare WAF Rule 2 | Renumbered: Allow `/ghost/api/content` (was Rule 1) |
| Cloudflare WAF Rule 3 | Renumbered: Block `/ghost` paths (was Rule 2) |
| Bot Fight Mode | Disabled globally (Security → Settings) |

### Key Decision

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Bot Fight Mode | Disabled globally | Free Cloudflare tier cannot create path-specific exceptions; blocks all cloud provider IPs including GitHub Actions |

### Lesson Learned

WAF custom rule "Skip all remaining custom rules" does **not** skip Bot Fight Mode - they are separate systems. To skip bot protection for a specific path, you must also check "All Super Bot Fight Mode Rules" in the WAF skip action **and** disable the global Bot Fight Mode toggle.

---

## February 3, 2026 - Phase 4.14: Uptime Kuma Monitoring

### Milestone: Self-hosted Endpoint Monitoring with Public Status Page

Deployed Uptime Kuma v2.0.2 for HTTP(s) endpoint monitoring of personal websites, homelab services, and infrastructure. Public status page exposed via Cloudflare Tunnel with Access policies blocking admin routes. Discord notifications on the #incidents channel.

| Component | Version | Status |
|-----------|---------|--------|
| Uptime Kuma | v2.0.2 (rootless) | Running (uptime-kuma namespace) |

### Files Added

| File | Purpose |
|------|---------|
| manifests/uptime-kuma/namespace.yaml | Namespace with PSS labels (baseline enforce, restricted audit/warn) |
| manifests/uptime-kuma/statefulset.yaml | StatefulSet with volumeClaimTemplates (Longhorn 1Gi) |
| manifests/uptime-kuma/service.yaml | Headless + ClusterIP services on port 3001 |
| manifests/uptime-kuma/httproute.yaml | Gateway API HTTPRoute for `uptime.k8s.rommelporras.com` |
| manifests/uptime-kuma/networkpolicy.yaml | CiliumNetworkPolicy (DNS, internet HTTPS, cluster-internal, home network) |
| manifests/monitoring/uptime-kuma-probe.yaml | Blackbox HTTP probe for Prometheus |
| docs/rebuild/v0.13.0-uptime-kuma.md | Full rebuild guide |

### Files Modified

| File | Change |
|------|--------|
| manifests/cloudflare/networkpolicy.yaml | Added uptime-kuma namespace egress on port 3001 |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Workload type | StatefulSet | Stable identity + persistent SQLite storage |
| Image variant | rootless (not slim-rootless) | Includes Chromium for browser-engine monitors |
| Database | SQLite | Single-instance, no external DB dependency |
| Storage | volumeClaimTemplates (1Gi) | Auto-creates PVC per pod, no separate manifest |
| Public access | Cloudflare Tunnel + block-admin | SPA-compatible; block `/dashboard`, `/manage-status-page`, `/settings` |
| Notifications | Reuse #incidents channel | Unified incident channel, no channel sprawl |
| Monitor retries | 1 for public/prod, 3 for internal/dev | Faster alerting for critical services |

### Architecture

```
uptime-kuma namespace
┌───────────────────────────────────┐
│ StatefulSet (1 replica)           │
│ - Image: 2.0.2-rootless           │
│ - SQLite on Longhorn PVC (1Gi)   │
│ - Non-root (UID 1000)            │
└───────────────┬───────────────────┘
                │
     ┌──────────┼──────────┐
     │          │          │
  Headless   ClusterIP   HTTPRoute
  Service    Service     uptime.k8s.rommelporras.com
                          │
               Cloudflare Tunnel
               status.rommelporras.com/status/homelab
```

### Access

| Environment | URL | Access |
|-------------|-----|--------|
| Admin | https://uptime.k8s.rommelporras.com | Internal (HTTPRoute) |
| Status Page | https://status.rommelporras.com/status/homelab | Public (Cloudflare Tunnel) |

### Monitors Configured

| Group | Monitors |
|-------|----------|
| Website | rommelporras.com, beta.rommelporras.com (Staging), Blog Prod, Blog Dev |
| Apps | Grafana, Homepage Dashboard, Longhorn Storage, Immich, Karakeep, MySpeed, Homepage (Proxmox) |
| Infrastructure | Proxmox PVE, Proxmox Firewall, OPNsense, OpenMediaVault, NAS Glances |
| DNS | AdGuard Primary, AdGuard Failover |

Tags: Kubernetes (Blue), Proxmox (Orange), Network (Purple), Storage (Pink), Public (Green)

### Cloudflare Access (Block Admin)

| Path | Action |
|------|--------|
| `status.rommelporras.com/dashboard` | Blocked (Everyone) |
| `status.rommelporras.com/manage-status-page` | Blocked (Everyone) |
| `status.rommelporras.com/settings` | Blocked (Everyone) |
| `status.rommelporras.com/status/homelab` | Public (no policy) |

### CKA Learnings

| Topic | Concept |
|-------|---------|
| StatefulSet | volumeClaimTemplates auto-create PVCs, headless Service for stable DNS |
| CiliumNetworkPolicy | Uses pod ports not service ports; private IP exclusion requires explicit toCIDR for home network |
| Gateway API | HTTPRoute sectionName for listener selection |
| Cloudflare Access | Block-admin simpler than allowlist for SPAs (JS/CSS/API paths) |
| Hairpin routing | Cilium Gateway returns 403 for pod-to-VIP-to-pod traffic |

### Lessons Learned

1. **StatefulSet vs Deployment for SQLite** - StatefulSet provides stable pod identity (`uptime-kuma-0`) and volumeClaimTemplates auto-create PVCs. No separate PVC manifest needed.

2. **CiliumNetworkPolicy uses pod ports, not service ports** - A service mapping port 80→3000 requires the network policy to allow port 3000 (the pod port). Service port abstraction doesn't apply at the CNI level.

3. **Private IP exclusion blocks home network** - `toCIDRSet` with `except: 10.0.0.0/8` blocks home network devices (AdGuard failover, OPNsense, NAS). Must add explicit `toCIDR` rules for specific IPs.

4. **Hairpin routing with Cilium Gateway** - Pods accessing their own service via the Gateway VIP (pod→VIP→pod) get 403. Use internal service URLs for self-monitoring or accept the limitation.

5. **Cloudflare Access: block-admin > allowlist for SPAs** - Allowlisting only `/status/homelab` blocks JS/CSS/API paths the SPA needs. Blocking only admin paths (`/dashboard`, `/manage-status-page`, `/settings`) is simpler and SPA-compatible.

6. **rootless vs slim-rootless** - The `rootless` image includes Chromium for browser-engine monitors (real browser rendering checks). `slim-rootless` saves ~200MB but loses this capability. Memory limits need bumping (256Mi→768Mi).

7. **HTTPRoute BackendNotFound timing issue** - Cilium Gateway controller may report `Service "uptime-kuma" not found` even when the service exists. Delete and re-apply the HTTPRoute to force re-reconciliation.

8. **Cloudflare Zero Trust requires payment method** - Even the free plan ($0/month, 50 seats) requires a credit card or PayPal for identity verification. Standard anti-abuse measure.

### 1Password Items

| Item | Vault | Fields |
|------|-------|--------|
| Uptime Kuma | Kubernetes | username, password, website |

---

## February 2, 2026 - Phase 4.13: Domain Migration

### Milestone: Corporate-Style Domain Hierarchy

Migrated all Kubernetes services from `*.k8s.home.rommelporras.com` to a tiered domain scheme under `*.k8s.rommelporras.com`. Introduced corporate-style environment tiers (base, dev, stg) with scoped wildcard TLS certificates.

| Component | Change |
|-----------|--------|
| Gateway | 3 HTTPS listeners (base, dev, stg) with scoped wildcards |
| TLS | 3 wildcard certs via cert-manager DNS-01 |
| API Server | New SAN `api.k8s.rommelporras.com` on all 3 nodes |
| DNS (K8s AdGuard) | New rewrites for all tiers + node hostnames |
| DNS (Failover LXC) | Matching rewrites for failover safety |

### Domain Scheme

| Tier | Wildcard | Purpose |
|------|----------|---------|
| Base | `*.k8s.rommelporras.com` | Infrastructure + production |
| Dev | `*.dev.k8s.rommelporras.com` | Development environments |
| Stg | `*.stg.k8s.rommelporras.com` | Staging environments |

### Service Migration

| Service | Old Domain | New Domain |
|---------|-----------|------------|
| Homepage | portal.k8s.home.rommelporras.com | portal.k8s.rommelporras.com |
| Grafana | grafana.k8s.home.rommelporras.com | grafana.k8s.rommelporras.com |
| GitLab | gitlab.k8s.home.rommelporras.com | gitlab.k8s.rommelporras.com |
| Registry | registry.k8s.home.rommelporras.com | registry.k8s.rommelporras.com |
| Blog Prod | blog.k8s.home.rommelporras.com | blog.k8s.rommelporras.com |
| Blog Dev | blog-dev.k8s.home.rommelporras.com | blog.dev.k8s.rommelporras.com |
| Portfolio Prod | portfolio-prod.k8s.home.rommelporras.com | portfolio.k8s.rommelporras.com |
| Portfolio Dev | portfolio-dev.k8s.home.rommelporras.com | portfolio.dev.k8s.rommelporras.com |
| Portfolio Stg | portfolio-staging.k8s.home.rommelporras.com | portfolio.stg.k8s.rommelporras.com |
| K8s API | k8s-api.home.rommelporras.com | api.k8s.rommelporras.com |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Tier convention | prod=default, non-prod=qualified | Corporate pattern: `blog.k8s` is prod, `blog.dev.k8s` is dev |
| Wildcard scope | Per-tier wildcards | `*.k8s`, `*.dev.k8s`, `*.stg.k8s` - no broad `*.rommelporras.com` |
| Legacy boundary | `*.home.rommelporras.com` untouched | Proxmox, OPNsense, OMV stay on NPM |
| Node hostnames | `cp{1,2,3}.k8s.rommelporras.com` | Hierarchical, consistent with service naming |
| API hostname | `api.k8s.rommelporras.com` | Short, follows corporate convention |

### Lessons Learned

1. **kubeadm `certs renew` does NOT add new SANs** - It only renews expiration, reusing existing SANs. To add a new SAN: delete the cert+key, then run `kubeadm init phase certs apiserver --config /path/to/config.yaml`.

2. **Local kubeadm config takes priority over ConfigMap** - If `/etc/kubernetes/kubeadm-config.yaml` exists on a node, `kubeadm init phase certs` uses it instead of the kube-system ConfigMap. Must update (or create) the local file on each node.

3. **AdGuard configmap is only an init template** - The init container copies config to PVC only on first boot (`if [ ! -f ... ]`). Runtime changes must be made via web UI. Configmap should still be updated as rebuild source of truth.

4. **RWO PVC + RollingUpdate = deadlock** - Grafana's Longhorn RWO volume caused a stuck rollout: new pod scheduled on different node couldn't attach the volume, old pod couldn't terminate (rolling update). Fix: scale to 0 then back to 1.

5. **Gateway API multi-listener migration pattern** - Add new listeners alongside old ones, switch HTTPRoutes to new listeners, verify, then remove old listeners in cleanup phase. Zero-downtime migration.

### CKA Learnings

| Topic | Concept |
|-------|---------|
| Gateway API | Multi-listener pattern, scoped wildcards, sectionName routing |
| cert-manager | Automatic Certificate creation from Gateway annotations, DNS-01 challenges |
| kubeadm | certSANs management, cert regeneration vs renewal, ConfigMap vs local config |
| TLS | Wildcard scope (one subdomain level only), multi-cert Gateway |

### Files Modified

| Category | Files |
|----------|-------|
| Gateway | manifests/gateway/homelab-gateway.yaml |
| HTTPRoutes (8) | gitlab, gitlab-registry, portfolio-prod, ghost-prod, longhorn, adguard, homepage, grafana |
| HTTPRoutes (3) | portfolio-dev, portfolio-staging, ghost-dev |
| Helm | gitlab/values.yaml, gitlab-runner/values.yaml, prometheus/values.yaml |
| Manifests | portfolio/deployment.yaml, ghost-dev/ghost-deployment.yaml, homepage/deployment.yaml |
| Config | homepage/config/services.yaml, homepage/config/settings.yaml |
| DNS | home/adguard/configmap.yaml |
| Scripts | scripts/sync-ghost-prod-to-dev.sh |
| Ansible | group_vars/all.yml, group_vars/control_plane.yml |

---

## January 31, 2026 - Phase 4.12: Ghost Blog Platform

### Milestone: Self-hosted Ghost CMS with Dev/Prod Environments

Deployed Ghost 6.14.0 blog platform with MySQL 8.4.8 LTS backend in two environments (ghost-dev, ghost-prod). Includes database sync scripts for prod-to-dev and prod-to-local workflows.

| Component | Version | Status |
|-----------|---------|--------|
| Ghost | 6.14.0 | Running (ghost-dev, ghost-prod) |
| MySQL | 8.4.8 LTS | Running (StatefulSet per environment) |

### Files Added

| File | Purpose |
|------|---------|
| manifests/ghost-dev/namespace.yaml | Dev namespace with PSA labels |
| manifests/ghost-dev/secret.yaml | Placeholder (1Password imperative) |
| manifests/ghost-dev/mysql-statefulset.yaml | MySQL StatefulSet with Longhorn 10Gi |
| manifests/ghost-dev/mysql-service.yaml | Headless Service for MySQL DNS |
| manifests/ghost-dev/ghost-pvc.yaml | Ghost content PVC (Longhorn 5Gi) |
| manifests/ghost-dev/ghost-deployment.yaml | Ghost Deployment with init container |
| manifests/ghost-dev/ghost-service.yaml | ClusterIP Service for Ghost |
| manifests/ghost-dev/httproute.yaml | Gateway API route (internal) |
| manifests/ghost-prod/* | Same structure for production |
| scripts/sync-ghost-prod-to-dev.sh | Database + content sync utility |
| scripts/sync-ghost-prod-to-local.sh | Prod database to local docker-compose |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Ghost version | 6.14.0 (Debian) | glibc compatibility, Sharp image library |
| MySQL version | 8.4.8 LTS | 5yr premier support, 8.0.x EOL April 2026 |
| Character set | utf8mb4 | Full unicode/emoji support in blog posts |
| Deployment strategy | Recreate | RWO PVC cannot be mounted by two pods |
| Gateway parentRefs | namespace: default | Corrected from plan (was kube-system) |
| MySQL security | No container restrictions | Entrypoint requires root (chown, gosu) |
| Ghost security | runAsNonRoot, uid 1000 | Full hardening with drop ALL capabilities |
| Mail config | Reused iCloud SMTP | Same app-specific password as Alertmanager |

### Access

| Environment | Internal URL | Public URL |
|-------------|-------------|------------|
| Dev | blog-dev.k8s.home.rommelporras.com | - |
| Prod | blog.k8s.home.rommelporras.com | blog.rommelporras.com (Cloudflare) |

### Public Access & Security (February 1)

Configured Cloudflare Tunnel for public access and WAF custom rules to protect the Ghost admin panel.

| Component | Change |
|-----------|--------|
| Cloudflare Tunnel | Added `blog.rommelporras.com` → `http://ghost.ghost-prod.svc.cluster.local:2368` |
| CiliumNetworkPolicy | Added ghost-prod:2368 egress rule for cloudflared |
| Cloudflare WAF Rule 1 | Skip: Allow `/rss/` (public RSS feed for GitHub Actions blog-post workflow) |
| Cloudflare WAF Rule 2 | Skip: Allow `/ghost/api/content` (public Content API for search) |
| Cloudflare WAF Rule 3 | Block: All other `/ghost` paths (admin panel, Admin API) |

### Files Modified

| File | Change |
|------|--------|
| manifests/cloudflare/networkpolicy.yaml | Added ghost-prod namespace egress on port 2368 |

### Key Decisions (Public Access)

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Tunnel protocol | HTTP (not HTTPS) | Ghost serves plain HTTP on 2368; cloudflared sends X-Forwarded-Proto: https |
| Admin protection | WAF custom rules | Cloudflare Access has known path precedence bugs; WAF evaluates in strict order |
| RSS feed | Skip rule (allow) + skip Super Bot Fight Mode | Cloudflare Bot Management blocks GitHub Actions IPs; `/rss/` is public read-only |
| Bot Fight Mode | Disabled globally | Free tier cannot create path-specific exceptions; blocks all cloud provider IPs |
| Content API | Skip rule (allow) | Sodo Search widget calls /ghost/api/content/ from browser; blocking breaks search |
| Admin API | Block rule | /ghost/api/admin/ is write-capable; original plan would have bypassed it |

### Lessons Learned (Public Access)

1. **Ghost 301-redirects HTTP when url is HTTPS** - Ghost checks `X-Forwarded-Proto` header. Cloudflare Tunnel with HTTP type sends this header automatically. Using HTTPS type causes cloudflared to attempt TLS to Ghost (which doesn't support it).

2. **CiliumNetworkPolicy blocks cross-namespace by default** - The cloudflared egress policy blocks all private IPs and whitelists per-namespace. New tunnel backends require an explicit egress rule.

3. **Cloudflare Access path precedence is unreliable** - "Most specific path wins" has [known bugs](https://community.cloudflare.com/t/policy-inheritance-not-prioritizing-most-specific-path/820213). WAF custom rules with Skip + Block pattern is deterministic.

4. **Ghost Content API vs Admin API** - Only `/ghost/api/content/` needs public access (read-only, API key auth). `/ghost/api/admin/` is write-capable (JWT auth) and should be blocked publicly.

### CKA Learnings

| Topic | Concept |
|-------|---------|
| StatefulSet | volumeClaimTemplates, headless Service, stable network identity |
| Pod Security Admission | 3 modes (enforce/audit/warn), baseline vs restricted |
| Init containers | wait-for pattern with busybox nc |
| Security context | runAsNonRoot, capabilities drop/add, seccompProfile |
| Gateway API | HTTPRoute parentRefs, cross-namespace routing |
| Secrets | Imperative creation from 1Password, placeholder pattern |
| CiliumNetworkPolicy | Per-namespace egress whitelisting for cross-namespace traffic |

---

## January 30, 2026 - Phase 4.8.1: AdGuard DNS Alerting

### Milestone: Synthetic DNS Monitoring for L2 Lease Misalignment

Deployed blackbox exporter with DNS probe to detect when AdGuard is running but unreachable due to Cilium L2 lease misalignment. This directly addresses the 3-day unnoticed outage (Jan 25-28) identified in Phase 4.8.

| Component | Version | Status |
|-----------|---------|--------|
| blackbox-exporter | v0.28.0 | Running (monitoring namespace) |
| Probe CRD (adguard-dns) | - | Scraping every 30s |
| PrometheusRule (AdGuardDNSUnreachable) | - | Loaded, severity: critical |

### Files Added/Modified

| File | Purpose |
|------|---------|
| helm/blackbox-exporter/values.yaml | Blackbox exporter config with dns_udp module |
| helm/prometheus/values.yaml | Added probeSelectorNilUsesHelmValues: false |
| manifests/monitoring/adguard-dns-probe.yaml | Probe CRD targeting 10.10.30.53 |
| manifests/monitoring/adguard-dns-alert.yaml | PrometheusRule with runbook |
| scripts/upgrade-prometheus.sh | Fixed Healthchecks Ping URL field name |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Blackbox exporter deployment | Separate Helm chart | kube-prometheus-stack does NOT bundle it |
| Probe target | LoadBalancer IP (10.10.30.53) | Tests full path including L2 lease alignment |
| DNS query domain | google.com | Universal, always resolvable |
| Alert threshold | 2 minutes | Avoids flapping while catching real outages |
| Alert severity | Critical | DNS is foundational; failure affects all VLANs |

### Architecture

```
Prometheus → Blackbox Exporter → DNS query to 10.10.30.53 → AdGuard
                                         │
                                         ├─ Success: probe_success=1
                                         └─ Failure: probe_success=0 → Alert
```

### CKA Learnings

| Topic | Concept |
|-------|---------|
| Probe CRD | Custom resource for blackbox exporter targets |
| PrometheusRule | Custom alert rules with PromQL expressions |
| Synthetic monitoring | Testing from outside the system under test |
| jobName field | Controls the `job` label in Prometheus metrics |

### Lessons Learned

1. **kube-prometheus-stack does NOT include blackbox exporter** - Despite the `prometheusBlackboxExporter` key existing in chart values, it requires a separate Helm chart installation.

2. **probeSelectorNilUsesHelmValues must be set** - Without `probeSelectorNilUsesHelmValues: false`, Prometheus ignores Probe CRDs. Silently fails with no error.

3. **Blackbox exporter has NO default DNS module** - Must explicitly configure `dns_udp` with `query_name` (required field). Without it, probe errors with no useful message.

4. **Service name follows `<release>-prometheus-blackbox-exporter` pattern** - Not `<release>-kube-prometheus-blackbox-exporter` as initially assumed.

5. **1Password field names must be exact** - `credential` vs `url` vs `password` - always verify with `op item get <name> --format json | jq '.fields[]'`.

### Alert Runbook

```
1. Check pod node:
   kubectl-homelab get pods -n home -l app=adguard-home -o wide

2. Check L2 lease holder:
   kubectl-homelab get leases -n kube-system cilium-l2announce-home-adguard-dns -o jsonpath='{.spec.holderIdentity}'

3. If pod node != lease holder, delete lease:
   kubectl-homelab delete lease -n kube-system cilium-l2announce-home-adguard-dns

4. Verify DNS restored:
   dig @10.10.30.53 google.com
```

### Alert Pipeline Verified

| Test | Result |
|------|--------|
| Test probe (non-existent IP) | probe_success=0 |
| Alert pending after 15s | ✓ |
| Alert firing after 1m | ✓ |
| Discord #status notification | ✓ Received |
| Cleanup + resolved notification | ✓ Received |

---

## January 29, 2026 - Phase 4.8: AdGuard Client IP Preservation

### Milestone: Fixed Client IP Visibility in AdGuard Logs

Resolved issue where AdGuard showed node IPs instead of real client IPs. Root cause was `externalTrafficPolicy: Cluster` combined with Cilium L2 lease on wrong node.

| Component | Change |
|-----------|--------|
| AdGuard DNS Service | externalTrafficPolicy: Cluster → Local |
| AdGuard Deployment | nodeSelector pinned to k8s-cp2 |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Traffic policy | Local | Preserves client IP (no SNAT) |
| Pod placement | Node pinning | Simpler than DaemonSet, keeps UI config |
| L2 alignment | Manual lease delete | Force re-election to pod node |

### CKA Learnings

| Topic | Concept |
|-------|---------|
| externalTrafficPolicy | Cluster (SNAT, any node) vs Local (preserve IP, pod node only) |
| Cilium L2 Announcement | Leader election via Kubernetes Leases |
| Health Check Node Port | Auto-created for Local policy services |

### Lessons Learned

1. **L2 lease must match pod node for Local policy** - Traffic dropped if mismatch occurs.

2. **Cilium agent restart can move L2 lease** - Caused 3-day outage (Jan 25-28) with no alerts.

3. **CoreDNS IPs in AdGuard are expected** - Pods query CoreDNS which forwards to AdGuard.

4. **General L2 policies can conflict with specific ones** - Delete conflicting policies before creating service-specific ones.

---

## January 28, 2026 - Phase 4.7: Portfolio CI/CD Migration

### Milestone: First App Deployed via GitLab CI/CD

Migrated portfolio website from PVE VM Docker Compose to Kubernetes with full GitLab CI/CD pipeline. Three environments (dev, staging, prod) with GitFlow branching strategy.

| Component | Status |
|-----------|--------|
| Portfolio (Next.js) | Running (3 environments) |
| GitLab CI/CD | 4-stage pipeline (validate, test, build, deploy) |
| Container Registry | Public project for anonymous pulls |

### Files Added

| File | Purpose |
|------|---------|
| manifests/portfolio/deployment.yaml | Deployment + Service (2 replicas) |
| manifests/portfolio/rbac.yaml | ServiceAccount for CI/CD deploys |
| manifests/gateway/routes/portfolio-*.yaml | HTTPRoutes for 3 environments |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Environments | dev/staging/prod | Corporate pattern learning |
| Branching | GitFlow | develop → dev (auto), staging (manual), main → prod (auto) |
| Registry auth | Public project | Simpler than imagePullSecrets for personal portfolio |
| URL pattern | Flat subdomains | portfolio-dev vs portfolio.dev for wildcard TLS |

### Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    GitLab CI/CD Pipeline                        │
├─────────────────────────────────────────────────────────────────┤
│  develop branch ──► validate ──► test ──► build ──► deploy:dev  │
│                                                    ──► deploy:staging (manual)
│  main branch ────► validate ──► test ──► build ──► deploy:prod  │
└─────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────┐
│  portfolio-dev        portfolio-staging      portfolio-prod     │
│  (internal only)      beta.rommelporras.com  www.rommelporras.com│
└─────────────────────────────────────────────────────────────────┘
```

### Cloudflare Tunnel Routes

| Subdomain | Target |
|-----------|--------|
| beta.rommelporras.com | portfolio.portfolio-staging.svc:80 |
| www.rommelporras.com | portfolio.portfolio-prod.svc:80 |

### Lessons Learned

1. **RBAC needs list/watch for rollout status** - `kubectl rollout status` requires list and watch verbs on deployments and replicasets.

2. **kubectl context order matters** - `set-context` must come before `use-context` in CI/CD scripts.

3. **Wildcard TLS only covers one level** - `*.k8s.home...` doesn't cover `portfolio.dev.k8s.home...`. Use flat subdomains like `portfolio-dev.k8s.home...`.

4. **CiliumNetworkPolicy for tunnel egress** - Cloudflared egress policy must explicitly allow each namespace it needs to reach.

5. **Docker-in-Docker needs wait loop** - Add `until docker info; do sleep 2; done` before docker commands in CI.

---

## January 25, 2026 - Phase 4.6: GitLab CE

### Milestone: Self-hosted DevOps Platform

Deployed GitLab CE v18.8.2 with GitLab Runner for CI/CD pipelines, Container Registry, and SSH access.

| Component | Version | Status |
|-----------|---------|--------|
| GitLab CE | v18.8.2 | Running |
| GitLab Runner | v18.8.0 | Running (Kubernetes executor) |
| PostgreSQL | 16.6 | Running (bundled) |
| Container Registry | v4.x | Running |

### Files Added

| File | Purpose |
|------|---------|
| helm/gitlab/values.yaml | GitLab Helm configuration |
| helm/gitlab-runner/values.yaml | Runner with Kubernetes executor |
| manifests/gateway/routes/gitlab.yaml | HTTPRoute for web UI |
| manifests/gateway/routes/gitlab-registry.yaml | HTTPRoute for container registry |
| manifests/gitlab/gitlab-shell-lb.yaml | LoadBalancer for SSH (10.10.30.21) |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Edition | Community Edition (CE) | Free, sufficient for homelab |
| Storage | Bundled PostgreSQL/Redis | Learning/PoC, not production |
| SSH Access | Dedicated LoadBalancer IP (.21) | Separate from Gateway, avoids port conflicts |
| SMTP | Shared iCloud SMTP | Reuses existing Alertmanager credentials |
| Secrets | SET_VIA_HELM pattern | Matches Alertmanager, no email in public repo |

### Architecture

```
                         Internet
                             │
          ┌──────────────────┴──────────────────┐
          ▼                                     ▼
┌───────────────────┐                ┌───────────────────┐
│  Gateway API      │                │  LoadBalancer     │
│  10.10.30.20:443  │                │  10.10.30.21:22   │
│  (HTTPS)          │                │  (SSH)            │
└─────────┬─────────┘                └─────────┬─────────┘
          │                                    │
    ┌─────┴─────┐                              │
    ▼           ▼                              ▼
┌───────┐  ┌──────────┐                ┌─────────────┐
│GitLab │  │ Registry │                │ gitlab-shell│
│  Web  │  │  :5000   │                │   :2222     │
│ :8181 │  └──────────┘                └─────────────┘
└───────┘
```

### 1Password Items

| Item | Vault | Fields |
|------|-------|--------|
| GitLab | Kubernetes | username, password, postgresql-password |
| GitLab Runner | Kubernetes | runner-token |
| iCloud SMTP | Kubernetes | username, password (renamed from "iCloud SMTP Alertmanager") |

### Access

| Type | URL |
|------|-----|
| Web UI | https://gitlab.k8s.home.rommelporras.com |
| Registry | https://registry.k8s.home.rommelporras.com |
| SSH | ssh://git@ssh.gitlab.k8s.home.rommelporras.com (10.10.30.21) |

### Lessons Learned

1. **gitlab-shell listens on 2222, not 22** - Container runs as non-root, uses high port internally. LoadBalancer maps 22→2222.

2. **Cilium L2 sharing requires annotation** - To share IP with Gateway, both services need `lro.io/sharing-key`. Used separate IP instead for simplicity.

3. **PostgreSQL secret needs two keys** - Chart expects both `postgresql-password` and `postgresql-postgres-password` in the secret.

4. **SET_VIA_HELM pattern** - Placeholders in values.yaml with `--set` injection at install time keeps credentials out of git.

---

## January 24, 2026 - Phase 4.5: Cloudflare Tunnel

### Milestone: HA Cloudflare Tunnel on Kubernetes

Migrated cloudflared from DMZ LXC to Kubernetes for high availability. Tunnel now survives node failures and Proxmox reboots.

| Component | Version | Status |
|-----------|---------|--------|
| cloudflared | 2026.1.1 | Running (2 replicas, HA) |

### Files Added

| File | Purpose |
|------|---------|
| manifests/cloudflare/deployment.yaml | 2-replica deployment with anti-affinity |
| manifests/cloudflare/networkpolicy.yaml | CiliumNetworkPolicy egress rules |
| manifests/cloudflare/pdb.yaml | PodDisruptionBudget (minAvailable: 1) |
| manifests/cloudflare/service.yaml | ClusterIP for Prometheus metrics |
| manifests/cloudflare/servicemonitor.yaml | Prometheus scraping |
| manifests/cloudflare/secret.yaml | Documentation placeholder for imperative secret |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Replicas | 2 with required anti-affinity | HA across nodes, survives single node failure |
| Security | CiliumNetworkPolicy | Block NAS/internal, allow only Cloudflare Edge + public services |
| DMZ access | Temporary 10.10.50.10/32 rule | Transition period until portfolio/invoicetron migrate to K8s |
| Secrets | 1Password → imperative kubectl | GitOps-friendly, future ESO migration path |
| Namespace PSS | restricted | Matches official cloudflared security recommendations |

### Architecture

```
                    Cloudflare Edge
         (mnl01, hkg11, sin02, sin11, etc.)
                         │
                    8 QUIC connections
                         │
         ┌───────────────┴───────────────┐
         ▼                               ▼
┌─────────────────┐             ┌─────────────────┐
│  cloudflared    │             │  cloudflared    │
│  k8s-cp1        │             │  k8s-cp2        │
│  4 connections  │             │  4 connections  │
└────────┬────────┘             └────────┬────────┘
         │                               │
         └───────────────┬───────────────┘
                         ▼
               ┌─────────────────┐
               │ reverse-mountain│
               │  10.10.50.10    │
               │ (DMZ - temporary)│
               └─────────────────┘
```

### CiliumNetworkPolicy Rules

| Rule | Target | Ports | Purpose |
|------|--------|-------|---------|
| DNS | kube-dns | 53/UDP | Service discovery |
| Cloudflare | 0.0.0.0/0 except RFC1918 | 443, 7844 | Tunnel traffic |
| Portfolio (K8s) | portfolio namespace | 80 | Future K8s service |
| Invoicetron (K8s) | invoicetron namespace | 3000 | Future K8s service |
| DMZ (temporary) | 10.10.50.10/32 | 3000, 3001 | Current Proxmox VM |

### Security Validation

Verified via test pod with `app=cloudflared` label:

| Test | Target | Result |
|------|--------|--------|
| NAS | 10.10.30.4:5000 | BLOCKED |
| Router | 10.10.30.1:80 | BLOCKED |
| Grafana | monitoring namespace | BLOCKED |
| Cloudflare Edge | 104.16.132.229:443 | ALLOWED |
| DMZ VM | 10.10.50.10:3000,3001 | ALLOWED |

### Lessons Learned

1. **CiliumNetworkPolicy blocks private IPs by design** - `toCIDRSet` with `except` for 10.0.0.0/8 blocks DMZ too. Added specific /32 rule for transition period.

2. **Pod Security Standards enforcement** - Test pods in `restricted` namespace need full securityContext (runAsNonRoot, capabilities.drop, seccompProfile).

3. **Loki log retention is 90 days** - Logs auto-delete after 2160h. Old tunnel errors will naturally expire.

4. **OPNsense allows SERVERS→DMZ** - But Cilium blocks it at K8s layer. Network segmentation works at multiple levels.

### 1Password Items

| Item | Vault | Field | Purpose |
|------|-------|-------|---------|
| Cloudflare Tunnel | Kubernetes | token | cloudflared tunnel authentication |

### Public Services (via Tunnel)

| Service | URL | Backend |
|---------|-----|---------|
| Portfolio | https://www.rommelporras.com | 10.10.50.10:3001 (temporary) |
| Invoicetron | https://invoicetron.rommelporras.com | 10.10.50.10:3000 (temporary) |

---

## January 22, 2026 - Phase 4.1-4.4: Stateless Workloads

### Milestone: Home Services Running on Kubernetes

Successfully deployed stateless home services to Kubernetes with full monitoring integration.

| Component | Version | Status |
|-----------|---------|--------|
| AdGuard Home | v0.107.71 | Running (PRIMARY DNS for all VLANs) |
| Homepage | v1.9.0 | Running (2 replicas, multi-tab layout) |
| Glances | v3.3.1 | Running (on OMV, apt install) |
| Metrics Server | v0.8.0 | Running (Helm chart 3.13.0) |

### Files Added

| File | Purpose |
|------|---------|
| manifests/home/adguard/ | AdGuard Home deployment (ConfigMap, Deployment, Service, HTTPRoute, PVC) |
| manifests/home/homepage/ | Homepage dashboard (Kustomize with configMapGenerator) |
| manifests/storage/longhorn/httproute.yaml | Longhorn UI exposure for Homepage widget |
| helm/metrics-server/values.yaml | Metrics server Helm values |
| docs/todo/phase-4.9-tailscale-operator.md | Future Tailscale K8s operator planning |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| DNS IP | 10.10.30.55 (LoadBalancer) | Cilium L2 announcement, separate from FW failover |
| AdGuard storage | Init container + Longhorn PVC | ConfigMap → PVC on first boot, runtime changes preserved |
| Homepage storage | ConfigMap only (stateless) | Kustomize hash suffix for automatic rollouts |
| Secrets | 1Password CLI (imperative) | Never commit secrets to git |
| Settings env vars | Init container substitution | Homepage doesn't substitute `{{HOMEPAGE_VAR_*}}` in providers section |
| Longhorn widget | HTTPRoute exposure | Widget needs direct API access to Longhorn UI |

### Architecture

```
                    ┌─────────────────────────────────────────┐
                    │         Home Namespace (home)           │
                    └─────────────────────────────────────────┘
                                      │
        ┌─────────────────────────────┼─────────────────────────────┐
        │                             │                             │
┌───────▼───────┐            ┌────────▼────────┐           ┌────────▼────────┐
│  AdGuard Home │            │    Homepage     │           │  Metrics Server │
│  v0.107.71    │            │    v1.9.0       │           │    v0.8.0       │
├───────────────┤            ├─────────────────┤           ├─────────────────┤
│ LoadBalancer  │            │ ClusterIP       │           │ ClusterIP       │
│ 10.10.30.55   │            │ → HTTPRoute     │           │ (kube-system)   │
│ DNS :53/udp   │            │                 │           │                 │
│ HTTP :3000    │            │ 2 replicas      │           │ metrics.k8s.io  │
└───────────────┘            └─────────────────┘           └─────────────────┘
        │                             │
        ▼                             ▼
  All VLAN DHCP              Grafana-style dashboard
  Primary DNS                with K8s/Longhorn widgets
```

### DNS Cutover

| VLAN | Primary DNS | Secondary DNS |
|------|-------------|---------------|
| GUEST | 10.10.30.55 | 10.10.30.54 |
| IOT | 10.10.30.55 | 10.10.30.54 |
| LAN | 10.10.30.55 | 10.10.30.54 |
| SERVERS | 10.10.30.55 | 10.10.30.54 |
| TRUSTED_WIFI | 10.10.30.55 | 10.10.30.54 |

### 1Password Items Created

| Item | Vault | Fields |
|------|-------|--------|
| Homepage | Kubernetes | proxmox-pve-user/token, proxmox-fw-user/token, opnsense-username/password, immich-key, omv-user/pass, glances-pass, adguard-user/pass, weather-key, grafana-user/pass, etc. |

### Lessons Learned

1. **Homepage env var substitution limitation:** `{{HOMEPAGE_VAR_*}}` works in `services.yaml` but NOT in `settings.yaml` `providers` section. Used init container with sed to substitute at runtime.

2. **Longhorn widget requires HTTPRoute:** The Homepage Longhorn info widget fetches data via HTTP from Longhorn UI. Must expose via Gateway API even for internal use.

3. **Security context for init containers:** Don't forget `allowPrivilegeEscalation: false` and `capabilities.drop: ALL` on init containers, not just main containers.

4. **Glances version matters:** OMV apt installs v3.x. Homepage widget config needs `version: 3`, not `version: 4`.

5. **ConfigMap hash suffix:** Kustomize `configMapGenerator` adds hash suffix, enabling automatic pod rollouts when config changes. Don't use `generatorOptions.disableNameSuffixHash`.

### HTTPRoutes Configured

| Service | URL |
|---------|-----|
| AdGuard | adguard.k8s.home.rommelporras.com |
| Homepage | portal.k8s.home.rommelporras.com |
| Longhorn | longhorn.k8s.home.rommelporras.com |

---

## January 20, 2026 - Phase 3.9: Alertmanager Notifications

### Milestone: Discord + Email Alerting Configured

Configured Alertmanager to send notifications via Discord and Email, with intelligent routing based on severity.

| Component | Status |
|-----------|--------|
| Discord #incidents | Webhook configured (critical alerts) |
| Discord #status | Webhook configured (warnings, info, resolved) |
| iCloud SMTP | Configured (noreply@rommelporras.com) |
| Email recipients | 3 addresses for critical alerts |

### Files Added/Modified

| File | Purpose |
|------|---------|
| helm/prometheus/values.yaml | Alertmanager config with routes and receivers |
| scripts/upgrade-prometheus.sh | Helm upgrade script with 1Password integration |
| manifests/monitoring/test-alert.yaml | Test alerts for verification |
| docs/rebuild/v0.5.0-alerting.md | Rebuild guide for alerting setup |
| docs/todo/deferred.md | Added kubeadm scraping issue |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Discord channel naming | #incidents + #status | Clear action expectation: incidents need action, status is FYI |
| Category naming | Notifications | Honest about purpose (notification inbox, not observability tool) |
| Email recipients | 3 addresses for critical | Redundancy: iCloud issues won't prevent delivery to Gmail |
| SMTP authentication | @icloud.com email | Apple requires Apple ID for SMTP auth, not custom domain |
| kubeadm alerts | Silenced (null receiver) | False positives from localhost-bound components; cluster works fine |
| Secrets management | 1Password + temp file | --set breaks array structures; temp file with cleanup is safer |

### Alert Routing

```
┌─────────────────────────────────────────────────┐
│                 Alertmanager                    │
└─────────────────────┬───────────────────────────┘
                      │
    ┌─────────────────┼─────────────────┐
    │                 │                 │
┌───▼───┐        ┌────▼────┐       ┌────▼────┐
│Silenced│        │Critical │       │Warning/ │
│kubeadm │        │         │       │  Info   │
└───┬───┘        └────┬────┘       └────┬────┘
    │                 │                 │
┌───▼───┐        ┌────▼────┐       ┌────▼────┐
│ null  │        │#incidents│       │#status  │
│       │        │+ 3 emails│       │  only   │
└───────┘        └─────────┘       └─────────┘
```

### Silenced Alerts (Deferred)

| Alert | Reason | Fix Location |
|-------|--------|--------------|
| KubeProxyDown | kube-proxy metrics not exposed | docs/todo/deferred.md |
| etcdInsufficientMembers | etcd bound to localhost | docs/todo/deferred.md |
| etcdMembersDown | etcd bound to localhost | docs/todo/deferred.md |
| TargetDown (kube-*) | Control plane bound to localhost | docs/todo/deferred.md |

### 1Password Items Created

| Item | Vault | Purpose |
|------|-------|---------|
| Discord Webhooks | Kubernetes | All Discord webhook URLs (incidents, apps, infra, versions, janitor, speedtest) |
| iCloud SMTP | Kubernetes | SMTP credentials |

### Lessons Learned

1. **Helm --set breaks arrays** - Using `--set 'receivers[0].webhook_url=...'` overwrites the entire array structure. Use multiple `--values` files instead.
2. **iCloud SMTP auth** - Must use @icloud.com email for authentication, not custom domain. From address can be custom domain.
3. **Port 587 = STARTTLS** - Not SSL. Common misconfiguration in email clients.
4. **kubeadm metrics** - Control plane components bind to localhost by default. Fixing requires modifying static pod manifests (risky, low value for homelab).

---

## January 20, 2026 - Documentation: Rebuild Guides

### Milestone: Split Rebuild Documentation by Release Tag

Created comprehensive step-by-step rebuild guides split by release tag for better organization and versioning.

| Document | Release | Phases |
|----------|---------|--------|
| [docs/rebuild/README.md](../rebuild/README.md) | Index | Overview, prerequisites, versions |
| [docs/rebuild/v0.1.0-foundation.md](../rebuild/v0.1.0-foundation.md) | v0.1.0 | Phase 1: Ubuntu, SSH |
| [docs/rebuild/v0.2.0-bootstrap.md](../rebuild/v0.2.0-bootstrap.md) | v0.2.0 | Phase 2: kubeadm, Cilium |
| [docs/rebuild/v0.3.0-storage.md](../rebuild/v0.3.0-storage.md) | v0.3.0 | Phase 3.1-3.4: Longhorn |
| [docs/rebuild/v0.4.0-observability.md](../rebuild/v0.4.0-observability.md) | v0.4.0 | Phase 3.5-3.8: Gateway, Monitoring, Logging, UPS |

### Benefits

- Each release is self-contained and versioned
- Can rebuild to a specific milestone
- Easier to maintain and update individual phases
- Aligns with git tags for reproducibility

---

## January 20, 2026 - Phase 3.8: UPS Monitoring (NUT)

### Milestone: NUT + Prometheus UPS Monitoring Running

Successfully installed Network UPS Tools (NUT) for graceful cluster shutdown during power outages, with Prometheus/Grafana integration for historical metrics and alerting.

| Component | Version | Status |
|-----------|---------|--------|
| NUT (Network UPS Tools) | 2.8.1 | Running (server on cp1, clients on cp2/cp3) |
| nut-exporter (DRuggeri) | 3.1.1 | Running (Deployment in monitoring namespace) |
| CyberPower UPS | CP1600EPFCLCD | Connected (USB to k8s-cp1) |

### Files Added

| File | Purpose |
|------|---------|
| manifests/monitoring/nut-exporter.yaml | Deployment, Service, ServiceMonitor for UPS metrics |
| manifests/monitoring/ups-alerts.yaml | PrometheusRule with 8 UPS alerts |
| manifests/monitoring/dashboards/ups-monitoring.json | Custom UPS dashboard (improved from Grafana.com #19308) |
| manifests/monitoring/ups-dashboard-configmap.yaml | ConfigMap for Grafana auto-provisioning |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| NUT server location | k8s-cp1 (bare metal) | Must run outside K8s to shutdown the node itself |
| Staggered shutdown | Time-based (10/20 min) | NUT upssched timers are native and reliable; percentage-based requires custom polling scripts |
| Exporter | DRuggeri/nut_exporter | Actively maintained (Dec 2025), better documentation, TLS support |
| Dashboard | Custom (repo-stored) | Grafana.com #19308 had issues; custom dashboard with ConfigMap auto-provisioning |
| Metric prefix | network_ups_tools_* | DRuggeri exporter uses this prefix (not nut_*) |
| UPS label | ServiceMonitor relabeling | Exporter doesn't add `ups` label; added via relabeling for dashboard compatibility |

### Architecture

```
CyberPower UPS ──USB──► k8s-cp1 (NUT Server + Master)
                              │
                    TCP 3493 (nutserver)
                              │
              ┌───────────────┼───────────────┐
              ▼               ▼               ▼
          k8s-cp2         k8s-cp3        K8s Cluster
        (upssched)      (upssched)     ┌─────────────────┐
       20min→shutdown  10min→shutdown  │  nut-exporter   │
                                       │  (Deployment)   │
                                       └────────┬────────┘
                                                │ :9995
                                       ┌────────▼────────┐
                                       │   Prometheus    │
                                       │ (ServiceMonitor)│
                                       └────────┬────────┘
                                                │
                                       ┌────────▼────────┐
                                       │    Grafana      │
                                       │  (Dashboard)    │
                                       └────────┬────────┘
                                                │
                                       ┌────────▼────────┐
                                       │  Alertmanager   │
                                       │(PrometheusRule) │
                                       └─────────────────┘
```

### Staggered Shutdown Strategy

| Node | Trigger | Timer | Reason |
|------|---------|-------|--------|
| k8s-cp3 | ONBATT event | 10 minutes | First to shutdown, reduce load early |
| k8s-cp2 | ONBATT event | 20 minutes | Second to shutdown, maintain quorum longer |
| k8s-cp1 | Low Battery (LB) | Native NUT | Last node, sends UPS power-off command |

With ~70 minute runtime at 9% load, these timers provide ample safety margin.

### Kubelet Graceful Shutdown

Configured on all nodes to evict pods gracefully before power-off:

```yaml
shutdownGracePeriod: 120s           # Total time for pod eviction
shutdownGracePeriodCriticalPods: 30s # Reserved for critical pods
```

### Alerts Configured

| Alert | Severity | Trigger |
|-------|----------|---------|
| UPSOnBattery | warning | On battery for 1m |
| UPSLowBattery | critical | LB flag set (immediate) |
| UPSBatteryCritical | critical | Battery < 30% for 1m |
| UPSBatteryWarning | warning | Battery 30-50% for 2m |
| UPSHighLoad | warning | Load > 80% for 5m |
| UPSExporterDown | critical | Exporter unreachable for 2m |
| UPSOffline | critical | Neither OL nor OB status for 2m |
| UPSBackOnline | info | Returns to line power |

### Lessons Learned

**USB permissions require udev rules:** The NUT driver couldn't access the USB device due to permissions. Created `/etc/udev/rules.d/90-nut-ups.rules` to grant the `nut` group access to CyberPower USB devices.

**DRuggeri Helm chart doesn't exist:** Despite documentation suggesting otherwise, there's no working Helm repository. Created manual manifests instead (Deployment, Service, ServiceMonitor).

**Metric names differ from documentation:** DRuggeri exporter uses `network_ups_tools_*` prefix, not `nut_*`. The status metric uses `{flag="OB"}` syntax, not `{status="OB"}`. Had to query the actual exporter to discover correct metric names.

**1Password CLI session scope:** The `op` CLI session is terminal-specific. Running `eval $(op signin)` in one terminal doesn't affect others. Each terminal needs its own session.

**Exporter doesn't add `ups` label:** The DRuggeri exporter doesn't include an `ups` label for single-UPS setups. Dashboard queries with `{ups="$ups"}` returned no data. Fixed with ServiceMonitor relabeling to inject `ups=cyberpower` label.

**Grafana.com dashboard had issues:** Dashboard #19308 showed "No Data" for several panels due to missing `--nut.vars_enable` metrics (battery.runtime, output.voltage). Created custom dashboard stored in repo with ConfigMap auto-provisioning.

**Grafana thresholdsStyle modes:** Setting `thresholdsStyle.mode: "line"` draws horizontal threshold lines on graphs; `"area"` fills background with threshold colors. Both can clutter graphs if overused.

### Access

- UPS Dashboard: https://grafana.k8s.home.rommelporras.com/d/ups-monitoring
- NUT Server: 10.10.30.11:3493
- nut-exporter (internal): nut-exporter.monitoring.svc.cluster.local:9995

### Sample PromQL Queries

```promql
network_ups_tools_battery_charge                        # Battery percentage
network_ups_tools_ups_load                              # Current load %
network_ups_tools_ups_status{flag="OL"}                 # Online status (1=true)
network_ups_tools_ups_status{flag="OB"}                 # On battery status
network_ups_tools_battery_runtime_seconds               # Estimated runtime
```

---

## January 19, 2026 - Phase 3.7: Logging Stack

### Milestone: Loki + Alloy Running

Successfully installed centralized logging with Loki for storage and Alloy for log collection.

| Component | Version | Status |
|-----------|---------|--------|
| Loki | v3.6.3 | Running (SingleBinary, 10Gi PVC) |
| Alloy | v1.12.2 | Running (DaemonSet, 3 pods) |

### Files Added

| File | Purpose |
|------|---------|
| helm/loki/values.yaml | Loki SingleBinary mode, 90-day retention, Longhorn storage |
| helm/alloy/values.yaml | Alloy DaemonSet with K8s API log collection + K8s events |
| manifests/monitoring/loki-datasource.yaml | Grafana datasource ConfigMap for Loki |
| manifests/monitoring/loki-servicemonitor.yaml | Prometheus scraping for Loki metrics |
| manifests/monitoring/alloy-servicemonitor.yaml | Prometheus scraping for Alloy metrics |
| manifests/monitoring/logging-alerts.yaml | PrometheusRule with Loki/Alloy alerts |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Loki mode | SingleBinary | Cluster generates ~4MB/day logs, far below 20GB/day threshold |
| Storage backend | Filesystem (Longhorn PVC) | SimpleScalable/Distributed require S3, overkill for homelab |
| Retention | 90 days | Storage analysis showed ~360-810MB needed, 10Gi provides headroom |
| Log collection | loki.source.kubernetes | Uses K8s API, no volume mounts or privileged containers needed |
| Alloy controller | DaemonSet | One pod per node ensures all logs collected |
| OCI registry | Loki only | Alloy doesn't support OCI yet, uses traditional Helm repo |
| K8s events | Single collector | Only k8s-cp1's Alloy forwards events to avoid triplicates |
| Observability | ServiceMonitors + Alerts | Monitor the monitors - Prometheus scrapes Loki/Alloy |
| Alloy memory | 256Mi limit | Increased from 128Mi to handle events collection safely |

### Lessons Learned

**Loki OCI available but undocumented:** Official docs still show `helm repo add grafana`, but Loki chart is available via OCI at `oci://ghcr.io/grafana/helm-charts/loki`. Alloy is not available via OCI (403 denied).

**lokiCanary is top-level setting:** The Loki chart has `lokiCanary.enabled` at the top level, NOT under `monitoring.lokiCanary`. This caused unwanted canary pods until fixed.

**loki.source.kubernetes vs loki.source.file:** The newer `loki.source.kubernetes` component tails logs via K8s API instead of mounting `/var/log/pods`. Benefits: no volume mounts, no privileged containers, works with restrictive Pod Security Standards.

**Grafana sidecar auto-discovery:** Creating a ConfigMap with label `grafana_datasource: "1"` automatically adds the datasource to Grafana. No manual configuration needed.

### Architecture

```
Pod stdout ──────► Alloy (DaemonSet) ──► Loki (SingleBinary) ──► Longhorn PVC
K8s Events ──────►        │                      │
                          │                      ▼
                          │                  Grafana
                          │                      ▲
                          ▼                      │
                    Prometheus ◄── ServiceMonitors (loki, alloy)
                          │
                          ▼
                    Alertmanager ◄── PrometheusRule (logging-alerts)
```

### Alerts Configured

| Alert | Severity | Trigger |
|-------|----------|---------|
| LokiDown | critical | Loki unreachable for 5m |
| LokiIngestionStopped | warning | No logs received for 15m |
| LokiHighErrorRate | warning | Error rate > 10% for 10m |
| LokiStorageLow | warning | PVC < 20% free for 30m |
| AlloyNotOnAllNodes | warning | Alloy pods < node count for 10m |
| AlloyNotSendingLogs | warning | No logs sent for 15m |
| AlloyHighMemory | warning | Memory > 80% limit for 10m |

### Access

- Grafana Explore: https://grafana.k8s.home.rommelporras.com/explore
- Loki (internal): loki.monitoring.svc.cluster.local:3100

### Sample LogQL Queries

```logql
{namespace="monitoring"}                    # All monitoring logs
{namespace="kube-system", container="etcd"} # etcd logs
{cluster="homelab"} |= "error"              # Search for errors
{source="kubernetes_events"}                # All K8s events
{source="kubernetes_events"} |= "Warning"   # Warning events only
```

---

## January 18, 2026 - Phase 3.6: Monitoring Stack

### Milestone: kube-prometheus-stack Running

Successfully installed complete monitoring stack with Prometheus, Grafana, Alertmanager, and node-exporter.

| Component | Version | Status |
|-----------|---------|--------|
| kube-prometheus-stack | v81.0.0 | Running |
| Prometheus | v0.88.0 | Running (50Gi PVC) |
| Grafana | latest | Running (10Gi PVC) |
| Alertmanager | latest | Running (5Gi PVC) |
| node-exporter | latest | Running (DaemonSet, 3 pods) |

### Files Added

| File | Purpose |
|------|---------|
| helm/prometheus/values.yaml | Helm values with 90-day retention, Longhorn storage |
| manifests/monitoring/grafana-httproute.yaml | Gateway API route for HTTPS access |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Pod Security | privileged | node-exporter needs hostNetwork, hostPID, hostPath |
| OCI registry | Yes | Recommended by upstream, no helm repo add needed |
| Retention | 90 days | Balance between history and storage usage |
| Storage | Longhorn | Consistent with cluster storage strategy |

### Lessons Learned

**Pod Security Standards block node-exporter:** The `baseline` PSS level rejects pods with hostNetwork/hostPID/hostPath. node-exporter requires these for host-level metrics collection.

**Solution:** Use `privileged` PSS for monitoring namespace: `kubectl label namespace monitoring pod-security.kubernetes.io/enforce=privileged`

**DaemonSet backoff requires restart:** After fixing PSS, the DaemonSet controller was in backoff. Required `kubectl rollout restart daemonset` to retry pod creation.

### Access

- Grafana: https://grafana.k8s.home.rommelporras.com
- Prometheus (internal): prometheus-kube-prometheus-prometheus:9090
- Alertmanager (internal): prometheus-kube-prometheus-alertmanager:9093

---

## January 17, 2026 - Phase 3: Storage Infrastructure

### Milestone: Longhorn Distributed Storage Running

Successfully installed Longhorn for persistent storage across all 3 nodes.

| Component | Version | Status |
|-----------|---------|--------|
| Longhorn | v1.10.1 | Running |
| StorageClass | longhorn (default) | Active |
| Replicas | 2 per volume | Configured |

### Ansible Playbooks Added

| Playbook | Purpose |
|----------|---------|
| 06-storage-prereqs.yml | Create /var/lib/longhorn, verify iscsid, install nfs-common |
| 07-remove-taints.yml | Remove control-plane taints for homelab workloads |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Replica count | 2 | With 3 nodes, survives 1 node failure. 3 replicas would waste storage. |
| Storage path | /var/lib/longhorn | Standard location, ~432GB available per node |
| Taint removal | All nodes | Homelab has no dedicated workers, workloads must run on control plane |
| Helm values file | helm/longhorn/values.yaml | GitOps-friendly, version controlled |

### Lessons Learned

**Control-plane taints block workloads:** By default, kubeadm taints control plane nodes with `NoSchedule`. In a homelab cluster with no dedicated workers, this prevents Longhorn (and all other workloads) from scheduling.

**Solution:** Remove taints with `kubectl taint nodes --all node-role.kubernetes.io/control-plane:NoSchedule-`

**Helm needs KUBECONFIG:** When using a non-default kubeconfig (like homelab.yaml), Helm requires the correct kubeconfig. Created `helm-homelab` alias in ~/.zshrc alongside `kubectl-homelab`.

**NFSv4 pseudo-root path format:** When OMV exports `/export` with `fsid=0`, it becomes the NFSv4 pseudo-root. Mount paths must be relative to this root:
- Filesystem path: `/export/Kubernetes/Immich`
- NFSv4 mount path: `/Kubernetes/Immich` (not `/export/Kubernetes/Immich`!)

This caused "No such file or directory" errors until the path format was corrected.

### Storage Strategy Documented

| Storage Type | Use Case | Example Apps |
|--------------|----------|--------------|
| Longhorn (block) | App data, databases, runtime state | AdGuard logs, PostgreSQL |
| NFS (file) | Bulk media, photos | Immich, *arr stack |
| ConfigMap (K8s) | Static config files | Homepage settings |

### NFS Status

- NAS (10.10.30.4) is network reachable
- NFS export /export/Kubernetes enabled on OMV
- NFSv4 mount tested and verified from cluster nodes
- Manifest ready at `manifests/storage/nfs-immich.yaml`
- PV name: `immich-nfs`, PVC name: `immich-media`

---

## January 16, 2026 - Kubernetes HA Cluster Bootstrap Complete

### Milestone: 3-Node HA Cluster Running

Successfully bootstrapped a 3-node high-availability Kubernetes cluster using kubeadm.

| Component | Version | Status |
|-----------|---------|--------|
| Kubernetes | v1.35.0 | Running |
| kube-vip | v1.0.3 | Active (VIP: 10.10.30.10) |
| Cilium | 1.18.6 | Healthy |
| etcd | 3 members | Quorum established |

### Ansible Playbooks Created

Full automation for cluster bootstrap:

| Playbook | Purpose |
|----------|---------|
| 00-preflight.yml | Pre-flight checks (cgroup v2, network, DNS) |
| 01-prerequisites.yml | System prep (swap, modules, containerd, kubeadm) |
| 02-kube-vip.yml | VIP setup with K8s 1.29+ workaround |
| 03-init-cluster.yml | kubeadm init with config generation |
| 04-cilium.yml | CNI installation with checksum verification |
| 05-join-cluster.yml | Control plane join with post-join reboot |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Post-join reboot | Enabled | Resolves Cilium init timeouts and kube-vip leader election conflicts |
| Workstation config | ~/.kube/homelab.yaml | Separate from work EKS (~/.kube/config) |
| kubectl alias | `kubectl-homelab` | Work wiki copy-paste compatibility |

### Lessons Learned

**Cascading restart issue:** Joining multiple control planes can cause cascading failures:
- Cilium init timeouts ("failed to sync configmap cache")
- kube-vip leader election conflicts
- Accumulated backoff timers on failed containers

**Solution:** Reboot each node after join to clear state and backoff timers.

### Workstation Setup

```bash
# Homelab cluster (separate from work)
kubectl-homelab get nodes

# Work EKS (unchanged)
kubectl get pods
```

---

## January 11, 2026 - Node Preparation & Project Setup

### Ubuntu Pro Attached

All 3 nodes attached to Ubuntu Pro (free personal subscription, 5 machine limit).

| Service | Status | Benefit |
|---------|--------|---------|
| ESM Apps | Enabled | Extended security for universe packages |
| ESM Infra | Enabled | Extended security for main packages |
| Livepatch | Enabled | Kernel patches without reboot |

### Firmware Updates

| Node | NVMe | BIOS | EC | Notes |
|------|------|------|-----|-------|
| cp1 | 41730C20 | 1.99 | 256.24 | All updates applied |
| cp2 | 41730C20 | 1.90 | 256.20 | Boot Order Lock blocking BIOS/EC |
| cp3 | 41730C20 | 1.82 | 256.20 | Boot Order Lock blocking BIOS/EC |

**NVMe update (High urgency):** Applied to all nodes.
**BIOS/EC updates (Low urgency):** Deferred for cp2/cp3 - requires physical access to disable Boot Order Lock in BIOS. Tracked in TODO.md.

### Claude Code Configuration

Created `.claude/` directory structure:

| Component | Purpose |
|-----------|---------|
| commands/commit.md | Conventional commits with `infra:` type |
| commands/release.md | Semantic versioning and GitHub releases |
| commands/validate.md | YAML and K8s manifest validation |
| commands/cluster-status.md | Cluster health checks |
| agents/kubernetes-expert | K8s troubleshooting and best practices |
| skills/kubeadm-patterns | Bootstrap issues and upgrade patterns |
| hooks/protect-sensitive.sh | Block edits to secrets/credentials |

### GitHub Repository

Recreated repository with clean commit history and proper conventional commit messages.

**Description:** From Proxmox VMs/LXCs to GitOps-driven Kubernetes. Proxmox now handles NAS and OPNsense only. Production workloads run on 3-node HA bare-metal K8s. Lenovo M80q nodes, kubeadm, Cilium, kube-vip, Longhorn. Real HA for real workloads. CKA-ready.

### Rules Added to CLAUDE.md

- No AI attribution in commits
- No automatic git commits/pushes (require explicit request or /commit, /release)

---

## January 11, 2026 - Ubuntu Installation Complete

### Milestone: Phase 1 Complete

All 3 nodes running Ubuntu 24.04.3 LTS with SSH access configured.

### Hardware Verification

**Actual hardware is M80q, not M70q Gen 1** as originally thought.

| Spec | Documented | Actual |
|------|------------|--------|
| Model | M70q Gen 1 | **M80q** |
| Product ID | - | 11DN0054PC |
| CPU | i5-10400T | i5-10400T |
| NIC | I219-V | **I219-LM** |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Hostnames | k8s-cp1/2/3 | Industry standard k8s prefix |
| Username | wawashi | Consistent across all nodes |
| IP Scheme | .11/.12/.13 | Node number matches last octet |
| VIP | 10.10.30.10 | "Base" cluster address |
| Filesystem | ext4 | Most stable for containers |
| LVM | Full disk | Manually expanded from 100GB default |

### Issues Resolved

| Issue | Cause | Solution |
|-------|-------|----------|
| DHCP not working in installer | Gateway/DNS not persisting | Use OPNsense DHCP reservations |
| Nodes can't reach gateway | VLAN 30 not in trunk list | Add VLAN to Native AND Trunk |
| LVM only 100GB | Ubuntu installer bug | Edit ubuntu-lv size to max |
| Interface name | Docs said enp0s31f6 | Actual is eno1 (Intel I219-LM) |

### Documentation Refactor

Consolidated documentation to reduce redundancy:

**Files Consolidated:**
- HARDWARE_SPECS.md → Merged into CLUSTER_STATUS.md
- SWITCH_CONFIG.md → Merged into NETWORK_INTEGRATION.md
- PRE_INSTALLATION_CHECKLIST.md → Lessons in CHANGELOG.md
- KUBEADM.md → Split into KUBEADM_BOOTSTRAP.md (project-specific)

**Key Principle:** CLUSTER_STATUS.md is the single source of truth for all node/hardware values.

---

## January 10, 2026 - Switch Configuration

### VLAN Configuration

Configured LIANGUO LG-SG5T1 managed switch.

### Critical Learning

**VLAN must be in Trunk VLAN list even if set as Native VLAN** on this switch model.

---

## January 4, 2026 - Pre-Installation Decisions

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Network Speed | 1GbE initially | Identify bottlenecks first |
| VIP Strategy | kube-vip (ARP) | No OPNsense changes needed |
| Switch Type | Managed | VLAN support required |
| Ubuntu Install | Full disk + LVM | Simple, Longhorn uses directory |

---

## January 3, 2026 - Hardware Purchase

### Hardware Purchased

| Item | Qty | Specs |
|------|-----|-------|
| Lenovo M80q | 3 | i5-10400T, 16GB, 512GB NVMe |
| LIANGUO LG-SG5T1 | 1 | 5x 2.5GbE + 1x 10G SFP+ |

### Decision: M80q over M70q Gen 3

| Factor | M70q Gen 3 | M80q (purchased) |
|--------|------------|------------------|
| CPU Gen | 12th (hybrid) | 10th (uniform) |
| RAM | DDR5 | DDR4 |
| Price | Higher | **Lower** |
| Complexity | P+E cores | Simple |

10th gen uniform cores simpler for Kubernetes scheduling.

---

## December 31, 2025 - Network Adapter Correction

### Correction Applied

| Previous | Corrected |
|----------|-----------|
| Intel i226-V | **Intel i225-V rev 3** |

**Reason:** i226-V has ASPM + NVMe conflicts causing stability issues.

---

## December 2025 - Initial Planning

### Project Goals Defined

1. Learn Kubernetes via hands-on homelab
2. Master AWS EKS monitoring for work
3. Pass CKA certification by September 2026

### Key Requirements

- High availability (3-node minimum for etcd quorum)
- Stateful workload support (Longhorn)
- CKA exam alignment (kubeadm, not k3s)
