---
name: audit-docs
description: |
  Triggered by: "audit docs", "check docs accuracy", "docs drift", "documentation
  audit", "are docs current", "check documentation". Audits documentation files
  against current cluster state: VERSIONS.md, docs/context/*.md frontmatter and
  content, rebuild/README, todo/README, root README, CLAUDE.md, broken links, and
  CHANGELOG. Reports issues then waits for "fix it" or "apply" approval before
  making any changes. Includes an optional deep mode that verifies every claim
  against live cluster state.
---

# audit-docs

Audit documentation files against current cluster state. Report issues, then fix
on user approval.

**Audit is always read-only.** Changes are only applied after explicit user approval.

## Usage

- Say "audit docs" (or any trigger phrase) - audit and report all issues (read-only)
- Say "fix it" or "apply" - apply fixes after reviewing the report

## Scope

| File/Directory | What is Checked | Auto-fixable? |
|----------------|----------------|---------------|
| `docs/context/*.md` | Frontmatter dates, content accuracy | Yes |
| `VERSIONS.md` | Last Updated date, version accuracy, HTTPRoutes, container images | Yes |
| `docs/reference/CHANGELOG.md` | Recent entries exist | No (template only) |
| `docs/rebuild/README.md` | Release timeline, component versions, key files tree, 1Password items | Yes |
| `docs/todo/README.md` | Release mapping table, phase index, namespace strategy | Yes |
| `README.md` (root) | Services list matches current deployments | Yes |
| `CLAUDE.md` | Repo structure tree, documentation guide table | Yes |
| `ansible/README.md` | Related documentation links | Yes |
| All `.md` files | Broken internal links (references to deleted/moved files) | Yes |

## Step 1 - Gather current state

```bash
# Current date
date +%Y-%m-%d

# Kubernetes version
kubectl --kubeconfig ~/.kube/homelab-claude.yaml version --short 2>/dev/null | grep Server

# Node count
kubectl --kubeconfig ~/.kube/homelab-claude.yaml get nodes --no-headers | wc -l

# Namespaces
kubectl --kubeconfig ~/.kube/homelab-claude.yaml get namespaces --no-headers | awk '{print $1}'

# Helm releases with versions (NAME, NAMESPACE, CHART)
KUBECONFIG=~/.kube/homelab.yaml helm list -A --no-headers 2>/dev/null | awk '{print $1, $2, $9}'

# HTTPRoutes
kubectl --kubeconfig ~/.kube/homelab-claude.yaml get httproute -A --no-headers 2>/dev/null

# Non-Helm container images (all pods)
kubectl --kubeconfig ~/.kube/homelab-claude.yaml get pods -A \
  -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{range .spec.containers[*]}{.image}{","}{end}{"\n"}{end}' \
  2>/dev/null

# Static pods (kube-vip, etc.)
kubectl --kubeconfig ~/.kube/homelab-claude.yaml get pods -n kube-system \
  -o jsonpath='{range .items[?(@.metadata.ownerReferences[0].kind=="Node")]}{.metadata.name}{"\t"}{range .spec.containers[*]}{.image}{end}{"\n"}{end}' \
  2>/dev/null

# Manifest directories (for cross-referencing Conventions.md)
ls -d manifests/*/

# Ollama model list requires manual verification (exec is outside the agent safety model):
# run `kubectl --kubeconfig ~/.kube/homelab.yaml exec -n ai deploy/ollama -- ollama list`
# yourself if needed.

# Rebuild guide files
ls docs/rebuild/

# Completed phase files
ls docs/todo/completed/

# Broken internal links - find all markdown link targets and check they exist
grep -rhoP '\]\((?!https?://|#|mailto:)([^)]+)\)' \
  docs/ CLAUDE.md README.md ansible/README.md 2>/dev/null \
  | sed 's/\](//' | sed 's/)//' | sort -u
