# Phase 5.9.1: CI/CD Pipeline Migration (Argo Events + Workflows)

> **Status:** Stage 1 Complete (v0.39.1 shipped 2026-04-16) / Stage 2 In Progress as of 2026-04-20.
>
> **Pipeline steps status (portfolio, after 22 smoke runs):**
> - clone, install-deps, lint, type-check, test-unit: green end-to-end.
> - build (BuildKit rootless): runs the Dockerfile successfully (Next.js compile + TS check + static export, ~25s); **registry push gets 403 despite valid PAT** — skopeo on the same credentials pushes fine. Decision: pivot the push path to skopeo (see Note #28 + Architectural Guidance at the end of Execution Notes).
> - push (skopeo copy, new step): TBD after implementation.
> - deploy (git commit to overlay), migrate (invoicetron), verify: untested.
>
> 28 commits landed (`2bcce8d` → `f5a2dc4`). See "Stage 2 Execution Notes" for the 28 plan-vs-cluster deltas accumulated; the last 13 were hit in this session and all are either fixed or have a concrete pivot.
> **Target:** v0.39.1 (Stage 1 - ArgoCD onboarding, SHIPPED) → v0.39.2 (Stage 2 - Argo Events CI/CD)
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

### Portfolio Manifest Layout (Stage 1 end state - ACTUAL)

```
manifests/portfolio/
  base/
    deployment.yaml            # image: registry.k8s.rommelporras.com/0xwsh/portfolio:placeholder
    rbac.yaml
    pdb.yaml
    kustomization.yaml
  overlays/
    dev/
      kustomization.yaml       # images: [{name: .../portfolio, newTag: 51ca6004...}]
      namespace.yaml
      networkpolicy.yaml       # per-overlay: dev has no Cloudflare ingress
      limitrange.yaml
      resourcequota.yaml
    staging/
      kustomization.yaml       # newTag: 0c7a025c...
      namespace.yaml
      networkpolicy.yaml       # per-overlay: staging has Cloudflare beta
      limitrange.yaml
      resourcequota.yaml
    prod/
      kustomization.yaml       # newTag: 6ac90343...
      namespace.yaml
      networkpolicy.yaml       # per-overlay: prod has Cloudflare prod
      limitrange.yaml
      resourcequota.yaml
```

NOTE: `networkpolicy.yaml` is per-overlay (not base) because dev/staging/prod have
different Cloudflare ingress rules. Plan originally had it in base.

Deploy step updates only `overlays/<env>/kustomization.yaml`.

### Invoicetron Manifest Layout (Stage 1 end state - ACTUAL)

```
manifests/invoicetron/
  base/
    deployment.yaml            # image: app (Kustomize placeholder, overlay sets newName+newTag)
    postgresql.yaml
    rbac.yaml
    kustomization.yaml
  overlays/
    dev/
      kustomization.yaml       # images: [{name: app, newName: .../invoicetron/dev, newTag: cbcf2251}]
      namespace.yaml
      externalsecret.yaml
      networkpolicy.yaml
      limitrange.yaml
      resourcequota.yaml
    prod/
      kustomization.yaml       # newName: .../invoicetron/prod, newTag: d4d63d4b
      namespace.yaml
      externalsecret.yaml
      networkpolicy.yaml
      limitrange.yaml
      resourcequota.yaml
      backup-cronjob.yaml      # prod-only (NFS path, 9AM schedule)
```

NOTE: `backup-cronjob.yaml` is in prod overlay only (not base as originally planned).
Dev does not need DB backups.

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
  - ArgoCD controller OOM during post-cp2-recovery reconciliation storm; permanently bumped to 1Gi/2Gi in `helm/argocd/values.yaml` (40+ apps exceeded 1Gi).
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
- [x] 5.9.1.4.2 Watch for ArgoCD selfHeal events (after apps are synced)
  - Tested: manually triggered `deploy:development` (pipeline 188, job 1295). GitLab CI `kubectl set image` succeeded but ArgoCD selfHeal reverted to overlay tag within 3 min. Confirmed working.
- [x] 5.9.1.4.3 Old flat manifests removed via `git rm` in homelab repo
- [x] 5.9.1.4.4 Remove outdated CLAUDE.md gotcha
  - Removed "Invoicetron manifest has CI/CD-managed image" from CLAUDE.md Gotchas section

## 5.9.1.5 Wave 1D: Verification + Ship v0.39.1

- [x] 5.9.1.5.1 Verify all 5 ArgoCD Applications Synced + Healthy
  - All 5 Synced + Healthy after auto-sync enablement push.
- [x] 5.9.1.5.2 Verify live images still match overlay tags (no unintended drift)
  - invoicetron dev:cbcf2251, prod:d4d63d4b; portfolio dev:51ca6004, staging:0c7a025c, prod:6ac90343
- [x] 5.9.1.5.3 Sanity check a manual deploy via GitLab CI `when: manual` job
  - Tested via portfolio pipeline 188 job 1295 (deploy:development). ArgoCD selfHeal reverted the kubectl set image within 3 min. Confirms dormant fallback works but is a no-op with auto-sync enabled.
- [x] 5.9.1.5.4 Update `docs/context/Conventions.md`: Portfolio and Invoicetron are now ArgoCD-managed; deploy workflow is "commit to overlay, ArgoCD syncs".
- [x] 5.9.1.5.5 Update `docs/reference/CHANGELOG.md` entry for v0.39.1
- [x] 5.9.1.5.6 `/audit-security` → `/commit` (infra commit `3a0366b`, auto-sync commit `1daf383`)
- [x] 5.9.1.5.7 `/audit-docs` → `/commit` (docs commit `f8404cb`, audit fixes `b6e9b28`)
- [x] 5.9.1.5.8 `/ship v0.39.1 "ArgoCD Onboarding for Portfolio and Invoicetron"` - shipped 2026-04-16

---

---

# Stage 2 — v0.39.2 — Argo Events CI/CD Migration

Goal: GitLab pushes drive Argo Workflows builds end-to-end; GitLab CI deploy jobs are deleted. Stage 1 must be complete and stable for at least 3 days before starting Stage 2.

> **Stage 1 shipped:** v0.39.1 on 2026-04-16. Earliest Stage 2 start: 2026-04-19.
>
> **Current deploy workflow (interim):** Update `newTag` in the overlay kustomization.yaml (e.g., `manifests/portfolio/overlays/dev/kustomization.yaml`), commit + push to homelab repo, ArgoCD auto-syncs within 3 min. Do NOT use `kubectl set image` or GitLab CI manual deploy buttons - ArgoCD selfHeal reverts them.
>
> **Bonus fixes shipped with v0.39.1:** GitLab Runner `concurrent: 4` + pod anti-affinity (prevents node OOM from simultaneous pipelines); ArgoCD controller memory 1Gi→2Gi (OOM with 40+ apps).
>
> **External repos:** invoicetron lives at `~/personal/invoicetron`, portfolio at `~/personal/portfolio`. Both have `develop` and `main` branches with deploy jobs flipped to `when: manual`.

## 5.9.1.6 Stage 2 Pre-Flight

- [x] 5.9.1.6.1 Verify argo-workflows controller has `--namespaced` configured
  - Confirmed: controller args include `--namespaced` (no separate `--managed-namespace` flag needed for single-namespace install).
- [x] 5.9.1.6.2 Verify argocd Applications from Stage 1 are still green
  - All 5 apps (invoicetron-dev/prod, portfolio-dev/staging/prod) Synced + Healthy.
- [x] 5.9.1.6.3 Check cluster resource headroom for Argo Events
  - Memory: cp1 80%, cp2 64%, cp3 69% — plenty of headroom. (Original "~128Mi" estimate was way off — actual footprint is ~5Gi peak; see Stage 2 Execution Notes #4.)
- [x] 5.9.1.6.4 VAP playwright check
  - `mcr.microsoft.com/playwright:v1.58.2-noble` returns expected Warn (policy is advisory, not Deny). Allowlist update committed in 5.9.1.7.

## 5.9.1.7 Wave 2A: Argo Events Installation (declarative)

All resources committed as YAML; nothing imperative (except the bootstrap namespace apply, see 5.9.1.7.9).

- [x] 5.9.1.7.1 1Password items
  - **DEVIATION FROM PLAN**: consolidated everything into a single renamed item `Argo Workflows` (was `Argo Workflows UI`) instead of two separate items. Holds all 9 fields: `sso-client-id`, `sso-client-secret`, `registry-username`, `registry-password`, `github-deploy-key`, `gitlab-api-token`, `invoicetron-webhook-secret`, `portfolio-webhook-secret`, `staging-promote-token`. Rationale: Argo Events is an argoproj sibling whose only purpose here is triggering Argo Workflows; one umbrella item is simpler than two.
  - Plan path was: `op://Kubernetes/Argo Workflows UI/<f>` + `op://Kubernetes/Argo Events/<f>` + `op://Kubernetes/Argo Workflows CI/CD/<f>`. Actual path: `op://Kubernetes/Argo Workflows/<f>` for everything.
  - GitLab token created as a Personal Access Token (registry scope) — group/project deploy tokens not available on the self-hosted GitLab edition.
  - SSH deploy key generated locally with `ssh-keygen -t ed25519 -f id_ed25519_argo_ci`, public key added to `rommelporras/homelab` Settings → Deploy keys with write access. Verified `ssh -i id_ed25519_argo_ci -o IdentitiesOnly=yes -T git@github.com` returns `Hi rommelporras/homelab!` (repo-scoped, not user-scoped).

- [x] 5.9.1.7.2 Update `scripts/vault/seed-vault-from-1password.sh` with new paths
  - All 9 paths point at the consolidated `Argo Workflows` 1P item.

- [x] 5.9.1.7.3 Commit `manifests/argo-events/` scaffolding (committed in `2bcce8d`, plus follow-up fixes — see Stage 2 Execution Notes)
  - All listed files created. Sensor structure ended up as 5 Sensor CRs (2 per project for branch filter + 1 for staging-promote) instead of the originally-imagined per-trigger Sensor count, because argo-events does not support per-trigger dependency filters in a single Sensor — splitting by branch into separate Sensors was cleaner.

- [x] 5.9.1.7.4 Commit `helm/argo-events/values.yaml` pinned to chart **2.4.21**
  - **Two iterations** required to land working values (Notes #1 and #2 below). Final state: chart defaults for image (`global.image.repository` schema, not `controller.image.registry`), no `configs.jetstream.settings` override (chart expects map not string).

- [x] 5.9.1.7.5 Commit `manifests/argocd/apps/argo-events.yaml` + companion `argo-events-manifests.yaml`
- [x] 5.9.1.7.6 Commit `manifests/argocd/appprojects.yaml` update — `argo-events` ns added to `infrastructure` project
- [x] 5.9.1.7.7 Add `mcr.microsoft.com/` to `manifests/kube-system/image-registry-policy.yaml`
  - Allowlist updated even though E2E was later deferred (the `mcr.microsoft.com/` allowlist entry is harmless and preserves optionality for the future re-wiring).
- [x] 5.9.1.7.8 Seed Vault (user ran locally via HTTPRoute, not port-forward — feedback memory saved)
- [x] 5.9.1.7.9 Push; ArgoCD installs Argo Events
  - Bootstrap gotcha: `argo-events` namespace had to be applied imperatively first (`kubectl-admin apply -f manifests/argo-events/namespace.yaml`) because both Helm app and manifests app have `CreateNamespace=false`. Same pattern as Phase 5.9 for `argo-workflows`.
  - Took 4 push iterations (chart values, image schema, NATS version, ResourceQuota) before all pods reached Running.
- [x] 5.9.1.7.10 Verify webhook auto-registration on GitLab
  - **Manual prerequisite uncovered**: GitLab admin setting `allow_local_requests_from_web_hooks_and_services` defaults to `false` and rejects internal-IP webhook URLs with `422 Invalid url given`. Flipped via `glab api --method PUT application/settings`. EventSource pods then registered both webhooks (id=1 portfolio, id=2 invoicetron) on first restart.
- [x] 5.9.1.7.11 Commit PrometheusRules (`manifests/monitoring/alerts/argo-events-alerts.yaml`)

## 5.9.1.8 Wave 2B: Shared WorkflowTemplates

All committed under `manifests/argo-workflows/templates/`.

- [x] 5.9.1.8.1 Extract `notify-on-failure` into a standalone template
  - vault-snapshot-template.yaml updated to delegate via templateRef. readOnlyRootFilesystem dropped because Argo Workflows does not propagate `spec.volumes` across templateRef boundaries — couldn't depend on a caller-provided tmp emptyDir.
- [x] 5.9.1.8.2 `clone-template.yaml`
  - **DEVIATION FROM PLAN**: `branch` parameter is required, not optional. `git fetch --depth=1 <short-sha>` doesn't work (wire protocol only accepts branch/tag/full-SHA refs). Updated to fetch the branch then `git checkout <short-sha>` from local objects.
- [x] 5.9.1.8.3 `lint-template.yaml`, `type-check-template.yaml`, `test-unit-template.yaml`
- [x] 5.9.1.8.4 `build-image-template.yaml`
  - Pending verification — has not yet been exercised by a smoke test that reached the build step.
- [x] 5.9.1.8.5 `deploy-image-template.yaml`
  - **SCHEMA DEVIATION**: Argo Workflows v3.6+ replaced singular `synchronization.mutex` with plural `synchronization.mutexes` list. Plan's `synchronization.mutex: { name: ... }` was rejected by SSA with "field not declared in schema". Final form uses `mutexes:`.
  - Pending verification — has not yet been exercised.
- [x] 5.9.1.8.6 `verify-health-template.yaml`
  - **DEVIATION FROM PLAN**: curl needs `-L` flag to follow redirects; live-tested `https://invoicetron.dev.k8s.rommelporras.com/` returns `307 -> /login -> 200`. Without `-L` the verify loop sees 307 not 200 and fails.
- [x] 5.9.1.8.7 Per-template `ttlStrategy` (DR-8): 1d success, 7d failure.
- [ ] 5.9.1.8.8 Individually test each template with `kubectl-admin create` submissions
  - **NOT DONE**: skipped per-template testing in favor of full-pipeline smoke tests. In hindsight this contributed to the iteration loop — per-template tests would have caught the synchronization.mutexes schema bug, the imagePullSecrets placement bug, and the clone short-SHA bug independently.

## 5.9.1.9 Wave 2C: Portfolio Pipeline (pilot)

- [x] 5.9.1.9.1 Commit `manifests/argo-workflows/templates/portfolio-pipeline.yaml`
  - **DEVIATION FROM PLAN (test-e2e deferred)**: Original DAG was clone → (lint, type-check, test:unit, test:e2e) → build → deploy → verify. test:e2e removed from the DAG and tracked in `docs/todo/deferred.md` "Portfolio Pipeline E2E Step" because the Playwright image lacks bun and `playwright.config.ts` requires `out/` (built artifact) which the DAG didn't provide.
  - **DEVIATION FROM PLAN (workspace sharing)**: Plan said "Steps share an emptyDir at /workspace". Wrong — emptyDir is per-pod; clone populated its own workspace, lint saw an empty mount. Fixed with `volumeClaimTemplates` (Longhorn RWO PVC per workflow run) + `securityContext.fsGroup: 1000` so non-root containers can write to the kubelet-mounted volume.
- [ ] 5.9.1.9.2 Smoke test by submitting manually
  - 5 attempts so far, all failed at different steps:
    - smoke1: clone failed (short SHA fetch bug)
    - smoke2: lint/type-check/test-unit/test-e2e all failed (workspace empty bug, plus Discord egress missing in CNP)
    - smoke3: lint/type-check ran, test-unit/test-e2e blocked on argo-workflows ResourceQuota
    - smoke4: lint/type-check/test-unit failed (`EACCES could not create node_modules` — root-owned PVC mount, fixed with fsGroup)
    - smoke5: same EACCES (smoke5 was diagnostic to capture logs)
  - Next attempt blocked on user pushing commit `4ff2c42` (verify-health -L flag fix).
- [ ] 5.9.1.9.3 Push to `develop` — verify full path: webhook → EventSource → Sensor → Workflow → all steps pass → git commit lands → ArgoCD syncs → pod rolls out.
- [ ] 5.9.1.9.4 Push to `main` — same, prod target.
- [ ] 5.9.1.9.5 Remove deploy stages from portfolio `.gitlab-ci.yml` (now truly dead)
  - Delete `deploy:dev`, `deploy:staging`, `deploy:prod` jobs.
  - Archive the Portfolio `kube-token-*` secrets in Vault (rename to `archived/kube-token-*`) — no longer used.

## 5.9.1.10 Wave 2D: Invoicetron Pipeline

- [x] 5.9.1.10.1 Commit `manifests/argo-workflows/templates/invoicetron-pipeline.yaml`
  - **SCHEMA DEVIATION**: `imagePullSecrets` is not valid at `.spec.templates[].imagePullSecrets` in v4.0.4 — must live at `.spec.imagePullSecrets` (workflow level). Plan put it on the migrate step; moved to workflow spec so every step pod inherits it.
  - **DB URL DEVIATION**: Plan said "Database connection string sourced from ExternalSecret". Implementation uses a single `invoicetron-migrate-db-urls` Secret with keys `dev` + `prod`, and the migrate step's `secretKeyRef.key` is parameterized by `{{workflow.parameters.environment}}`. One Secret + one resourceName grant in ci-workflow-sa Role.
  - **CNP DEVIATION**: migrate pods use `app.kubernetes.io/component: invoicetron-migrate` (not `ci-pipeline`) so they get the dedicated `argo-workflows-invoicetron-migrate` CNP for cross-namespace PostgreSQL egress. Updated `manifests/invoicetron/overlays/{dev,prod}/networkpolicy.yaml` to allow ingress from these pods on the `invoicetron-db` selector.
- [ ] 5.9.1.10.2 Test: push to `develop`; verify prisma migration ran, image has correct `NEXT_PUBLIC_APP_URL`, ArgoCD synced new tag.
  - Blocked on portfolio smoke test passing first (shared infrastructure surfaces).
- [ ] 5.9.1.10.3 Test: push to `main`; same for prod.
- [ ] 5.9.1.10.4 Remove deploy stages from invoicetron `.gitlab-ci.yml`.

## 5.9.1.11 Wave 2E: Portfolio Staging Promotion

- [x] 5.9.1.11.1 Commit `manifests/argo-workflows/templates/portfolio-staging-promote.yaml`
- [ ] 5.9.1.11.2 Create a GitLab manual job in portfolio `.gitlab-ci.yml` that POSTs to `argo-events.k8s.rommelporras.com/staging-promote` with `source_sha` payload.
  - Pending — to be done in the portfolio repo after homelab smoke test passes.
- [x] 5.9.1.11.3 Add staging-promote EventSource + Sensor (single endpoint, token-validated)
  - EventSource is generic `webhook` type (not `gitlab` type) since GitLab manual job posts arbitrary JSON. Sensor filter validates the `X-Staging-Promote-Token` header against the `staging-promote-token` Secret.
- [ ] 5.9.1.11.4 Test: promote a `develop` SHA to staging; verify ArgoCD syncs portfolio-staging to that SHA.

## 5.9.1.12 Wave 2F: Monitoring

- [x] 5.9.1.12.1 Commit Grafana dashboard `manifests/monitoring/dashboards/argo-cicd-dashboard-configmap.yaml`
  - Starter dashboard with 5 rows (Pod Status, Pipeline Execution, Webhook Events, Resource Usage). Build Metrics + Deploy Mutex rows deferred to post-ship refinement once real metrics accumulate.
- [x] 5.9.1.12.2 HTTP probe added: `manifests/monitoring/probes/argo-events-probe.yaml` for `argo-events.k8s.rommelporras.com/gitlab/invoicetron`
  - `/health` endpoint not implemented by EventSource pods; using a known webhook path that returns 405 for GET (which blackbox treats as up).

## 5.9.1.13 Stage 2 Documentation + Ship

- [x] 5.9.1.13.1 Update context docs (commit `6f21676`):
  - `Architecture.md`: new "Argo Events + Argo Workflows for CI/CD" section.
  - `Conventions.md`: deploy workflow + manifests/ tree updated.
  - `Secrets.md`: 1P item consolidation + new Vault paths documented.
  - `Monitoring.md`: alerts + dashboard + probe added.
  - `ExternalServices.md`: GitLab Webhooks section.
- [ ] 5.9.1.13.2 Update CLAUDE.md (deferred to post-ship)
  - The new gotchas surfaced during execution (15 of them, see Stage 2 Execution Notes below) should be condensed and added to CLAUDE.md Gotchas section before ship. Doing this post-stable to avoid churn.
- [x] 5.9.1.13.3 `docs/rebuild/v0.39.2-argo-events-cicd.md` written
  - Includes install/validation/rollback. Updates from execution: 1P item consolidation reflected in install steps.
- [x] 5.9.1.13.4 `docs/reference/CHANGELOG.md` v0.39.2 entry (Unreleased)
- [x] 5.9.1.13.5 `/audit-security` → `/commit` (commit `2bcce8d`)
- [x] 5.9.1.13.6 `/audit-docs` → `/commit` (commit `6f21676`)
- [ ] 5.9.1.13.7 `/ship v0.39.2 "Argo Events CI/CD Migration"` — pending end-to-end smoke test pass
- [ ] 5.9.1.13.8 `git mv docs/todo/phase-5.9.1-cicd-pipeline-migration.md docs/todo/completed/` — done at ship

---

## Stage 2 Execution Notes

What actually happened, vs the plan, between 2026-04-18 and 2026-04-19. Captured for the post-mortem and for future phases that touch Argo Events + Workflows + BuildKit on this cluster.

### Commits landed during execution

| Commit | Type | What |
|--------|------|------|
| `2bcce8d` | infra | Initial Argo Events + WorkflowTemplates batch (49 files) |
| `6f21676` | docs  | Context docs + CHANGELOG + rebuild guide + deferred.md |
| `bae726d` | fix   | Drop `configs.jetstream.settings` string override (Notes #1) |
| `da68905` | fix   | Use chart default image (Notes #2) |
| `0a49b1e` | fix   | Pin EventBus NATS to supported 2.10.10 (Notes #3) |
| `b048343` | fix   | Bump argo-events ResourceQuota to fit fleet (Notes #4) |
| `60474ad` | fix   | WorkflowTemplate v4.0.4 schema (mutexes + imagePullSecrets) (Notes #5, #6) |
| `337c289` | fix   | clone branch fetch + Discord CNP egress (Notes #7, #8) |
| `c8a9e98` | fix   | volumeClaimTemplates for cross-step workspace sharing (Notes #9) |
| `27770ec` | fix   | Bump argo-workflows ResourceQuota for 4-way parallel (Notes #10) |
| `fc40f0a` | infra | Defer test-e2e + broaden CI pipeline HTTPS egress (Notes #11, #12) |
| `aa6a239` | fix   | fsGroup=1000 for PVC write access (Notes #13) |
| `c910e55` | fix   | Use actual HTTPRoute hostnames in verify URLs (Notes #14) |
| `4ff2c42` | fix   | verify-health follows redirects (Notes #15) |
| `13eff22` | fix   | Install deps once before parallel lint/test (Notes #16) |
| `ac08cd0` | fix   | Pin portfolio test-unit to node:22-slim (Notes #17) |
| `37c0cf0` | fix   | Raise install-deps memory limit to 2Gi (Notes #18) |
| `0fdb33f` | fix   | npm-prefix workaround for non-root test-unit (Notes #19) |
| `9344f29` | infra | Relax argo-workflows PSS enforce to privileged (Notes #20) |
| `40f9eb1` | fix   | Allow privilege escalation on build-image (Notes #21) |
| `f5a2dc4` | fix   | Drop capabilities block on build-image (Notes #22) |

### 15 plan-vs-cluster deltas

1. **`configs.jetstream.settings` schema** — chart 2.4.21 expects this as a map with typed keys (`maxFileStore`, `maxMemoryStore`), not a YAML pipe-block string. Helm template fails with "cannot overwrite table with non table". Fix: drop the override, chart defaults are fine.

2. **`controller.image.*` schema** — chart uses `global.image.repository` (full path) + `global.image.tag`, NOT the split `registry/repository/tag` pattern used by other argoproj charts. My override resolved to `docker.io/argoproj/argo-events:v1.9.6` (doesn't exist on Docker Hub) instead of `quay.io/argoproj/argo-events:v1.9.10` (chart default). Fix: drop the override.

3. **NATS JetStream version allowlist** — argo-events v1.9.10 controller hardcodes a list: `latest, 2.8.1, 2.8.1-alpine, 2.8.2, 2.8.2-alpine, 2.9.1, 2.9.12, 2.9.16, 2.10.10`. Plan picked 2.10.17 from NATS release notes — rejected with `unsupported version`. Fix: pin to 2.10.10.

4. **argo-events ResourceQuota too small** — plan estimate "~128Mi memory" was off by 30x. Actual peak: 3-replica NATS (~1.5Gi total) + 3 EventSources + 5 Sensors + controller ≈ 4Gi. Bumped 2Gi → 5Gi.

5. **`synchronization.mutex` (singular) → `synchronization.mutexes` (plural)** — Argo Workflows 3.6+ removed the singular form from the CRD schema. SSA rejected with "field not declared in schema".

6. **`imagePullSecrets` placement** — not valid at `.spec.templates[].imagePullSecrets`; must be at workflow `spec.imagePullSecrets`. Plan had it on the migrate template.

7. **clone short-SHA fetch** — `git fetch <8-char-sha>` doesn't work over wire protocol. Server-side accepts only branch/tag/full-SHA refs. Restructured clone-template to fetch by branch then `git checkout <short-sha>` from local objects. Required adding a `branch` parameter throughout the pipeline templates.

8. **Discord egress missing from CI pipeline CNP** — notify-on-failure pod inherits `ci-pipeline` label from caller pipeline's `podMetadata`, so the existing vault-snapshot Discord rule didn't apply. Added discord.com to the ci-pipeline CNP, then later replaced enumerated egress with `toEntities: world` on 443 (Note #12).

9. **emptyDir is per-pod, not per-workflow** — plan said "steps share an emptyDir at /workspace". This is wrong at the Kubernetes level: each step is a separate pod, each gets its own empty mount. Clone wrote to its workspace fine, lint saw "No package.json" because its workspace was empty. Fix: `volumeClaimTemplates` (Longhorn RWO PVC per workflow run); Argo pins all step pods to the same node so RWO works.

10. **argo-workflows ResourceQuota too small for 4-way parallel test phase** — plan didn't account for argoexec sidecar overhead (~512Mi per pod). lint+type-check+test-unit+test-e2e (now 3-way after deferring e2e) needed ~6Gi. Bumped 4Gi → 10Gi.

11. **test-e2e (Playwright) was half-specified** — the template image has no bun, the portfolio playwright.config.ts requires `out/` (built artifact), and the DAG didn't depend on build before e2e. Deferred to a follow-up tracked in `docs/todo/deferred.md` "Portfolio Pipeline E2E Step".

12. **Enumerated CNP allow-list doesn't scale to CI workloads** — bun install hits npm + jsr.io, BuildKit pulls Docker Hub + its CDN, invoicetron Dockerfile uses apt-get via deb.debian.org, deploy-image apk add hits dl-cdn.alpinelinux.org, kustomize tarball comes from objects.githubusercontent.com. Every dependency needed another CNP edit + push. Switched to `toEntities: world` on 443/TCP only (other ports stay tight), with rationale in the CNP file. This is the standard pattern for trusted CI workloads.

13. **fsGroup=1000 needed on workflow pod for PVC writes** — Longhorn RWO mounts as root:root 0755 by default. clone runs as root and writes the repo, but lint/test/build run as UID 1000 (oven/bun:*-alpine) and hit `EACCES: Permission denied: could not create the "node_modules" directory`. Adding `securityContext.fsGroup: 1000` + `fsGroupChangePolicy: OnRootMismatch` at workflow spec level chowns the mount on first attach.

14. **Verify URL hostnames invented from plan, not verified against HTTPRoutes** — used `portfolio-dev.k8s.rommelporras.com` (dash) instead of `portfolio.dev.k8s.rommelporras.com` (dot). Six URLs wrong (3 portfolio verify, 1 staging, 2 invoicetron verify, 1 NEXT_PUBLIC_APP_URL). Fixed by curling each HTTPRoute and using actual hostnames.

15. **verify-health needs `-L` for apps with auth redirects** — Invoicetron returns 307 on `/` (redirect to `/login`). Without `-L` curl reports 307 as the http_code, the verify loop never sees the configured `expected_status: 200`, and the pipeline fails even though the app is healthy. Added `-L` to make verify-health robust for any future app with redirects.

16. **Parallel `bun install` on the same RWO workspace crashes Bun** — with `lint`, `type-check`, `test-unit` each running `bun install --frozen-lockfile` against the shared Longhorn PVC, three pods race on `node_modules/*` writes. Bun 1.2.15 segfaults in the post-install pass (observed deterministically in smoke6: lint and test-unit SIGILL after "Resolved, downloaded and extracted [N]", type-check happened to finish first and survived). Fix: new `install-deps` WorkflowTemplate runs install exactly once, between clone and the parallel layer; lint/type-check/test-unit drop the `bun install &&` prefix and just `bun run <script>` against the pre-populated workspace. Invoicetron's `bunx prisma generate` folded into `install-deps.extra_command` for the same race-safety reason.

17. **Bun 1.2.15 + Vitest + JSDOM is broken** — running JSDOM-based component tests under bun crashes every vitest worker with `TypeError: The "context" argument must be of type object. Received type symbol (Symbol(vm_context_no_contextify))` from `jsdom/lib/jsdom/browser/Window.js:57:17`. Bun's `vm.createContext` returns a sentinel Symbol that JSDOM's Window ctor unconditionally treats as a real context. Already documented for invoicetron as "Vitest SSR is unreliable on bun"; portfolio has the same JSDOM tests and needed the same workaround. Fix: portfolio test-unit now runs on `node:22-slim`, matching invoicetron.

18. **Bun install memory footprint is non-deterministic** — smoke7 `install-deps` peaked at ~810 MiB RSS and finished cleanly, smoke8 OOMKilled against the exact same lockfile at a 1 GiB limit. Bun's post-install (native-module extract + lockfile write) varies with cache warmth and parallel-extract scheduling. Fix: bump `install-deps` limit to 2 GiB. Namespace quota (10 GiB) has plenty of room and `install-deps` runs alone in its DAG phase, so the burst doesn't compete with the parallel layer.

19. **`npm install -g` on `node:22-slim` hits EACCES under non-root** — the template runs as UID 1000 (`node` user) with `runAsNonRoot: true`, but `/usr/local/lib/node_modules` is root-owned. `npm install -g bun` to bootstrap bun on node:22-slim fails with `EACCES: mkdir '/usr/local/lib/node_modules/bun'`. Fix: redirect npm prefix to a writable tmpfs path:
    ```
    npm install --prefix /tmp/npm-global -g bun && /tmp/npm-global/bin/bun run test:unit
    ```
    Applies to both portfolio and invoicetron test-unit (invoicetron's command was latent-broken — the previous build-time command had `bun install --frozen-lockfile` between `-g bun` and `run test:unit`, but neither of those can write to `/usr/local/lib/node_modules/bun` anyway).

20. **Baseline PSS prohibits `seccompProfile: Unconfined`** — the plan claimed baseline would accept the override. It does not; baseline explicitly rejects that value. BuildKit rootless NEEDS Unconfined for CLONE_NEWUSER + unshare syscalls (RuntimeDefault blocks a subset even with `--oci-worker-no-process-sandbox`; localhost profile would work but requires per-node files we haven't shipped). Fix: change `argo-workflows` namespace label `pod-security.kubernetes.io/enforce: baseline` → `privileged`, keep `warn: restricted` so drift in other templates stays visible. Only `build-image` actually uses the extra headroom; every other CI step keeps a baseline-compatible securityContext. Documented as a new entry in `docs/context/Security.md` → "Privileged Justifications".

21. **BuildKit rootless needs `allowPrivilegeEscalation: true`** — rootlesskit execs setuid-root `newuidmap`/`newgidmap` to build its user-namespace UID/GID map. `allowPrivilegeEscalation: false` sets `NO_NEW_PRIVS` and blocks setuid elevation, failing with `fork/exec /usr/bin/newuidmap: operation not permitted`. Upstream BuildKit k8s examples leave this at default (true) for this reason. Fix: explicit `allowPrivilegeEscalation: true` on the build-image container.

22. **BuildKit rootless breaks with `capabilities: drop: [ALL]`** — after fixing #21, next error was the same operation-not-permitted: dropping all caps clears the bounding set, so `P'(permitted) = F(permitted) & P(bounding) = 0` even on setuid-root exec. newuidmap ends up without SETUID/SETGID in its permitted set and can't call `setresuid()`. Upstream BuildKit's k8s example omits the capabilities block entirely. Fix: remove the drop. If a future hardening pass wants to drop, the minimum set BuildKit needs is SETUID + SETGID, plus SYS_ADMIN added back for mount-namespace ops (see #23).

23. **BuildKit rootless needs `CAP_SYS_ADMIN` for `mount --make-rprivate /`** — after #21 and #22 unblocked the setuid path, rootlesskit child failed with `failed to share mount point: /: permission denied`. CAP_SYS_ADMIN isn't in containerd's default non-privileged cap set; must be explicitly added. PSS=privileged accepts it. In-container SYS_ADMIN is scoped to the pod's user namespace — it can change the pod's own mount namespace but doesn't reach the host.

24. **Ubuntu 24.04's default AppArmor profile blocks container mounts** — after #23, still `permission denied` on `mount --make-rprivate /`. The `runtime/default` AppArmor profile blocks `mount()` syscalls. Fix: annotate the build container with `appArmorProfile.type: Unconfined` (Kubernetes v1.30+ native field; replaces the old `container.apparmor.security.beta.kubernetes.io/<container>` annotation).

25. **Argo Workflows controller caches WorkflowTemplate specs** — editing a WorkflowTemplate doesn't immediately propagate to newly-created Workflows. `workflowTemplateRef` freezes spec at Workflow creation time, but the controller's *in-memory cache* of WorkflowTemplate specs was stale after my first `kubectl apply` (client-side with managed-field conflict). Visible when `status.storedTemplates[].container.securityContext` on a new Workflow didn't match the template. Fix: use `kubectl apply --server-side --force-conflicts` to cleanly overwrite ArgoCD-owned fields, then restart the controller deployment if the freeze still looks stale.

26. **ArgoCD `syncPolicy.automated` cannot be paused via in-cluster patch** — `kubectl patch app argo-workflows-manifests --type=merge -p '{"spec":{"syncPolicy":{"automated":null}}}'` takes effect for 1-3 minutes, then the `argocd-manifests` Application re-syncs and overwrites it from `manifests/argocd/apps/argo-workflows-manifests.yaml` in git. Selfheal is driven by the declared Application spec in git; there is no in-cluster pause that survives a reconcile. Options: (a) one commit to remove the `automated` block in git, iterate, revert with another commit (cost: 2 commits per pause window); (b) live with self-heal reverting experimental changes every few minutes during iteration; (c) use `podSpecPatch` on individual Workflows to override pod spec without editing any WorkflowTemplate (the approach used for securityContext iteration in this session — see #27).

27. **`podSpecPatch` is the right escape hatch for BuildKit iteration** — Argo Workflows' `spec.podSpecPatch` on a Workflow overrides the pod spec of any step without touching the WorkflowTemplate. Used to iterate on `capabilities.add: [SYS_ADMIN]` and `appArmorProfile` without racing ArgoCD's self-heal. Works cleanly because `podSpecPatch` is applied after the stored-template materialization. The syntax is a YAML document matching a subset of PodSpec; use the `containers[].name: main` key to target the step container.

28. **BuildKit rootless gets 403 on GitLab registry despite valid PAT** — unresolved upstream issue. Portfolio build runs the Dockerfile cleanly end-to-end (Next.js compiled, layers exported), then fails on `HEAD /v2/<repo>/blobs/<sha>: 403 Forbidden`. In-cluster diagnostics prove the credential is fine:
    - `tags/list` with the bearer token: **200**, 11 existing tags returned.
    - `HEAD /blobs/<real-sha>` with the bearer token: **200**.
    - `POST /blobs/uploads/` with the bearer token: **202 Accepted**.
    - `skopeo copy docker://alpine:3.21 docker://registry.k8s.rommelporras.com/0xwsh/portfolio:skopeo-test` using the same `gitlab-registry` Secret: exit 0.
    BuildKit's auth implementation is demonstrably going sideways against this GitLab registry — probably a scope-request bug in BuildKit v0.29.0's containerd registry client — but chasing it would be multi-hour and the project's CI doesn't need it to ship. Decision: **pivot the push path to skopeo**. See "Architectural Guidance: BuildKit vs skopeo" at the end of this section.

### Manual prerequisites uncovered

- **GitLab admin setting** `allow_local_requests_from_web_hooks_and_services` defaults to `false` and rejects internal-IP webhook URLs with `422 Invalid url given`. Required `glab api --method PUT application/settings --field allow_local_requests_from_web_hooks_and_services=true` before EventSource auto-registration would succeed. Worth a CLAUDE.md gotcha for future webhook-driven services.

### What the plan would have caught earlier

- Per-template `kubectl-admin create` smoke tests (5.9.1.8.8) were skipped in favor of full-pipeline runs. Would have surfaced the mutexes/imagePullSecrets schema bugs and the clone short-SHA bug independently of pipeline integration. Lesson: do not skip incremental verification, even when the templates "look right".

- The plan's "shared emptyDir" assumption for cross-step workspace was an architectural gap. Would have been caught by a one-step manual workflow (clone + ls) before writing the full DAG. Lesson: validate shared-state assumptions against actual k8s primitive behavior, not against developer intuition.

- Live-curling verify URLs before writing them into the template would have caught all 6 URL typos + the redirect-follow requirement. Lesson: probe the live cluster, never invent values from the plan document.

- The `emptyDir` → `volumeClaimTemplates` lesson (Note #9) and the parallel-install race lesson (Note #16) share the same root cause: shared-state assumptions across step pods were never validated. A one-step "write X, then separate pod reads X" smoke would have caught both. Lesson: for any pipeline that shares state between steps, treat the sharing mechanism as the first thing to validate, not the last.

- The BuildKit securityContext saga (Notes #20–#24) could have been a single-commit fix if the plan had verified upstream BuildKit's k8s example *before* writing the template. Lesson: when adopting a project's rootless/privileged pattern, copy the upstream-documented spec verbatim first, then scope-reduce. Don't invent the spec from security principles.

---

## Architectural Guidance (for future Argo Workflows CI/CD)

These are patterns this cluster should use going forward. Every one was earned from a smoke-test failure in this phase.

### Pipeline DAG skeleton (both projects)

```
clone -> install-deps -+- lint ----+- build (BuildKit, OCI archive) -> push (skopeo) -> deploy -> verify
                       +- type-check
                       +- test-unit
                           (parallel)
```

- **Never install dependencies inside parallel steps that share an RWO workspace.** Install once, in its own step, between clone and the fan-out. Parallel steps then do read-only `<runner> run <script>`.
- **Never assume `emptyDir` is cross-pod.** Each step is its own pod; Argo pins them to one node for a reason. Use `volumeClaimTemplates` with a per-workflow RWO PVC (Longhorn in this cluster) when steps need to share files.
- **Always set `securityContext.fsGroup` at workflow level** when mixing root + non-root steps against the shared PVC. `fsGroupChangePolicy: OnRootMismatch` keeps remount cost low for large workspaces.

### Build + push: build with BuildKit, push with skopeo

Do not try to make BuildKit push to this cluster's GitLab registry; it has a demonstrated 403 issue against the self-hosted GitLab JWT flow in BuildKit v0.29.0.

- **Build step** — image `moby/buildkit:vX.Y-rootless`, `buildctl-daemonless.sh build ... --output type=oci,dest=/workspace/image.tar` (no push). Everything inside a BuildKit pod stays local; registry is not touched.
- **Push step** — image `quay.io/skopeo/stable:vX.Y`, `skopeo copy --authfile /docker/config.json oci-archive:/workspace/image.tar docker://<registry>/<repo>:<tag>`. skopeo's registry client handles GitLab's JWT auth correctly.
- **Registry caching** — lose BuildKit's `--export-cache type=inline` / `--import-cache type=registry,ref=...:buildcache`. For a homelab CI that builds one app per commit, cold Dockerfile builds complete in ~25s (portfolio) and cache gives at best a 10s speedup on no-op changes. Accept the cost; revisit if build wall-time becomes a real problem.
- **Workspace PVC sizing** — OCI archives for Node.js apps are ~200 MB. Keep the 2Gi workspace PVC headroom; no change needed.

### BuildKit rootless securityContext on this cluster — the exact working spec

When adding a new CI pipeline that needs BuildKit, copy this block verbatim:

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 1000
  runAsGroup: 1000
  allowPrivilegeEscalation: true     # Note #21 — setuid newuidmap needs this
  seccompProfile:
    type: Unconfined                  # Note #20 — CLONE_NEWUSER/unshare need this
  appArmorProfile:
    type: Unconfined                  # Note #24 — Ubuntu 24.04 AppArmor blocks mount()
  capabilities:
    add: ["SYS_ADMIN"]                # Note #23 — mount --make-rprivate /
  # Deliberately no `drop: [ALL]` — clearing the bounding set blocks setuid
  # exec (Note #22). If scoping caps later, keep at least SETUID/SETGID.
env:
  - name: BUILDKITD_FLAGS
    value: --oci-worker-no-process-sandbox
  - name: DOCKER_CONFIG
    value: /home/user/.docker
```

The namespace hosting this pod must have `pod-security.kubernetes.io/enforce: privileged` (Note #20). Document the exception in `docs/context/Security.md`.

### Namespace PSS strategy for CI namespaces

- **CI pipelines that run BuildKit → namespace PSS `enforce: privileged`, `warn: restricted`.** Only the build step uses the relaxation; every other step keeps a baseline-compatible spec voluntarily. Document in `docs/context/Security.md` → "Privileged Justifications".
- **CI pipelines that don't run BuildKit** (e.g., only run tests, skopeo mirroring, kustomize commits) → keep the namespace at baseline. Nothing those workloads do needs more.
- **Future tightening path**: ship a localhost seccomp profile allowing `unshare`/`clone3` with CLONE_NEWUSER to every node, then flip the CI namespace back to baseline. Not in scope for this phase.

### Argo Workflows template iteration without commits

When iterating on a WorkflowTemplate's spec during debugging:

1. **Don't fight ArgoCD's self-heal.** The `argocd-manifests` app will reconcile the `syncPolicy.automated` block back from git within minutes. A `kubectl patch` on the Application doesn't survive.
2. **Use `spec.podSpecPatch` on the Workflow.** It overrides pod specs at materialization time, no WorkflowTemplate edit needed. Good for securityContext, resources, env, volumes-on-main-container.
3. **If you MUST edit a WorkflowTemplate spec live**: `kubectl apply --server-side --force-conflicts -f <template>.yaml`, submit a Workflow immediately (it freezes the spec at creation), and accept that ArgoCD will revert the live template within minutes. `status.storedTemplates[]` on the Workflow is the authoritative record of what the pods used.
4. **When template spec changes don't seem to propagate to new Workflows**: `kubectl rollout restart deployment/argo-workflows-workflow-controller -n argo-workflows` — the controller caches WorkflowTemplate specs in memory.

### CiliumNetworkPolicy for CI namespaces

Enumerated allow-lists don't scale for CI workloads (Note #12). Every new tool introduces 2-3 new domains. For CI namespaces, use:

- `toEntities: world` on 443/TCP (HTTPS to anything — trusted egress for package managers, registries, build caches)
- Keep everything else (53/UDP DNS, 22/TCP SSH for deploy, inter-namespace NATS/Redis/etc.) explicit
- Default-deny on all other egress

The 443/world rule is the common trusted-CI shape; lock it down when CI runs un-reviewed user code (not the case here — all Dockerfiles come from private GitLab repos the user owns).

### GitLab registry credentials for Kubernetes CI

- **Scopes**: Personal Access Token with `read_registry, write_registry` (no `api`). Group/project deploy tokens are not available on this GitLab edition.
- **PAT owner**: must have Developer role or higher on every registry project the pipeline targets (source of truth for actual authorization; PAT scope is necessary but not sufficient).
- **Username field** in the `auths` map: GitLab accepts any non-empty username when the PAT is valid. Convention: the GitLab username of the PAT owner.
- **Format**: ExternalSecret template should emit `.dockerconfigjson` with `auths["<registry-host>"]` holding `username`, `password`, `auth`. skopeo and BuildKit both read this; if switching push to skopeo, the same Secret keeps working.

### Pre-flight checklist for the next CI pipeline

For any new Argo Workflows CI pipeline (new project, new promotion flow, etc.):

- [ ] Namespace has correct PSS label for the build engine (`privileged` if BuildKit, otherwise `baseline`).
- [ ] ResourceQuota allows for peak parallel phase + build peak (portfolio peak: ~5 GiB total during parallel phase; budget ≥ 2x that).
- [ ] `gitlab-registry` Secret ExternalSecret rendered and verified with a skopeo copy smoke test BEFORE wiring the build step.
- [ ] `github-deploy-key` Secret has **write** access to `rommelporras/homelab`.
- [ ] Overlay exists at `manifests/<project>/overlays/<env>/kustomization.yaml` with `images:` entry matching the pipeline's `image_name` parameter.
- [ ] verify-health URL tested with live `curl -L` against the HTTPRoute before committing.
- [ ] CiliumNetworkPolicy for the CI namespace allows `world:443/TCP`, `github.com:22/TCP`, and whatever in-cluster services the build/migrate steps need.
- [ ] At least one per-template `kubectl-admin create workflow --from workflowtemplate/<name>` test before wiring into a full pipeline DAG.

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

### Stage 1 (v0.39.1) - VERIFIED 2026-04-16
- [x] 5 new ArgoCD Applications visible, `syncPolicy.automated: { prune: true, selfHeal: true }`, Synced + Healthy
- [x] Kustomize overlays produce correct output (`kubectl-admin kustomize`)
- [x] Live images unchanged vs pre-migration snapshot (no unintended drift)
- [x] GitLab CI deploy jobs all `when: manual`; no auto-deploy churn visible in ArgoCD events
- [x] CLAUDE.md gotcha "Invoicetron manifest has CI/CD-managed image" removed
- [x] selfHeal tested: manual GitLab CI deploy reverted by ArgoCD within 3 min
- [x] GitLab Runner OOM fix: concurrent=4 + pod anti-affinity (bonus fix, shipped with v0.39.1)
- [x] ArgoCD controller memory bumped 1Gi→2Gi (bonus fix, shipped with v0.39.1)

### Stage 2 (v0.39.2) - Status as of 2026-04-19

- [x] `argo-events` namespace + controllers Running, PSS baseline labeled
- [x] Per-project EventSources auto-registered webhooks on GitLab (after manual `allow_local_requests_from_web_hooks_and_services=true`)
- [x] All shared WorkflowTemplates deployed
- [ ] All shared WorkflowTemplates **individually tested** — skipped, smoke-tested via full pipeline only (build + deploy templates still unproven)
- [x] `notify-on-failure` extracted; vault-snapshot delegates via templateRef
- [x] Cross-namespace RBAC: `argo-events-sa` can create Workflows in `argo-workflows` (verified by Sensor pod startup logs)
- [x] Controller `--namespaced` confirmed (no separate `--managed-namespace` flag needed for single-ns install)
- [x] Discord notification reaches #incidents on workflow failure (verified during smoke2)
- [ ] Webhook secret validation works (untested — would need a forged POST without the X-Gitlab-Token)
- [ ] Per-project secret isolation (untested — implicit from per-EventSource secrets)
- [ ] Portfolio develop push → Workflow → all steps pass → ArgoCD sync → dev pod updated
- [ ] Portfolio main push → same, prod target
- [ ] Portfolio staging promotion via manual GitLab job works
- [ ] Invoicetron develop push → pipeline with prisma migration → ArgoCD sync → dev pod updated, correct NEXT_PUBLIC_APP_URL baked in
- [ ] Invoicetron main push → same for prod
- [ ] Deploy mutex serializes concurrent runs
- [ ] Rebase retry loop works
- [x] Workflow TTL applied per template (1d success / 7d failure) — actual cleanup not yet observed (need 24h elapsed)
- [x] VAP allows mcr.microsoft.com/ (Playwright) — image not actually pulled since e2e is deferred
- [ ] CI alerts fire on induced failure (alerts deployed, not yet exercised end-to-end)
- [x] Grafana dashboard deployed (panels mostly empty until first runs land)

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

**Stage 1 (v0.39.1) - SHIPPED 2026-04-16:**
- [x] `/audit-security` → `/commit` for Kustomize restructure + new ArgoCD Applications
- [x] `/audit-docs` → `/commit` for context doc updates
- [x] `/ship v0.39.1 "ArgoCD Onboarding for Portfolio and Invoicetron"`

**Stage 2 (v0.39.2) - in progress:**
- [x] `/audit-security` → `/commit` (commit `2bcce8d`, 49 files)
- [x] `/audit-docs` → `/commit` (commit `6f21676`, 10 files)
- [x] Plus 12 follow-up fix commits during smoke testing (`bae726d` through `4ff2c42`) — see Stage 2 Execution Notes for the per-commit breakdown
- [ ] Portfolio smoke test (build + deploy + verify) passes end-to-end — **next milestone**
- [ ] Real webhook trigger from `portfolio/develop` push
- [ ] Invoicetron smoke test passes end-to-end
- [ ] Real webhook trigger from `invoicetron/develop` push
- [ ] Remove `deploy:*` jobs from both projects' `.gitlab-ci.yml` after 3 days stable
- [ ] Archive `kube-token-*` Vault entries
- [ ] Update CLAUDE.md with new gotchas distilled from Stage 2 Execution Notes
- [ ] `/ship v0.39.2 "Argo Events CI/CD Migration"`
- [ ] `git mv docs/todo/phase-5.9.1-cicd-pipeline-migration.md docs/todo/completed/`
