---
name: audit-security
description: |
  Triggered by: "audit security", "pre-commit security scan", "scan for secrets",
  "security scan", "check for secrets". Scope-aware security scan: auto-detects
  docs-only vs full mode, runs multi-pattern secret scanning with known-safe
  exclusions, sensitive file type checks, per-manifest securityContext/PSS/image-pin/
  probe checks with accepted-risk lookup, network policy coverage, Helm values scan,
  and docs secret scan. Works entirely offline - no cluster access needed.
---

# audit-security

Scope-aware pre-commit security scan. Read-only. Works entirely offline against
local files - no cluster access needed.

Note: The commit hook already does a secrets scan on staged changes. This skill is
broader - it scans the entire repo and checks manifest security posture, not just
secrets.

## Step 0 - Determine scope

Check which files have changed (staged, unstaged, AND untracked):

```bash
git diff --cached --name-only
git diff --name-only
git ls-files --others --exclude-standard
```

**Mode selection:**
- If **only** `docs/` and/or `.claude/` files changed - **docs-only mode** (run steps 1, 1.5, 2.5, 6 only)
- If `manifests/` or `helm/` or other infra files changed - **full mode** (all steps)
- If no changes detected (fresh audit) - **full mode**

State the mode in the report header:
```
Mode: docs-only (only docs/ and .claude/ files changed)
```
or
```
Mode: full (infrastructure files changed)
```

## Step 1 - Secrets scan

Scan the entire repo for leaked credentials using shell grep.

**Search patterns:**

```bash
# manifests/ and helm/ - credentials fields
grep -rn "password:\|secret:\|token:\|apiKey:\|-----BEGIN\|PRIVATE KEY\|stringData:" \
  manifests/ helm/ 2>/dev/null

# docs/ - API key patterns and webhook URLs
grep -rn "ghp_\|glpat-\|sk-\|AKIA\|xox[bpras]-\|tskey-\|ops_\|whsec_\|discord.com/api/webhooks\|hooks.slack.com" \
  docs/ 2>/dev/null

# scripts/ and ansible/ - same credential patterns
grep -rn "password:\|secret:\|token:\|apiKey:\|-----BEGIN\|PRIVATE KEY\|stringData:" \
  scripts/ ansible/ 2>/dev/null

# All directories - JWT tokens and bearer tokens
grep -rn "eyJ\|bearer [A-Za-z0-9_-]\{20,\}" . --include="*.yaml" --include="*.yml" \
  --include="*.md" --include="*.sh" --include="*.json" --include="*.env" 2>/dev/null
```

**Token prefix patterns to scan for (all directories):**
- `ghp_` - GitHub personal access tokens
- `glpat-` - GitLab personal access tokens
- `sk-` - OpenAI API keys
- `AKIA` - AWS access keys
- `xox` - Slack tokens (xoxb-, xoxp-, xoxr-, xoxa-, xoxs-)
- `tskey-` - Tailscale auth keys
- `ops_` - 1Password service account tokens
- `whsec_` - Webhook signing secrets
- `discord.com/api/webhooks` - Discord webhook URLs
- `hooks.slack.com` - Slack webhook URLs

**Known safe patterns (skip these):**
- `op://` - 1Password reference URIs
- `secret-source: "op://..."` - Annotation referencing 1Password item
- `secretKeyRef` / `secretName` - K8s references to Secret objects by name
- `$(op read ...)` / `$(kubectl get secret ...)` - runtime lookups
- `{{HOMEPAGE_VAR_*}}` / `SET_VIA_HELM` - template placeholders
- `openssl rand` - instructions to generate, not actual values
- Field name references in tables/docs (backtick-quoted field names like `password`)
- `<your-password>` / `<your-token>` / `<never commit this>` - doc placeholders
- `REPLACE_WITH_*` / `CHANGE_ME` - explicit placeholder values
- Comments describing fields (e.g., `# Fields: username, password`)
- Lines with `op item create` or `op read` (1Password CLI usage)
- `managed-by: "imperative-kubectl"` - annotation on safe secret placeholders
- `future-migration: "external-secrets-operator"` - annotation on safe secret placeholders
- `# DATA INTENTIONALLY OMITTED` - comment pattern in secret placeholder files
- Commented-out `# stringData:` blocks (documentation, not actual secrets)
- Bcrypt hashes (`$2a$`, `$2b$`, `$2y$` prefixes) - one-way hashes, not plaintext credentials
- `secretKey:` - ESO ExternalSecret field naming a K8s Secret key (no credential value)
- `secretStoreRef:` - ESO reference to a SecretStore by name (no credential value)
- `remoteRef:` - ESO Vault KV path reference (e.g., `key: ghost-prod/mysql`) - path, not value
- `kind: ExternalSecret` / `kind: ClusterSecretStore` / `kind: SecretStore` - ESO CRD types, never hold credentials
- `path: "secret"` in ClusterSecretStore - Vault KV mount name, not a credential

