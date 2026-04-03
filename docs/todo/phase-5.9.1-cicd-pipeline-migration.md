# Phase 5.9.1: CI/CD Pipeline Migration (Argo Events + Workflows)

> **Status:** Planned
> **Target:** v0.39.1
> **Prerequisite:** Phase 5.9 (v0.39.0 - Argo Workflows installed, controller running)
> **DevOps Topics:** Event-driven CI/CD, GitOps image promotion, BuildKit, webhook triggers
> **CKA Topics:** CRD-based automation, RBAC, cross-namespace access, Kustomize overlays

> **Purpose:** Replace GitLab CI deploy pipelines for Invoicetron and Portfolio with
> Argo Events (triggers) + Argo Workflows (execution) + ArgoCD (deploy). GitLab remains
> as source code host and container registry. Eliminates imperative `kubectl set image`
> that conflicts with ArgoCD selfHeal.
>
> **Learning Goal:** Event-driven architecture (Argo Events), BuildKit rootless image
> builds in k8s, GitOps-native deploy (commit image tag to Git, ArgoCD syncs),
> reusable WorkflowTemplates, and Kustomize overlay patterns for multi-env deployments.

---

## Problem

Invoicetron and Portfolio CI/CD pipelines run on GitLab CI with `kubectl set image`
(imperative deploy). ArgoCD selfHeal would revert these changes. These are the only
two services not managed by ArgoCD.

Additionally, Invoicetron has a manifest bug: one `deployment.yaml` shared across
dev/prod causes environment contamination when applied directly.

## Solution

Replace GitLab CI pipelines with Argo Events (triggers) + Argo Workflows (execution)
+ ArgoCD (deploy). GitLab remains as source code host and container registry.

## Architecture

```
GitLab (source + registry)
    |
    | webhook (push event)
    v
Argo Events (EventSource + Sensor)       [argo-events namespace]
    |
    | creates Workflow
    v
Argo Workflows (WorkflowTemplate)        [argo-workflows namespace]
    |
    +-- validate (lint, type-check, test)  -- parallel steps
    |
    +-- build (BuildKit rootless -> push to GitLab registry)
    |
    +-- deploy (commit image tag to homelab repo -> ArgoCD syncs)
    |
    +-- verify (health check)
```

### Event Flow

1. Developer pushes to GitLab (`develop` or `main` branch)
2. GitLab fires webhook POST to `argo-events.k8s.rommelporras.com/gitlab`
3. EventSource (webhook type) receives the payload
4. Sensor evaluates filters:
   - Push event? (not MR, tag, etc.)
   - Branch is `develop` or `main`?
   - Which repo? (portfolio or invoicetron)
5. Sensor creates a Workflow from the matching WorkflowTemplate with parameters:
   - `commit_sha` (short)
   - `branch`
   - `repo_url`
   - `project_name`

### Components

**EventSource** - one shared webhook endpoint for both projects:
- Webhook type, port 12000, endpoint `/gitlab`
- Namespace: `argo-events`
- Exposed via HTTPRoute: `argo-events.k8s.rommelporras.com`

**Sensors** - one per project:
- `sensor-portfolio.yaml` - filters by `body.project.name == "portfolio"`
- `sensor-invoicetron.yaml` - filters by `body.project.name == "invoicetron"`
- Each filters by branch (`refs/heads/develop`, `refs/heads/main`)
- Maps to the right WorkflowTemplate with environment-specific parameters

**GitLab webhook secret** - validates payload authenticity, stored in Vault.

---

## Build Engine: BuildKit Rootless

Replaces Docker-in-Docker (DinD) from GitLab CI. BuildKit is the engine that
`docker buildx` uses under the hood - running it directly eliminates the Docker
daemon. Kaniko (the previous go-to) was archived June 2025 with no successor.

| Aspect | Current (GitLab CI + DinD) | New (Argo Workflows + BuildKit) |
|--------|--------------------------|--------------------------------|
| Trigger | GitLab webhook -> Runner | GitLab webhook -> Argo Events -> Workflow |
| Build engine | Docker daemon (DinD) | BuildKit (no daemon) |
| Privilege | Privileged container | Rootless (UID 1000) |
| Image | docker:27.4.1-dind | moby/buildkit:rootless |
| Build command | docker buildx build | buildctl build |
| Cache | Registry cache | Same registry cache (compatible) |
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
                                        on-exit: discord-notify
```

### Invoicetron

```
                +--- lint --------+
