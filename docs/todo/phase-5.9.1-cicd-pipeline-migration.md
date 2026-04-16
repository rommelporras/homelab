# Phase 5.9.1: CI/CD Pipeline Migration (Argo Events + Workflows)

> **Status:** Planned
> **Target:** v0.39.1 (Stage 1 - ArgoCD onboarding) → v0.39.2 (Stage 2 - Argo Events CI/CD)
> **Prerequisite:** Phase 5.9 (v0.39.0 - Argo Workflows installed, controller + argo-server running with `--namespaced` mode)
> **DevOps Topics:** Event-driven CI/CD, GitOps image promotion, BuildKit rootless, webhook triggers, Kustomize overlays
> **CKA Topics:** CRD-based automation, RBAC (cross-namespace), ValidatingAdmissionPolicy, Kustomize

> **Purpose:** Two-stage migration. Stage 1 (v0.39.1) puts Portfolio and Invoicetron under ArgoCD declarative management via Kustomize overlays while keeping GitLab CI's `kubectl set image` dormant. Stage 2 (v0.39.2) replaces the GitLab CI deploy jobs with Argo Events (webhook triggers) + Argo Workflows (build/test/deploy) + ArgoCD (reconciles the git-commit-back).
>
> **Learning Goal:** Event-driven architecture, GitOps-native image promotion (CI commits image tag to Git, ArgoCD syncs), BuildKit rootless image builds in Kubernetes, reusable WorkflowTemplates, Kustomize overlay patterns, and why splitting migrations into "declarative-first + automation-later" reduces blast radius.

> **Image tag verification gate:** All container image tags in this plan were pinned 2026-04-16. Image ecosystems move fast — **re-verify every tag on the Docker Hub / registry page before the relevant wave runs.** Specifically check BuildKit, Playwright, alpine/git, bun, curl, node, and the Argo Events Helm chart version. Update the plan in Git if newer stable versions exist. Never use floating tags (`:latest`, `:1.2-alpine`, `:rootless`).

---

## Why Two Releases

Plan review on 2026-04-16 found that Invoicetron and Portfolio are **not currently ArgoCD-managed** — they deploy via GitLab CI's `kubectl set image`. The original single-release plan presupposed ArgoCD Applications already existed for them. They do not (verified: `manifests/argocd/apps/` contains no `portfolio*` or `invoicetron*` files). Jumping from "imperative kubectl" to "event-driven Argo pipeline" in one release couples two independent risks.

Splitting:

| Release | Scope | Rollback if something breaks |
|---------|-------|-------------------------------|
| **v0.39.1 (Stage 1)** | Restructure manifests into Kustomize overlays. Create 5 ArgoCD Applications (invoicetron-dev/prod, portfolio-dev/staging/prod) pointed at current live images. Enable auto-sync + selfHeal. Set GitLab CI deploy jobs to `when: manual` to stop fighting ArgoCD. | Delete the 5 ArgoCD Applications; flip GitLab CI back to automatic. Cluster state is unchanged (ArgoCD was pointed at live images). |
| **v0.39.2 (Stage 2)** | Install Argo Events. Build shared WorkflowTemplates. Create GitLab EventSources + Sensors. Deploy step commits the new image tag into the Kustomize overlay; ArgoCD syncs. Remove the GitLab CI deploy jobs. | Re-enable GitLab CI deploy jobs, delete Sensors + WorkflowTemplates. ArgoCD stays; Stage 1 state is preserved. |

---

## Decision Records

### DR-1: Image promotion pattern — CI commits image tag to Git

**Considered:** argocd-image-updater v1.1.1 (maintained, supports Kustomize `newTag` write-back, watches registry).

**Chosen:** CI commits the new image tag to the homelab repo; ArgoCD detects + syncs.

