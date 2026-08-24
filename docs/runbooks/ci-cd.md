# CI/CD pipeline runbook (Argo Workflows + GitLab)

> **What this is:** break-glass triage for the self-hosted CI/CD pipeline
> (GitLab push -> Argo Events webhook -> Argo Workflows DAG: clone, install-deps,
> lint/type-check/test-unit fan-out, build, push, [migrate], deploy via a Kustomize
> `newTag` commit, verify). Use it when a `CIBuildStuck`, `CIPipelineFailed`,
> `CIDeployMutexHeldTooLong`, or `WebhookDeliveryFailed` alert fires, or a push does
> not deploy. For the platform-health side (controller / EventSource / Sensor /
> EventBus down) see [argo-events.md](argo-events.md) (webhook plumbing) and
> [argo-workflows.md](argo-workflows.md) (controller health + the vault-snapshot
> CronWorkflow - this doc does NOT duplicate those). For how the deploy commit flows
> to production see [../operations/argocd-guide.md](../operations/argocd-guide.md).

---

## Quick reference

| Thing | Value |
|-------|-------|
| Workflow namespace | `argo-workflows` |
| Events namespace | `argo-events` |
| UI | `https://argo-workflows.k8s.rommelporras.com` (SSO via self-hosted GitLab OIDC) |
| Pipelines (`WorkflowTemplate`s) | `portfolio-pipeline`, `invoicetron-pipeline`, `portfolio-staging-promote` |
| Shared step templates (`WorkflowTemplate`s) | `clone`, `install-deps`, `lint`, `type-check`, `test-unit`, `test-e2e` (deferred - not wired into any DAG), `build-image`, `push-image`, `deploy-image`, `verify-health`, `notify-on-failure` |
| Deploy mutex | `deploy-image-lock` (namespace `argo-workflows`) |
| Deploy target repo | `git@github.com:rommelporras/homelab.git` over SSH (commit updates the Kustomize overlay -> ArgoCD syncs) |
| CI git identity | `Argo CI Bot <ci-bot@k8s.rommelporras.com>`; commit msg `chore(ci): update <project>/<env> image to <sha> [skip ci]` (uses `--signoff`) |
| Pod label (per workflow) | `workflows.argoproj.io/workflow=<workflow-name>` |
| Controller / server (deployments) | `argo-workflows-workflow-controller`, `argo-workflows-server` (image `quay.io/argoproj/argocli:v4.0.4`, `--namespaced` mode) |
| ArgoCD apps | `argo-workflows` + `argo-events` = Helm charts (controller/server only). **`argo-workflows-manifests` + `argo-events-manifests` = the WorkflowTemplates, Sensors, EventSources, CNPs** |

> **RBAC note:** `kubectl-homelab` (the restricted read-only kubeconfig,
> `~/.kube/homelab-claude.yaml`) is **Forbidden** from listing
> `workflows`/`workflowtemplates`/`cronworkflows` in `argo-workflows` (verified live:
> `workflows.argoproj.io is forbidden ... cannot list resource "workflows"`). Every
> `kubectl get workflows` / `logs` / `exec` command below **requires** `kubectl-admin`
> (`~/.kube/homelab.yaml`). Plain `kubectl-homelab` reads only work for `pods` /
> `events` (both verified OK).

---

## How the pipeline is wired (read this once)

```
git push to GitLab (0xwsh/portfolio or 0xwsh/invoicetron)
   -> GitLab webhook POST
   -> Argo Events EventSource (gitlab-portfolio / gitlab-invoicetron) :12000
   -> EventBus (NATS JetStream, eventbus-default-js-0/1/2)
   -> Sensor (gitlab-portfolio-develop|-main, gitlab-invoicetron-develop|-main)
      filters branch (body.ref), submits a Workflow from the pipeline WorkflowTemplate
   -> Argo Workflows controller runs the DAG:

   clone -> install-deps -+-- lint -------+-- build -- push --[migrate]-- deploy -- verify
                          +-- type-check -+
                          +-- test-unit --+   (parallel fan-out)
                          (invoicetron adds migrate between push and deploy)
```

- **portfolio-pipeline:** no migrate step. `develop` branch -> `dev` env, `main` ->
  `prod`. A `test-e2e` (Playwright) template exists but is **deferred and NOT wired
  into the DAG** (see the comment at the top of
  `manifests/argo-workflows/templates/portfolio-pipeline.yaml`), so do not expect an
  E2E node in the graph. Typical run 4-8 min.