clone --------+ +--- type-check --+---> build ---> migrate ---> deploy ---> verify
                +--- test:unit ---+       |
                    (parallel)     env-specific build
                                  (NEXT_PUBLIC_APP_URL)
                                        on-exit: discord-notify
```

### Step Details

| Step | Image | What it does | Shared? |
|------|-------|-------------|---------|
| clone | alpine/git:2.47.2 | Clones repo from GitLab into shared volume | Yes |
| lint | oven/bun:1.2-alpine | `bun run lint` | Yes (template) |
| type-check | oven/bun:1.2-alpine | `bun run type-check` (+ prisma generate for Invoicetron) | Parameterized |
| test:unit | oven/bun:1.2-alpine | `bun run test:unit` (Invoicetron uses node:22-slim) | Per-project |
| test:e2e | mcr.microsoft.com/playwright:v1.52.0 | Smoke tests (Portfolio only, requires VAP exception) | Portfolio only |
| build | moby/buildkit:v0.21.1-rootless | `buildctl build` + push to GitLab registry | Yes (template) |
| migrate | App image (just built) | `bunx prisma migrate deploy` | Invoicetron only |
| deploy | alpine/git:2.47.2 | Updates image tag in homelab repo, ArgoCD syncs | Yes (template) |
| verify | curlimages/curl:8.12.1 | Health check HTTP probe | Yes (template) |
| discord-notify | curlimages/curl:8.12.1 | Exit handler, reuses notify-on-failure from Phase 5.9 | Yes (template) |

### Shared Volume

Steps within a workflow share data via an `emptyDir` volume at `/workspace`.
The `clone` step checks out source code, subsequent steps read from it.

### Branch to Environment Mapping

| Project | Branch | Build | Deploy to | ArgoCD App |
|---------|--------|-------|-----------|------------|
| Portfolio | develop | Single image | portfolio-dev | portfolio-dev |
| Portfolio | develop (manual `kubectl create workflow`) | Same image | portfolio-staging | portfolio-staging |
| Portfolio | main | Single image | portfolio-prod | portfolio-prod |
| Invoicetron | develop | Image with dev URL | invoicetron-dev | invoicetron-dev |
| Invoicetron | main | Image with prod URL | invoicetron-prod | invoicetron-prod |

---

## Deploy Strategy: Git-based Image Updates

**Current (imperative):** `kubectl set image` directly mutates the Deployment.

**New (GitOps-native):** Build step commits the new image tag to the homelab repo.
ArgoCD detects the change and syncs.

### Flow

1. Build step pushes image to GitLab registry
2. Deploy step updates the image tag in the homelab repo manifest
3. Deploy step commits + pushes to homelab repo (GitHub)
4. ArgoCD detects the commit, syncs the Deployment, pod rolls out

### Invoicetron Kustomize Overlays

Fixes the shared deployment.yaml bug by splitting into base + overlays:

```
manifests/invoicetron/
  base/
    deployment.yaml          # shared spec (ports, probes, resources, securityContext)
    service.yaml
    postgresql.yaml
  overlays/
    dev/
      kustomization.yaml     # patches image to .../dev:<sha>
    prod/
      kustomization.yaml     # patches image to .../prod:<sha>
