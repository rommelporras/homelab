---
name: audit-docs-deep
description: Deep documentation audit that verifies every claim against live cluster state using parallel agents. Use when docs accuracy is critical or after major infrastructure changes.
allowed-tools: Agent, Bash, Read, Grep, Glob
---

Deep audit of all documentation against live cluster state. Every factual claim is verified - nothing is trusted at face value.

## Rules

1. **NEVER trust what a doc says** - verify every claim against the cluster or codebase
2. **Evidence before assertions** - every finding must include the command output that proves it
3. **Report only** - do NOT fix anything. The user reviews and decides what to fix
4. **Use kubectl-homelab and helm-homelab** - not plain kubectl/helm (wrong cluster)
5. **Use kubectl-admin for ArgoCD** - kubectl-homelab RBAC can't access argocd namespace
6. **Counts = cluster state, not file count** - "34 ExternalSecrets" means 34 deployed in cluster, not 34 YAML files in Git. Always verify counts against `kubectl get`, never `ls | wc -l`
7. **git commands may be blocked** - use `git log` (allowed) but `git tag -l` may be blocked by hooks. Use `ls .git/refs/tags/` as fallback

## Step 1 - Launch parallel verification agents

Launch all 5 agents in parallel using background mode. Each agent independently verifies a different documentation area.

### Agent 1a: Security + Monitoring docs (model: sonnet)

These are the densest files with the most verifiable claims (counts, schedules, policy coverage).

```
Read docs/context/Security.md and docs/context/Monitoring.md. For each file:
1. Extract ALL numerical claims: namespace counts, policy counts, ExternalSecret counts,
   ResourceQuota counts, PSS coverage ratios, alert counts, probe counts
2. Verify EVERY count against the cluster (not against file counts):
   - CiliumNetworkPolicy count: kubectl-admin get ciliumnetworkpolicies -A --no-headers | wc -l
   - CiliumNP namespace coverage: kubectl-admin get ciliumnetworkpolicies -A -o custom-columns=NS:.metadata.namespace --no-headers | sort -u | wc -l
   - ExternalSecret count: kubectl-admin get externalsecrets -A --no-headers | wc -l
   - ESO namespace count: kubectl-admin get externalsecrets -A -o custom-columns=NS:.metadata.namespace --no-headers | sort -u | wc -l
   - ESO-enabled namespaces: kubectl-homelab get namespaces -l eso-enabled=true --no-headers | wc -l
   - ResourceQuota count: kubectl-homelab get resourcequotas -A --no-headers | wc -l
   - PSS labeled namespaces: kubectl-homelab get namespaces -l pod-security.kubernetes.io/enforce --no-headers | wc -l
   - Total namespaces: kubectl-homelab get namespaces --no-headers | wc -l
   - PDB count: kubectl-homelab get pdb -A --no-headers | wc -l
   - PrometheusRule alert count per file: grep -c 'alert:' in each alerts YAML
   - ServiceMonitor count: kubectl-admin get servicemonitors -A --no-headers | wc -l
   - Probe count: kubectl-admin get probes.monitoring.coreos.com -n monitoring --no-headers | wc -l
3. Verify schedules: compare documented CronJob schedules against:
   kubectl-admin get cronjobs -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,SCHEDULE:.spec.schedule,TZ:.spec.timeZone' --no-headers
4. Verify version numbers against running pod images
5. Classify each claim as VERIFIED / STALE / WRONG / MISSING

Report ONLY issues (STALE/WRONG/MISSING). If a file is clean, say "No issues".
```

### Agent 1b: All other context docs (model: sonnet)

```
Read these docs/context/ files: _Index.md, Architecture.md, Backups.md, Cluster.md,
Conventions.md (skip - covered by Agent 4), ExternalServices.md, Gateway.md,
Networking.md, Secrets.md, Storage.md, UPS.md, Upgrades.md

For each file:
1. Extract factual claims: versions, IPs, hostnames, namespace names, file paths,
   component names, port numbers
2. Verify against cluster:
   - Namespace list: kubectl-homelab get namespaces -o custom-columns=NAME:.metadata.name --no-headers | sort
   - HTTPRoutes: kubectl-homelab get httproute -A --no-headers
   - File paths: use Glob to verify they exist
   - Version numbers: cross-check against running pod images
   - Vault KV paths in Secrets.md: verify ExternalSecrets exist in cluster (not just in Git)
     kubectl-admin get externalsecrets -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name' --no-headers
3. For _Index.md specifically: verify current phase and latest release version
4. For Secrets.md specifically: cross-reference Vault KV paths table against deployed
   ExternalSecrets. Flag entries where the ExternalSecret manifest exists in Git but
   is NOT deployed in the cluster (no ArgoCD app manages it).

Also check frontmatter dates - flag any older than 14 days from today.
Report ONLY issues (STALE/WRONG/MISSING).
```

### Agent 2: Versions and images verification (model: haiku)

