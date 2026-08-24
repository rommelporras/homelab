# Using ArgoCD (Day-to-Day GitOps)

> **What this is:** how to *operate* ArgoCD in normal times - deploy, sync, check
> status, diff, roll back. For fixing a broken/stuck ArgoCD, use
> [../runbooks/argocd.md](../runbooks/argocd.md) and
> [../runbooks/00-EMERGENCY.md §9](../runbooks/00-EMERGENCY.md#9-argocd--gitops-stuck).

---

## The one thing to internalize

**Git is the source of truth. You do not deploy - you commit, and ArgoCD deploys.**

```
You edit a manifest  ->  git push  ->  ArgoCD notices (≤3 min)  ->  ArgoCD applies it
```

Never `kubectl apply` or `helm upgrade` a managed resource. ArgoCD's **selfHeal**
reverts any manual change on its next reconcile (~3 min). If you need a change to
stick, it must be in Git.

`cilium` is a special case: it's the last app still on a Helm chart and is
manual-sync (it IS the CNI - a chicken-and-egg bootstrap problem). It is still an
ArgoCD Application, just synced by hand, not `helm upgrade`d outside ArgoCD. See
[the sync-policy section](#sync-policy--which-apps-auto-sync) for the other
manual-sync apps.

---

## How this cluster is wired (app-of-apps)

There is one **root** Application (`manifests/argocd/apps/root.yaml`) that watches
the `manifests/argocd/apps/` directory. Every file in there is itself an
Application pointing at a service's manifests. So:

```
root  (watches manifests/argocd/apps/)
 ├── karakeep      -> manifests/karakeep/
 ├── atuin         -> manifests/atuin/
 ├── monitoring-*  -> manifests/monitoring/ + helm/prometheus/...
 └── ... ~55 apps
```

Add a file to `manifests/argocd/apps/` and the root app auto-creates that
Application. Delete the file and the Application is removed - but **the managed
resources stay** (individual Apps have no `resources-finalizer`), so deleting an
app YAML does not nuke the running service. That is intentional (safety).

### The 6 AppProjects (RBAC boundaries)

Each Application belongs to a **project** that restricts which namespaces and
cluster-scoped resources it may touch. Defined in
`manifests/argocd/appprojects.yaml`:

| Project | For | Namespaces it can deploy to |
|---------|-----|-----------------------------|
| `infrastructure` | Platform (Cilium, Longhorn, cert-manager, Vault, monitoring, ...) | many + cluster-scoped resources |
| `homelab-apps` | General self-hosted apps | home, ghost-*, browser, ai, karakeep, atuin, cloudflare, tailscale, uptime-kuma |
| `arr-stack` | Media stack | arr-stack, monitoring |
| `gitlab` | GitLab platform | gitlab, gitlab-runner |
| `cicd-apps` | CI/CD-deployed apps (per-env) | invoicetron-*, portfolio-* |
| `argocd-self` | ArgoCD managing itself | argocd |

When you add a new app, its `spec.project` must be a project whose
`destinations` include your target namespace. If not, add the namespace to that
project first (or pick the right project). A common mistake: new app in a new
namespace, but the project doesn't list it -> sync fails with a permissions error.

### Sync policy - which apps auto-sync

```yaml
syncPolicy:
  syncOptions:
    - ServerSideApply=true
    - CreateNamespace=false          # namespace is a manifest in the service dir
    - PrunePropagationPolicy=foreground
    - ServerSideDiff=true
    - RespectIgnoreDifferences=true
  automated:
    prune: true        # deleting a manifest from Git deletes the resource
    selfHeal: true     # manual kubectl changes get reverted
```

**Not every app auto-syncs.** In Git, ~18 of 55 Application files omit the
`automated:` block - the critical Helm-based infrastructure apps: `cilium`,
`longhorn`, `vault`, `prometheus`, `loki`, `velero`, `cert-manager`,
`external-secrets`, `metrics-server`, `alloy`, `blackbox-exporter`,
`smartctl-exporter`, the `intel-device-plugins-*`, `node-feature-discovery`,
`tailscale-operator`, `gitlab`, and `gitlab-runner`. These are declared manual-sync
so a bad commit can't auto-roll a platform component.

> **Live-vs-Git drift (verify before trusting):** the live cluster currently shows
> `selfHeal: true` on several of these infra apps (e.g. `longhorn`, `prometheus`)
> even though their Git manifests declare no `automated:` block. Only `cilium` and
> `gitlab` are fully manual (no `automated` at all) in the live spec. This drift is
> worth reconciling - treat the Git declaration as intent, and check
> `argocd app get <app>` for the live behavior before you rely on auto-sync.

Practically: **`gitlab` is the one you'll manually sync most often** (its Helm
hooks fight with ArgoCD auto-prune). After any change to `helm/gitlab/values.yaml`
or `manifests/argocd/apps/gitlab.yaml`, sync it by hand (see below).

---

## Accessing ArgoCD

### Web UI

`https://argocd.k8s.rommelporras.com` - log in as `admin`; the password is in
1Password ("ArgoCD" item, `admin-password`). The UI is the easiest way to see the
whole tree, diffs, and sync/rollback with a click.

### CLI from inside the controller (no login, no port-forward)

The `argocd-application-controller` pod ships the `argocd` binary. In `--core`
mode it uses the in-cluster kubeconfig directly - no server, no token. This is the
reliable path when the UI is slow or you're scripting:

```bash
# Pattern - prefix any argocd command with this exec:
kubectl-admin exec -n argocd statefulset/argocd-application-controller -- \
  argocd <command> --core
```

For brevity below, `argocd ...` means "run it via that exec with `--core`".

---

## The commands you'll actually use

### See what's going on

```bash
# All apps and their sync/health state (quickest read):
kubectl-homelab get applications -n argocd
# Anything not Synced+Healthy:
kubectl-homelab get applications -n argocd | grep -vE 'Synced.*Healthy'

# Detail on one app (source revision, conditions, resources):
argocd app get <app>

# What differs between Git and the cluster right now:
argocd app diff <app>
```

### Deploy a change (the normal path)

```bash
# 1. Edit the manifest or helm values in Git.
# 2. Commit + push via the project's workflow (use /commit - do NOT git push raw).
# 3. Wait ≤3 min, or force ArgoCD to look now:
argocd app get <app> --refresh
# 4. Confirm it converged:
kubectl-homelab get applications -n argocd | grep <app>
```

### Force a sync now (don't wait for the 3-min poll)

```bash
argocd app sync <app>
# Multi-source ($values) apps sometimes need an explicit refresh first
# (seen on alloy): 
argocd app get <app> --refresh && argocd app sync <app>
```

**Refresh vs sync (important):** the annotation below triggers a *refresh*
(re-compare Git vs live), NOT a *sync* (apply). On an app with `selfHeal: true` a
refresh that finds drift then triggers the sync automatically. On a **truly
manual-sync app (`gitlab` and `cilium` - the only two with no `automated:` in the
live spec) a refresh applies nothing**; you must still run `argocd app sync <app>`.
The other infra apps *currently* carry `selfHeal: true` live (the drift noted
above), so a refresh WILL auto-sync them today - but don't rely on that as intended
behavior. Use the annotation to make ArgoCD re-detect a change without exec-ing:

```bash
kubectl-admin annotate application <app> -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite
```

### Roll back a bad deploy

ArgoCD keeps a deploy history. Two ways:

- **Revert in Git (preferred, GitOps-correct):** revert the commit that caused it,
  push, let ArgoCD sync forward to the reverted state. History stays honest.
- **Fast rollback via ArgoCD (break-glass):** roll the *live* state back to a
  previous synced revision while you sort out Git:
  ```bash
  argocd app history <app>              # find the target revision ID
  argocd app rollback <app> <id>
  ```
  Note: with `selfHeal` on, a rollback that doesn't match Git will get pulled
  back toward Git. Use the Git revert for anything that must persist. Rollback is
  for buying minutes during an incident.

### GitLab (manual-sync) - remember this one

Shown in full (there is no `argocd` binary on your workstation - it lives inside
the controller pod, so every `argocd` command needs the exec wrapper):

```bash
# After ANY change to helm/gitlab/values.yaml or the gitlab Application:
kubectl-admin exec -n argocd statefulset/argocd-application-controller -- \
  argocd app sync gitlab --core
# Then watch it reach Synced/Healthy within ~5 min before walking away
# (admin: homelab RBAC can't list Applications):
kubectl-admin get applications -n argocd | grep gitlab
```

---

## When to reach for the runbook instead

If an app is stuck `OutOfSync` forever, sync is deadlocked, a hook Job is wedged,
or health won't go green, that's break-glass territory:
[../runbooks/argocd.md](../runbooks/argocd.md) and
[../runbooks/00-EMERGENCY.md §9](../runbooks/00-EMERGENCY.md#9-argocd--gitops-stuck).

Two of the most common non-obvious ones (full detail in the runbook + `CLAUDE.md`):

- **App won't stop being `OutOfSync`, log says "spec.source differs":** a
  `directory.recurse: false` block in the Application - remove the whole
  `directory:` block (recurse=false is the default and gets stripped, causing an
  infinite loop).
- **`gitlab` shows `Health=Missing` but every pod is healthy:** the migrations
  container OOMKilled (needs ≥1536Mi memory limit).

---

## Related

- [adding-a-service.md](adding-a-service.md) - creates the Application YAML this
  guide talks about
- [../context/Architecture.md](../context/Architecture.md) - why GitOps / ArgoCD
- `/verify-sync` slash command - scripted "did my sync land?" check