# Verify each target file exists (resolve relative to the source file's directory)
```

## Step 2 - Audit files

**VERSIONS.md:**
- Compare `Last Updated:` with today's date
- Compare documented versions against `KUBECONFIG=~/.kube/homelab.yaml helm list -A`
- Check Kubernetes version matches cluster
- Check Version History has entries for recent significant changes

**docs/context/*.md:**
- Check `updated:` frontmatter dates - only flag as stale if **older than 14 days**.
  Under 14 days is acceptable if content is accurate.
- Compare content against cluster reality:

| File | Check Against |
|------|---------------|
| `_Index.md` | Current phase, K8s version |
| `Cluster.md` | Node count, namespaces |
| `Conventions.md` | `manifests/` directory tree matches actual `ls -d manifests/*/`; rebuild guide range matches actual files in `docs/rebuild/` |
| `Gateway.md` | HTTPRoutes, exposed services |
| `Networking.md` | VIPs, DNS IPs |
| Others | Relevant cluster state |

**docs/rebuild/README.md:**
- Release timeline table matches actual files in `docs/rebuild/` (every `v*.md` file should appear)
- Component versions table matches cluster images (from pod image jsonpath)
- Key files tree matches actual manifest directories (from `ls -d manifests/*/`)
- 1Password items table has entries for all secrets referenced in manifests

**docs/todo/README.md:**
- Release mapping shows correct latest release and status
- Phase index lists all completed phases (cross-check against `docs/todo/completed/`)
- Namespace strategy table matches current namespaces

**README.md (root):**
- Services list matches current deployments (cross-check against Helm releases and non-Helm manifests)

**VERSIONS.md (deeper checks):**
- Compare Home Services / non-Helm component versions against actual running container images (not just Helm chart versions)
- HTTPRoutes table matches `kubectl --kubeconfig ~/.kube/homelab-claude.yaml get httproute -A`
- Ollama models list matches `ollama list` output (if Ollama section exists)

**CLAUDE.md:**
- Repository structure tree matches actual directories/files (cross-check `ls` against the tree)
- Documentation guide table links point to files that exist
- Common commands section is accurate

**ansible/README.md:**
- Related documentation links point to files that exist

**Broken internal links (all `.md` files):**
- Extract all relative markdown links `](path)` from docs/, CLAUDE.md, README.md, ansible/README.md
- Resolve each link relative to the source file's directory
- Flag any links where the target file does not exist
- Ignore external URLs (`https://`), anchors (`#`), and `mailto:` links

**docs/reference/CHANGELOG.md:**
- Check if significant recent commits have entries
- Significant = new component, architecture change, namespace, bug fix with lessons

## Step 3 - Generate audit report

**IMPORTANT:** This step is READ-ONLY. Do not make any changes.

**Report format:**

```
Documentation Audit Report
==========================
Date: YYYY-MM-DD

=== VERSIONS.md ===
Last Updated: 2026-01-22  [current/stale]
Kubernetes: v1.35.0  [matches/mismatch]
Helm versions: [All match / list mismatches]
Container images: [All match / list mismatches]
HTTPRoutes: [All match / list mismatches]
Ollama models: [All match / list mismatches]

=== docs/context/ ===
Dates: [All current / list stale files]
Content:
  Gateway.md: [WARNING] URL mismatch (homepage.k8s -> portal.k8s)
  Cluster.md: [WARNING] Missing namespace "home"
  Conventions.md: [WARNING] manifests/ tree missing "karakeep/"

=== docs/rebuild/README.md ===
Release timeline: [All files present / list missing]
Component versions: [Match cluster / list mismatches]
Key files tree: [WARNING] Missing manifests/karakeep/
1Password items: [Complete / list missing]

=== docs/todo/README.md ===
Release mapping: [Current / stale]
Phase index: [All completed phases listed / list missing]
Namespace strategy: [Matches cluster / list mismatches]

=== README.md (root) ===
Services list: [Matches deployments / list mismatches]

=== CLAUDE.md ===
Repo structure tree: [Matches / list mismatches]
Documentation guide links: [All exist / list broken]

=== ansible/README.md ===
Related documentation links: [All exist / list broken]

=== Broken Internal Links ===
[No broken links found] or [list broken links with source file]

=== CHANGELOG.md ===
[Current] or [list missing entries]

=== Summary ===
Issues found: N
  1. [Gateway.md] Fix URL: homepage.k8s -> portal.k8s
  2. [Cluster.md] Add namespace: home
  3. [Conventions.md] Add karakeep/ to manifests/ tree

Say "fix it" or "apply" to fix these issues.
```

**If no issues:**

