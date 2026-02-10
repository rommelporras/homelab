# Create Release

Create version tag, push commits and tag, and create GitHub release.

## Usage

```
/release                      → Auto-determine version from commits
/release v0.1.0               → Use explicit version, auto-generate title
/release v0.1.0 "Title Here"  → Use explicit version AND title
```

## Instructions

1. **Check Current State**
   ```bash
   git branch --show-current   # Must be on main
   git status                  # Must be clean working tree
   git log --oneline -5        # Recent commits
   git describe --tags --abbrev=0 2>/dev/null || echo "No tags yet"
   ```

   - **Must be on `main`** branch — abort if on any other branch
   - Working tree **must** be clean — abort if dirty

2. **Remote Tag Collision Check**

   Fetch latest tags from origin and verify the target version doesn't already exist:
   ```bash
   git fetch origin --tags
   git tag -l "v<VERSION>"
   ```

   If the tag already exists on remote:
   - **ABORT** immediately
   - Show: `"Error: Tag v<VERSION> already exists. Check https://github.com/rommelporras/homelab/releases"`
   - Suggest the next available version

3. **Determine Version and Title**

   **If user provided version and title** (e.g., `/release v0.1.0 "Project Setup"`):
   - Use the provided version
   - Use the provided title in tag and release

   **If user provided version only** (e.g., `/release v0.1.0`):
   - Use the provided version
   - Auto-generate title from commit analysis

   **If no version provided** (`/release`):
   - Find last tag
   - Analyze commits since last tag
   - Auto-bump based on commit types:
     - `feat:` → **minor** bump (v0.1.0 → v0.2.0)
     - `fix:` only → **patch** bump (v0.1.0 → v0.1.1)
     - `BREAKING CHANGE` → **major** bump (v0.1.0 → v1.0.0)
     - `docs:`, `chore:` only → **patch** bump
   - Auto-generate title from commit analysis

   **First release** (no previous tags):
   - Default to `v0.1.0` unless user specifies

4. **Pre-Release Checks**

   Before proceeding, scan for common release oversights:

   **Phase plan check** — find the phase plan for this release:
   ```bash
   # Search active plans for the target version (e.g., "v0.14.0")
   grep -rl "Target.*v<VERSION>\|release.*v<VERSION>" docs/todo/ --include="*.md" 2>/dev/null | grep -v completed/
   # Also check completed/ in case it was moved but not finalized
   grep -rl "Target.*v<VERSION>\|release.*v<VERSION>" docs/todo/completed/ --include="*.md" 2>/dev/null
   ```
   - If a matching plan is found, read it and check:
     - Status line contains "Complete" (not "In Progress" or "pending release")
     - Release checkbox is checked: `- [x] Release v<VERSION>` (not `- [ ]`)
     - All other task checkboxes are checked (no remaining `- [ ]` items)
   - If any are unchecked or status is not "Complete": **WARN** and show which items remain

   **Orphaned active plans check** — scan `docs/todo/` (not `completed/`) for any plans with:
   - Unchecked release boxes: `- [ ] Release` patterns
   - "pending release" or "In Progress" status strings
   - If found and they DON'T match this release version: **INFO** (not blocking, just notify)

   **VERSIONS.md check** — read `VERSIONS.md` and check if the `Last Updated` date is older than 7 days:
   - If stale: **WARN** "VERSIONS.md last updated on <date>. Should it be updated before release?"

   If any warnings are raised, present them all at once and ask for confirmation to proceed or fix first.

5. **Analyze Changes for Release Notes**

   Group commits by category:
   - Documentation changes
   - Infrastructure/configuration
   - Features
   - Bug fixes
   - Chores

   Understand the PURPOSE, not just list commits.

6. **Write Release Notes**

   **Tag annotation format:**
   ```
   v<VERSION> - <Short Title>

   <One sentence summary of this release>

   <Category 1>:
   - Specific item
   - Specific item

   <Category 2>:
   - Specific item
   ```

   **GitHub release format:**
   ```markdown
   ## Summary
   <One paragraph describing what this release contains>

   ## What's Included

   ### <Category 1>
   - Item 1
   - Item 2

   ### <Category 2>
   - Item 1
   - Item 2

   ## Commits
   - `abc1234` commit message 1
   - `def5678` commit message 2
   ```

