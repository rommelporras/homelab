# Security Audit (Pre-Commit)

Scan manifests, Helm values, and docs for security issues. No cluster access needed.

## Usage

```
/audit-security          → Scope-aware scan (auto-detects docs-only vs full)
```

Run before committing. Fast, offline, catches issues before they reach git.

**Note:** `/commit` already does a secrets scan on staged changes. This command is broader — it scans the entire repo and checks manifest security posture, not just secrets.

## Instructions

### 0. Determine Scope

Check which files have changed (staged, unstaged, AND untracked):

```bash
git diff --cached --name-only
git diff --name-only
git ls-files --others --exclude-standard
```

**Mode selection:**
- If **only** `docs/` and/or `.claude/` files changed → **docs-only mode** (run Steps 1, 1.5, 2.5, 6 only — skip manifest/helm/networkpolicy/PSS checks)
- If `manifests/` or `helm/` or other infra files changed → **full mode** (all steps)
- If no changes detected (fresh audit) → **full mode**

State the mode in the report header:

```
Mode: docs-only (only docs/ and .claude/ files changed)
```
or
```
Mode: full (infrastructure files changed)
```

### 1. Secrets Scan

Scan the entire repo for leaked credentials. Use the Grep tool (not bash grep) to search across all file types:

**Search patterns (run as separate Grep calls):**
- `manifests/` and `helm/` directories for: `password:`, `secret:`, `token:`, `apiKey:`, `-----BEGIN`, `PRIVATE KEY`, `stringData:`
- `docs/` directory for: API key patterns (see list below), long base64 strings, Discord/Slack webhook URLs, Cloudflare API tokens
- `scripts/` and `ansible/` directories for: same patterns as manifests (passwords, tokens, keys)
- All directories for: `eyJ` (JWT tokens with payloads), `bearer` followed by actual token values

**Token prefix patterns to scan for:**
- `ghp_` — GitHub personal access tokens
- `glpat-` — GitLab personal access tokens
- `sk-` — OpenAI API keys
- `AKIA` — AWS access keys
- `xox` — Slack tokens (xoxb-, xoxp-, xoxr-, xoxa-, xoxs-)
- `tskey-` — Tailscale auth keys
- `ops_` — 1Password service account tokens
- `whsec_` — Webhook signing secrets
- `discord.com/api/webhooks` — Discord webhook URLs
- `hooks.slack.com` — Slack webhook URLs

**Known safe patterns (skip these):**
- `op://` — 1Password reference URIs
- `secret-source: "op://..."` — Annotation referencing 1Password item
- `secretKeyRef` / `secretName` — K8s references to Secret objects by name
- `$(op read ...)` / `$(kubectl get secret ...)` — runtime lookups
- `{{HOMEPAGE_VAR_*}}` / `SET_VIA_HELM` — template placeholders
- `openssl rand` — instructions to generate, not actual values
- Field name references in tables/docs: `` `password` ``, `` `root-password` ``, `username`
- `<your-password>` / `<your-token>` / `<never commit this>` — doc placeholders
- `REPLACE_WITH_*` / `CHANGE_ME` — explicit placeholder values
- Comments describing fields (e.g., `# Fields: username, password`)
- Lines with `op item create` or `op read` (1Password CLI usage)
- `managed-by: "imperative-kubectl"` — annotation on safe secret placeholders
- `future-migration: "external-secrets-operator"` — annotation on safe secret placeholders
- `# DATA INTENTIONALLY OMITTED` — comment pattern in secret placeholder files
- Commented-out `# stringData:` blocks (documentation, not actual secrets)

**Classification:**
- ⛔ CRITICAL — Looks like a real credential (actual value, not a reference or field name)
- SAFE — Matches a known safe pattern

**If unsure:** Flag as ⚠️ WARNING for human review. Don't suppress it.

### 1.5. Sensitive File Types

Check for sensitive file types that should never exist in the repo, even if gitignored. Use Glob to search for:

- `**/*.pem`, `**/*.key`, `**/*.p12`, `**/*.pfx` — Certificates and private keys
- `**/kubeconfig`, `**/*.kubeconfig` — Cluster credentials
- `**/id_rsa`, `**/id_ed25519`, `**/id_ecdsa` — SSH private keys
- `**/.env`, `**/.env.*`, `**/*.env` — Environment files

