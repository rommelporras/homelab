# Cluster Security Audit

Audit live cluster security posture. Requires cluster access via `kubectl-homelab`.

## Usage

```
/audit-cluster           → Full cluster security audit
```

Run on-demand when you want a deep security check of the running cluster.

## Instructions

### 1. Verify Cluster Access

```bash
kubectl-homelab get nodes --no-headers 2>/dev/null | wc -l
```

If 0 or error: report "Cannot reach cluster" and stop.

### 2. Collect Cluster State (Single Fetch)

Fetch all pod data once and save for reuse across checks:

```bash
kubectl-homelab get pods -A -o json > /tmp/audit-pods.json
kubectl-homelab get namespaces -o json > /tmp/audit-namespaces.json
kubectl-homelab get clusterrolebindings -o json > /tmp/audit-crbs.json
```

### 3. Pod Security Standards

Check all namespaces for PSS labels:

```bash
jq -r '.items[] | [.metadata.name, (.metadata.labels["pod-security.kubernetes.io/enforce"] // "MISSING")] | @tsv' /tmp/audit-namespaces.json
```

**Classify:**
- `kube-system`, `kube-node-lease`, `kube-public`, `default` — system namespaces, PSS labels optional (ℹ️ INFO if missing)
- Any other namespace with running pods but no `enforce` label → ⚠️ WARNING

### 4. Running Container Security

All checks use `/tmp/audit-pods.json`. Only examine pods with `status.phase == "Running"`.

**Check for root containers:**

Check both pod-level and container-level securityContext. A pod is running as non-root if either:
- Pod spec has `securityContext.runAsNonRoot: true`, OR
- Pod spec has `securityContext.runAsUser` > 0, OR
- Every container has `securityContext.runAsUser` > 0

```bash
# Pods where runAsNonRoot is not set at pod or container level
# NOTE: Use "== true | not" instead of "!=" to avoid zsh shell escaping issues
jq -r '
  .items[] | select(.status.phase=="Running") |
  select(
    (.spec.securityContext.runAsNonRoot == true | not) and
    ((.spec.securityContext.runAsUser // 0) == 0) and
    (.spec.containers | any(.securityContext.runAsUser == null or .securityContext.runAsUser == 0))
  ) |
  .metadata.namespace + "/" + .metadata.name
' /tmp/audit-pods.json | sort -u
```

- `kube-system` pods → ℹ️ INFO (expected for etcd, kube-proxy, etc.)
- Other namespaces → ⚠️ WARNING

**Check for privileged containers (including init containers):**
```bash
jq -r '
  .items[] | select(.status.phase=="Running") |
  select(
    (.spec.containers[]?.securityContext.privileged == true) or
    (.spec.initContainers[]?.securityContext.privileged == true)
  ) |
  .metadata.namespace + "/" + .metadata.name
' /tmp/audit-pods.json | sort -u
```
- `kube-system` → ℹ️ INFO
- Other namespaces → ⛔ CRITICAL

**Check for containers without any security context:**
```bash
jq -r '
  .items[] | select(.status.phase=="Running") |
  select(.spec.containers[] | .securityContext == null) |
  .metadata.namespace + "/" + .metadata.name
' /tmp/audit-pods.json | sort -u
```
- `kube-system` → ℹ️ INFO
- Other namespaces → ⚠️ WARNING

**Check for missing probes (liveness AND readiness both absent):**
```bash
# NOTE: Use "== ... | not" instead of "!=" to avoid zsh shell escaping issues
jq -r '
  .items[] | select(.status.phase=="Running") |
  select(.metadata.namespace == "kube-system" | not) |
  select(.spec.containers[] | (.livenessProbe == null) and (.readinessProbe == null)) |
  .metadata.namespace + "/" + .metadata.name
' /tmp/audit-pods.json | sort -u
```
- Workload pods without any probes → ⚠️ WARNING

### 5. Default Namespace Check

```bash
jq -r '
  .items[] | select(.status.phase=="Running") |
  select(.metadata.namespace == "default") |
  .metadata.namespace + "/" + .metadata.name
' /tmp/audit-pods.json
```

- Workload pods in `default` namespace → ⚠️ WARNING (workloads should use dedicated namespaces)
- Gateway/infrastructure pods in `default` are acceptable (ℹ️ INFO)

### 6. Network Policies

**Get namespaces with network policies:**
```bash
kubectl-homelab get ciliumnetworkpolicies -A --no-headers 2>/dev/null | awk '{print $1}' | sort -u
kubectl-homelab get networkpolicies -A --no-headers 2>/dev/null | awk '{print $1}' | sort -u
```

**Get namespaces with running workload pods:**
```bash
jq -r '
  .items[] | select(.status.phase=="Running") | .metadata.namespace
' /tmp/audit-pods.json | sort -u | grep -vE '^(kube-system|kube-node-lease|kube-public|cilium-secrets|cert-manager)$'
```

