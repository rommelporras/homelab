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
| `VERSIONS.md` | Last Updated date, version accuracy | ✓ Yes |
| `docs/reference/CHANGELOG.md` | Recent entries exist | ✗ No (template only) |

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

# Helm releases with versions
helm-homelab list -A --no-headers 2>/dev/null | awk '{print $1, $9, $10}'

# HTTPRoutes
kubectl-homelab get httproute -A --no-headers 2>/dev/null
```

### 2. Audit Files

**VERSIONS.md:**
- Compare `Last Updated:` with today's date
- Compare documented versions against `helm-homelab list -A`
- Check Kubernetes version matches cluster
- Check Version History has entries for recent significant changes

**docs/context/*.md:**
- Check `updated:` frontmatter dates
- Compare content against cluster reality:

| File | Check Against |
|------|---------------|
| `_Index.md` | Current phase, K8s version |
| `Cluster.md` | Node count, namespaces |
| `Gateway.md` | HTTPRoutes, exposed services |
| `Networking.md` | VIPs, DNS IPs |
| Others | Relevant cluster state |

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

=== docs/context/ ===
Dates: ✓ All current
Content:
  Gateway.md: ⚠ URL mismatch (homepage.k8s → portal.k8s)
  Cluster.md: ⚠ Missing namespace "home"

=== CHANGELOG.md ===
✓ Current

=== Summary ===
Issues found: 2
  1. [Gateway.md] Fix URL: homepage.k8s → portal.k8s
  2. [Cluster.md] Add namespace: home

Say "fix it" or "apply" to fix these issues.
```

**If no issues:**

```
Documentation Audit Report
==========================
Date: YYYY-MM-DD

=== VERSIONS.md ===
✓ Up to date

=== docs/context/ ===
✓ All 10 files current and accurate

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
- Update `updated:` dates in frontmatter
- Update `Last Updated:` in VERSIONS.md
- Fix content mismatches (URLs, IPs, names)
- Add missing items to simple lists/tables

**DO NOT auto-fix (provide template only):**
- CHANGELOG prose entries
- VERSIONS.md Version History entries
- New documentation sections requiring context

**After fixing:**
```bash
git diff docs/context/ VERSIONS.md docs/reference/CHANGELOG.md
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
