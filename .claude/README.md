# Homelab Slash Commands

Custom slash commands for infrastructure management and git workflow.

## Available Commands

### `/commit` - Smart Conventional Commits
Analyzes changes and creates properly formatted conventional commit.

**Usage:** `/commit`

**What it does:**
- Detects commit type (feat/fix/docs/infra/etc.)
- Scans staged changes for leaked secrets (blocks commit if found)
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

### `/audit-docs` - Documentation Audit
Audit docs/context/ files against current cluster state. Requires cluster access.

**Usage:** `/audit-docs`

**What it does:**
- Compares docs against live cluster (namespaces, HTTPRoutes, versions)
- Checks frontmatter dates are current
- Reports issues, waits for "fix it" approval before changing files

---

### `/audit-security` - Pre-Commit Security Scan
Scan manifests, Helm values, and docs for security issues. No cluster access needed.

**Usage:** `/audit-security`

**What it does:**
- Scans entire repo for leaked secrets (broader than `/commit`'s staged-only scan)
- Reads each manifest to check security context, capabilities, PSS, image pinning
- Verifies network policy coverage for all workload namespaces
- Checks Helm values for hardcoded credentials
- Reports findings with file:line references and severity levels

---

### `/audit-cluster` - Live Cluster Security Audit
Deep security check of running cluster. Requires cluster access.

**Usage:** `/audit-cluster`

**What it does:**
- Verifies PSS enforcement on all namespaces
- Checks running containers (including init containers) for root, privileged, missing security context
- Flags workloads in the default namespace
- Audits network policy coverage
- Reviews RBAC for unexpected cluster-admin bindings
- Cross-references exposed services against Gateway.md
- Detects image version drift against VERSIONS.md

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
```
# 1. Make infrastructure changes
# 2. /audit-security    — Full repo security scan
# 3. /commit            — Stage and commit (includes secrets scan on diff)
```

### Creating a Release
```
# 1. /audit-docs        — Compare docs against live cluster
# 2. "fix it"           — Apply doc fixes if needed
# 3. /commit            — Commit doc fixes
# 4. /release v0.x.0    — Tag, push, GitHub release
```

### Security Review
```
# Pre-commit (fast, no cluster needed):
/audit-security

# Deep cluster check (needs cluster access):
/audit-cluster
```

## Which audit command when?

| Situation | Command | Needs cluster? |
|-----------|---------|----------------|
| Before committing manifests | `/audit-security` | No |
| Before a release | `/audit-docs` | Yes |
| Periodic security review | `/audit-cluster` | Yes |

---

## Command Files

Project commands (`.claude/commands/`):
- `release.md` - Release automation
- `audit-docs.md` - Documentation audit
- `audit-security.md` - Pre-commit security scan
- `audit-cluster.md` - Live cluster security audit

Global skills (`~/.claude/skills/`):
- `commit/` - Commit message generation
- `push/` - Push to remote

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