- **invoicetron-pipeline:** has a dedicated `migrate` step
  (`bunx prisma migrate deploy`) between `push` and `deploy`. `migrate` depends on
  `push` (not `build`) because it pulls the just-pushed image from the private GitLab
  registry. Typical run ~6 min.
- **portfolio-staging-promote:** no rebuild - takes an already-built dev image SHA
  and commits it to the `portfolio` `staging` overlay. Triggered by a manual GitLab
  job POST. `activeDeadlineSeconds: 900` (15 min).

### The deploy step = a Git commit, not a `kubectl apply`

The `deploy-image` template does **not** touch the live Deployment. It:

1. clones `git@github.com:rommelporras/homelab.git` (SSH key `github-deploy-key`,
   mounted as `/root/.ssh/id_ed25519`),
2. runs `kustomize edit set image <image_name>=<repo>:<sha>` in the env overlay
   (`manifests/<project>/overlays/<env>`),
3. commits as `Argo CI Bot` with `--signoff` and a `[skip ci]` message,
4. `git push origin main` with a 5-attempt retry-rebase loop,
5. holds the `deploy-image-lock` mutex the whole time so two pipelines never race the
   push.

ArgoCD then notices the overlay change (<= 3 min) and syncs the real Deployment. So a
"successful CI run" only means the tag was **committed** - the actual rollout is an
ArgoCD sync. If verify passes but the app didn't update, the problem is on the ArgoCD
side: see [../operations/argocd-guide.md](../operations/argocd-guide.md) and
[00-EMERGENCY.md §9](00-EMERGENCY.md#9-argocd--gitops-stuck).

---

## CIBuildStuck

**Severity:** warning. **Fires:** any workflow in `argo-workflows` has been in
`Running` phase for 15+ minutes (`argo_workflows_gauge{phase="Running"} > 0` for 15m).
Typical runs finish in 4-8 min (invoicetron ~6m). This means a step is wedged.

### 1. Find the stuck workflow (admin required)

```bash
# Newest first - look for STATUS=Running with a large AGE:
kubectl-admin get workflows -n argo-workflows \
  --sort-by=.metadata.creationTimestamp | tail

# Only the running ones:
kubectl-admin get workflows -n argo-workflows \
  --field-selector=status.phase=Running
```

Note the workflow NAME (e.g. `invoicetron-dev-w7sth`, `portfolio-prod-xxxxx`).

### 2. See which DAG node is blocking

The UI is by far the fastest here - it draws the DAG and colours the stuck node:
`https://argo-workflows.k8s.rommelporras.com` -> the workflow -> the node that is
still spinning. From the CLI:

```bash
# Full status incl. per-node phase + message:
kubectl-admin get workflow <name> -n argo-workflows -o yaml | less

# Just the node phases (needs yq; skip if not installed):
kubectl-admin get workflow <name> -n argo-workflows -o yaml \
  | yq '.status.nodes[] | {"name": .displayName, "phase": .phase, "message": .message}'

# The pods this workflow created and their state (kubectl-homelab OK for pods):
kubectl-homelab get pods -n argo-workflows \
  -l workflows.argoproj.io/workflow=<name> -o wide
```

### 3. Read the stuck step's logs and events (admin required for logs)

```bash
# Logs for every step pod in this workflow:
kubectl-admin logs -n argo-workflows \
  -l workflows.argoproj.io/workflow=<name> --all-containers --prefix --tail=100

# Why a pod is not starting (Multi-Attach, image pull, scheduling) - homelab OK:
kubectl-homelab get events -n argo-workflows \
  --sort-by=.lastTimestamp | grep <pod-name>
```

`podGC.strategy: OnPodSuccess` deletes only **successful** step pods, so
**failed/running** pods stay around for triage and their logs are still available.

### 4. Common causes

| Symptom in step/pod | Cause | Fix |
|---------------------|-------|-----|
| `FailedAttachVolume: Multi-Attach error for volume "pvc-…"` on `lint`/`type-check`/`test-unit` | Parallel DAG siblings scheduled onto **different** nodes; the RWO `workspace` PVC (Longhorn, `volumeClaimTemplates`) can only attach to one node at a time. | Both pipelines already carry a workflow-level `affinity.podAffinity.preferredDuringSchedulingIgnoredDuringExecution` on `workflows.argoproj.io/workflow={{workflow.name}}` at `topologyKey: kubernetes.io/hostname` (weight 100) to co-locate all pods. If it recurs, confirm that block is still present in `manifests/argo-workflows/templates/{portfolio,invoicetron}-pipeline.yaml`. Do **NOT** switch it to `required` - the first pod has no siblings to match and `required` becomes unsatisfiable. **NEVER delete the PVC** to clear a mount error (see CLAUDE.md Longhorn PVC Safety). |
| `migrate` step fails with Prisma `P1001: Can't reach database server` | migrate runs in `argo-workflows` but the DB lives in `invoicetron-<env>`; a **short** host name only resolves in its own namespace. | The `DATABASE_URL` in Vault (target Secret `invoicetron-migrate-db-urls`, key = env name) must use the FQDN `<svc>.<namespace>.svc.cluster.local`, never `invoicetron-db:5432`. |
| `migrate` fails P1001 even with the right URL, connection **timed out** at Cilium L3 | Argo Workflows **v4.0.4** does not let a template-level `metadata.labels` override a key already set by workflow-level `podMetadata.labels`; the migrate pod would otherwise keep `app.kubernetes.io/component=ci-pipeline` and the cross-namespace DB CiliumNetworkPolicy selector would miss it. | The migrate template uses a **dedicated** label key `invoicetron-migrate: "true"` (not the shared `component` key), which the DB ingress CNP (`manifests/invoicetron/overlays/<env>/networkpolicy.yaml`) selects on together with `namespace=argo-workflows`. Verify with `kubectl-admin get pod <migrate-pod> -n argo-workflows -o yaml \| yq '.metadata.labels'`. |
| `build` OOMKilled / `deploy` push retry loop spinning | BuildKit RSS (invoicetron: Next.js Turbopack + Prisma + native `canvas`), or `deploy-image` losing the push race repeatedly. | Bump the memory limit in `build-image-template.yaml` (Git -> ArgoCD sync `argo-workflows-manifests`). For the push loop see **CIDeployMutexHeldTooLong** below. |
| deploy `git push origin main` rejected `pre-receive hook declined` | Note: the CI deploy commit targets `github.com/rommelporras/homelab` (which allows CI pushes), so this only bites when you separately promote **portfolio's own** GitLab repo, whose `main` is `push_access_levels: "No one"`. | Portfolio `main` needs an MR (push a feature branch, merge via `glab api` - not `glab mr create`). Invoicetron `main` allows Maintainer direct push. See CLAUDE.md gotcha + `docs/todo/phase-5.9.1-cicd-pipeline-migration.md` Notes #55. |

### 5. If a step is genuinely wedged and you must stop it

The safe first action is to let it hit `activeDeadlineSeconds` (1800s = 30 min for the
two CI pipelines, 900s for staging-promote) - it will fail cleanly and
`notify-on-failure` posts to Discord `#incidents`. To stop it sooner, use the Argo UI
(**Stop** = graceful, runs the exit handler; **Terminate** = immediate, no exit
handler). The UI is the primary path.

The `argo` CLI also ships inside the server pod (image `quay.io/argoproj/argocli:v4.0.4`),
so you can drive it from there. Because the server runs in `--namespaced` mode its
default namespace is already `argo-workflows`:

```bash
# Graceful stop (runs onExit / notify-on-failure):
kubectl-admin exec -n argo-workflows deployment/argo-workflows-server -- \
  argo stop <name> -n argo-workflows
# Hard terminate (no exit handler):
kubectl-admin exec -n argo-workflows deployment/argo-workflows-server -- \
  argo terminate <name> -n argo-workflows
```

> **Note:** the exact server-mode `argo stop`/`terminate` invocation was not exercised
> live while writing this doc (the image is confirmed to be `argocli`, which contains
> the binary). If the exec errors, use the UI Stop / Terminate buttons - same effect,
> and it is the primary path anyway.

---

## CIPipelineFailed

**Severity:** warning. **Fires:** a workflow is in `Failed` phase
(`argo_workflows_gauge{phase="Failed"} > 0` for 5m) - a step exited non-zero (test
failure, lint error, build error, migrate error). This is normal for a genuinely broken
commit. `notify-on-failure` already posts to Discord `#incidents`.

```bash
# 1. Find it:
kubectl-admin get workflows -n argo-workflows \
  --sort-by=.metadata.creationTimestamp | tail
# 2. Which step failed + why (message field):
kubectl-admin get workflow <name> -n argo-workflows -o yaml | less
# 3. Failing step's logs:
kubectl-admin logs -n argo-workflows \
  -l workflows.argoproj.io/workflow=<name> --all-containers --prefix --tail=200
```

If it is a real code/test failure -> that is working as intended; fix the code and push
again. If it is infra (image pull, mount, node not ready), it usually shows as **Error**
phase, not Failed - see [argo-workflows.md#ArgoWorkflowError](argo-workflows.md#ArgoWorkflowError).
Failed Workflow CRs auto-prune after 24h (`ttlStrategy.secondsAfterFailure: 86400`) for
the two CI pipelines, so grab logs before then. (Exception: `portfolio-staging-promote`
keeps failed workflows for 7d - `secondsAfterFailure: 604800`.)

---

## CIDeployMutexHeldTooLong

**Severity:** warning. **Fires:** a workflow has been blocking on `deploy-image-lock`
for 10+ minutes (`argo_workflows_workflow_condition{type="Synchronization",status="False"} > 0`
for 10m). Normal hold is seconds. Almost always a stuck `deploy-image` step: git push
retry-rebase loop spinning, or SSH auth to GitHub failing.

```bash
# 1. Which workflow is in the deploy step right now:
kubectl-admin get workflows -n argo-workflows --field-selector=status.phase=Running
# 2. deploy-image pod logs - look for the push-attempt loop:
kubectl-admin logs -n argo-workflows \
  -l workflows.argoproj.io/workflow=<name> --all-containers --prefix \
  | grep -iE 'push attempt|rebase|permission denied|libcrypto'
```

Common roots:

- **`error in libcrypto` / SSH key parse:** the `github-deploy-key` Secret is malformed
  (the private key must end with a trailing newline). Source is Vault via ExternalSecret
  (`manifests/argo-workflows/externalsecret-github-deploy-key.yaml`); do not hand-edit
  the Secret.
- **`Permission denied (publickey)`:** the GitHub deploy key was rotated/removed.
  Re-provision via Vault + ESO.
- **Push loop losing the race 5x:** a human (or another pipeline) is committing to
  `homelab` `main` at the same time. It fails after 5 attempts and `notify-on-failure`
  fires. Re-run once the contention clears.

Do **not** manually delete the mutex object to "unstick" it - let the step fail (it
releases the lock on pod exit) or Stop the workflow (above). Deleting the lock out from
under a running holder can double-commit.

---

## WebhookDeliveryFailed

**Severity:** warning. **Fires:** an EventSource failed to process incoming events
(`rate(argo_events_event_processing_failed_total[10m]) > 0` for 10m). Usually a webhook
token mismatch (`X-Gitlab-Token`) or malformed payload - i.e. pushes are arriving but
not turning into workflows.

This is the **plumbing** layer. Full triage lives in [argo-events.md](argo-events.md).
Quick checks:

```bash
# EventSource + Sensor pods healthy? (kubectl-homelab OK for pods)
kubectl-homelab get pods -n argo-events
# EventSource logs (which EventSource is in the alert's eventsource_name label):
kubectl-admin logs -n argo-events -l eventsource-name=<name> --tail=100
# Sensor logs (did the filter reject the event?):
kubectl-admin logs -n argo-events -l sensor-name=<name> --tail=100
```

EventSource label values: `gitlab-portfolio`, `gitlab-invoicetron`,
`portfolio-staging-promote`. Sensor label values: `gitlab-portfolio-develop`,
`gitlab-portfolio-main`, `gitlab-invoicetron-develop`, `gitlab-invoicetron-main`,
`portfolio-staging-promote`.

> **SECURITY - do not paste sensor logs anywhere:** on a filter rejection, the Argo
> Events sensor logs the **full event body including header values in plaintext** at
> warn level. Any auth token in a header (e.g. a staging-promote token) leaks into pod
> logs. Treat sensor-log access as equivalent to secret-value access. Also note Argo
> Events puts HTTP headers under `header.*` (singular) - a filter path of `headers.X-…`
> silently drops every event. (Both from CLAUDE.md gotchas.)

---

## Manually re-run / debug a pipeline

### Via the UI (preferred)

`https://argo-workflows.k8s.rommelporras.com` (SSO: log in with GitLab). You can:

- **Resubmit** a finished workflow with the same parameters (re-runs the whole DAG),
- **Retry** a failed workflow from the failed node onward,
- **Stop / Terminate** a stuck one,
- read per-node logs inline.

### Via kubectl (admin required) - submit from a template

There is no `kubectl-homelab` path (RBAC-blocked). Submit a fresh Workflow that
references the pipeline `WorkflowTemplate`, supplying the same parameters the Sensor
would inject.

> **WARNING - this triggers a REAL deploy.** The `deploy` step commits a new image tag
> to `homelab` `main`, which ArgoCD will roll out to the named environment. Point
> `environment` at `dev`/`staging` unless you intend a prod release. `commit_sha` must
> be an 8-char short SHA that exists on the given `branch`, and `image_repo` must be a
> repo where that exact tag was already built/pushed (the manual run skips nothing for
> the two full pipelines - it rebuilds - but for `portfolio-staging-promote` the image
> must already exist).

```yaml
# Verify parameter names against the template FIRST - they are load-bearing:
#   kubectl-admin get workflowtemplate portfolio-pipeline -n argo-workflows -o yaml | less
# portfolio-pipeline params:   commit_sha, branch, environment, image_repo
# invoicetron-pipeline params: commit_sha, branch, environment, image_repo
kubectl-admin create -f - <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  generateName: portfolio-manual-
  namespace: argo-workflows
spec:
  workflowTemplateRef:
    name: portfolio-pipeline
  arguments:
    parameters:
      - name: commit_sha
        value: "<8-char-sha>"
      - name: branch
        value: "develop"
      - name: environment
        value: "dev"
      - name: image_repo
        value: "registry.k8s.rommelporras.com/0xwsh/portfolio"
EOF
```

For **portfolio-staging-promote** (redeploy an already-built dev image to staging, no
rebuild), the only required parameter is `source_sha` (`target_env` defaults to
`staging`):

```yaml
kubectl-admin create -f - <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  generateName: portfolio-staging-promote-manual-
  namespace: argo-workflows
spec:
  workflowTemplateRef:
    name: portfolio-staging-promote
  arguments:
    parameters:
      - name: source_sha
        value: "<8-char-sha>"
EOF
```

Watch it:

```bash
kubectl-admin get workflow -n argo-workflows -w
```

> **Do not `kubectl apply` / `helm upgrade` any of the Argo Workflows or Argo Events
> manifests to "fix" a pipeline** - both are ArgoCD-managed, so selfHeal reverts manual
> edits within ~3 min. Real fixes go through Git and (if needed) an ArgoCD sync.
> **The WorkflowTemplates / Sensors / EventSources / CNPs live in the
> `*-manifests` apps, NOT the Helm chart apps.** Force a sync from the controller pod:
> ```bash
> kubectl-admin exec -n argocd statefulset/argocd-application-controller -- \
>   argocd app sync argo-workflows-manifests --core
> # webhook / Sensor / EventSource fixes:
> kubectl-admin exec -n argocd statefulset/argocd-application-controller -- \
>   argocd app sync argo-events-manifests --core
> ```
> (`argo-workflows` / `argo-events` are the Helm chart apps - controller + server only.)
> See [../operations/argocd-guide.md](../operations/argocd-guide.md).

---

## Related

- [argo-workflows.md](argo-workflows.md) - controller health, `ArgoWorkflow*` alerts,
  the `vault-snapshot` CronWorkflow (this doc does not repeat those).
- [argo-events.md](argo-events.md) - EventSource / Sensor / EventBus health, webhook
  token/secret debugging.
- [../operations/argocd-guide.md](../operations/argocd-guide.md) - how the deploy commit
  becomes a live rollout; sync/rollback.
- [apps.md](apps.md) - Invoicetron / Portfolio app-level troubleshooting.
- [00-EMERGENCY.md §9](00-EMERGENCY.md#9-argocd--gitops-stuck) - ArgoCD stuck / sync
  deadlock (the deploy step's downstream).
- [alert-index.md](alert-index.md) - one-line-per-alert index across all runbooks.
- CLAUDE.md (repo root) Gotchas - grep it for hard-won CI/CD fixes:
  `grep -niE 'argo-workflows|Multi-Attach|Prisma P1001|podMetadata|protected branch' /home/wsl/personal/homelab/CLAUDE.md`