```
Read VERSIONS.md fully. For every version listed:
1. Helm charts: compare against helm-homelab list -A
2. Container images: compare against
   kubectl-homelab get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}: {range .spec.containers[*]}{.image} {end}{"\n"}{end}'
3. Static pods:
   kubectl-homelab get pods -n kube-system -o jsonpath='{range .items[?(@.metadata.ownerReferences[0].kind=="Node")]}{.metadata.name}: {range .spec.containers[*]}{.image}{end}{"\n"}{end}'
4. HTTPRoutes: compare documented routes against kubectl-homelab get httproute -A --no-headers
5. Kubernetes version: kubectl-homelab version -o json | check serverVersion.gitVersion
6. Check "Last Updated" date

Report as a table: component | documented version | actual version | status (MATCH/MISMATCH)
Only report MISMATCHES.
```

### Agent 3: CHANGELOG, phases, rebuild, and broken links (model: sonnet)

```
Part A - CHANGELOG verification:
1. Read docs/reference/CHANGELOG.md
2. Run git log --oneline -30
3. Check: do significant commits have CHANGELOG entries? Do dates match?
4. Check: do any entries reference removed components?

Part B - Phase tracking:
1. Read docs/todo/README.md
2. Cross-reference completed phases: ls docs/todo/completed/ (list all files)
3. Every .md file in completed/ should appear in the Completed table
4. Every file in the Completed table should exist in completed/
5. Check release mapping: use ls .git/refs/tags/ as fallback if git tag is blocked
6. Verify phase statuses match reality (which are completed, in-progress, planned)

Part C - Rebuild guide:
1. Read docs/rebuild/README.md
2. Cross-reference: ls docs/rebuild/*.md
3. Every rebuild guide file should appear in the timeline table
4. Check component versions table against running images (spot-check 5 key ones)

Part D - Broken internal links:
1. Run: grep -rhoP '\]\((?!https?://|#|mailto:)([^)]+)\)' docs/ CLAUDE.md README.md 2>/dev/null | sed 's/\](//' | sed 's/)//' | sort -u
2. For each relative link, resolve it relative to the source file's directory
3. Use Glob or ls to verify the target exists
4. Report any broken links

Report issues only.
```

### Agent 4: CLAUDE.md, Conventions, README, and memory (model: sonnet)

```
Part A - CLAUDE.md (project root):
1. Read CLAUDE.md fully
2. Verify every file path with Glob (scripts/, manifests/, docs/ references)
3. GitOps section: verify against kubectl-admin get applications -n argocd --no-headers | wc -l
4. AppProject list: verify against kubectl-admin get appprojects -n argocd -o custom-columns=NAME:.metadata.name --no-headers
5. "Still on Helm" count: verify against helm-homelab list -A --no-headers | wc -l
6. Every gotcha: check if the referenced component/file still exists
7. Check if "GitLab is the primary remote" matches git remote -v

Part B - Conventions.md:
1. Read docs/context/Conventions.md
2. Repository structure tree: compare manifests/ listing against ls -d manifests/*/
3. helm/ directory listing: compare against ls helm/
4. Verify subdirectory descriptions are accurate (e.g., monitoring/ comment lists subdirs)
5. Deploy workflow section: verify commands reference correct tools

Part C - README.md (root):
1. Read README.md
2. Services list: cross-reference against deployed namespaces and pods
3. Management method mentions: should say ArgoCD/GitOps, not kubectl apply

Part D - Memory files:
1. Read .claude/projects/-home-wsl-personal-homelab/memory/MEMORY.md
2. For each memory file referenced, read it and check if factual claims are still accurate
3. Check version numbers, image tags, file paths mentioned in memory files
4. Flag stale entries (outdated facts that could mislead future sessions)

Report as: location | claim | still valid? | evidence
Only report issues.
```

## Step 2 - Collect and compile results

After all 5 agents complete, compile their findings into a single report.

## Step 3 - Generate report

```
Deep Documentation Audit Report
================================
Date: YYYY-MM-DD
Agents: 5 parallel checks completed

=== Security + Monitoring (Agent 1a) ===
[table of findings - counts, schedules, versions]

=== Other Context Docs (Agent 1b) ===
[table of findings - versions, paths, claims]

=== Versions & Images (Agent 2) ===
[table of findings - version comparisons]

=== CHANGELOG, Phases & Links (Agent 3) ===
[findings - missing entries, broken links, phase status]

=== CLAUDE.md, Conventions & Memory (Agent 4) ===
[findings - stale rules, wrong paths, memory drift]

=== Summary ===
Total claims verified: ~N
VERIFIED: N
STALE: N (need update)
WRONG: N (incorrect)
MISSING: N (undocumented)

Top priority fixes:
1. [most impactful - WRONG items first]
2. [next - STALE counts that affect security posture]
3. [next - version drift]
...
```

## Step 4 - Wait

Do NOT fix anything. End with:

```
Say "fix it" to apply corrections, or review individual items first.
```