**For each found file:**
1. Check if it's tracked by git: `git ls-files <path>`
2. If tracked → ⛔ CRITICAL (sensitive file committed to repo)
3. If not tracked, check if covered by `.gitignore`: `git check-ignore <path>`
4. If not tracked and not gitignored → ⚠️ WARNING (could be accidentally committed)
5. If not tracked and gitignored → SAFE (note existence in report)

### 2. Manifest Security

Read each workload manifest in `manifests/` (files containing Deployment, StatefulSet, DaemonSet, Job, or CronJob). Use the Read tool to examine each file — don't rely on grep for multi-document YAML files.

**Efficiency guidance:**
- Use Grep to find all workload files first: `kind:\s*(Deployment|StatefulSet|DaemonSet|Job|CronJob)` in `manifests/`
- Read files in parallel where possible (batch 3-5 reads at a time)
- In docs-only mode, skip this step entirely

**For each workload, check:**

| Check | What to look for | Severity |
|-------|-----------------|----------|
| runAsNonRoot | Pod or container `securityContext.runAsNonRoot: true` | ⚠️ WARNING if missing |
| allowPrivilegeEscalation | Container `securityContext.allowPrivilegeEscalation: false` | ⚠️ WARNING if missing |
| capabilities | Container `securityContext.capabilities.drop: [ALL]` | ⚠️ WARNING if missing |
| seccompProfile | Pod `securityContext.seccompProfile.type: RuntimeDefault` | ⚠️ WARNING if missing |
| readOnlyRootFilesystem | Container `securityContext.readOnlyRootFilesystem: true` | ℹ️ INFO if missing (some apps need writable root) |
| privileged | Container `securityContext.privileged: true` | ⛔ CRITICAL |
| hostNetwork/hostPID/hostIPC | Pod spec `hostNetwork`, `hostPID`, or `hostIPC: true` | ⛔ CRITICAL |
| resource limits | Container `resources.limits` (memory and cpu) | ⚠️ WARNING if missing |
| image pinning | Image tag is not `:latest` and is not missing | ⚠️ WARNING if `:latest` or no tag |
| automountServiceAccountToken | Set to `false` if pod doesn't need K8s API access | ℹ️ INFO if missing |

**Also check for hardcoded secrets in manifests:**
- `stringData:` blocks with actual values (not `op://` references or placeholders) → ⛔ CRITICAL
- `data:` blocks with base64-encoded values → ⚠️ WARNING (review manually)

### 2.5. Committed Secret Files

**This step runs in ALL modes (full and docs-only).**

Check for secret manifest files and .env files in the repo:

**Search using Glob for:**
- `**/secret.yaml`, `**/secret*.yaml` (e.g., `secret-db.yaml`)
- `**/.env`, `**/.env.*`

**For each found file:**
1. Check if tracked by git: `git ls-files <path>`
2. If not tracked (gitignored) → SAFE (note in report as "gitignored, local only")
3. If tracked, read the file contents and verify it only contains safe patterns:
   - Empty `stringData: {}` or `data: {}`
   - Values using `op://` references
   - `# DATA INTENTIONALLY OMITTED` comment with no actual data block
   - Commented-out `# stringData:` / `# data:` blocks
   - `managed-by: "imperative-kubectl"` annotation (imperative creation pattern)
   - `secret-source: "op://..."` annotation documenting 1Password source
   - Placeholder values (`REPLACE_WITH_*`, `CHANGE_ME`, `<your-password>`, `<never commit this>`)
   - Comments explaining imperative creation (e.g., `# Created via: kubectl create secret ...`)
4. If real credential values are found → ⛔ CRITICAL
5. If file is tracked and only contains safe patterns → SAFE (note it in report)

### 3. Network Policy Coverage

For each namespace directory under `manifests/` that contains a workload:
1. Read the directory listing
2. Check if a `networkpolicy.yaml` or file containing `CiliumNetworkPolicy` exists
3. If no network policy → ⚠️ WARNING

**Note:** Helm-managed namespaces (gitlab, monitoring, cert-manager, longhorn-system, tailscale) may have network policies configured in Helm values, not in `manifests/`. This step only covers manifest-based namespaces. Helm namespace coverage is checked via `/audit-cluster` (live cluster audit).

### 4. Namespace PSS Labels

For each `namespace.yaml` in `manifests/`:
1. Read the file
2. Check for `pod-security.kubernetes.io/enforce` label
3. If missing → ⚠️ WARNING

**Note:** Helm-managed namespaces (gitlab, gitlab-runner, monitoring, longhorn-system, cert-manager, tailscale) create their own Namespace objects. PSS labels for those namespaces should be set in Helm values or verified via `/audit-cluster`. This step only covers manifest-defined namespaces.

