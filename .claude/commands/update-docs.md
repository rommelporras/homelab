# Update Documentation

Audit and update documentation files to ensure they reflect current cluster state.

## Usage

```
/update-docs              → Audit mode (report what's outdated)
/update-docs --apply      → Update dates and flag changes needing review
```

## Scope

This command audits and updates:

| File/Directory | What's Checked |
|----------------|----------------|
| `docs/context/*.md` | Frontmatter dates, content accuracy |
| `VERSIONS.md` | Last Updated date, version accuracy |
| `docs/reference/CHANGELOG.md` | Recent entries exist for changes |

## Instructions

### 1. Gather Current State

Run these commands to gather current cluster state:

```bash
# Get current date
date +%Y-%m-%d

# Get Kubernetes version
kubectl-homelab version --short 2>/dev/null | grep Server

# Get node count and status
kubectl-homelab get nodes --no-headers | wc -l

# Get namespaces
kubectl-homelab get namespaces --no-headers | awk '{print $1}'

# Get Helm releases with versions
helm-homelab list -A --no-headers 2>/dev/null | awk '{print $1, $9, $10}'

# Get Gateway/HTTPRoutes
kubectl-homelab get gateway -A --no-headers 2>/dev/null
kubectl-homelab get httproute -A --no-headers 2>/dev/null

# Get certificates
kubectl-homelab get certificate -A --no-headers 2>/dev/null
```

### 2. Audit VERSIONS.md

Read `/VERSIONS.md` and check:

**Date check:**
- Extract `Last Updated:` date from header
- Compare with today's date
- Flag if stale (> 7 days without updates during active development)

**Version accuracy:**
- Compare documented versions against `helm-homelab list -A`
- Check Kubernetes version matches `kubectl-homelab version`
- Flag any mismatches

**Version History:**
- Check if recent changes have corresponding entries in "Version History" section
- Flag if significant changes occurred but no history entry exists

### 3. Audit docs/context/ Files

For each file in `docs/context/`, check:

| File | Check |
|------|-------|
| `_Index.md` | Current phase status, Kubernetes version |
| `Cluster.md` | Node count, namespaces list |
| `Architecture.md` | HA components table matches reality |
| `Conventions.md` | Repository structure is accurate |
| `Gateway.md` | Exposed services list, HTTPRoutes |
| `Monitoring.md` | Component versions, alert routing |
| `Networking.md` | VIPs, DNS records, service URLs |
| `Secrets.md` | 1Password paths still valid |
| `Storage.md` | Longhorn settings, NFS exports |
| `UPS.md` | NUT architecture, shutdown timers |

**Frontmatter dates:**
```bash
grep -r "^updated:" docs/context/*.md
```

### 4. Audit CHANGELOG.md

Read `docs/reference/CHANGELOG.md` and check:

**Recent activity:**
- Get the date of the most recent entry
- Compare with recent git commits
- Flag if significant commits exist without CHANGELOG entry

**What counts as "significant" (needs CHANGELOG entry):**
- New component installed
- Architecture change
- New namespace created
- Configuration change with lessons learned
- Bug fix with root cause analysis

**What does NOT need CHANGELOG entry:**
- Documentation-only updates
- Date refreshes
- Minor formatting changes

### 5. Generate Audit Report

**Audit Report Format:**

```
Documentation Audit Report
==========================
Date: YYYY-MM-DD

=== VERSIONS.md ===
Last Updated: 2026-01-20  ✓ Current
Kubernetes: v1.35.0  ✓ Matches cluster
Cilium: 1.18.6  ✓ Matches helm release
Longhorn: 1.10.1  ✓ Matches helm release
Version History: Last entry 2026-01-20  ✓ Current

=== docs/context/ (10 files) ===
Date Check:
  _Index.md:       2026-01-20  ✓ Current
  Cluster.md:      2026-01-20  ✓ Current
  Gateway.md:      2026-01-15  ⚠ STALE (5 days old)

Content Check:
  Gateway.md:
    - HTTPRoutes in cluster: grafana, longhorn
    - HTTPRoutes documented: grafana
    ⚠ MISSING: longhorn HTTPRoute not documented

  Namespaces:
    In cluster: default, kube-system, monitoring, longhorn-system, cert-manager, gateway
    Documented: ✓ All namespaces documented

=== docs/reference/CHANGELOG.md ===
Most Recent Entry: January 20, 2026 — Phase 3.9: Alertmanager
Recent Commits Since: 3 commits
  - docs: update context files (no CHANGELOG needed)
  - docs: create update-docs command (no CHANGELOG needed)
✓ CHANGELOG is current

=== Summary ===
  ✓ VERSIONS.md up to date
  ✓ 8 context files up to date
  ⚠ 2 context files need attention
  ✓ CHANGELOG is current

Actions Needed:
  1. Update Gateway.md: Add longhorn HTTPRoute
  2. Update Gateway.md: Refresh date to 2026-01-20
```