Cross-reference: workload namespace without any network policy → ⚠️ WARNING

### 7. RBAC Review

**List all cluster-admin bindings:**
```bash
jq -r '
  .items[] | select(.roleRef.name == "cluster-admin") |
  .metadata.name + " → " + (.subjects[]? | .kind + "/" + .name + " (" + (.namespace // "cluster-wide") + ")")
' /tmp/audit-crbs.json
```

**Classify each binding:**
- Names starting with `system:` or `kubeadm:` → ℹ️ INFO (expected system bindings)
- Helm/operator bindings (cilium, longhorn, prometheus, etc.) → ℹ️ INFO (review if list grows unexpectedly)
- Unexpected ServiceAccount with cluster-admin → ⛔ CRITICAL
- Unknown bindings → ⚠️ WARNING (investigate)

**Don't maintain a hardcoded "expected" list.** Instead, classify by pattern: system prefixes are expected, operator names are expected, everything else needs review.

### 8. Exposed Services

**List all HTTPRoutes:**
```bash
# NOTE: Quote the custom-columns argument to prevent zsh glob expansion on brackets
kubectl-homelab get httproute -A -o 'custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,HOSTNAMES:.spec.hostnames[0],BACKEND:.spec.rules[0].backendRefs[0].name'
```

**List all LoadBalancer services:**
```bash
kubectl-homelab get svc -A -o json | jq -r '
  .items[] | select(.spec.type == "LoadBalancer") |
  .metadata.namespace + "\t" + .metadata.name + "\t" +
  (.status.loadBalancer.ingress[0].ip // "pending") + "\t" +
  ([.spec.ports[].port | tostring] | join(","))
'
```

**Cross-reference with Gateway.md:**
Read `docs/context/Gateway.md` "Exposed Services" table. Parse the table to extract service names and namespaces. Compare:
- HTTPRoute in cluster but NOT in Gateway.md table → ⚠️ WARNING (undocumented exposure)
- HTTPRoute in Gateway.md but NOT in cluster → ℹ️ INFO (may be temporarily down)

### 9. Image Version Drift

**Get running images (deduplicated):**
```bash
jq -r '
  .items[] | select(.status.phase=="Running") |
  .metadata.namespace + "\t" + (.spec.containers[].image)
' /tmp/audit-pods.json | sort -u
```

**Compare against VERSIONS.md:**
Read `VERSIONS.md`. For each component listed, check if the running image version matches the documented version.
- Version mismatch → ⚠️ WARNING (may indicate untracked upgrade or drift)
- Image not in VERSIONS.md → ℹ️ INFO (system images don't need tracking)

### 10. Cleanup

```bash
rm -f /tmp/audit-pods.json /tmp/audit-namespaces.json /tmp/audit-crbs.json
```

### 11. Generate Report

**Format:**

```
Cluster Security Audit
======================
Date: YYYY-MM-DD
Cluster: 3 nodes, v1.35.x

Pod Security Standards .... ✅ 15/15 workload namespaces enforced
Running Containers ........ ⚠️  2 warnings
Default Namespace ......... ✅ No workloads in default
Network Policies .......... ✅ All workload namespaces covered
RBAC ...................... ✅ Only expected bindings
Exposed Services .......... ✅ Matches Gateway.md
Image Versions ............ ✅ All match VERSIONS.md

Findings:
  ℹ️  kube-system/kube-proxy-abc — Running as root (expected for system component)
  ⚠️  monitoring/prometheus-node-exporter-xyz — No readiness probe

Result: PASS (0 critical, 1 warning, 1 info)
```

**Severity levels:**
- ⛔ CRITICAL — Privileged workload containers (non-system), unexpected cluster-admin SA, undocumented external exposure
- ⚠️ WARNING — Missing security context, no network policy, root containers (non-system), image drift, workloads in default namespace
- ℹ️ INFO — System namespace defaults, expected operator bindings, temporarily missing services

**Pass/fail logic:**
- 0 critical = PASS
- 1+ critical = FAIL

**Expected findings (flag but don't alarm):**
- `kube-system` pods running as root — system components
- `kube-system` pods without probes — managed by kubelet
- System/operator ClusterRoleBindings — expected
- Gateway controller pods in `default` namespace — that's where the Gateway resource lives

## Important Rules

1. **Read-only** — Never modify cluster resources or files
2. **Uses kubectl-homelab** — Never plain `kubectl` (wrong cluster)
3. **Fetch once, reuse** — Collect pod/namespace/CRB JSON once, reuse across checks
4. **Classify by pattern, not hardcoded lists** — System prefixes, operator names, etc.
5. **System vs workload** — Different expectations for kube-system vs application namespaces
6. **Evidence-based** — Show the actual data that led to each finding
7. **Cleanup temp files** — Remove /tmp/audit-*.json when done