**Why:**
- Tight coupling: failed tests → no deploy → nothing written to Git (visible).
- Git history is the audit trail — every deploy leaves a `chore(ci): update <project> to <sha>` commit.
- Rollback is `git revert` of the image-update commit; ArgoCD syncs automatically.
- argocd-image-updater has known friction with private GitLab registries (argoproj/argo-cd#25364).

**Accepted trade-off:** Every deploy creates a commit on main. Acceptable churn for two apps.

### DR-2: Image tag format — 8-char short commit SHA across both projects

**Considered:** Full 40-char SHA (Portfolio's current format).

**Chosen:** 8-char short SHA for both projects (Invoicetron's current format).

**Why:** Readable in `kubectl describe`, Grafana, Discord alerts. Collision risk across a single repo is negligible (Birthday-paradox math: <1% over decades of daily commits). One standard for both apps.

**Migration note:** Portfolio's first Stage-2 deploy will introduce 8-char tags. Old 40-char tags in GitLab registry remain referenceable for rollback.

### DR-3: Automated commit identity

```
Author / Committer: Argo CI Bot <ci-bot@k8s.rommelporras.com>
Message:            chore(ci): update <project> image to <sha> [skip ci]
Signoff:            yes (git commit --signoff)
Signing:            not yet (ArgoCD signatureKeys on AppProject not configured)
```

`[skip ci]` included defensively in case this repo ever gains its own CI (currently none — `renovate.json:3` has `"enabled": false`, no `.github/workflows/`). `--signoff` for DCO audit trail.

### DR-4: One webhook secret per project (not shared)

**Considered:** Single shared webhook secret, projects distinguished by Sensor filter on `body.project.name`.

**Chosen:** Per-project webhook secret: `invoicetron-webhook-secret`, `portfolio-webhook-secret`.

**Why:** GitLab webhooks don't HMAC the payload (gitlab-org/gitlab-foss#50745). The shared secret is the only authentication, and `body.project.name` is attacker-controlled JSON. A shared secret means anyone holding it can forge pushes for *any* project. Per-project secrets bound the blast radius.

**Implementation:** Two EventSources (one per project), each with its own `accessToken` (GitLab API) + `webhookSecret`.

### DR-5: GitHub write credential — SSH deploy key, scoped to homelab repo

**Considered:** GitHub App (rotating 1h tokens, installable with fine-grained perms); fine-grained PAT (GA Mar 2025).

**Chosen:** SSH deploy key on `rommelporras/homelab` only.

**Why:** Simplest for a homelab, no rotation plumbing needed. Scope limited to this one repo. Stored in Vault, mounted only in the `deploy-image` template's pod (not the build pod).

**Mitigations for whole-repo write blast radius:**
- Deploy step runs in its own pod (SA isolation) — build pod never sees the key.
- `cicd-apps` AppProject `clusterResourceWhitelist` restricts what any Application can create, limiting damage from a malicious manifest commit.
- Future upgrade to GitHub App once rotation is tooled.

### DR-6: EventSource type — dedicated `gitlab` type (not generic `webhook`)

**Considered:** Generic `webhook` EventSource (original plan).

**Chosen:** Dedicated `gitlab` EventSource, one per project.

**Why:**
- Auto-registers the webhook on the GitLab project via API — no manual UI configuration.
- Validates `X-Gitlab-Token` natively at the EventSource, not in a Sensor filter.
- Manages its own webhook lifecycle (delete the EventSource → hook is deregistered from GitLab).

**Required:** GitLab personal/deploy access token with `api` scope, stored in Vault at `argo-events/gitlab-api-token`.

### DR-7: Concurrency guard on deploy step — Argo Workflows mutex + retry-rebase

**Chosen:** Belt and braces.

- `synchronization.mutex: name: deploy-image-lock` at the `deploy-image` template level (scoped to `argo-workflows` namespace). Serializes all deploy steps cluster-wide.
- Inside the step: 5-attempt retry loop with `git pull --rebase` on push failure. Catches races at the GitHub layer if somehow two simultaneous pushes occur.

**Why both:** Mutex handles in-cluster concurrency; rebase handles external writes (e.g. a human committing to main at the same time as a deploy).

### DR-8: Workflow TTL — 1 day on success, 7 days on failure

Matches Phase 5.9's CronWorkflow convention. Applied as `ttlStrategy` on every CI WorkflowTemplate:

```yaml
ttlStrategy:
  secondsAfterSuccess: 86400       # 1 day
  secondsAfterFailure: 604800      # 7 days (keep failures longer for debugging)
  secondsAfterCompletion: 604800
```

Combined with argo-workflows controller `archiveTTL` (phase 5.9 setting) so historic workflow metadata survives pod cleanup.

---

## Problem

Invoicetron and Portfolio deploy today via GitLab CI using `kubectl set image`:

- **Invoicetron** — `manifests/invoicetron/deployment.yaml:75` hardcodes a prod image path; GitLab CI patches it into both `invoicetron-dev` and `invoicetron-prod`. Applying the manifest directly causes env contamination (tracked in CLAUDE.md gotcha: "Invoicetron manifest has CI/CD-managed image"). Live tags verified 2026-04-16: `invoicetron/dev:cbcf2251` and `invoicetron/prod:d4d63d4b` — note the distinct `dev/` vs `prod/` registry sub-paths (different images because `NEXT_PUBLIC_APP_URL` is baked in at build time).
- **Portfolio** — `manifests/portfolio/deployment.yaml:48` uses `:latest` as a placeholder; CI patches per-namespace. Live tags: `portfolio:6ac9034…` (prod), `:51ca6004…` (dev), `:0c7a025c…` (staging) — three distinct images across three namespaces from one flat manifest file.

Both apps need per-env manifests before ArgoCD can manage them, because ArgoCD Applications require a deterministic image tag per Application. Stage 1 delivers that via Kustomize overlays; Stage 2 replaces the imperative CI deploy.

## Solution

**Stage 1 (v0.39.1) — declarative foundation:**
- Restructure `manifests/portfolio/` and `manifests/invoicetron/` into `base/` + `overlays/<env>/`.
- Each overlay pins its own image tag via Kustomize `images` transformer.
- Create 5 ArgoCD Applications in `cicd-apps` AppProject, each pointing at its overlay path. Initial tags = currently-running live images (zero cluster drift at sync time).
- Flip GitLab CI deploy jobs to `when: manual` so they don't fight ArgoCD selfHeal.

**Stage 2 (v0.39.2) — event-driven CI/CD:**
- Install Argo Events (chart-managed, ArgoCD-synced).
- Build shared WorkflowTemplates (clone, lint, test, build-image, deploy-image, verify-health) + project-specific DAGs.
- Deploy step commits the new image tag to the overlay's `kustomization.yaml` using the scoped SSH deploy key.
- Per-project GitLab EventSource + Sensor in `argo-events` namespace, creates Workflows cross-namespace into `argo-workflows`.
- Remove GitLab CI deploy jobs entirely; archive the Portfolio `kube-token-*` Vault entries.

## Architecture (v0.39.2 end state)

```
GitLab (source + registry)
    |
    | webhook (push event)           [per-project endpoint + secret]
    v
Argo Events: gitlab EventSource + Sensor                         [argo-events namespace]
    |
    | creates Workflow (cross-namespace, ClusterRole-backed)
    v
Argo Workflows: WorkflowTemplate (DAG)                           [argo-workflows namespace]
    |
    +-- clone
    +-- lint   |
    +-- type-check  |-- parallel fan-out
    +-- test:unit   |
    +-- test:e2e (Portfolio only)
    +-- build (BuildKit rootless -> push to GitLab registry)
    +-- migrate (Invoicetron only: prisma migrate deploy)
    +-- deploy (commit image tag to homelab repo via SSH deploy key + mutex + rebase-retry)
    +-- verify (HTTP health check)
    |
    + onExit: notify-on-failure (Discord)

    GitHub push ---> ArgoCD reconciles overlay ---> pod rolls out
```

### Event Flow (Stage 2)

1. Developer pushes to GitLab (`develop` or `main`).
2. GitLab fires webhook POST to `argo-events.k8s.rommelporras.com/gitlab/<project>` with `X-Gitlab-Token` header.
3. Dedicated `gitlab` EventSource validates the token, publishes event to EventBus.
4. Per-project Sensor applies branch filter (`refs/heads/develop` or `refs/heads/main`), creates a Workflow from the project's WorkflowTemplate with parameters:
   - `commit_sha` (short 8-char, per DR-2)
   - `branch`
   - `environment` (dev/staging/prod)
   - `image_repo` (full registry path, including the dev/prod sub-path for Invoicetron)

---

## Build Engine: BuildKit Rootless

Replaces DinD from GitLab CI. Kaniko was archived 2025-06-03 (GoogleContainerTools/kaniko), so BuildKit is the current consensus for daemonless k8s builds.

| Aspect | GitLab CI + DinD (today) | Argo Workflows + BuildKit (Stage 2) |
|--------|--------------------------|-------------------------------------|
| Trigger | GitLab webhook → Runner | GitLab webhook → Argo Events → Workflow |
| Build engine | Docker daemon (DinD) | BuildKit (no daemon) |
| Privilege | Privileged container | Rootless, UID 1000 |
| Image (pinned) | `docker:27.4.1-dind` | `moby/buildkit:v0.29.0-rootless` |
| Build command | `docker buildx build` | `buildctl build` |
| Cache | Registry cache | Same registry cache (`--cache-type=registry`, `BUILDKIT_INLINE_CACHE=1`) |
| Registry | GitLab registry (unchanged) | GitLab registry (unchanged) |
| Dockerfiles | Unchanged | Unchanged |

---

## Workflow DAGs

### Portfolio

```
                +--- lint --------+
clone --------+ +--- type-check --+---> build ---> deploy ---> verify
                +--- test:unit ---+
                +--- test:e2e ----+
                    (parallel)
                                        onExit: notify-on-failure
```

### Invoicetron

```
                +--- lint --------+
clone --------+ +--- type-check --+---> build ---> migrate ---> deploy ---> verify
                +--- test:unit ---+       (env-specific build args:
                    (parallel)              NEXT_PUBLIC_APP_URL)
                                        onExit: notify-on-failure
```

### Step Details (pinned image tags — verify before install)

| Step | Image (verified 2026-04-16) | What it does | Shared? |
|------|-----------------------------|--------------|---------|
| clone | `alpine/git:2.52.0` | Clones repo from GitLab into shared volume | Yes |
| lint | `oven/bun:1.2.15-alpine` | `bun install && bun run lint` | Yes (template) |
| type-check | `oven/bun:1.2.15-alpine` | `bun run type-check` (+ `prisma generate` for Invoicetron) | Parameterized |
| test:unit (Portfolio) | `oven/bun:1.2.15-alpine` | `bun run test:unit` | Per-project |
| test:unit (Invoicetron) | `node:22.14-slim` | `bun run test:unit` (Vitest SSR needs Node) | Per-project |
| test:e2e (Portfolio only) | `mcr.microsoft.com/playwright:v1.58.2-noble` | Smoke tests; VAP allowlist update required | Portfolio only |
| build | `moby/buildkit:v0.29.0-rootless` | `buildctl build` + push to GitLab registry | Yes (template) |
| migrate (Invoicetron only) | App image just built | `bunx prisma migrate deploy` | Invoicetron only |
| deploy | `alpine/git:2.52.0` | Updates image tag in overlay via kustomize + commits + pushes | Yes (template) |
| verify | `curlimages/curl:8.19.0` | HTTP health check with retry | Yes (template) |
| notify-on-failure | `curlimages/curl:8.19.0` | onExit handler — reuses Phase 5.9 template | Yes (existing) |

**Argo Events Helm chart (Stage 2):** `argo/argo-events` version **2.4.21** (verify before install — chart cadence is weekly).

**Notify template reuse:** `manifests/argo-workflows/templates/vault-snapshot-template.yaml:155-159` already defines `notify-on-failure`. It is specific to vault-snapshot today; Stage 2 extracts it into a standalone template file that both vault-snapshot and CI workflows reference. No functional change for vault-snapshot.

### Shared Volume

Steps within a workflow share data via an `emptyDir` volume at `/workspace`. `clone` populates it; subsequent steps read from it.

### Branch-to-Environment Mapping

| Project | Branch | Image built | Deploy target | ArgoCD App |
|---------|--------|-------------|---------------|------------|
| Portfolio | `develop` | `.../portfolio:<sha>` | `portfolio-dev` | portfolio-dev |
| Portfolio | `main` | `.../portfolio:<sha>` | `portfolio-prod` | portfolio-prod |
| Portfolio | Staging promotion | (see below) | `portfolio-staging` | portfolio-staging |
| Invoicetron | `develop` | `.../invoicetron/dev:<sha>` (NEXT_PUBLIC_APP_URL=dev URL) | `invoicetron-dev` | invoicetron-dev |
| Invoicetron | `main` | `.../invoicetron/prod:<sha>` (NEXT_PUBLIC_APP_URL=prod URL) | `invoicetron-prod` | invoicetron-prod |

**Portfolio staging promotion (GitOps-compliant):** A `GitOpsPromoteToStaging` WorkflowTemplate accepts a `source_sha` parameter and a `target_env=staging` parameter, runs `verify` + `deploy` only (skips build), promoting a previously-built dev image. Triggered by either (a) a GitLab manual job on the portfolio pipeline that POSTs to a dedicated `/staging-promote` webhook, or (b) a `kubectl-admin create workflow` with explicit SHA. Option (a) preferred because it leaves a GitLab pipeline record; option (b) kept as break-glass. **No `kubectl set image` or direct namespace mutation.**

---

## Deploy Strategy: Git-Based Image Updates

### Flow

1. Build step pushes the image to GitLab registry.
2. Deploy step:
   - Acquires Argo Workflows mutex `deploy-image-lock` (serializes all deploys).
   - Clones homelab repo with SSH deploy key.
   - Runs `kustomize edit set image <name>=<registry>/...:<sha>` inside the correct overlay directory.
   - Commits with DR-3 identity, `--signoff`, message includes `[skip ci]`.
   - Retry loop (5 attempts, exponential backoff): `git pull --rebase origin main && git push`. If the push fails due to a concurrent commit (human or bot), rebase and retry.
3. ArgoCD detects the commit within ~3 min, syncs the Deployment, pod rolls out.
4. `verify` step hits the app's health endpoint (with retry), fails the workflow if unhealthy.

### Concurrency Guard (DR-7 detail)

```yaml
# In deploy-image WorkflowTemplate
synchronization:
  mutex:
    name: deploy-image-lock
    namespace: argo-workflows
```

Mutex holder is logged in workflow events; Prometheus alert `CIDeployMutexHeldTooLong` fires if held > 10 min (indicates stuck step).

### Portfolio Manifest Layout (Stage 1 end state)

```
manifests/portfolio/
  base/
    deployment.yaml
    rbac.yaml
    networkpolicy.yaml
    pdb.yaml
    kustomization.yaml
  overlays/
    dev/
      kustomization.yaml       # images: [{name: ..., newTag: <current-dev-sha>}]
      namespace.yaml
      limitrange.yaml
      resourcequota.yaml
    staging/
      kustomization.yaml       # newTag: <current-staging-sha>
      namespace.yaml
      limitrange.yaml
      resourcequota.yaml
    prod/
      kustomization.yaml       # newTag: <current-prod-sha>
      namespace.yaml
      limitrange.yaml
      resourcequota.yaml
```

Deploy step updates only `overlays/<env>/kustomization.yaml`.

### Invoicetron Manifest Layout (Stage 1 end state)

```
manifests/invoicetron/
  base/
    deployment.yaml            # no namespace, no hardcoded image path
    postgresql.yaml
    rbac.yaml
    backup-cronjob.yaml
    kustomization.yaml
  overlays/
    dev/
      kustomization.yaml       # images: [{name: app, newName: .../invoicetron/dev, newTag: <sha>}]
      namespace.yaml
      externalsecret.yaml
      networkpolicy.yaml
      limitrange.yaml
      resourcequota.yaml
    prod/
      kustomization.yaml       # newName: .../invoicetron/prod, newTag: <sha>
      namespace.yaml
      externalsecret.yaml
      networkpolicy.yaml
      limitrange.yaml
      resourcequota.yaml
```

Kustomize `newName` handles the dev vs prod registry sub-path difference; `newTag` handles the SHA.

### Git Authentication

Deploy step mounts the SSH deploy key from Vault (via ESO):

- Vault path: `secret/argo-workflows/github-deploy-key`
- K8s Secret: `github-deploy-key` in `argo-workflows` namespace
- Mount: `volumeMounts[].name: ssh-key, mountPath: /root/.ssh/id_ed25519, subPath: ssh-privatekey`
- Env: `GIT_SSH_COMMAND="ssh -i /root/.ssh/id_ed25519 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/tmp/known_hosts"`
- Remote URL: `git@github.com:rommelporras/homelab.git`

---

## Security

### RBAC

| ServiceAccount | Namespace | Permissions |
|----------------|-----------|-------------|
| `argo-events-sa` | argo-events | EventSource + Sensor CRUD in `argo-events`; create Workflows in `argo-workflows` (via ClusterRole-backed RoleBinding — see note) |
| `ci-workflow-sa` | argo-workflows | Get Secrets in `argo-workflows`; no cluster-wide access |

**Cross-namespace Workflow creation (DR-relevant):** A `RoleBinding` in `argo-workflows` can name a subject in `argo-events`, so a namespace-scoped `Role` is sufficient for the create permission. **However, the argo-workflows controller is running in `--namespaced` mode (Phase 5.9 gotcha), so it reconciles only Workflows in its own namespace.** That is fine for Stage 2 because all Workflows created by Sensors target `argo-workflows`. Verify controller `--managed-namespace` covers `argo-workflows` explicitly (step 5.9.1.6.1).

No cluster-admin. No wildcards.

### Secrets (Vault → ESO)

| Secret | Vault Path | Namespace | Used By |
|--------|-----------|-----------|---------|
| GitLab API token (for EventSource hook registration) | `argo-events/gitlab-api-token` | argo-events | EventSource |
| Invoicetron webhook secret | `argo-events/invoicetron-webhook-secret` | argo-events | EventSource (per DR-4) |
| Portfolio webhook secret | `argo-events/portfolio-webhook-secret` | argo-events | EventSource (per DR-4) |
| GitLab registry push credentials | `argo-workflows/gitlab-registry` | argo-workflows | `build` step |
| GitHub deploy key (SSH) | `argo-workflows/github-deploy-key` | argo-workflows | `deploy` step (per DR-5) |
| Discord webhooks | `argo-workflows/discord-webhooks` (already seeded for Phase 5.9) | argo-workflows | `notify-on-failure` |

### CiliumNetworkPolicy

| Namespace | Ingress | Egress |
|-----------|---------|--------|
| argo-events | `fromEntities: [ingress]` on EventSource service (Cilium Gateway API, per Phase 5.9 gotcha); Prometheus (metrics) | kube-apiserver (create Workflows cross-namespace); GitLab API (hook registration) |
| argo-workflows | Prometheus (metrics, existing) | GitLab registry push; GitHub SSH (port 22 to github.com CIDRs); GitLab clone HTTPS; DNS for FQDN resolution (`toFQDNs` requires matching DNS egress rule, per CLAUDE.md gotcha); kube-apiserver |

### PSS Compliance

- `argo-events` namespace: `pod-security.kubernetes.io/enforce: baseline` (EventBus uses NATS which needs baseline, not restricted).
- All workflow pods: `seccompProfile: RuntimeDefault`, `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`.
- BuildKit rootless: UID 1000 → baseline compatible.
- No privileged containers, no `hostNetwork`, no `hostPID`, no `hostIPC`.

### VAP (Image Registry Allowlist)

`manifests/kube-system/image-registry-policy.yaml:44-55` currently allows: `docker.io/`, `ghcr.io/`, `registry.k8s.io/`, `quay.io/`, `registry.k8s.rommelporras.com/`, `registry.gitlab.com/`, `lscr.io/`, `gcr.io/`, `public.ecr.aws/`. Currently in `Warn` mode only (`validationActions: [Warn]`).

**Stage 2 adds:** `mcr.microsoft.com/` (for Playwright E2E). This is a plan change that ships with Stage 2, not Stage 1.

### Webhook Authentication (per DR-4 + DR-6)

- `gitlab` EventSource validates `X-Gitlab-Token` natively.
- Per-project secrets — no cross-project forgery if one leaks.
- EventSource auto-registers the hook in GitLab via API (requires `argo-events/gitlab-api-token`).
- Sensor filters by branch (`refs/heads/develop|main`) before creating the Workflow.

---

## Namespace Layout

| Namespace | What lives there |
|-----------|------------------|
| `argo-events` | EventBus, per-project GitLab EventSources, Sensors |
| `argo-workflows` | WorkflowTemplates (shared + per-project), CronWorkflows (existing), CI Workflow instances |
| `portfolio-dev`, `portfolio-staging`, `portfolio-prod` | Application pods (existing namespaces, onboarded to ArgoCD in Stage 1) |
| `invoicetron-dev`, `invoicetron-prod` | Application pods (existing, onboarded in Stage 1) |

---

---

# Stage 1 — v0.39.1 — ArgoCD Onboarding

Goal: every manifest under `manifests/portfolio/` and `manifests/invoicetron/` becomes ArgoCD-managed via Kustomize overlays, with overlay image tags matching current live pods. Zero cluster drift at first sync.

## 5.9.1.1 Stage 1 Pre-Flight

- [x] 5.9.1.1.1 Capture current live images (record for overlays)
  - portfolio-dev: `...portfolio:51ca6004a9f8fc78a1dd7ea54dcd465c810f2c60`
  - portfolio-staging: `...portfolio:0c7a025cdf9f1808cb73499868c052ef9f6c838d`
  - portfolio-prod: `...portfolio:6ac9034300a27657504e4517154b9d0d6b1f2919`
  - invoicetron-dev: `...invoicetron/dev:cbcf2251`
  - invoicetron-prod: `...invoicetron/prod:d4d63d4b`

- [x] 5.9.1.1.2 Confirm `cicd-apps` AppProject exists and has the 5 destinations
  - Verified: `manifests/argocd/appprojects.yaml` already has all 5 destinations. No change needed.

- [x] 5.9.1.1.3 Confirm GitLab CI deploy jobs are ready to be dormant
  - Invoicetron: `deploy:dev` (develop), `deploy:prod` (main) — both auto, flipped to manual in 5.9.1.4.1
  - Portfolio: `deploy:development` (develop), `deploy:production` (main), `deploy:staging` (already manual)

## 5.9.1.2 Wave 1A: Invoicetron Kustomize Overlays

- [x] 5.9.1.2.1 Restructure `manifests/invoicetron/` into `base/` + `overlays/{dev,prod}/`
  - NOTE: `backup-cronjob.yaml` placed in `overlays/prod/` only (not base) — it's prod-specific (NFS path, 9AM schedule). Dev does not need DB backups.
  - Image placeholder in base/deployment.yaml: `image: app` → overlay sets `newName + newTag` per env.
  - Old flat files removed via `git rm`.

- [x] 5.9.1.2.2 Verify overlays produce expected output
  - invoicetron-dev: `registry.k8s.rommelporras.com/0xwsh/invoicetron/dev:cbcf2251` ✓, all resources in `invoicetron-dev` namespace ✓
  - invoicetron-prod: `registry.k8s.rommelporras.com/0xwsh/invoicetron/prod:d4d63d4b` ✓, CronJob included ✓

- [x] 5.9.1.2.3 Create `manifests/argocd/apps/invoicetron-dev.yaml` and `invoicetron-prod.yaml`
  - Created with manual sync (no `syncPolicy.automated`) — enable after zero-diff verify in 5.9.1.2.5

- [x] 5.9.1.2.4 Commit the restructure; ArgoCD auto-discovers apps within 3 min
  - Committed as `3a0366b`. Root app auto-sync created the 5 Application resources.
  - ArgoCD controller OOM during post-cp2-recovery reconciliation storm; temporarily bumped to 2Gi, reverted after sync completed.
- [x] 5.9.1.2.5 Manually trigger initial sync for each app, verify **zero diff** (image matches live)
  - All 5 apps: only ArgoCD tracking-id annotation diffs (expected on first sync). Zero image/spec drift.
  - invoicetron-prod required patching live deployment strategy from RollingUpdate back to Recreate (was modified by CI at some point; SSA field manager conflict).
- [x] 5.9.1.2.6 Enable auto-sync + selfHeal on both invoicetron apps once diff is clean
- [x] 5.9.1.2.7 Remove CLAUDE.md gotcha "Invoicetron manifest has CI/CD-managed image"
  - Removed in the infra commit (same as 5.9.1.2.4)

## 5.9.1.3 Wave 1B: Portfolio Kustomize Overlays

- [x] 5.9.1.3.1 Restructure `manifests/portfolio/` into `base/` + `overlays/{dev,staging,prod}/`
  - NOTE: `networkpolicy.yaml` placed per-overlay (not base) — dev/staging/prod have different Cloudflare ingress rules.
  - Base: `deployment.yaml` (image placeholder `registry.k8s.rommelporras.com/0xwsh/portfolio:placeholder`), `rbac.yaml`, `pdb.yaml`.
  - Overlay kustomization uses `name: registry.k8s.rommelporras.com/0xwsh/portfolio` + `newTag:` only (no newName needed — same registry path for all envs).

- [x] 5.9.1.3.2 Verify overlays with `kubectl-admin kustomize`
  - portfolio-dev: `...portfolio:51ca6004a9f8fc78a1dd7ea54dcd465c810f2c60` ✓
  - portfolio-staging: `...portfolio:0c7a025cdf9f1808cb73499868c052ef9f6c838d` ✓
  - portfolio-prod: `...portfolio:6ac9034300a27657504e4517154b9d0d6b1f2919` ✓

- [x] 5.9.1.3.3 Create `manifests/argocd/apps/portfolio-dev.yaml`, `portfolio-staging.yaml`, `portfolio-prod.yaml`
  - Created with manual sync — enable after zero-diff verify in 5.9.1.3.4

- [x] 5.9.1.3.4 Commit restructure; manual sync; verify zero diff
  - All 3 portfolio apps: only tracking-id annotation diffs. Zero image/spec drift.
- [x] 5.9.1.3.5 Enable auto-sync + selfHeal on all three portfolio apps

## 5.9.1.4 Wave 1C: Flip GitLab CI Deploys to Manual + Docs Cleanup

- [x] 5.9.1.4.1 Flip deploy jobs in both `.gitlab-ci.yml` files to `when: manual`
  - Invoicetron: `deploy:dev` and `deploy:prod` rules updated to `when: manual` (inside `rules:` block, not job-level)
  - Portfolio: `deploy:development` and `deploy:production` rules updated to `when: manual`; `deploy:staging` was already manual
  - `kubectl set image` lines retained as-is (still works for emergency break-glass; ArgoCD's selfHeal reverts it within 3 min if run)
  - Commit + push on each project repo pending user `/commit` in each repo.
- [ ] 5.9.1.4.2 Watch for ArgoCD selfHeal events (after apps are synced)
  - `kubectl-admin get events -n portfolio-dev --field-selector reason=ResourceUpdated --sort-by=.lastTimestamp | tail -20`
- [x] 5.9.1.4.3 Old flat manifests removed via `git rm` in homelab repo
- [x] 5.9.1.4.4 Remove outdated CLAUDE.md gotcha
  - Removed "Invoicetron manifest has CI/CD-managed image" from CLAUDE.md Gotchas section

## 5.9.1.5 Wave 1D: Verification + Ship v0.39.1

- [ ] 5.9.1.5.1 Verify all 5 ArgoCD Applications Synced + Healthy
  ```bash
  kubectl-admin get applications -n argocd -l argocd.argoproj.io/instance \
    -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status | \
    grep -E 'invoicetron|portfolio'
  ```
- [ ] 5.9.1.5.2 Verify live images still match overlay tags (no unintended drift)
- [ ] 5.9.1.5.3 Sanity check a manual deploy via GitLab CI `when: manual` job
  - Bump an image tag on `develop`, trigger the manual deploy job, confirm ArgoCD picks up the change (because GitLab CI's `kubectl set image` is a no-op against the Kustomize overlay — the real change is the manual overlay edit or Stage 2 automation). **This step is optional; it's just verifying the dormant fallback still works.**
- [ ] 5.9.1.5.4 Update `docs/context/Conventions.md`: Portfolio and Invoicetron are now ArgoCD-managed; deploy workflow is "commit to overlay, ArgoCD syncs".
- [ ] 5.9.1.5.5 Update `docs/reference/CHANGELOG.md` entry for v0.39.1
- [ ] 5.9.1.5.6 `/audit-security` → `/commit`
- [ ] 5.9.1.5.7 `/audit-docs` → `/commit`
- [ ] 5.9.1.5.8 `/ship v0.39.1 "ArgoCD Onboarding for Portfolio and Invoicetron"`

---

---

# Stage 2 — v0.39.2 — Argo Events CI/CD Migration

Goal: GitLab pushes drive Argo Workflows builds end-to-end; GitLab CI deploy jobs are deleted. Stage 1 must be complete and stable for at least 3 days before starting Stage 2.

## 5.9.1.6 Stage 2 Pre-Flight

- [ ] 5.9.1.6.1 Verify argo-workflows controller has `--managed-namespace=argo-workflows` configured
  ```bash
  kubectl-homelab -n argo-workflows get deploy argo-workflows-workflow-controller \
    -o jsonpath='{.spec.template.spec.containers[0].args}' | jq
  ```
  Should include `--namespaced` AND `--managed-namespace=argo-workflows` (or the controller installed in `argo-workflows` with `--namespaced` alone is sufficient — confirm by reading Phase 5.9 install values).

- [ ] 5.9.1.6.2 Verify argocd Applications from Stage 1 are still green
- [ ] 5.9.1.6.3 Check cluster resource headroom for Argo Events (~100m CPU, ~128Mi memory)
- [ ] 5.9.1.6.4 VAP playwright check (expect Warn, not Deny — policy is currently advisory):
  ```bash
  kubectl-admin run test-playwright \
    --image=mcr.microsoft.com/playwright:v1.58.2-noble \
    --dry-run=server -n default
  ```
  Plan to add `mcr.microsoft.com/` to the allowlist in step 5.9.1.7.

## 5.9.1.7 Wave 2A: Argo Events Installation (declarative)

All resources committed as YAML; nothing imperative.

- [ ] 5.9.1.7.1 Create 1Password items (user runs once in a safe terminal)
  - **Argo Events** (Kubernetes vault):
    - `gitlab-api-token` — GitLab personal access token with `api` scope (for webhook auto-registration)
    - `invoicetron-webhook-secret` — random 32-byte hex
    - `portfolio-webhook-secret` — random 32-byte hex
  - **Argo Workflows CI/CD** (Kubernetes vault):
    - `gitlab-registry-username` — GitLab deploy token username
    - `gitlab-registry-password` — GitLab deploy token password (scope: `write_registry`)
    - `github-deploy-key` — SSH private key generated via `ssh-keygen -t ed25519 -f id_ed25519_argo_ci -C argo-ci@k8s.rommelporras.com`
  - Add the matching public key to the `rommelporras/homelab` GitHub repo as a **deploy key with write access**.

- [ ] 5.9.1.7.2 Update `scripts/vault/seed-vault-from-1password.sh` with new paths
  - `argo-events/gitlab-api-token` → from "Argo Events" 1P item, field `gitlab-api-token`
  - `argo-events/invoicetron-webhook-secret` → same 1P item
  - `argo-events/portfolio-webhook-secret` → same 1P item
  - `argo-workflows/gitlab-registry` → from "Argo Workflows CI/CD" 1P item (username+password)
  - `argo-workflows/github-deploy-key` → from "Argo Workflows CI/CD" 1P item (ssh-privatekey field)

- [ ] 5.9.1.7.3 Commit `manifests/argo-events/` scaffolding (declarative)
  - `namespace.yaml` with `pod-security.kubernetes.io/enforce: baseline`, `pod-security.kubernetes.io/warn: restricted`, `eso-enabled: "true"` labels.
  - `limitrange.yaml`, `resourcequota.yaml` (matching Phase 5.9's conventions).
  - `ciliumnetworkpolicy.yaml` (ingress: `reserved:ingress` for Gateway API webhook traffic, egress to kube-apiserver + GitLab API + DNS with `toFQDNs` + matching DNS rule).
  - `externalsecret-*.yaml` files for each of the three secrets (target `ClusterSecretStore: vault`).
  - `eventbus.yaml` (NATS-based EventBus CR).
  - `eventsource-invoicetron.yaml` and `eventsource-portfolio.yaml` (`gitlab` type, per DR-6).
  - `sensor-invoicetron.yaml` and `sensor-portfolio.yaml` (branch filter → create Workflow).
  - `httproute.yaml` — `argo-events.k8s.rommelporras.com/gitlab/invoicetron` and `/gitlab/portfolio`.
  - `servicemonitor.yaml` for EventSource/Sensor metrics.
  - `rbac/` — Role + RoleBinding for `argo-events-sa` to create Workflows in `argo-workflows`.

- [ ] 5.9.1.7.4 Commit `helm/argo-events/values.yaml` pinned to chart **2.4.21** (verify before apply)
  - Disable `argo-events-webhook` (we run our own).
  - Set seccompProfile, drop capabilities, non-root.
  - Enable metrics ServiceMonitor.

- [ ] 5.9.1.7.5 Commit `manifests/argocd/apps/argo-events.yaml`
  - AppProject: `infrastructure`.
  - Multi-source Helm + values ref (same pattern as argo-workflows).
  - `targetRevision: 2.4.21`.

- [ ] 5.9.1.7.6 Commit `manifests/argocd/appprojects.yaml` update — add `argo-events` namespace destination to `infrastructure` project.

- [ ] 5.9.1.7.7 Add `mcr.microsoft.com/` to `manifests/kube-system/image-registry-policy.yaml`

- [ ] 5.9.1.7.8 Seed Vault (user runs locally)
  ```bash
  ./scripts/vault/seed-vault-from-1password.sh
  ```

- [ ] 5.9.1.7.9 Push; ArgoCD installs Argo Events. Verify controllers Ready:
  ```bash
  kubectl-homelab -n argo-events get pods
  kubectl-homelab -n argo-events get eventsources,sensors,eventbus
  ```

- [ ] 5.9.1.7.10 Verify webhook auto-registration on GitLab
  - GitLab → invoicetron project → Settings → Webhooks → should see hook pointing at `https://argo-events.k8s.rommelporras.com/gitlab/invoicetron`.
  - Same for portfolio.

- [ ] 5.9.1.7.11 Commit PrometheusRules
  - `EventSourceDown`, `SensorDown`, `CIPipelineFailed` (workflow phase=Failed for > 5m), `CIBuildStuck` (running > 15m), `WebhookDeliveryFailed`, `CIDeployMutexHeldTooLong` (mutex held > 10m).

## 5.9.1.8 Wave 2B: Shared WorkflowTemplates

All committed under `manifests/argo-workflows/templates/`.

- [ ] 5.9.1.8.1 Extract `notify-on-failure` into a standalone template
  - Move the definition from `vault-snapshot-template.yaml:155-159` into `notify-on-failure-template.yaml`.
  - Update `vault-snapshot-template.yaml` to reference the standalone template (`templateRef`).
  - Verify vault-snapshot still runs cleanly.
- [ ] 5.9.1.8.2 `clone-template.yaml`
  - `alpine/git:2.52.0`. Parameters: `repo_url`, `branch`, `commit_sha`, `ssh_secret` (optional, public repos skip).
- [ ] 5.9.1.8.3 `lint-template.yaml`, `type-check-template.yaml`, `test-unit-template.yaml`
  - Parameterized `image` + `command` so both Portfolio (bun) and Invoicetron (node) can share.
- [ ] 5.9.1.8.4 `build-image-template.yaml`
  - `moby/buildkit:v0.29.0-rootless`. Parameters: `image_repo`, `tag`, `build_args`, `dockerfile_path`.
  - Mounts BuildKit `rootlesskit` tmpfs. Uses `buildctl-daemonless.sh build` with `--cache-type=registry` and `BUILDKIT_INLINE_CACHE=1`.
- [ ] 5.9.1.8.5 `deploy-image-template.yaml` (most complex)
  - `alpine/git:2.52.0`. Parameters: `project`, `environment`, `image_repo`, `image_tag`, `overlay_path` (`manifests/<project>/overlays/<env>`).
  - `synchronization.mutex: { name: deploy-image-lock, namespace: argo-workflows }` (DR-7).
  - Steps inside the template:
    1. `git clone` the homelab repo via SSH deploy key.
    2. `cd <overlay_path> && kustomize edit set image app=<image_repo>:<image_tag>`.
    3. `git config user.name "Argo CI Bot" && git config user.email ci-bot@k8s.rommelporras.com`.
    4. `git add kustomization.yaml && git commit --signoff -m "chore(ci): update <project>/<env> image to <sha> [skip ci]"`.
    5. Retry loop (5 attempts, `sleep $((2**i))`): `git pull --rebase origin main && git push`.
    6. On final failure, exit non-zero — workflow fails, `notify-on-failure` fires.
- [ ] 5.9.1.8.6 `verify-health-template.yaml`
  - `curlimages/curl:8.19.0`. Parameters: `url`, `expected_status` (default 200), `retries` (default 30), `interval` (default 10s).
- [ ] 5.9.1.8.7 Per-template `ttlStrategy` (DR-8): 1d success, 7d failure.
- [ ] 5.9.1.8.8 Individually test each template with `kubectl-admin create` submissions
  - Use throwaway parameters. Confirm each step reaches Succeeded.
  - For `deploy-image`: point at a test overlay (e.g., create a sandbox app); verify the retry-rebase loop works by committing to main mid-run.

## 5.9.1.9 Wave 2C: Portfolio Pipeline (pilot)

- [ ] 5.9.1.9.1 Commit `manifests/argo-workflows/templates/portfolio-pipeline.yaml`
  - WorkflowTemplate with DAG: clone → (lint, type-check, test:unit, test:e2e in parallel) → build → deploy → verify; onExit: notify-on-failure.
  - Parameters from Sensor: `commit_sha`, `branch`, `environment`.
- [ ] 5.9.1.9.2 Smoke test by submitting manually with a known-good commit SHA
  ```bash
  kubectl-admin -n argo-workflows create -f <(cat <<EOF
  apiVersion: argoproj.io/v1alpha1
  kind: Workflow
  metadata:
    generateName: portfolio-pipeline-smoke-
  spec:
    workflowTemplateRef:
      name: portfolio-pipeline
    arguments:
      parameters:
      - name: commit_sha
        value: <known-good-sha>
      - name: branch
        value: develop
      - name: environment
        value: dev
  EOF
  )
  ```
- [ ] 5.9.1.9.3 Push to `develop` — verify full path: webhook → EventSource → Sensor → Workflow → all steps pass → git commit lands → ArgoCD syncs → pod rolls out.
- [ ] 5.9.1.9.4 Push to `main` — same, prod target.
- [ ] 5.9.1.9.5 Remove deploy stages from portfolio `.gitlab-ci.yml` (now truly dead)
  - Delete `deploy:dev`, `deploy:staging`, `deploy:prod` jobs.
  - Archive the Portfolio `kube-token-*` secrets in Vault (rename to `archived/kube-token-*`) — no longer used.

## 5.9.1.10 Wave 2D: Invoicetron Pipeline

- [ ] 5.9.1.10.1 Commit `manifests/argo-workflows/templates/invoicetron-pipeline.yaml`
  - DAG: clone → (lint, type-check, test:unit in parallel) → build → migrate → deploy → verify; onExit: notify-on-failure.
  - `migrate` step runs `bunx prisma migrate deploy` using the just-built app image. Database connection string sourced from ExternalSecret.
  - `image_repo` parameter includes the `/dev` or `/prod` sub-path per Sensor branch mapping.
  - Env-specific build args (`NEXT_PUBLIC_APP_URL`) passed to `build-image-template` as `build_args`.
- [ ] 5.9.1.10.2 Test: push to `develop`; verify prisma migration ran, image has correct `NEXT_PUBLIC_APP_URL`, ArgoCD synced new tag.
- [ ] 5.9.1.10.3 Test: push to `main`; same for prod.
- [ ] 5.9.1.10.4 Remove deploy stages from invoicetron `.gitlab-ci.yml`.

## 5.9.1.11 Wave 2E: Portfolio Staging Promotion

- [ ] 5.9.1.11.1 Commit `manifests/argo-workflows/templates/portfolio-staging-promote.yaml`
  - Accepts `source_sha` parameter; skips build; runs deploy → verify against `portfolio-staging`.
- [ ] 5.9.1.11.2 Create a GitLab manual job in portfolio `.gitlab-ci.yml` that POSTs to `argo-events.k8s.rommelporras.com/staging-promote` with `source_sha` payload.
- [ ] 5.9.1.11.3 Add staging-promote EventSource + Sensor (single endpoint, token-validated).
- [ ] 5.9.1.11.4 Test: promote a `develop` SHA to staging; verify ArgoCD syncs portfolio-staging to that SHA.

## 5.9.1.12 Wave 2F: Monitoring

- [ ] 5.9.1.12.1 Commit Grafana dashboard `manifests/monitoring/dashboards/argo-cicd.json`
  - Row: Pod Status (EventBus + EventSource + Sensor + controller)
  - Row: Pipeline Execution (workflow phase=Succeeded/Failed rates, duration percentiles)
  - Row: Build Metrics (BuildKit duration, cache hit rate, image size)
  - Row: Webhook Events (received, filtered, triggered — per project)
  - Row: Deploy mutex hold time
  - Row: Resource Usage (CPU/Memory with dashed request/limit lines)
  - Descriptions on every panel and row. ConfigMap with `grafana_dashboard: "1"` label, `grafana_folder: "Homelab"` annotation.
- [ ] 5.9.1.12.2 Update `manifests/monitoring/probes/` with HTTP probes for:
  - `argo-events.k8s.rommelporras.com/health` (EventSource liveness)
  - `argo-workflows.k8s.rommelporras.com/healthz` (already exists from Phase 5.9)

## 5.9.1.13 Stage 2 Documentation + Ship

- [ ] 5.9.1.13.1 Update context docs:
  - `Architecture.md`: Add Argo Events to architecture section, CI/CD flow.
  - `Conventions.md`: Deploy workflow is now "commit to overlay, ArgoCD syncs" (automated via Sensor).
  - `Secrets.md`: Add the 6 new Vault paths.
  - `Monitoring.md`: Add CI/CD alerts and dashboard.
  - `ExternalServices.md`: GitLab section — document webhook configuration.
- [ ] 5.9.1.13.2 Update CLAUDE.md:
  - Add Argo Events to architecture section.
  - Add any new gotchas discovered during Stage 2 (track them as we go).
  - Confirm "Invoicetron deployment.yaml CI/CD-managed" gotcha was already removed in Stage 1.
- [ ] 5.9.1.13.3 Update `docs/rebuild/` with a v0.39.2 rebuild guide entry.
- [ ] 5.9.1.13.4 Update `docs/reference/CHANGELOG.md` v0.39.2 entry.
- [ ] 5.9.1.13.5 `/audit-security` → `/commit`
- [ ] 5.9.1.13.6 `/audit-docs` → `/commit`
- [ ] 5.9.1.13.7 `/ship v0.39.2 "Argo Events CI/CD Migration"`
- [ ] 5.9.1.13.8 `git mv docs/todo/phase-5.9.1-cicd-pipeline-migration.md docs/todo/completed/`

---

## What Changes Per Repo

| Repo | Stage 1 changes | Stage 2 changes |
|------|-----------------|-----------------|
| homelab | Kustomize base+overlays for portfolio and invoicetron; 5 new ArgoCD Applications; CLAUDE.md gotcha removal | `manifests/argo-events/`, `manifests/argo-workflows/templates/` (shared + per-project), VAP allowlist update, monitoring dashboards/alerts, context docs |
| portfolio (GitLab) | Deploy jobs flipped to `when: manual` | Webhook configured; deploy jobs deleted; `kube-token-*` Vault entries archived |
| invoicetron (GitLab) | Deploy jobs flipped to `when: manual` | Webhook configured; deploy jobs deleted |

## What Does NOT Change

- GitLab stays as source code host + container registry.
- GitLab Runner stays deployed through Stage 2 (used for build/test/lint in GitLab CI until Stage 2 lands; dormant after).
- Application runtime (Services, NetworkPolicies, ExternalSecrets, PostgreSQL StatefulSet) — contents may be reorganized into overlays but resources are identical.
- Existing CronWorkflows from Phase 5.9 (vault-snapshot) — extract `notify-on-failure` into a shared template file, reference preserved.

---

## Verification Checklist

### Stage 1 (v0.39.1)
- [ ] 5 new ArgoCD Applications visible, `syncPolicy.automated: { prune: true, selfHeal: true }`, Synced + Healthy
- [ ] Kustomize overlays produce correct output (`kubectl-admin kustomize`)
- [ ] Live images unchanged vs pre-migration snapshot (no unintended drift)
- [ ] GitLab CI deploy jobs all `when: manual`; no auto-deploy churn visible in ArgoCD events
- [ ] CLAUDE.md gotcha "Invoicetron manifest has CI/CD-managed image" removed

### Stage 2 (v0.39.2)
- [ ] `argo-events` namespace + controllers Running, PSS baseline labeled
- [ ] Per-project EventSources auto-registered webhooks on GitLab
- [ ] All shared WorkflowTemplates deployed and individually tested
- [ ] `notify-on-failure` extracted; vault-snapshot still succeeds referencing it
- [ ] Cross-namespace RBAC: `argo-events-sa` can create Workflows in `argo-workflows`
- [ ] Controller `--managed-namespace` confirmed to cover `argo-workflows`
- [ ] Webhook secret validation works (test with wrong token → request rejected at EventSource)
- [ ] Per-project secret isolation: leaking invoicetron secret cannot forge portfolio push
- [ ] Portfolio develop push → Workflow → all steps pass → ArgoCD sync → dev pod updated
- [ ] Portfolio main push → same, prod target
- [ ] Portfolio staging promotion via manual GitLab job works
- [ ] Invoicetron develop push → pipeline with prisma migration → ArgoCD sync → dev pod updated, correct NEXT_PUBLIC_APP_URL baked in
- [ ] Invoicetron main push → same for prod
- [ ] Deploy mutex serializes concurrent runs (test: trigger two near-simultaneous pushes, verify second deploy waits)
- [ ] Rebase retry loop works (test: commit to main during deploy step, verify the rebase+retry succeeds)
- [ ] Workflow TTL: succeeded workflows cleaned after 24h; failed retained 7 days
- [ ] VAP allows mcr.microsoft.com/ (Playwright)
- [ ] CI alerts fire on induced failure; Discord notification works
- [ ] Grafana dashboard populated

### Security (both stages)
- [ ] All workflow pods non-root, PSS baseline compliant
- [ ] BuildKit rootless UID 1000
- [ ] No cluster-admin ServiceAccounts
- [ ] SSH deploy key mounted only in deploy step pod (not build pod)
- [ ] Per-project webhook secrets validated
- [ ] `[skip ci]` marker present on automated commits
- [ ] `--signoff` present on automated commits

---

## Rollback

### Stage 1 rollback (pre-ship or post-ship)
```bash
# Delete the 5 ArgoCD Applications — apps continue to run with current image
kubectl-admin delete application -n argocd invoicetron-dev invoicetron-prod portfolio-dev portfolio-staging portfolio-prod

# Flip GitLab CI back to automatic by reverting the `when: manual` commit in each project
# (or just let it stay manual — cluster state is unchanged)

# Optionally revert the homelab Kustomize restructure commits in Git (not required for runtime)
git revert <stage-1-commits>
git push
```
Apps continue running on their live images. GitLab CI's `kubectl set image` still works.

### Stage 2 rollback (per-project)
```bash
# Re-enable deploy stages in .gitlab-ci.yml for the affected project
# Delete the project's Sensor (+ EventSource if the only project on it)
kubectl-admin delete sensor -n argo-events sensor-<project>
kubectl-admin delete eventsource -n argo-events eventsource-<project>

# GitLab Runner picks up deploys immediately — no cluster state lost
```

### Full Stage 2 rollback
```bash
# Delete Argo Events Application
kubectl-admin delete application -n argocd argo-events

# Remove namespace
kubectl-admin delete namespace argo-events

# Re-enable all GitLab CI deploy stages on both projects
# Restore archived kube-token-* Vault entries if needed
```

### App rollback (production incident)
Image-specific rollback — no Stage/Phase rollback needed:
```bash
# Find the offending commit on the homelab repo (chore(ci): update <project>...)
git log --oneline | grep "update <project>"

# Revert it
git revert <sha>
git push

# ArgoCD syncs the previous image tag within 3 min
```

---

## Final: Commit and Ship

**Stage 1 (v0.39.1):**
- [ ] `/audit-security` → `/commit` for Kustomize restructure + new ArgoCD Applications
- [ ] `/audit-docs` → `/commit` for context doc updates
- [ ] `/ship v0.39.1 "ArgoCD Onboarding for Portfolio and Invoicetron"`

**Stage 2 (v0.39.2):**
- [ ] `/audit-security` → `/commit` for Argo Events manifests + WorkflowTemplates
- [ ] `/audit-docs` → `/commit` for context doc updates
- [ ] `/ship v0.39.2 "Argo Events CI/CD Migration"`
- [ ] `git mv docs/todo/phase-5.9.1-cicd-pipeline-migration.md docs/todo/completed/`