```

ArgoCD Applications point at overlays:
- `invoicetron-dev` Application -> `manifests/invoicetron/overlays/dev/`
- `invoicetron-prod` Application -> `manifests/invoicetron/overlays/prod/`

The deploy workflow step modifies only the overlay's `kustomization.yaml`
(image transformer), not the base Deployment.

### Portfolio

Single image across all envs. Deploy step updates the image tag directly in
`manifests/portfolio/deployment.yaml`. No Kustomize needed.

### Git Authentication

Deploy step pushes to the homelab GitHub repo via SSH deploy key (read/write):
- Stored in Vault: `secret/argo-workflows/github-deploy-key`
- Pulled via ESO ExternalSecret
- Mounted in deploy step as SSH key

Automated commit message: `chore(ci): update <project> image to <sha>`

---

## Security

### RBAC

| ServiceAccount | Namespace | Permissions |
|---------------|-----------|-------------|
| argo-events-sa | argo-events | Create Workflows in argo-workflows |
| ci-workflow-sa | argo-workflows | Get Secrets in argo-workflows |

No cluster-admin. No cross-namespace access except Sensor -> Workflow creation.

### Secrets (Vault -> ESO)

| Secret | Vault Path | Used By |
|--------|-----------|---------|
| GitLab registry credentials | argo-workflows/gitlab-registry | build step |
| GitHub deploy key (SSH) | argo-workflows/github-deploy-key | deploy step |
| GitLab webhook token | argo-events/gitlab-webhook-secret | EventSource |
| Discord webhook | monitoring/discord-webhooks (existing) | notify step |

### CiliumNetworkPolicy

| Namespace | Ingress | Egress |
|-----------|---------|--------|
| argo-events | Gateway (webhook) | kube-apiserver (create Workflows) |
| argo-workflows | Prometheus (metrics) | GitLab registry, GitHub, kube-apiserver, GitLab (clone) |

### PSS Compliance

- BuildKit rootless: UID 1000, baseline compatible
- All workflow pods: seccompProfile RuntimeDefault, allowPrivilegeEscalation false, drop ALL
- No privileged containers, no hostNetwork, no hostPID
- VAP image-registry-policy: mcr.microsoft.com/ added for Playwright E2E tests

---

## Namespace Layout

| Namespace | What lives there |
|-----------|-----------------|
| argo-events | EventSource, Sensors, event-bus controller |
| argo-workflows | WorkflowTemplates, CronWorkflows (Phase 5.9), CI Workflows |
| portfolio-dev/staging/prod | Application pods (unchanged) |
| invoicetron-dev/prod | Application pods (unchanged) |

---

## 5.9.1.0 Pre-Installation

> **Gate:** Phase 5.9 must be complete. Argo Workflows controller running, CRDs registered.

- [ ] 5.9.1.0.1 Verify Argo Workflows controller is healthy
- [ ] 5.9.1.0.2 Verify ArgoCD Applications all Synced/Healthy
- [ ] 5.9.1.0.3 Check cluster resource headroom for Argo Events controller (~100m CPU, ~128Mi)
- [ ] 5.9.1.0.4 Verify VAP allows Playwright image (Portfolio E2E tests)
  ```bash
  kubectl-admin run test-playwright \
    --image=mcr.microsoft.com/playwright:v1.52.0 \
    --dry-run=server -n default
  # If VAP denies: add mcr.microsoft.com/ to manifests/kube-system/image-registry-policy.yaml
  ```

---

## 5.9.1.1 Wave 0: Argo Events Installation

- [ ] 5.9.1.1.1 Create namespace `argo-events` with PSS baseline + ESO label
  ```bash
  kubectl-admin create namespace argo-events
  kubectl-admin label namespace argo-events \
    pod-security.kubernetes.io/enforce=baseline \
    pod-security.kubernetes.io/warn=restricted \
    eso-enabled="true"
  ```
- [ ] 5.9.1.1.2 Create LimitRange and ResourceQuota
- [ ] 5.9.1.1.3 Create Helm values file (`helm/argo-events/values.yaml`)
  - event-bus-controller, eventsource-controller, sensor-controller
  - Disable argo-events-webhook (not needed, saves resources)
  - Non-root, seccompProfile, drop ALL
- [ ] 5.9.1.1.4 Create ArgoCD Application (`manifests/argocd/apps/argo-events.yaml`)
  - Helm chart: `argo/argo-events`
  - AppProject: `infrastructure`
- [ ] 5.9.1.1.5 Deploy and verify controllers are running
- [ ] 5.9.1.1.6 Create CiliumNetworkPolicy for argo-events namespace
- [ ] 5.9.1.1.6a Update infrastructure AppProject destinations
  ```yaml
  # manifests/argocd/appprojects.yaml - add to infrastructure project destinations:
  - namespace: argo-events
    server: https://kubernetes.default.svc
  # Note: argo-workflows destination should already be added in Phase 5.9
  ```

- [ ] 5.9.1.1.6b Create cross-namespace RBAC for Sensor -> Workflow creation
  ```yaml
  # manifests/argo-workflows/rbac/argo-events-workflow-creator.yaml
  apiVersion: rbac.authorization.k8s.io/v1
  kind: Role
  metadata:
    name: workflow-creator
    namespace: argo-workflows
  rules:
    - apiGroups: ["argoproj.io"]
      resources: ["workflows"]
      verbs: ["create", "get", "list", "watch"]
  ---
  apiVersion: rbac.authorization.k8s.io/v1
  kind: RoleBinding
  metadata:
    name: argo-events-workflow-creator
    namespace: argo-workflows
  roleRef:
    apiGroup: rbac.authorization.k8s.io
    kind: Role
    name: workflow-creator
  subjects:
    - kind: ServiceAccount
      name: argo-events-sa
      namespace: argo-events
  ```

- [ ] 5.9.1.1.7 Create ESO ExternalSecret for GitLab webhook token
  - Vault path: `argo-events/gitlab-webhook-secret`
  - Seed Vault with a generated webhook secret
- [ ] 5.9.1.1.7a Create 1Password items for Argo CI/CD secrets
  ```
  # User must create these in 1Password Kubernetes vault:
  # 1. "Argo Events" item:
  #    - gitlab-webhook-secret: generated random token
  # 2. "Argo Workflows CI/CD" item:
  #    - gitlab-registry-username: deploy token username
  #    - gitlab-registry-password: deploy token password
  #    - github-deploy-key: SSH private key (generate with ssh-keygen)
  #
  # Add public key to GitHub homelab repo as deploy key (read/write)
  ```

- [ ] 5.9.1.1.7b Update Vault seed script
  ```bash
  # scripts/vault/seed-vault-from-1password.sh - add new paths:
  # argo-events/gitlab-webhook-secret -> from "Argo Events" 1P item
  # argo-workflows/gitlab-registry -> from "Argo Workflows CI/CD" 1P item
  # argo-workflows/github-deploy-key -> from "Argo Workflows CI/CD" 1P item
  ```

- [ ] 5.9.1.1.8 Create EventSource (`manifests/argo-events/eventsource-gitlab.yaml`)
  - Webhook type, port 12000, endpoint `/gitlab`
  - Secret ref for webhook token validation
- [ ] 5.9.1.1.9 Create HTTPRoute for webhook ingress
  - `argo-events.k8s.rommelporras.com` -> EventSource Service
- [ ] 5.9.1.1.10 Create ServiceMonitor for Argo Events controllers
- [ ] 5.9.1.1.11 Create PrometheusRules (EventSourceDown, SensorDown)

---

## 5.9.1.2 Wave 1: Shared WorkflowTemplates

- [ ] 5.9.1.2.1 Create ESO ExternalSecrets in argo-workflows namespace
  - GitLab registry credentials (`argo-workflows/gitlab-registry`)
  - GitHub deploy key SSH (`argo-workflows/github-deploy-key`)
  - Seed both in Vault (generate GitHub deploy key, configure on GitHub repo)
- [ ] 5.9.1.2.2 Create shared WorkflowTemplate: `clone`
  - alpine/git image, clones repo to /workspace
  - Parameters: repo_url, branch, commit_sha
- [ ] 5.9.1.2.3 Create shared WorkflowTemplate: `lint`
  - oven/bun:1-alpine, `bun install && bun run lint`
- [ ] 5.9.1.2.4 Create shared WorkflowTemplate: `build-image`
  - moby/buildkit:rootless
  - `buildctl build` with registry cache, push to GitLab registry
  - Parameters: image_name, tag, build_args, dockerfile_path
- [ ] 5.9.1.2.5 Create shared WorkflowTemplate: `deploy-image`
  - alpine/git:2.47.2, updates image tag in homelab repo via git commit + push
  - Parameters: project, image_tag, target_file, target_field (supports both
    deployment.yaml image field and kustomization.yaml newTag field)
  - Uses GitHub deploy key from Secret mount
  - target_file must be parameterized to support future Deployment-to-Rollout
    conversions (Phase 5.10) without pipeline changes
- [ ] 5.9.1.2.6 Create shared WorkflowTemplate: `verify-health`
  - curlimages/curl, HTTP health check with retry
  - Parameters: url, expected_status
- [ ] 5.9.1.2.7 Reuse `notify-on-failure` WorkflowTemplate from Phase 5.9
  - Already created in Phase 5.9 (manifests/argo-workflows/templates/notify-on-failure.yaml)
  - CI/CD workflows reference the same template via onExit handler
  - No new template needed - just verify it exists and is deployed
- [ ] 5.9.1.2.8 Test each template individually with manual Workflow submissions
  - `kubectl-admin create -f` test workflows for clone, build, deploy
  - Verify each step completes successfully in isolation

---

## 5.9.1.3 Wave 2: Portfolio (pilot)

- [ ] 5.9.1.3.1 Verify ArgoCD Applications exist for portfolio-dev/staging/prod
  - If missing, create them pointing at `manifests/portfolio/`
- [ ] 5.9.1.3.2 Create portfolio WorkflowTemplate (DAG)
  - Entrypoint: clone -> (lint + type-check + test:unit + test:e2e parallel) -> build -> deploy -> verify
  - Parameters from Sensor: commit_sha, branch, environment
  - Exit handler: notify-discord
- [ ] 5.9.1.3.3 Create Sensor for portfolio (`manifests/argo-events/sensor-portfolio.yaml`)
  - Filter: `body.project.name == "portfolio"`
  - Branch mapping: develop -> portfolio-dev, main -> portfolio-prod
  - Creates Workflow from portfolio WorkflowTemplate with parameters
- [ ] 5.9.1.3.4 Configure GitLab webhook on portfolio project
  - URL: `https://argo-events.k8s.rommelporras.com/gitlab`
  - Secret token: from Vault
  - Events: Push events only