```
Documentation Audit Report
==========================
Date: YYYY-MM-DD

=== VERSIONS.md ===
Up to date (versions, HTTPRoutes, container images all match)

=== docs/context/ ===
All files current and accurate

=== docs/rebuild/README.md ===
Timeline, versions, tree, and 1Password items all current

=== docs/todo/README.md ===
Release mapping, phase index, and namespaces all current

=== README.md (root) ===
Services list matches cluster

=== CLAUDE.md ===
Repo structure and documentation links all current

=== ansible/README.md ===
Related documentation links all exist

=== Broken Internal Links ===
No broken links found

=== CHANGELOG.md ===
Current

No issues found. Documentation matches cluster state.
```

## Step 4 - Wait for approval

After the report:
1. **DO NOT make any changes**
2. End with: `Say "fix it" or "apply" to fix these issues.`
3. Wait for user response

**Valid approval phrases:** "fix it", "apply", "apply fixes", "yes", "do it"

## Step 5 - Apply fixes (after approval)

When user approves:

**Auto-fix these:**
- Update `updated:` dates in frontmatter (only if >14 days stale OR content was changed)
- Update `Last Updated:` in VERSIONS.md
- Fix content mismatches (URLs, IPs, names)
- Add missing items to simple lists/tables

**DO NOT auto-fix (provide template only):**
- CHANGELOG prose entries
- VERSIONS.md Version History entries
- New documentation sections requiring context

**After fixing:**
```bash
git diff docs/context/ VERSIONS.md docs/reference/CHANGELOG.md \
  docs/rebuild/README.md docs/todo/README.md README.md CLAUDE.md ansible/README.md
```

Report what was fixed and what needs manual attention.

## Step 6 - Templates for manual entries

**CHANGELOG entry template:**
```
CHANGELOG Entry Needed (manual):
================================
Date: [Today]
Suggested Title: [Phase X.X: Description]

Components Changed:
- [What changed]

Add to docs/reference/CHANGELOG.md
```

**VERSIONS.md history template:**
```
Version History Entry Needed (manual):
======================================
| [Date] | [Description of change] |

Add to VERSIONS.md "Version History" section.
```

## Quick reference

| Phase | Action | Changes Files? |
|-------|--------|----------------|
| Audit | Gather state, compare, report | No |
| Approval | Wait for "fix it" or "apply" | No |
| Fix | Apply identified changes | Yes |

## Important rules

1. **Audit is read-only** - Never change files during audit
2. **Wait for explicit approval** - "fix it", "apply", "yes", or "do it"
3. **Fix what is auto-fixable** - Dates, URLs, IPs, simple lists
4. **Template for prose** - Never auto-generate CHANGELOG entries
5. **Report what changed** - Show git diff after fixing
6. **Never bare kubectl or helm** - Always use `kubectl --kubeconfig ~/.kube/homelab-claude.yaml` or `KUBECONFIG=~/.kube/homelab.yaml helm`

---

## Deep mode

Run deep mode when docs accuracy is critical (after major infrastructure changes) or
when the standard audit is insufficient. Deep mode verifies every factual claim
against live cluster state - nothing is trusted at face value.

**Trigger:** User says "deep audit docs", "deep docs audit", or "verify all docs".

### Deep mode rules

1. **Never trust what a doc says** - verify every claim against the cluster or codebase
2. **Evidence before assertions** - every finding must include the command output that proves it
3. **Report only** - do NOT fix anything. The user reviews and decides what to fix
4. **Use restricted kubeconfig for most reads** - `kubectl --kubeconfig ~/.kube/homelab-claude.yaml`
5. **Use admin kubeconfig for ArgoCD namespace** - `kubectl --kubeconfig ~/.kube/homelab.yaml` (restricted RBAC cannot access argocd namespace)
6. **Counts = cluster state, not file count** - "34 ExternalSecrets" means 34 deployed in cluster, not 34 YAML files in Git. Always verify counts against `kubectl get`, never `ls | wc -l`
7. **git tag may be blocked** - use `git log` (allowed) but `git tag -l` may be blocked by hooks. Use `ls .git/refs/tags/` as fallback

### Deep mode verification groups

Kiro can run these sequentially or spawn homelab-sre subagents for each group.

#### Group 1a: Security + Monitoring docs

Read `docs/context/Security.md` and `docs/context/Monitoring.md`. For each file:

1. Extract ALL numerical claims: namespace counts, policy counts, ExternalSecret counts,
   ResourceQuota counts, PSS coverage ratios, alert counts, probe counts
2. Verify EVERY count against the cluster (not against file counts):

```bash
# CiliumNetworkPolicy count
kubectl --kubeconfig ~/.kube/homelab.yaml get ciliumnetworkpolicies -A --no-headers | wc -l

# CiliumNP namespace coverage
kubectl --kubeconfig ~/.kube/homelab.yaml get ciliumnetworkpolicies -A \
  -o custom-columns=NS:.metadata.namespace --no-headers | sort -u | wc -l

# ExternalSecret count
kubectl --kubeconfig ~/.kube/homelab.yaml get externalsecrets -A --no-headers | wc -l

# ESO namespace count
kubectl --kubeconfig ~/.kube/homelab.yaml get externalsecrets -A \
  -o custom-columns=NS:.metadata.namespace --no-headers | sort -u | wc -l

# ESO-enabled namespaces
kubectl --kubeconfig ~/.kube/homelab-claude.yaml get namespaces \
  -l eso-enabled=true --no-headers | wc -l

# ResourceQuota count
kubectl --kubeconfig ~/.kube/homelab-claude.yaml get resourcequotas -A --no-headers | wc -l

# PSS labeled namespaces
kubectl --kubeconfig ~/.kube/homelab-claude.yaml get namespaces \
  -l pod-security.kubernetes.io/enforce --no-headers | wc -l

# Total namespaces
kubectl --kubeconfig ~/.kube/homelab-claude.yaml get namespaces --no-headers | wc -l

# PDB count
kubectl --kubeconfig ~/.kube/homelab-claude.yaml get pdb -A --no-headers | wc -l

# PrometheusRule alert count per file
grep -c 'alert:' manifests/monitoring/alerts/*.yaml

# ServiceMonitor count
kubectl --kubeconfig ~/.kube/homelab.yaml get servicemonitors -A --no-headers | wc -l

# Probe count
kubectl --kubeconfig ~/.kube/homelab.yaml get probes.monitoring.coreos.com \
  -n monitoring --no-headers | wc -l
```

3. Verify schedules: compare documented CronJob schedules against:
```bash
kubectl --kubeconfig ~/.kube/homelab.yaml get cronjobs -A \
  -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,SCHEDULE:.spec.schedule,TZ:.spec.timeZone' \
  --no-headers
```

4. Verify version numbers against running pod images
5. Classify each claim as VERIFIED / STALE / WRONG / MISSING

Report ONLY issues (STALE/WRONG/MISSING). If a file is clean, say "No issues".

#### Group 1b: All other context docs

Read these `docs/context/` files: `_Index.md`, `Architecture.md`, `Backups.md`,
`Cluster.md`, `Conventions.md`, `ExternalServices.md`, `Gateway.md`, `Networking.md`,
`Secrets.md`, `Storage.md`, `UPS.md`, `Upgrades.md`.

For each file:
1. Extract factual claims: versions, IPs, hostnames, namespace names, file paths,
   component names, port numbers
2. Verify against cluster:

```bash
# Namespace list
kubectl --kubeconfig ~/.kube/homelab-claude.yaml get namespaces \
  -o custom-columns=NAME:.metadata.name --no-headers | sort

# HTTPRoutes
kubectl --kubeconfig ~/.kube/homelab-claude.yaml get httproute -A --no-headers

# Verify ExternalSecrets exist in cluster (not just in Git)
kubectl --kubeconfig ~/.kube/homelab.yaml get externalsecrets -A \
  -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name' --no-headers
```

3. For `_Index.md` specifically: verify current phase and latest release version
4. For `Secrets.md` specifically: cross-reference Vault KV paths table against deployed
   ExternalSecrets. Flag entries where the ExternalSecret manifest exists in Git but
   is NOT deployed in the cluster (no ArgoCD app manages it).

Also check frontmatter dates - flag any older than 14 days from today.
Report ONLY issues (STALE/WRONG/MISSING).

#### Group 2: Versions and images verification

Read `VERSIONS.md` fully. For every version listed:

1. Helm charts: compare against `KUBECONFIG=~/.kube/homelab.yaml helm list -A`
2. Container images: compare against:
```bash
kubectl --kubeconfig ~/.kube/homelab-claude.yaml get pods -A \
  -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}: {range .spec.containers[*]}{.image} {end}{"\n"}{end}'
```
3. Static pods:
```bash
kubectl --kubeconfig ~/.kube/homelab-claude.yaml get pods -n kube-system \
  -o jsonpath='{range .items[?(@.metadata.ownerReferences[0].kind=="Node")]}{.metadata.name}: {range .spec.containers[*]}{.image}{end}{"\n"}{end}'
```
4. HTTPRoutes: compare documented routes against:
```bash
kubectl --kubeconfig ~/.kube/homelab-claude.yaml get httproute -A --no-headers
```
5. Kubernetes version:
```bash
kubectl --kubeconfig ~/.kube/homelab-claude.yaml version -o json | jq '.serverVersion.gitVersion'
```
6. Check "Last Updated" date

Report as a table: component | documented version | actual version | status (MATCH/MISMATCH).
Only report MISMATCHES.

#### Group 3: CHANGELOG, phases, rebuild, and broken links

**CHANGELOG verification:**
1. Read `docs/reference/CHANGELOG.md`
2. Run `git log --oneline -30`
3. Check: do significant commits have CHANGELOG entries? Do dates match?
4. Check: do any entries reference removed components?

**Phase tracking:**
1. Read `docs/todo/README.md`
2. Cross-reference completed phases: `ls docs/todo/completed/`
3. Every `.md` file in `completed/` should appear in the Completed table
4. Every file in the Completed table should exist in `completed/`
5. Check release mapping: use `ls .git/refs/tags/` as fallback if `git tag` is blocked
6. Verify phase statuses match reality

**Rebuild guide:**
1. Read `docs/rebuild/README.md`
2. Cross-reference: `ls docs/rebuild/*.md`
3. Every rebuild guide file should appear in the timeline table
4. Check component versions table against running images (spot-check 5 key ones)

**Broken internal links:**
```bash
grep -rhoP '\]\((?!https?://|#|mailto:)([^)]+)\)' \
  docs/ CLAUDE.md README.md 2>/dev/null \
  | sed 's/\](//' | sed 's/)//' | sort -u
```
For each relative link, resolve it relative to the source file's directory.
Verify the target exists with `ls` or `test -f`. Report any broken links.

#### Group 4: CLAUDE.md, Conventions, README, and memory

**CLAUDE.md:**
1. Read `CLAUDE.md` fully
2. Verify every file path referenced (scripts/, manifests/, docs/ references)
3. GitOps section: verify against:
```bash
kubectl --kubeconfig ~/.kube/homelab.yaml get applications -n argocd --no-headers | wc -l
```
4. AppProject list: verify against:
```bash
kubectl --kubeconfig ~/.kube/homelab.yaml get appprojects -n argocd \
  -o custom-columns=NAME:.metadata.name --no-headers
```
5. "Still on Helm" count: verify against:
```bash
KUBECONFIG=~/.kube/homelab.yaml helm list -A --no-headers | wc -l
```
6. Every gotcha: check if the referenced component/file still exists

**Conventions.md:**
1. Read `docs/context/Conventions.md`
2. Repository structure tree: compare `manifests/` listing against `ls -d manifests/*/`
3. `helm/` directory listing: compare against `ls helm/`
4. Verify subdirectory descriptions are accurate

**README.md (root):**
1. Read `README.md`
2. Services list: cross-reference against deployed namespaces and pods
3. Management method mentions: should say ArgoCD/GitOps, not kubectl apply

Report as: location | claim | still valid? | evidence. Only report issues.

### Deep mode report format

```
Deep Documentation Audit Report
================================
Date: YYYY-MM-DD

=== Security + Monitoring (Group 1a) ===
[table of findings - counts, schedules, versions]

=== Other Context Docs (Group 1b) ===
[table of findings - versions, paths, claims]

=== Versions and Images (Group 2) ===
[table of findings - version comparisons]

=== CHANGELOG, Phases and Links (Group 3) ===
[findings - missing entries, broken links, phase status]

=== CLAUDE.md, Conventions and Memory (Group 4) ===
[findings - stale rules, wrong paths]

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

After the deep mode report, end with:

```
Say "fix it" to apply corrections, or review individual items first.
```

Deep mode is report-only. Do NOT fix anything automatically.
