# Audit Documentation

Audit documentation files against current cluster state. Report issues, then fix on user approval.

## Usage

```
/audit-docs              → Audit and report all issues (read-only)
"fix it" / "apply"       → User approval to apply fixes
```

No flags. Always audit first, fix only after explicit approval.

## Scope

| File/Directory | What's Checked | Auto-fixable? |
|----------------|----------------|---------------|
| `docs/context/*.md` | Frontmatter dates, content accuracy | ✓ Yes |
| `VERSIONS.md` | Last Updated date, version accuracy, HTTPRoutes, container images | ✓ Yes |
| `docs/reference/CHANGELOG.md` | Recent entries exist | ✗ No (template only) |
| `docs/rebuild/README.md` | Release timeline, component versions, key files tree, 1Password items | ✓ Yes |
| `docs/todo/README.md` | Release mapping table, phase index, namespace strategy | ✓ Yes |
| `README.md` (root) | Services list matches current deployments | ✓ Yes |
| `CLAUDE.md` | Repo structure tree, documentation guide table | ✓ Yes |
| `ansible/README.md` | Related documentation links | ✓ Yes |
| All `.md` files | Broken internal links (references to deleted/moved files) | ✓ Yes |

## Instructions

### 1. Gather Current State

```bash
# Current date
date +%Y-%m-%d

# Kubernetes version
kubectl-homelab version --short 2>/dev/null | grep Server

# Node count
kubectl-homelab get nodes --no-headers | wc -l

# Namespaces
kubectl-homelab get namespaces --no-headers | awk '{print $1}'

# Helm releases with versions (NAME, NAMESPACE, CHART)
helm-homelab list -A --no-headers 2>/dev/null | awk '{print $1, $2, $9}'

# HTTPRoutes
kubectl-homelab get httproute -A --no-headers 2>/dev/null

# Non-Helm container images (all pods)
kubectl-homelab get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{range .spec.containers[*]}{.image}{","}{end}{"\n"}{end}' 2>/dev/null

# Static pods (kube-vip, etc.)
kubectl-homelab get pods -n kube-system -o jsonpath='{range .items[?(@.metadata.ownerReferences[0].kind=="Node")]}{.metadata.name}{"\t"}{range .spec.containers[*]}{.image}{end}{"\n"}{end}' 2>/dev/null

# Manifest directories (for cross-referencing Conventions.md)
ls -d manifests/*/

# Ollama models (if ollama is deployed)
kubectl-homelab exec -n ai deploy/ollama -- ollama list 2>/dev/null

# Rebuild guide files
ls docs/rebuild/

# Completed phase files
ls docs/todo/completed/

# Broken internal links — find all markdown link targets and check they exist
# Extract relative links from all .md files and verify targets
grep -rhoP '\]\((?!https?://|#|mailto:)([^)]+)\)' docs/ CLAUDE.md README.md ansible/README.md 2>/dev/null \
  | sed 's/\](//' | sed 's/)//' | sort -u
# Manually verify each target file exists (resolve relative to the source file's directory)
```

### 2. Audit Files

**VERSIONS.md:**
- Compare `Last Updated:` with today's date
- Compare documented versions against `helm-homelab list -A`
- Check Kubernetes version matches cluster
- Check Version History has entries for recent significant changes

**docs/context/*.md:**
- Check `updated:` frontmatter dates — only flag as stale if **older than 14 days**. Under 14 days is acceptable if content is accurate.
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
- Namespace strategy table matches current namespaces (from `kubectl-homelab get namespaces`)

**README.md (root):**
- Services list matches current deployments (cross-check against Helm releases and non-Helm manifests)

**VERSIONS.md (deeper checks):**
- Compare Home Services / non-Helm component versions against actual running container images (not just Helm chart versions)
- HTTPRoutes table matches `kubectl-homelab get httproute -A`
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

### 3. Generate Audit Report

**IMPORTANT:** This step is READ-ONLY. Do not make any changes.

**Report Format:**

```
Documentation Audit Report
==========================
Date: YYYY-MM-DD

=== VERSIONS.md ===
Last Updated: 2026-01-22  ✓ Current
Kubernetes: v1.35.0  ✓ Matches
Helm versions: ✓ All match
Container images: ✓ All match
HTTPRoutes: ✓ All match
Ollama models: ✓ All match

=== docs/context/ ===
Dates: ✓ All current
Content:
  Gateway.md: ⚠ URL mismatch (homepage.k8s → portal.k8s)
  Cluster.md: ⚠ Missing namespace "home"
  Conventions.md: ⚠ manifests/ tree missing "karakeep/"

=== docs/rebuild/README.md ===
Release timeline: ✓ All files present
Component versions: ✓ Match cluster
Key files tree: ⚠ Missing manifests/karakeep/
1Password items: ✓ Complete

=== docs/todo/README.md ===
Release mapping: ✓ Current
Phase index: ✓ All completed phases listed
Namespace strategy: ✓ Matches cluster

=== README.md (root) ===
Services list: ✓ Matches deployments

=== CLAUDE.md ===
Repo structure tree: ✓ Matches
Documentation guide links: ✓ All exist

=== ansible/README.md ===
Related documentation links: ✓ All exist

=== Broken Internal Links ===
✓ No broken links found (or list broken ones)

=== CHANGELOG.md ===
✓ Current

=== Summary ===
Issues found: 3
  1. [Gateway.md] Fix URL: homepage.k8s → portal.k8s
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
✓ Up to date (versions, HTTPRoutes, container images all match)

=== docs/context/ ===
✓ All files current and accurate

=== docs/rebuild/README.md ===
✓ Timeline, versions, tree, and 1Password items all current

=== docs/todo/README.md ===
✓ Release mapping, phase index, and namespaces all current

=== README.md (root) ===
✓ Services list matches cluster

=== CLAUDE.md ===
✓ Repo structure and documentation links all current

=== ansible/README.md ===
✓ Related documentation links all exist

=== Broken Internal Links ===
✓ No broken links found

=== CHANGELOG.md ===
✓ Current

No issues found. Documentation matches cluster state.
```

### 4. Wait for Approval

After the report:
1. **DO NOT make any changes**
2. End with: `Say "fix it" or "apply" to fix these issues.`
3. Wait for user response

**Valid approval phrases:** "fix it", "apply", "apply fixes", "yes", "do it"

### 5. Apply Fixes (After Approval)

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
git diff docs/context/ VERSIONS.md docs/reference/CHANGELOG.md docs/rebuild/README.md docs/todo/README.md README.md CLAUDE.md ansible/README.md
```

Report what was fixed and what needs manual attention.

### 6. Templates for Manual Entries

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

## Quick Reference

| Phase | Action | Changes Files? |
|-------|--------|----------------|
| Audit | Gather state, compare, report | No |
| Approval | Wait for "fix it" or "apply" | No |
| Fix | Apply identified changes | Yes |

## Important Rules

1. **Audit is read-only** - Never change files during audit
2. **Wait for explicit approval** - "fix it", "apply", "yes", or "do it"
3. **Fix what's auto-fixable** - Dates, URLs, IPs, simple lists
4. **Template for prose** - Never auto-generate CHANGELOG entries
5. **Report what changed** - Show git diff after fixing