- [ ] 5.9.1.3.5 Test: push to develop branch
  - Verify: webhook received -> Workflow created -> all steps pass -> image pushed -> git commit -> ArgoCD syncs -> pod rolls out
- [ ] 5.9.1.3.6 Test: push to main branch (prod deploy)
- [ ] 5.9.1.3.7 Test: manual staging deploy via `kubectl create workflow`
- [ ] 5.9.1.3.8 Disable deploy stages in portfolio `.gitlab-ci.yml`
  - Keep validate/test/build stages as comments for rollback reference
  - Or add `when: manual` to all deploy jobs as a dormant fallback

---

## 5.9.1.4 Wave 3: Invoicetron

- [ ] 5.9.1.4.1 Restructure `manifests/invoicetron/` into Kustomize base + overlays
  - Move shared resources to `base/` (deployment, service, postgresql)
  - Create `overlays/dev/kustomization.yaml` with dev image
  - Create `overlays/prod/kustomization.yaml` with prod image
  - Move per-env resources (limitrange, resourcequota, namespace, networkpolicy, externalsecret) into overlays
- [ ] 5.9.1.4.2 Create ArgoCD Applications pointing at overlays
  - `invoicetron-dev` -> `manifests/invoicetron/overlays/dev/`
  - `invoicetron-prod` -> `manifests/invoicetron/overlays/prod/`
  - Replace existing invoicetron ArgoCD app (if any) or create new ones
