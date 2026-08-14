---
name: commit
description: |
  Triggered by: "commit", "commit changes", "create a commit", "stage and commit",
  "make a commit". Creates a git commit following homelab conventional-commit rules:
  plain type: subject format (no ticket IDs), infra+docs 2-commit rule, secret scan
  before staging, specific file staging only, no AI attribution.
---

# commit

Create a git commit following homelab rules exactly. Work through each step in order
and stop immediately if a step reveals a problem.

## Arguments

If an argument (commit message) is provided, use it as the full message (still apply
formatting rules and run all steps). If empty, determine the message from the changes.

## Step 1 - Understand current state

Run these in parallel:
- `git -C "$(git rev-parse --show-toplevel)" status` - identify staged, unstaged, and untracked files
- `git -C "$(git rev-parse --show-toplevel)" diff` - unstaged changes
- `git -C "$(git rev-parse --show-toplevel)" diff --cached` - staged changes
- `git -C "$(git rev-parse --show-toplevel)" log --oneline -5` - recent commit style

If there are no changes at all (nothing staged, nothing modified), stop here and say
so. Do not create an empty commit.

## Step 2 - Identify change categories

Before drafting the message, classify every changed file into one of two buckets:

- **Infra changes** - manifests, Helm values (`helm/`, `manifests/`, `.kiro/`,
  `scripts/`, Ansible)
- **Docs changes** - documentation only (`docs/`, `CLAUDE.md`, `README.md`,
  `VERSIONS.md`, `docs/reference/CHANGELOG.md`)

If BOTH buckets have changes, this requires TWO SEPARATE COMMITS:
1. First commit covers infra changes only
2. Second commit covers docs changes only

Announce this clearly before proceeding:
"This changeset has both infra and docs changes. Homelab convention requires two
separate commits. I will stage and commit each group separately."

Proceed with the infra commit first, then the docs commit.

## Step 3 - Secret scan

Before staging anything, scan all modified and untracked files for leaked secrets.
Check git diff output for:
- Private key headers: `-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----`
- AWS access key IDs: `AKIA[0-9A-Z]{16}`
- GitHub tokens: `gh[pousr]_[A-Za-z0-9]{36,}`
- Anthropic API keys: `sk-ant-api`
- OpenAI project keys: `sk-proj-`

This is a PUBLIC repository. If a secret pattern is found, STOP immediately. Report
the file and pattern. Do not proceed to staging under any circumstances.

## Step 4 - Draft the commit message

Homelab conventional commit format: `type: subject`

| Type | When to use |
|------|-------------|
| `feat:` | New service, feature, or capability |
| `fix:` | Bug fix |
| `docs:` | Documentation only (CLAUDE.md, docs/, README.md, VERSIONS.md, CHANGELOG) |
| `infra:` | Manifests, Helm values, Kiro config, scripts, Ansible |
| `refactor:` | Restructure without behavior change |
| `chore:` | Tooling, config, dependencies, maintenance |

Rules:
- Subject line: max 72 characters total, lowercase after the colon, no trailing period
- Examples: `infra: add vault snapshot cronjob`, `docs: update changelog for v0.14.0`
- Body (optional): explain WHY, not what - blank line after subject, wrap at 72 chars
- NO ticket IDs, NO Jira/Linear references, NO issue numbers in the subject line
- NO feature-branch checks - this repo commits directly to main (ArgoCD syncs from main)
- NEVER add AI attribution - no "Co-Authored-By:", no "Generated with", no AI references

## Step 5 - Stage specific files

Stage files by name. NEVER use `git add -A` or `git add .` - they risk including
unintended files (kubeconfig, temp files, secrets).

Only stage files that belong to this commit's intent (infra OR docs, not both at once).
If unrelated changes are mixed in, ask the user what to include before staging.

```bash
git add path/to/file1 path/to/file2
```

## Step 6 - Create the commit

Pass the message via HEREDOC to preserve formatting:

```bash
git commit -m "$(cat <<'EOF'
type: subject line

Optional body explaining why.
EOF
)"
```

## Step 7 - Verify

Run both and show the output:

```bash
git log --oneline -1
git status
```

## Hard stops

- **Pre-commit hook failure** - do not retry with `--no-verify`. Report the failure
  and ask the user how to proceed.
- **No changes** - do not create an empty commit.
- **Secret found** - stop before staging. Never suppress or bypass. This is a public
  repo; any pushed secret must be treated as compromised.
- **Mixed infra+docs** - do not commit both in one shot. Split them (Step 2).
- **Never push** unless the user explicitly asks after the commit is created.
- **Never `git add -A` or `git add .`** - always name files explicitly.