**Classification:**
- CRITICAL - Looks like a real credential (actual value, not a reference or field name)
- SAFE - Matches a known safe pattern
- WARNING - If unsure: flag for human review. Do not suppress it.

## Step 1.5 - Sensitive file types

Check for sensitive file types that should never exist in the repo, even if gitignored.

Search for:
```bash
find . -name "*.pem" -o -name "*.key" -o -name "*.p12" -o -name "*.pfx" \
  -o -name "kubeconfig" -o -name "*.kubeconfig" \
  -o -name "id_rsa" -o -name "id_ed25519" -o -name "id_ecdsa" \
  -o -name ".env" -o -name ".env.*" -o -name "*.env" \
  2>/dev/null | grep -v ".git/"
```

**For each found file:**
1. Check if tracked by git: `git ls-files <path>`
2. If tracked - CRITICAL (sensitive file committed to repo)
3. If not tracked, check if covered by `.gitignore`: `git check-ignore <path>`
4. If not tracked and not gitignored - WARNING (could be accidentally committed)
5. If not tracked and gitignored - SAFE (note existence in report)

## Step 2 - Manifest security (full mode only)

Read each workload manifest in `manifests/` (files containing Deployment, StatefulSet,
DaemonSet, Job, or CronJob). Use file reads to examine each file - do not rely on grep
for multi-document YAML files.

**Find all workload files first:**
```bash
grep -rl "kind: Deployment\|kind: StatefulSet\|kind: DaemonSet\|kind: Job\|kind: CronJob" \
  manifests/ 2>/dev/null
```

**For each workload, check:**

| Check | What to look for | Severity |
|-------|-----------------|----------|
| runAsNonRoot | Pod or container `securityContext.runAsNonRoot: true` | WARNING if missing |
| allowPrivilegeEscalation | Container `securityContext.allowPrivilegeEscalation: false` | WARNING if missing |
| capabilities | Container `securityContext.capabilities.drop: [ALL]` | WARNING if missing |
| seccompProfile | Pod `securityContext.seccompProfile.type: RuntimeDefault` | WARNING if missing |
| readOnlyRootFilesystem | Container `securityContext.readOnlyRootFilesystem: true` | INFO if missing (some apps need writable root) |
| privileged | Container `securityContext.privileged: true` | CRITICAL |
| hostNetwork/hostPID/hostIPC | Pod spec `hostNetwork`, `hostPID`, or `hostIPC: true` | CRITICAL |
| resource limits | Container `resources.limits` (memory and cpu) | WARNING if missing |
| image pinning | Image tag is not `:latest` and is not missing | WARNING if `:latest` or no tag |
| automountServiceAccountToken | Set to `false` if pod does not need K8s API access | INFO if missing |

**Accepted risks - read `docs/context/Security.md` to classify known exceptions:**

Before flagging, check if `docs/context/Security.md` documents the issue as an accepted risk.
If it does:

- **Known non-root exceptions** (listed in Security.md "Known Non-Root Exceptions" table):
  Downgrade missing `runAsNonRoot` from WARNING to ACCEPTED for these workloads.
  Still flag missing `capabilities.drop`/`allowPrivilegeEscalation`/`seccompProfile` as WARNING.
- **Database containers without container securityContext** (gosu/su-exec breaks `allowPrivilegeEscalation: false`):
  If documented in Security.md, report as ACCEPTED instead of WARNING.
- **CI/CD placeholder images** (`:latest` with a comment like `# CI/CD will patch this`):
  Report as ACCEPTED instead of WARNING.

