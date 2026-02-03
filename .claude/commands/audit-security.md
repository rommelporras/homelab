# Security Audit (Pre-Commit)

Scan manifests, Helm values, and docs for security issues. No cluster access needed.

## Usage

```
/audit-security          → Full scan of manifests, helm, and docs
```

Run before committing. Fast, offline, catches issues before they reach git.

**Note:** `/commit` already does a secrets scan on staged changes. This command is broader — it scans the entire repo and checks manifest security posture, not just secrets.

## Instructions

### 1. Secrets Scan

Scan the entire repo for leaked credentials. Use the Grep tool (not bash grep) to search across all file types:

**Search patterns (run as separate Grep calls):**
- `manifests/` and `helm/` directories for: `password:`, `secret:`, `token:`, `apiKey:`, `-----BEGIN`, `stringData:`
- `docs/` directory for: API key patterns (`ghp_`, `glpat-`, `sk-`, `AKIA`, `xox`), long base64 strings, Discord/Slack webhook URLs (`discord.com/api/webhooks`, `hooks.slack.com`), Cloudflare API tokens
- All directories for: `eyJ` (JWT tokens with payloads), `bearer` followed by actual token values

**Known safe patterns (skip these):**
- `op://` — 1Password reference URIs
- `secretKeyRef` / `secretName` — K8s references to Secret objects by name
- `$(op read ...)` / `$(kubectl get secret ...)` — runtime lookups
- `{{HOMEPAGE_VAR_*}}` / `SET_VIA_HELM` — template placeholders
- `openssl rand` — instructions to generate, not actual values
- Field name references in tables/docs: `` `password` ``, `` `root-password` ``, `username`
- `<your-password>` / `<your-token>` — doc placeholders
- Comments describing fields (e.g., `# Fields: username, password`)
- Lines with `op item create` or `op read` (1Password CLI usage)

**Classification:**
- ⛔ CRITICAL — Looks like a real credential (actual value, not a reference or field name)
- SAFE — Matches a known safe pattern

**If unsure:** Flag as ⚠️ WARNING for human review. Don't suppress it.

### 2. Manifest Security

Read each workload manifest in `manifests/` (files containing Deployment, StatefulSet, DaemonSet, Job, or CronJob). Use the Read tool to examine each file — don't rely on grep for multi-document YAML files.

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
- `stringData:` blocks with actual values (not `op://` references) → ⛔ CRITICAL
- `data:` blocks with base64-encoded values → ⚠️ WARNING (review manually)

### 3. Network Policy Coverage

For each namespace directory under `manifests/` that contains a workload:
1. Read the directory listing
2. Check if a `networkpolicy.yaml` or file containing `CiliumNetworkPolicy` exists
3. If no network policy → ⚠️ WARNING

### 4. Namespace PSS Labels

For each `namespace.yaml` in `manifests/`:
1. Read the file
2. Check for `pod-security.kubernetes.io/enforce` label
3. If missing → ⚠️ WARNING

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
- Discord webhook URLs (`discord.com/api/webhooks/` followed by numbers)
- Cloudflare API tokens (32+ hex strings near "cloudflare" or "cf" context)
- JWT tokens with payloads (`eyJ` followed by 50+ chars that decode to JSON)
- Generic long hex/base64 strings (40+ chars) that appear to be credential values

If found → ⛔ CRITICAL

### 7. Generate Report

**Format:**

```
Security Audit (Pre-Commit)
===========================

Secrets Scan .............. ✅ PASS (0 findings)
Manifest Security ......... ⚠️  2 warnings
Network Policies .......... ✅ All namespaces covered
PSS Labels ................ ✅ All namespaces labeled
Helm Values ............... ✅ PASS
Docs Secrets .............. ✅ PASS

Findings:
  ⚠️  manifests/foo/statefulset.yaml:25 — Missing resource limits
  ⚠️  manifests/foo/statefulset.yaml:37 — Image uses :latest tag
  ℹ️  manifests/foo/statefulset.yaml:42 — readOnlyRootFilesystem not set

Result: PASS (0 critical, 2 warnings, 1 info)
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
4. **Known safe patterns** — Don't flag `op://` paths, field name references, or placeholders
5. **File:line references** — Always include file path and line number for findings
6. **Be specific** — "Missing runAsNonRoot in container uptime-kuma" not "security issue found"
7. **When unsure, flag it** — If you can't tell whether something is a real secret, flag as WARNING for human review
