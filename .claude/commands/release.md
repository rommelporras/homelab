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
   git status              # Must be clean working tree
   git log --oneline -5    # Recent commits
   git describe --tags --abbrev=0 2>/dev/null || echo "No tags yet"
   ```

2. **Determine Version and Title**

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

3. **Analyze Changes for Release Notes**

   Group commits by category:
   - Documentation changes
   - Infrastructure/configuration
   - Features
   - Bug fixes
   - Chores

   Understand the PURPOSE, not just list commits.

4. **Write Release Notes**

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

5. **Execute Release**

   **Show plan first:**
   ```
   Release Plan:
   - Version: v0.1.0
   - Commits: 1
   - Will push to: origin/main
   - Will create: GitHub release
   ```

   **Then execute:**
   ```bash
   # Create annotated tag
   git tag -a v<VERSION> -m "<tag message>"

   # Push commits
   git push origin main

   # Push tag
   git push origin v<VERSION>

   # Create GitHub release
   gh release create v<VERSION> --title "<title>" --notes "<notes>"
   ```

6. **Report Results**
   - Show GitHub release URL
   - Show tag details
   - Confirm success

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
- [ ] Working tree is clean (no uncommitted changes)
- [ ] All commits are meaningful and well-formatted
- [ ] Version number follows SemVer
- [ ] Release notes are categorized and specific
- [ ] Tag annotation has context sentence
- [ ] GitHub release has full summary

## Important Notes

- NEVER release with uncommitted changes
- NEVER release without meaningful release notes
- Always use annotated tags (`git tag -a`)
- Follow semantic versioning (MAJOR.MINOR.PATCH)
- First release defaults to v0.1.0
- Release notes should explain "what's in this release" not just list commits
- NO AI attribution in release notes