7. **Show Release Plan and Confirm**

   Present the full plan and **wait for user confirmation**:
   ```
   Release Plan:
   - Version: v0.1.0
   - Title: "<title>"
   - Commits: <N> (since <last-tag>)
   - Will push to: origin/main
   - Will create: Annotated tag v<VERSION>
   - Will create: GitHub release

   Pre-release checks:
   - Remote tag collision: ✓ No conflict
   - Phase plan status: ✓ All complete (or ⚠ warnings listed)
   - VERSIONS.md: ✓ Up to date (or ⚠ stale)

   Proceed with release? (waiting for confirmation)
   ```

   **Do NOT proceed until user confirms.**

8. **Execute Release**

   ```bash
   # Create annotated tag
   git tag -a v<VERSION> -m "<tag message>"

   # Push commits
   git push origin main

   # Push tag
   git push origin v<VERSION>

   # Create GitHub release (title MUST match tag format: "v0.X.0 - Short Title")
   gh release create v<VERSION> --title "v<VERSION> - <Short Title>" --notes "<notes>"
   ```

9. **Report Results**
   ```
   Release Complete:
   - Version: v<VERSION>
   - Tag: v<VERSION> on main
   - origin (GitHub): ✓ main + tag pushed
   - GitHub release: <URL>
   ```

## Examples

### First Release (v0.1.0)

**Tag annotation:**
```
v0.1.0 - Project Setup and Planning

Initial documentation for 3-node HA Kubernetes homelab.

Documentation:
- kubeadm bootstrap guide for Ubuntu 24.04
- Architecture decisions and network planning
- CKA learning materials and K8s v1.35 notes
- Storage setup with Longhorn

Configuration:
- Claude Code commands, agents, and skills
- Security hooks for sensitive file protection

Project:
- MIT License and conventional commit workflow
```

**GitHub release notes:**
```markdown
## Summary

Initial release containing documentation and planning for a 3-node HA
Kubernetes cluster on Lenovo M80q bare-metal nodes. This release establishes
the foundation for CKA certification prep and production homelab workloads.

## What's Included

### Documentation
- kubeadm bootstrap guide for Ubuntu 24.04
- Architecture decisions and network planning
- CKA learning materials and K8s v1.35 notes
- Storage setup with Longhorn
- Changelog with node preparation progress

### Claude Code Configuration
- Custom commands (commit, release, validate, cluster-status)
- kubernetes-expert agent and kubeadm-patterns skill
- Security hooks for sensitive file protection

### Project Setup
- README, LICENSE (MIT), and version tracking
- Rules for no AI attribution and no auto-commits

## Commits
- `abc1234` docs: project setup and planning documentation
```

### Feature Release (v0.2.0)

**Tag annotation:**
```
v0.2.0 - Kubernetes Cluster Bootstrap

Cluster successfully bootstrapped with HA control plane.

Infrastructure:
- 3-node control plane with stacked etcd
- kube-vip providing API server VIP
- Cilium CNI with eBPF datapath

Documentation:
- Updated bootstrap guide with troubleshooting
- Added post-installation verification steps
```

### Patch Release (v0.1.1)

**Tag annotation:**
```
v0.1.1 - Documentation Fixes

Minor corrections and improvements to documentation.

Fixes:
- Corrected IP addresses in cluster status
- Fixed broken links in bootstrap guide
- Updated outdated kubectl commands
```

## Quality Checklist

Before releasing, verify:
- [ ] On `main` branch
- [ ] Working tree is clean (no uncommitted changes)
- [ ] Remote tags fetched and no version collision
- [ ] Phase plan checkboxes all checked and status is "Complete"
- [ ] VERSIONS.md is up to date
- [ ] All commits are meaningful and well-formatted
- [ ] Version number follows SemVer
- [ ] Release notes are categorized and specific
- [ ] Tag annotation has context sentence
- [ ] GitHub release has full summary
- [ ] User confirmed the release plan before execution

## Important Notes

- NEVER release with uncommitted changes
- NEVER release without meaningful release notes
- NEVER release without user confirmation of the release plan
- Always fetch remote tags before creating a new tag
- Always use annotated tags (`git tag -a`)
- Follow semantic versioning (MAJOR.MINOR.PATCH)
- First release defaults to v0.1.0
- Release notes should explain "what's in this release" not just list commits
- NO AI attribution in release notes
- **Title format:** Always `v<VERSION> - <Short Title>` — use a regular hyphen (`-`), NEVER an em dash (`—`). Keep titles concise (2-4 words). Example: `v0.19.0 - Cloudflare Traffic Analytics`