- [ ] 5.9.1.4.3 Verify Kustomize overlays produce correct output
  - `kubectl-admin kustomize manifests/invoicetron/overlays/dev/`
  - `kubectl-admin kustomize manifests/invoicetron/overlays/prod/`
  - Verify image paths are environment-specific
- [ ] 5.9.1.4.4 Create invoicetron WorkflowTemplate (DAG)
  - Adds: prisma migrate step after build, env-specific build args (NEXT_PUBLIC_APP_URL)
  - Invoicetron test:unit uses node:22-slim (Vitest SSR compatibility)
  - No test:e2e (Invoicetron has no E2E tests)
- [ ] 5.9.1.4.5 Create Sensor for invoicetron (`manifests/argo-events/sensor-invoicetron.yaml`)
  - Filter: `body.project.name == "invoicetron"`
  - Branch mapping: develop -> invoicetron-dev, main -> invoicetron-prod
  - Per-env build args passed as parameters
- [ ] 5.9.1.4.6 Configure GitLab webhook on invoicetron project
- [ ] 5.9.1.4.7 Test: push to develop branch
  - Verify: full pipeline with Prisma migration
  - Verify: dev image has correct NEXT_PUBLIC_APP_URL baked in
- [ ] 5.9.1.4.8 Test: push to main branch (prod deploy with migration)
- [ ] 5.9.1.4.9 Disable deploy stages in invoicetron `.gitlab-ci.yml`

---

## 5.9.1.5 Wave 4: Monitoring + Cleanup

- [ ] 5.9.1.5.1 Create Grafana dashboard for CI/CD pipelines
  - Row 1: Pod Status (Argo Events + Workflows controllers)
  - Row 2: Pipeline Execution (success/failure rates, duration)
  - Row 3: Build Metrics (BuildKit build duration, image sizes)
  - Row 4: Webhook Events (received, filtered, triggered)
  - Row 5: Resource Usage (CPU/Memory with dashed request/limit lines)
  - Descriptions on every panel and row
  - ConfigMap with grafana_dashboard: "1" label, grafana_folder: "Homelab" annotation
- [ ] 5.9.1.5.2 Create PrometheusRules for CI/CD
  - CIPipelineFailed (workflow status Failed, 5m)
  - CIBuildStuck (workflow running > 15m)
  - WebhookDeliveryFailed (EventSource errors)
  - CIPipelineNoActivity (no workflows created in 7d, info)