### 6. Apply Updates (if --apply)

When `--apply` is specified:

**Auto-update (safe):**
- Update `updated:` dates in `docs/context/*.md` frontmatter
- Update `Last Updated:` date in `VERSIONS.md` header
- These are mechanical changes, low risk

**Flag for manual review (do NOT auto-update):**
- New namespaces to document
- New HTTPRoutes/services to add
- Version mismatches (requires verification)
- Missing CHANGELOG entries (requires prose writing)
- New components to add to VERSIONS.md

**After auto-updates:**
```bash
# Show what changed
git diff docs/context/ VERSIONS.md

# Report what needs manual attention
```

### 7. CHANGELOG Guidelines

When flagging CHANGELOG updates needed, provide:

```
CHANGELOG Entry Needed:
=======================
Date: January 21, 2026
Suggested Title: Phase 4.1: AdGuard Home Migration

Components Changed:
- AdGuard Home deployed to K8s
- New namespace: adguard
- New HTTPRoute: adguard.k8s.home.rommelporras.com

Suggested Sections:
- Milestone: AdGuard Home Running on K8s
- Files Added: manifests/adguard/*.yaml
- Key Decisions: (you fill in)
- Lessons Learned: (you fill in)

Note: CHANGELOG requires manual writing. This is a prompt, not auto-generated content.
```

### 8. VERSIONS.md History Entry

When new components are installed, suggest adding to Version History:

```
VERSIONS.md History Entry Needed:
=================================
| 2026-01-21 | Installed: AdGuard Home v0.107.x (Phase 4.1) |

Add this line to the "Version History" section at the top of the list.
```

## Checklist

**Files to audit:**
- [ ] `VERSIONS.md` - Last Updated date, version accuracy, history entries
- [ ] `docs/context/*.md` - Frontmatter dates, content accuracy
- [ ] `docs/reference/CHANGELOG.md` - Recent entries for significant changes

**Auto-update with --apply:**
- [ ] `updated:` dates in docs/context/*.md
- [ ] `Last Updated:` date in VERSIONS.md

**Manual review required:**
- [ ] New components in VERSIONS.md
- [ ] Version history entries in VERSIONS.md
- [ ] New CHANGELOG.md entries
- [ ] New content in docs/context/ files

## Example Workflow

### Before Release

```
User: /update-docs --apply

Claude: Running documentation audit...

Documentation Audit Report
==========================
Date: 2026-01-21

=== VERSIONS.md ===
Last Updated: 2026-01-20 → Updated to 2026-01-21
All versions match cluster state ✓

=== docs/context/ ===
Auto-updates applied:
- Gateway.md: date 2026-01-20 → 2026-01-21
- Monitoring.md: date 2026-01-20 → 2026-01-21

Manual review needed:
- Gateway.md: Document new longhorn HTTPRoute

=== CHANGELOG.md ===
✓ Current (last entry matches recent work)

Run `git diff` to review changes.
```

### After Major Changes

```
User: /update-docs

Claude: Running documentation audit (read-only)...

Documentation Audit Report
==========================

=== VERSIONS.md ===
⚠ Missing from Version History:
  - AdGuard Home installation (detected in helm releases)

=== CHANGELOG.md ===
⚠ Entry needed for:
  - Phase 4.1: AdGuard Home Migration
  - Last CHANGELOG entry: Jan 20 (2 days ago)
  - Significant commits since: 5

Suggested CHANGELOG entry:
[... template provided ...]

To apply safe updates, run: /update-docs --apply
```

## Important Notes

- NEVER auto-generate prose content (CHANGELOG entries, descriptions)
- ONLY auto-update dates (mechanical, safe)
- ALWAYS flag content changes for manual review
- VERSIONS.md version history entries require manual addition
- CHANGELOG.md entries require manual writing (provide templates only)
- This command is READ-SAFE by default
- Use `--apply` explicitly to make date changes
