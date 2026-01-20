# Homelab Slash Commands

Custom slash commands for infrastructure management and git workflow.

## Available Commands

### `/commit` - Smart Conventional Commits
Analyzes changes and creates properly formatted conventional commit.

**Usage:** `/commit`

**What it does:**
- Detects commit type (feat/fix/docs/infra/etc.)
- Generates descriptive message
- Stages all changes
- Creates commit (NO AI attribution)

---

### `/release` - Automated Versioning
Creates version tags with changelog and pushes to GitHub.

**Usage:**
```
/release         # Auto-determine version from commits
/release v1.0.0  # Explicit version
```

**What it does:**
- Analyzes commits since last tag
- Auto-determines version bump (major/minor/patch)
- Generates changelog from commits
- Creates annotated git tag
- Pushes commits and tag to origin
- Creates GitHub release with gh CLI

---

### `/cluster-status` - Kubernetes Health Check
Quick overview of cluster health and status.

**Usage:** `/cluster-status`

**What it does:**
- Shows node status and versions
- Lists problematic pods
- Displays recent events
- Reports control plane health
- Provides resource usage (if metrics available)

---

### `/validate` - Configuration Validation
Validate Kubernetes manifests and YAML files.

**Usage:** `/validate`

**What it does:**
- Validates YAML syntax
- Runs kubectl dry-run validation
- Checks for security issues
- Reports missing required fields
- Identifies best practice violations

---

### `/update-docs` - Documentation Audit
Audit and update docs/context/ files to match current cluster state.

**Usage:**
```
/update-docs          # Audit only (read-only)
/update-docs --apply  # Update dates, flag content changes
```

**What it does:**
- Checks frontmatter dates are current
- Verifies versions match VERSIONS.md
- Finds undocumented namespaces, HTTPRoutes, services
- Auto-updates dates with `--apply`
- Flags content changes for manual review

**Recommended before `/release`:**
```
/update-docs --apply
/release
```

---

## Commit Types

| Type | Use Case | Example |
|------|----------|---------|
| `feat:` | New feature | `feat: add Cilium network policies` |
| `fix:` | Bug fix | `fix: correct API server VIP address` |
| `docs:` | Documentation | `docs: update bootstrap guide` |
| `infra:` | Infrastructure | `infra: add storage class manifest` |
| `refactor:` | Code cleanup | `refactor: reorganize manifest structure` |
| `perf:` | Performance | `perf: optimize etcd disk settings` |
| `chore:` | Tooling | `chore: update .gitignore` |

---

## Semantic Versioning

```
v<MAJOR>.<MINOR>.<PATCH>

MAJOR: Breaking changes, cluster rebuild required
MINOR: New features, new components added
PATCH: Bug fixes, documentation updates
```

---

## Typical Workflows

### Making Changes
```bash
# 1. Make infrastructure changes
vim manifests/network-policy.yaml

# 2. Validate changes
/validate

# 3. Commit with smart message
/commit

# 4. Push to remote
git push
```

### Creating a Release
```bash
# 1. Audit and update docs first
/update-docs --apply

# 2. Review any flagged changes
git diff docs/context/

# 3. Commit doc updates if needed
/commit

# 4. Create release
/release

# Or with explicit version
/release v0.2.0
```

### Checking Cluster (when running)
```bash
# Quick health check
/cluster-status
```

---

## Command Files

All commands are in `.claude/commands/`:
- `commit.md` - Commit message generation
- `release.md` - Release automation
- `cluster-status.md` - Cluster health
- `validate.md` - Config validation
- `update-docs.md` - Documentation audit

---

## Security

Commands are protected by hooks:
- `.claude/hooks/protect-sensitive.sh` - Blocks edits to secrets, credentials
- Prevents dangerous operations (force push, cluster deletion)

Protected patterns:
- `kubeconfig`, `.kube/config`
- `*.pem`, `*.key`, certificates
- `secrets.yaml`, credentials files
- etcd backup files