- [ ] 5.9.1.5.3 Update context docs
  - Architecture.md: add Argo Events + CI/CD flow
  - Conventions.md: update deploy workflow section
  - Secrets.md: add new Vault paths
  - Monitoring.md: add CI/CD alerts and dashboard
  - ExternalServices.md: update GitLab section (webhook config)
- [ ] 5.9.1.5.4 Update CLAUDE.md
  - Add Argo Events to architecture section
  - Remove invoicetron deployment.yaml gotcha (fixed by Kustomize overlays)
  - Update "Still on Helm" if applicable
- [ ] 5.9.1.5.5 Remove invoicetron CI/CD deferred item from `docs/todo/deferred.md`

---

## What Changes Per Repo

| Repo | Changes |
|------|---------|
| homelab | New manifests (argo-events/, argo-workflows/templates), Kustomize overlays for invoicetron, new ArgoCD Applications, monitoring |
| portfolio (GitLab) | Webhook configured, .gitlab-ci.yml deploy stages disabled |
| invoicetron (GitLab) | Webhook configured, .gitlab-ci.yml deploy stages disabled |

## What Does NOT Change

- GitLab stays as source code host + container registry
- GitLab Runner stays deployed (dormant fallback)
- Application manifests (Services, NetworkPolicies, ExternalSecrets) unchanged
- Existing ArgoCD Applications for non-CI/CD services unchanged
- Existing CronWorkflows from Phase 5.9 unchanged

---

## Verification Checklist

**Argo Events:**
- [ ] `argo-events` namespace with PSS baseline label
- [ ] EventSource receiving webhooks from GitLab
- [ ] Sensors filtering and creating Workflows
- [ ] CiliumNetworkPolicy applied

**Shared Templates:**
- [ ] All 6 WorkflowTemplates deployed and tested individually (notify-on-failure reused from Phase 5.9)
- [ ] ESO ExternalSecrets synced (GitLab registry, GitHub deploy key)
- [ ] Cross-namespace RBAC: argo-events-sa can create Workflows in argo-workflows
- [ ] 1Password items created and Vault seed script updated
- [ ] VAP updated to allow mcr.microsoft.com/ images (if Playwright approach kept)

**Portfolio:**
- [ ] Push to develop -> full pipeline -> ArgoCD sync -> dev pod updated
- [ ] Push to main -> full pipeline -> ArgoCD sync -> prod pod updated
- [ ] Manual staging deploy works
- [ ] GitLab CI deploy stages disabled

**Invoicetron:**
- [ ] Kustomize overlays produce correct per-env manifests
- [ ] Push to develop -> pipeline with migration -> ArgoCD sync -> dev pod updated
- [ ] Push to main -> pipeline with migration -> ArgoCD sync -> prod pod updated
- [ ] GitLab CI deploy stages disabled

**Monitoring:**
- [ ] ServiceMonitor scraping Argo Events controllers
- [ ] CI/CD alerts firing correctly (test with a failing workflow)
- [ ] Grafana dashboard showing pipeline metrics

**Security:**
- [ ] All workflow pods non-root, PSS baseline compliant
- [ ] BuildKit rootless (UID 1000)
- [ ] No cluster-admin ServiceAccounts
- [ ] Webhook secret validates GitLab payloads
- [ ] GitHub deploy key has minimal repo scope (read/write on homelab only)

---

## Rollback

**Per-project rollback (re-enable GitLab CI):**
```bash
# 1. Re-enable deploy stages in .gitlab-ci.yml (uncomment or remove when: manual)
# 2. Push to trigger GitLab CI pipeline
# 3. Delete the Argo Events Sensor for that project
# GitLab Runner is dormant but still deployed - it picks up jobs immediately
```

**Full rollback (remove Argo Events):**
```bash
# Delete ArgoCD Application
kubectl-admin delete application argo-events -n argocd

# Remove namespace
kubectl-admin delete namespace argo-events

# Re-enable all GitLab CI deploy stages
# GitLab Runner handles all deployments again
```

**Invoicetron Kustomize rollback:**
```bash
# Revert manifests/invoicetron/ to flat structure (git revert the restructure commit)
# Re-create single ArgoCD Application pointing at manifests/invoicetron/
```

---

## Final: Commit and Release

- [ ] `/audit-security` then `/commit`
- [ ] `/audit-docs` then `/commit`
- [ ] `/release v0.39.1 "CI/CD Pipeline Migration"`
- [ ] `mv docs/todo/phase-5.9.1-cicd-pipeline-migration.md docs/todo/completed/`