### 5. Helm Values Security

The secrets scan in Step 1 already grepped `helm/` for `password:`, `secret:`, `token:`, `apiKey:`. Review those results here — don't re-read all values files individually.

Classify the Step 1 `helm/` matches:
- `secret: <k8s-secret-name>` — SAFE (reference to a K8s Secret object)
- `SET_VIA_HELM` / `op://` / `{{ }}` — SAFE (placeholder/template)
- Literal credential value (actual password or token string) → ⛔ CRITICAL

### 6. Docs Secrets Check

Scan `docs/**/*.md` for patterns that look like real credentials:
- GitHub tokens (`ghp_` followed by 36+ alphanumeric chars)
- GitLab tokens (`glpat-` followed by 20+ chars)
- OpenAI keys (`sk-` followed by 48+ chars)
- AWS access keys (`AKIA` followed by 16 uppercase alphanumeric)
- Tailscale auth keys (`tskey-` followed by alphanumeric chars)
- 1Password service account tokens (`ops_` followed by alphanumeric chars)
- Discord webhook URLs (`discord.com/api/webhooks/` followed by numbers)
- Cloudflare API tokens (32+ hex strings near "cloudflare" or "cf" context)
- JWT tokens with payloads (`eyJ` followed by 50+ chars that decode to JSON)
- Generic long hex/base64 strings (40+ chars) that appear to be credential values

If found → ⛔ CRITICAL

### 7. Generate Report

**Format:**

**Full mode:**
```
Security Audit (Pre-Commit)
===========================
Mode: full (infrastructure files changed)

Secrets Scan .............. ✅ PASS (0 findings)
Sensitive File Types ...... ✅ PASS (0 sensitive files tracked)
Committed Secret Files .... ✅ PASS (6 secret files found, all gitignored)
Manifest Security ......... ⚠️  2 warnings
Network Policies .......... ✅ All manifest namespaces covered
PSS Labels ................ ✅ All manifest namespaces labeled
Helm Values ............... ✅ PASS
Docs Secrets .............. ✅ PASS

Note: Helm-managed namespaces (gitlab, monitoring, etc.) checked via /audit-cluster

Findings:
  ⚠️  manifests/foo/statefulset.yaml:25 — Missing resource limits
  ⚠️  manifests/foo/statefulset.yaml:37 — Image uses :latest tag
  ℹ️  manifests/foo/statefulset.yaml:42 — readOnlyRootFilesystem not set

Result: PASS (0 critical, 2 warnings, 1 info)
```

**Docs-only mode:**
```
Security Audit (Pre-Commit)
===========================
Mode: docs-only (only docs/ and .claude/ files changed)

Secrets Scan .............. ✅ PASS (0 findings)
Sensitive File Types ...... ✅ PASS (0 sensitive files tracked)
Committed Secret Files .... ✅ PASS (6 secret files found, all gitignored)
Docs Secrets .............. ✅ PASS

⏭️  Skipped: Manifest Security, Network Policies, PSS Labels, Helm Values (no infra changes)

Result: PASS (0 critical, 0 warnings)
```

**If critical issues found:**
```
Result: ⛔ FAIL (1 critical, 2 warnings)

⛔ DO NOT COMMIT — fix critical issues first.
```

**Severity levels:**
- ⛔ CRITICAL — Real secrets, privileged containers, host namespace access. Blocks commit.
- ⚠️ WARNING — Missing security context, unpinned images, missing network policy. Should fix.
- ℹ️ INFO — Best practice suggestions (readOnlyRootFilesystem, automountServiceAccountToken).

**Pass/fail logic:**
- 0 critical = PASS (warnings are informational)
- 1+ critical = FAIL (do not commit)

## Important Rules

1. **Read-only** — This command never modifies files
2. **No cluster access** — Works entirely offline against local files
3. **Read files, don't grep multi-doc YAML** — Use Read tool for manifests to handle `---` separators correctly
4. **Known safe patterns** — Don't flag `op://` paths, field name references, placeholders, or imperative creation comments
5. **File:line references** — Always include file path and line number for findings
6. **Be specific** — "Missing runAsNonRoot in container uptime-kuma" not "security issue found"
7. **When unsure, flag it** — If you can't tell whether something is a real secret, flag as WARNING for human review
8. **Scan all directories** — Include `scripts/` and `ansible/` in secrets scan, not just manifests/helm/docs
9. **Step 2.5 always runs** — Committed secret file check runs in both full and docs-only mode
