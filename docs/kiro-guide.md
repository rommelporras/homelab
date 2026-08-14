# Kiro CLI Agent Guide

This guide covers the homelab Kiro agent ecosystem: what the agents are, how to
switch between them, how skills trigger, when to use each workflow path, and the
safety model behind all of it.

Config reference: [`.kiro/README.md`](../.kiro/README.md)
Design spec: [`docs/plans/2026-08-14-kiro-homelab-agents-design.md`](plans/2026-08-14-kiro-homelab-agents-design.md)

---

## 1. Overview

Three workspace-local Kiro agents live in `.kiro/agents/`. Each has exactly one
write surface. That separation is the core safety property.

| Agent | Responsibility | Write surface |
|-------|---------------|---------------|
| `homelab-orchestrator` | Converse, plan, delegate, own git | git only |
| `homelab-sre` | Investigate alerts/incidents, perform safe live remediation | live cluster only |
| `homelab-deploy` | Author declarative repo changes: manifests, Helm values | repo only (`manifests/`, `helm/`) |

`homelab-sre` can never commit a bad manifest. `homelab-deploy` can never touch
the live cluster. Only `homelab-orchestrator` touches git.

The workspace setting `chat.disableInheritingDefaultResources: true` is set
intentionally. Each agent loads only the steering it needs, listed explicitly in
its `resources` block. Global steering (terraform, AWS, TypeScript noise) is
excluded by design. The homelab agents are self-contained.

All three agents run `claude-sonnet-5`.

---

## 2. Getting Started

`homelab-orchestrator` is the default agent for this repo (set in
`.kiro/settings/cli.json`). It starts automatically when you open a Kiro chat in
this directory.

### Switching agents

Use the `/agent <name>` command in chat, or the keyboard shortcuts:

| Shortcut | Agent |
|----------|-------|
| `ctrl+shift+h` | homelab-orchestrator |
| `ctrl+shift+s` | homelab-sre |
| `ctrl+shift+d` | homelab-deploy |

### When to use each

**homelab-orchestrator** - use this for cross-domain work: incident investigations
that end in a Git fix, new service deployments, anything that involves both cluster
investigation and repo changes. It delegates to the specialists and handles the
commit on your approval.

**homelab-sre** - use this when the work is purely about the live cluster: triaging
an alert storm, diagnosing a CrashLoop, checking pod health, investigating resource
usage. One agent, one context, no round-trips. This is the token-efficient path for
pure cluster incidents.

**homelab-deploy** - use this for focused declarative authoring: writing new
manifests, updating Helm values, expanding a PVC in the values file. It has no
cluster write access, so it is safe to use for structured editing work.

---

## 3. How Skills Trigger

Skills are not slash commands. They auto-load because Kiro reads each SKILL.md
description and activates the skill when your message matches a trigger phrase.
Say the phrase in natural conversation - no syntax required.

All skill trigger phrases are pulled from the SKILL.md frontmatter `description:` field.

### Skill reference table