In the report, separate accepted risks from new/actionable warnings:
```
Findings:
  WARNING  manifests/foo/deployment.yaml:25 - Missing runAsNonRoot (NEW)

Accepted risks (documented in Security.md):
  INFO     manifests/ghost-dev/mysql-statefulset.yaml:34 - No container securityContext (gosu/su-exec)
  INFO     manifests/portfolio/deployment.yaml:39 - Image :latest (CI/CD placeholder)
```

**Also check for hardcoded secrets in manifests:**
- `stringData:` blocks with actual values (not `op://` references or placeholders) - CRITICAL
- `data:` blocks with base64-encoded values - WARNING (review manually)

## Step 2.5 - Committed secret files (all modes)

This step runs in ALL modes (full and docs-only).

Check for secret manifest files and .env files in the repo:

```bash
find . \( -name "secret.yaml" -o -name "secret*.yaml" -o -name ".env" -o -name ".env.*" \) \
  2>/dev/null | grep -v ".git/"
```

Note: `externalsecret.yaml` files are intentionally tracked - they contain only Vault path
references, never credential values. Do NOT flag these; they are the ESO source-of-truth
for secrets, equivalent to a config file.

**For each found file:**
1. Check if tracked by git: `git ls-files <path>`
2. If not tracked (gitignored) - SAFE (note in report as "gitignored, local only")
3. If tracked, read the file contents and verify it only contains safe patterns:
   - Empty `stringData: {}` or `data: {}`
   - Values using `op://` references
   - ESO `remoteRef.key:` values (Vault KV path references - not credential values)
   - `# DATA INTENTIONALLY OMITTED` comment with no actual data block
   - Commented-out `# stringData:` / `# data:` blocks
   - `managed-by: "imperative-kubectl"` annotation
   - `secret-source: "op://..."` annotation
   - Placeholder values (`REPLACE_WITH_*`, `CHANGE_ME`, `<your-password>`, `<never commit this>`)
   - Comments explaining imperative creation
4. If real credential values are found - CRITICAL
5. If file is tracked and only contains safe patterns - SAFE (note in report)

## Step 3 - Network policy coverage (full mode only)

For each namespace directory under `manifests/` that contains a workload:
1. List the directory
2. Check if a `networkpolicy.yaml` or file containing `CiliumNetworkPolicy` exists:
   ```bash
   grep -l "CiliumNetworkPolicy\|NetworkPolicy" manifests/<namespace>/*.yaml 2>/dev/null
   ```
3. If no network policy - WARNING

**Deferred scope:** If a future phase plan (e.g., `docs/todo/phase-5.3*` for NetworkPolicies)
exists and covers the missing namespaces, report those as DEFERRED instead of WARNING:
```
Deferred (covered by Phase 5.3):
  INFO     manifests/ghost-dev/ - No CiliumNetworkPolicy (Phase 5.3 scope)
```
Check for the phase file:
```bash
git ls-files docs/todo/ | grep -i "phase-5\.3\|network"
```

If no phase plan covers them, report as WARNING.

Note: Helm-managed namespaces (gitlab, monitoring, cert-manager, longhorn-system, tailscale)
may have network policies configured in Helm values, not in `manifests/`. This step only
covers manifest-based namespaces. Helm namespace coverage is checked via the audit-cluster
skill (live cluster audit).

## Step 4 - Namespace PSS labels (full mode only)

For each `namespace.yaml` in `manifests/`:
1. Read the file
2. Check for `pod-security.kubernetes.io/enforce` label
3. If missing - WARNING

Note: Helm-managed namespaces (gitlab, gitlab-runner, monitoring, longhorn-system,
cert-manager, tailscale) create their own Namespace objects. PSS labels for those
namespaces should be set in Helm values or verified via the audit-cluster skill.
This step only covers manifest-defined namespaces.

## Step 5 - Helm values security (full mode only)

The secrets scan in step 1 already searched `helm/` for credential fields. Review
those results here - do not re-read all values files individually.

Classify the step 1 `helm/` matches:
- `secret: <k8s-secret-name>` - SAFE (reference to a K8s Secret object)
- `SET_VIA_HELM` / `op://` / `{{ }}` - SAFE (placeholder/template)
- Literal credential value (actual password or token string) - CRITICAL

## Step 6 - Docs secrets check (all modes)

Scan `docs/**/*.md` for patterns that look like real credentials:

```bash
grep -rn "ghp_[A-Za-z0-9]\{36,\}" docs/ 2>/dev/null
grep -rn "glpat-[A-Za-z0-9_-]\{20,\}" docs/ 2>/dev/null
grep -rn "sk-[A-Za-z0-9]\{48,\}" docs/ 2>/dev/null
grep -rn "AKIA[A-Z0-9]\{16\}" docs/ 2>/dev/null
grep -rn "tskey-[A-Za-z0-9]\{10,\}" docs/ 2>/dev/null
grep -rn "ops_[A-Za-z0-9]\{10,\}" docs/ 2>/dev/null
grep -rn "discord.com/api/webhooks/[0-9]" docs/ 2>/dev/null
grep -rn "eyJ[A-Za-z0-9_-]\{50,\}" docs/ 2>/dev/null
```

If found - CRITICAL.

## Step 7 - Generate report

**Full mode:**
```
Security Audit (Pre-Commit)
===========================
Mode: full (infrastructure files changed)

Secrets Scan .............. PASS (0 findings)
Sensitive File Types ...... PASS (0 sensitive files tracked)
Committed Secret Files .... PASS (0 secret files found)
Manifest Security ......... WARNING - 1 warning, 3 accepted
Network Policies .......... 6 covered, 5 deferred (Phase 5.3)
PSS Labels ................ All manifest namespaces labeled
Helm Values ............... PASS
Docs Secrets .............. PASS

Note: Helm-managed namespaces (gitlab, monitoring, etc.) checked via audit-cluster skill

Findings:
  WARNING  manifests/foo/deployment.yaml:25 - Missing runAsNonRoot (NEW)

Accepted risks (documented in Security.md):
  INFO     manifests/ghost-dev/mysql-statefulset.yaml:34 - No container securityContext (gosu)
  INFO     manifests/portfolio/deployment.yaml:39 - Image :latest (CI/CD placeholder)
  INFO     manifests/karakeep/karakeep-deployment.yaml:122 - runAsNonRoot=false (s6-overlay)

Deferred (covered by future phase plan):
  INFO     manifests/ghost-dev/ - No CiliumNetworkPolicy (Phase 5.3)

Result: PASS (0 critical, 1 warning, 3 accepted, 5 deferred)
```

**Docs-only mode:**
```
Security Audit (Pre-Commit)
===========================
Mode: docs-only (only docs/ and .claude/ files changed)

Secrets Scan .............. PASS (0 findings)
Sensitive File Types ...... PASS (0 sensitive files tracked)
Committed Secret Files .... PASS (6 secret files found, all gitignored)
Docs Secrets .............. PASS

Skipped: Manifest Security, Network Policies, PSS Labels, Helm Values (no infra changes)

Result: PASS (0 critical, 0 warnings)
```

**If critical issues found:**
```
Result: CRITICAL FAIL (1 critical, 2 warnings)

DO NOT COMMIT - fix critical issues first.
```

**Severity levels:**
- CRITICAL - Real secrets, privileged containers, host namespace access. Blocks commit.
- WARNING - Missing security context, unpinned images, missing network policy. Should fix.
- ACCEPTED - Documented in `docs/context/Security.md` as a known trade-off. Not actionable.
- DEFERRED - Covered by a future phase plan in `docs/todo/`. Not actionable now.
- INFO - Best practice suggestions (readOnlyRootFilesystem, automountServiceAccountToken).

**Pass/fail logic:**
- 0 critical = PASS (warnings are informational, accepted/deferred do not count)
- 1+ critical = FAIL (do not commit)

## Important rules

1. **Read-only** - Never modify files
2. **No cluster access** - Works entirely offline against local files
3. **Read files for multi-doc YAML** - Use file reads for manifests to handle `---` separators correctly; do not rely on grep for multi-document YAML
4. **Known safe patterns** - Do not flag `op://` paths, field name references, placeholders, or imperative creation comments
5. **File:line references** - Always include file path and line number for findings
6. **Be specific** - "Missing runAsNonRoot in container uptime-kuma" not "security issue found"
7. **When unsure, flag it** - If you cannot tell whether something is a real secret, flag as WARNING for human review
8. **Scan all directories** - Include `scripts/` and `ansible/` in secrets scan, not just manifests/helm/docs
9. **Step 2.5 always runs** - Committed secret file check runs in both full and docs-only mode
10. **Never bare kubectl or helm** - This skill is offline; no cluster commands needed