| Skill | Trigger phrases | What it does | Runs on |
|-------|----------------|-------------|---------|
| `homelab-alert-triage` | "investigate alerts", "what is firing", "why am I getting alerts", "triage", "cluster health" | Enumerates firing alerts via Prometheus/Alertmanager APIs, collapses to root causes, drills with kubectl, cross-references runbooks, reports tiered remediation plan | homelab-sre |
| `commit` | "commit", "commit changes", "create a commit", "stage and commit", "make a commit" | Creates a conventional-commit following homelab rules: infra+docs two-commit split, secret scan before staging, explicit file staging only, no AI attribution | homelab-orchestrator |
| `ship` | "ship", "release", "cut a release", "tag a version", "create a release", "make a release" | Creates an annotated git tag, pushes commits and tag to main, creates a GitHub release from CHANGELOG.md. Requires `gh` CLI authenticated. | homelab-orchestrator |
| `verify-sync` | "verify sync", "check argocd", "did it deploy", "confirm sync", "did it land", "check if deployed" | Polls ArgoCD Applications until Synced/Healthy or fail. Auto-detects affected apps from HEAD commit, supports parallel polling for 3+ apps, triggers manual-sync for apps without automated syncPolicy, produces PASS/FAIL/TIMEOUT table with next-step hints | homelab-orchestrator, homelab-sre |
| `audit-cluster` | "audit cluster", "cluster security audit", "check cluster security", "cluster posture", "security posture" | Full read-only cluster security audit: PSS labels, container securityContexts, privileged pods, probes, default namespace usage, network policies, Vault/ESO health, RBAC cluster-admin bindings, exposed HTTPRoutes, image drift vs VERSIONS.md. Severity-rated report. | homelab-sre |
| `audit-security` | "audit security", "pre-commit security scan", "scan for secrets", "security scan", "check for secrets" | Scope-aware repo security scan: multi-pattern secret scanning with known-safe exclusions, sensitive file type checks, per-manifest securityContext/PSS/image-pin/probe checks with accepted-risk lookup, network policy coverage, Helm values scan, docs secrets scan. Works entirely offline. | homelab-orchestrator, homelab-deploy |
| `audit-docs` | "audit docs", "check docs accuracy", "docs drift", "documentation audit", "are docs current", "check documentation" | Audits docs against current cluster state: VERSIONS.md, docs/context/*.md, rebuild/README, root README, CLAUDE.md, broken links, CHANGELOG. Waits for approval before making any changes. Includes deep mode for live cluster verification. | homelab-orchestrator |

---

## 4. Proper Workflow

### Two paths

**Direct path - pure cluster incident:**

```
you --> homelab-sre --> investigate + correlate --> (confirm) safe live fix
```

Switch to `homelab-sre` directly (`ctrl+shift+s`). One agent, one context, no
round-trips. Use this when you do not expect the fix to need a Git change.

**Orchestrated path - incident needs a Git fix:**

```
you --> homelab-orchestrator
          |-- delegates to homelab-sre: investigate
          |                              returns root cause + recommended fix
          |-- delegates to homelab-deploy: edit the values/manifest
          |                                returns diff
          |-- (your approval) git commit + push
          |-- delegates to homelab-sre: verify alerts cleared
```

The orchestrator coordinates the specialists. It reads the SRE's findings, hands
the structural diff to deploy, reviews the result, then commits on your explicit
approval. It never auto-commits.

### The GitOps rule

ArgoCD is the source of truth. All services except `cilium` have `selfHeal: true`.
An imperative `kubectl apply` or `helm upgrade` against an ArgoCD-managed resource
is reverted within roughly 3 minutes.

**Structural fixes go through Git.** If the right fix is a manifest or Helm values
change (PVC size, retention setting, resource limits, replica count), that change
must be authored by `homelab-deploy` and committed by `homelab-orchestrator`. The
SRE agent does not edit manifests, does not run `kubectl apply`, and does not fight
selfHeal.

---

## 5. Sample Workflow A - Investigate an Alert Storm

You wake up to 16 alerts in Discord. Switch to `homelab-sre` and say:

> "investigate alerts"

The alert-triage skill activates. It:

1. Verifies cluster connectivity (`getent hosts api.k8s.rommelporras.com`)
2. Fetches firing alerts from both Prometheus and Alertmanager APIs and produces a
   count-sorted table grouped by alertname, severity, and namespace
3. Collapses correlated alerts to root causes rather than triaging one-by-one. A
   real example: 16 active alerts collapsed to 3 problems; `loki-0` PVC full
   explained ~9 of them (LokiDown, LokiIngestionStopped, AlloyNotSendingLogs,
   and several TargetDown alerts all traced back to one full volume)
4. Drills with `kubectl` using the restricted kubeconfig for pod/event/describe
   data; switches to the admin kubeconfig for logs (required for `pods/log` RBAC)
5. Cross-references `docs/runbooks/alert-index.md` and scans `CLAUDE.md` gotchas
   for known patterns
6. Produces a structured report: firing count, named root cause(s) with evidence,
   correlated alerts, and remediation options classified by tier

For a live-safe fix (restart a single pod, clear a stuck job), the SRE will ask
your confirmation before running each action.

For a structural fix (expand a PVC, cut retention, bump a resource limit), the SRE
reports the exact change needed and hands off to the orchestrator path. It does not
make the change directly.

---

## 6. Sample Workflow B - Debug and Fix (Loki PVC Full)

This is the acceptance test case the agent ecosystem was designed around.

**Step 1 - Investigate with homelab-sre**

Start on `homelab-orchestrator` (`ctrl+shift+h`):

> "The Loki alerts are firing - investigate and fix whatever is causing them."

The orchestrator delegates the investigation to `homelab-sre`. The SRE runs
alert-triage, finds `loki-0` in CrashLoopBackOff with 680+ restarts, pulls logs:

```bash
kubectl --kubeconfig ~/.kube/homelab.yaml logs -n loki loki-0 --tail=50
```

Log output confirms: `no space left on device`. The SRE reads the PVC usage and
identifies this as a structural fix: the `helm/loki/values.yaml` retention settings
need to be cut, or the PVC needs expansion.

**Step 2 - Author the repo change with homelab-deploy**

The orchestrator delegates the values change to `homelab-deploy`. The deploy agent:

- Reads the current `helm/loki/values.yaml`
- Updates the retention window (e.g. cuts `retention_period` to a value that fits
  the current PVC, or adjusts `compactor.retentionEnabled`)
- Runs `helm template` against the updated values to validate
- Returns a diff summary to the orchestrator for review

**Step 3 - Commit on approval**

The orchestrator shows you the diff. You approve. Say "commit it." The commit skill
activates:

- Scans staged files for secrets
- Drafts the message: `infra: cut loki retention to fix PVC full`
- Stages the specific file only (no `git add .`)
- Creates the commit

You then approve the push: "push it." The orchestrator runs `git push origin main`.

**Step 4 - Verify with verify-sync**

Either say "verify sync" or "did it deploy." The verify-sync skill activates,
detects `loki` as the affected app from HEAD, polls ArgoCD until `Synced/Healthy`:

```
Verification complete.
+----------------------+---------+---------+------------------+
| App                  | Sync    | Health  | Result           |
+----------------------+---------+---------+------------------+
| loki                 | Synced  | Healthy | PASS (2m15s)     |
+----------------------+---------+---------+------------------+
```

**Step 5 - Confirm alerts cleared**

The orchestrator delegates a final check back to `homelab-sre`. It re-queries the
Alertmanager API. LokiDown, LokiIngestionStopped, AlloyNotSendingLogs are all
resolved. The alert storm is over.

---

## 7. Sample Debugging Session - CrashLoopBackOff

You notice a pod is not running. Here is the full command sequence using the two
kubeconfigs correctly.

**Check what is happening (restricted kubeconfig):**

```bash
kubectl --kubeconfig ~/.kube/homelab-claude.yaml get pods -n <namespace> -o wide
kubectl --kubeconfig ~/.kube/homelab-claude.yaml describe pod <pod-name> -n <namespace>
kubectl --kubeconfig ~/.kube/homelab-claude.yaml get events -n <namespace> \
  --sort-by='.lastTimestamp' | tail -20
```

The restricted kubeconfig covers most investigation: pod state, restart counts,
OOMKilled status, image pull errors, probe failures, PVC mount errors. No write
access, no log access.

**Pull logs to confirm root cause (admin kubeconfig required):**

```bash
kubectl --kubeconfig ~/.kube/homelab.yaml logs -n <namespace> <pod-name> --tail=50
kubectl --kubeconfig ~/.kube/homelab.yaml logs -n <namespace> <pod-name> \
  --previous --tail=50
```

The restricted SA does not have `pods/log` permission. Any log read requires the
admin kubeconfig at `~/.kube/homelab.yaml`.

**Correlate to known patterns:**

From the events and logs, check whether this matches a known gotcha:

- **OOMKilled + RWO volume** - do not delete the PVC. Delete the pod. The ReplicaSet
  creates a fresh pod; Longhorn cleanly detaches and reattaches. Deleting the PVC
  destroys the Longhorn volume and all replicas permanently.
- **Loki sidecar CrashLoop** - check `sidecar.rules.enabled: false` if Ruler is not
  in use.
- **GitLab Health=Missing with healthy pods** - migrations container OOMKilled; needs
  at least 1536Mi.

**Confirm before any remediation (CONFIRM tier):**

If the investigation points to a stuck pod that can be safely restarted, the SRE
will ask your confirmation before running:

```bash
kubectl --kubeconfig ~/.kube/homelab.yaml delete pod <pod-name> -n <namespace>
```

It will not run this without your explicit approval. One action at a time. It
re-checks after each action before suggesting the next step.

**If a structural fix is needed:**

The SRE hands off to the orchestrator path (section 4). It describes the exact
manifest or Helm values change needed. It does not run `kubectl apply` or `helm
upgrade` against an ArgoCD-managed resource.

---

## 8. Safety Model

### Two kubeconfigs

| Config | Path | When to use |
|--------|------|------------|
| Restricted | `~/.kube/homelab-claude.yaml` | All read operations: `get`, `describe`, `top`, `events`, `explain`. No logs, no secrets, no write. |
| Admin | `~/.kube/homelab.yaml` | Pod logs, live remediation (delete pod/job/lease, rollout restart), ArgoCD application reads. |

Never bare `kubectl` or `helm`. Plain commands without `--kubeconfig` or
`KUBECONFIG=` connect to the work AWS EKS cluster, not the homelab. The
`protect-cluster.sh` hook blocks these at the tool level.

**WSL DNS fallback:** if `api.k8s.rommelporras.com` does not resolve (AdGuard
down, or WSL not using cluster DNS), append the direct VIP:

```bash
kubectl --kubeconfig ~/.kube/homelab-claude.yaml \
  --server=https://10.10.30.10:6443 \
  get nodes
```

The VIP `10.10.30.10` is a SAN on the API cert; TLS validates.

### Remediation tiers

**AUTO - no confirmation required (read-only):**
- `kubectl get`, `describe`, `top`, `events`, `explain`
- `kubectl logs` (admin kubeconfig)
- `helm list`, `helm status`, `helm get`
- `curl` the Prometheus/Alertmanager APIs
- `jq`, `grep`, `awk` parsing of any of the above

**CONFIRM - ask before each action (GitOps-safe live changes):**
- `kubectl delete pod <name>` - restarts a single pod
- `kubectl delete job <name>` - clears a completed or stuck Job
- `kubectl delete lease <name>` - forces leader re-election
- `kubectl rollout restart deployment|statefulset|daemonset`
- `kubectl annotate application ... argocd.argoproj.io/refresh=hard`
- ArgoCD `app sync <app> --core` for manual-sync apps (via `kubectl exec -n argocd statefulset/argocd-application-controller -- argocd app sync <app> --core`)

**NEVER - hook-blocked, no exceptions:**
- `kubectl delete pvc` or `kubectl delete statefulset` (without `--cascade=orphan`)
- `helm uninstall`
- `kubectl delete --all` (any resource type)
- `kubeadm reset`
- `kubectl get secret -o ...` or `kubectl describe secret`
- Bare `kubectl` or `helm`
- `rm -rf`

### What the hooks block

Two `preToolUse` hooks run on every tool call:

**`protect-cluster.sh`** (all three agents, fires on `execute_bash`):
- Blocks bare `kubectl` or `helm` without `--kubeconfig` or `KUBECONFIG=`
- Blocks `kubectl get/describe secret -o json|yaml|jsonpath`
- Blocks destructive deletes: PVCs, StatefulSets, `--all`, `--cascade`
- Blocks `kubectl exec`, `kubectl cp`, `kubectl port-forward` (exception: `kubectl exec -n argocd statefulset/argocd-application-controller -- argocd app sync|get|list --core` is allowed as a narrow carve-out for the verify-sync skill)
- Blocks `helm uninstall`, `helm delete`
- Blocks `kubeadm reset`
- Blocks recursive `rm -rf`
- Git write operations (`git add`, `git commit`, `git push`, `git tag`) are NOT
  blocked here - enforcement moved to agent config level. `homelab-sre` and
  `homelab-deploy` deny git write commands via their `deniedCommands` lists.
  `homelab-orchestrator` is permitted to commit/push and requires your approval.

**`scan-write-content.sh`** (`homelab-deploy` only, fires on `fs_write`):
- Blocks any file write that contains a PEM private key header
- Blocks AWS access key IDs (`AKIA[0-9A-Z]{16}`)
- Blocks GitHub tokens (`gh[pousr]_...`)
- Blocks GitLab tokens (`glpat-...`)
- Blocks Anthropic API keys (`sk-ant-...`)
- Blocks OpenAI project keys (`sk-proj-...`)

### Secret handling

No secret values flow through the model. Agents use `op://Kubernetes/<item>/<field>`
references in manifests; the actual values stay in 1Password and are injected at
runtime through the Vault/ESO pipeline. The `homelab-deploy` agent's write paths
deny `*secret*`, `*.key`, `*.pem`, and kubeconfig paths at the `fs_write` tool
config level.

The only narrow exception: `homelab-sre` reads pod logs via the admin kubeconfig.
Logs occasionally contain secrets - this is a conscious tradeoff that mirrors the
emergency runbook where humans already read logs via admin.

### git operations

Only `homelab-orchestrator` can run git write operations. `homelab-sre` and
`homelab-deploy` have `git add`, `git commit`, and `git push` in their
`deniedCommands` lists. Even within the orchestrator, git write operations require
your explicit approval - the orchestrator does not auto-commit.

---

## 9. Reference Tables

### Agents

| Agent | Model | Shortcut | Write surface | Key denied operations |
|-------|-------|----------|--------------|----------------------|
| `homelab-orchestrator` | claude-sonnet-5 | `ctrl+shift+h` | git (with approval) | `kubectl apply/delete/patch`, `helm install/upgrade`, `git push --force` |
| `homelab-sre` | claude-sonnet-5 | `ctrl+shift+s` | live cluster (CONFIRM tier only) | `delete pvc/statefulset`, `helm uninstall`, `git add/commit/push`, `get secret -o` |
| `homelab-deploy` | claude-sonnet-5 | `ctrl+shift+d` | `manifests/**`, `helm/**` | `kubectl apply/delete/patch`, `helm install/upgrade/uninstall`, `git add/commit/push` |

### Skills

| Skill | Trigger (example) | Agent |
|-------|------------------|-------|
| `homelab-alert-triage` | "investigate alerts" | homelab-sre |
| `commit` | "commit changes" | homelab-orchestrator |
| `ship` | "cut a release" | homelab-orchestrator |
| `verify-sync` | "did it deploy" | homelab-orchestrator, homelab-sre |
| `audit-cluster` | "audit cluster" | homelab-sre |
| `audit-security` | "scan for secrets" | homelab-orchestrator, homelab-deploy |
| `audit-docs` | "audit docs" | homelab-orchestrator |

### Steering files

| File | Scope | What it enforces | Loaded by |
|------|-------|-----------------|-----------|
| `steering/cluster-access.md` | global agents | Kubeconfig table, full command forms, WSL DNS fallback, log/secret rules | all three |
| `steering/gitops.md` | global agents | ArgoCD source of truth, selfHeal, normal change flow, manual-sync apps | all three |
| `steering/remediation-safety.md` | global agents | AUTO/CONFIRM/NEVER tiers, Longhorn PVC safety, golden rules | orchestrator, sre |
| `steering/conventions.md` | global agents | Cluster layout, repo structure, secrets pipeline, commit format, homelab gotchas | all three |
| `steering/engineering.md` | global agents | Plan before building, evidence over assertions, systematic debugging | all three |
| `steering/manifests.md` | `manifests/**` | securityContext requirements, resources.limits, namespace field, automountServiceAccountToken | sre, deploy |

### Hooks

| Hook | Matcher | Runs on | Purpose |
|------|---------|---------|---------|
| `protect-cluster.sh` | `execute_bash` | all three agents | Block bare kubectl/helm, secret exposure, destructive deletes, exec/cp/port-forward (except ArgoCD controller exec for verify-sync), helm uninstall, kubeadm reset, recursive rm |
| `scan-write-content.sh` | `fs_write` | homelab-deploy | Block hardcoded secrets (private keys, AWS keys, GitHub/GitLab/Anthropic/OpenAI tokens) in any file write |

---

## 10. Further Reading

- **[`.kiro/README.md`](../.kiro/README.md)** - config reference: agent family table, safety summary, full contents tree
- **[`docs/plans/2026-08-14-kiro-homelab-agents-design.md`](plans/2026-08-14-kiro-homelab-agents-design.md)** - design spec: motivation (the live Loki investigation), architecture decisions, write-surface split rationale, acceptance criteria
- **[`docs/runbooks/alert-index.md`](runbooks/alert-index.md)** - alert anchor index that alert-triage cross-references
- **[`docs/context/Security.md`](context/Security.md)** - documented security exceptions that audit-cluster and audit-security reference for accepted-risk lookups
