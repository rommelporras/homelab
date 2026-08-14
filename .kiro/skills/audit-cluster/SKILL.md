---
name: audit-cluster
description: |
  Triggered by: "audit cluster", "cluster security audit", "check cluster security",
  "cluster posture", "security posture". Audits live cluster security: PSS labels,
  container security contexts, privileged pods, probes, default namespace, network
  policies, Vault/ESO health, RBAC cluster-admin bindings, exposed HTTPRoutes,
  and image version drift vs VERSIONS.md. Fetches once, reuses across checks,
  cleans up temp files, produces a severity-rated PASS/FAIL report.
---

# audit-cluster

Full cluster security audit. Read-only. Uses the restricted kubeconfig for most
checks; admin kubeconfig is not needed for this audit.

## Step 1 - Verify cluster access

```bash
kubectl --kubeconfig ~/.kube/homelab-claude.yaml get nodes --no-headers 2>/dev/null | wc -l
```

If 0 or error, report "Cannot reach cluster" and stop.

## Step 2 - Collect cluster state (single fetch)

Fetch all data once and save for reuse across all checks:

```bash
kubectl --kubeconfig ~/.kube/homelab-claude.yaml get pods -A -o json > /tmp/audit-pods.json
kubectl --kubeconfig ~/.kube/homelab-claude.yaml get namespaces -o json > /tmp/audit-namespaces.json
kubectl --kubeconfig ~/.kube/homelab-claude.yaml get clusterrolebindings -o json > /tmp/audit-crbs.json
```

## Step 3 - Pod Security Standards

Check all namespaces for PSS labels:

```bash
jq -r '.items[] | [.metadata.name, (.metadata.labels["pod-security.kubernetes.io/enforce"] // "MISSING")] | @tsv' /tmp/audit-namespaces.json
```

**Classify:**
- `kube-system`, `kube-node-lease`, `kube-public`, `default` - system namespaces, PSS labels optional (INFO if missing)
- Any other namespace with running pods but no `enforce` label - WARNING

## Step 4 - Running container security

All checks use `/tmp/audit-pods.json`. Only examine pods with `status.phase == "Running"`.

**Check for root containers:**

A pod is running as non-root if any of the following is true:
- Pod spec has `securityContext.runAsNonRoot: true`
- Pod spec has `securityContext.runAsUser` > 0
- Every container has `securityContext.runAsUser` > 0

```bash
# NOTE: Use "== true | not" instead of "!=" to avoid shell escaping issues
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

- `kube-system` pods - INFO (expected for etcd, kube-proxy, etc.)
- Other namespaces - WARNING

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

- `kube-system` - INFO
- Other namespaces - CRITICAL

**Check for containers without any security context:**

```bash
jq -r '
  .items[] | select(.status.phase=="Running") |
  select(.spec.containers[] | .securityContext == null) |
  .metadata.namespace + "/" + .metadata.name
' /tmp/audit-pods.json | sort -u
```

- `kube-system` - INFO
- Other namespaces - WARNING

**Check for missing probes (liveness AND readiness both absent):**

```bash
# NOTE: Use "== ... | not" instead of "!=" to avoid shell escaping issues
jq -r '
  .items[] | select(.status.phase=="Running") |
  select(.metadata.namespace == "kube-system" | not) |
  select(.spec.containers[] | (.livenessProbe == null) and (.readinessProbe == null)) |
  .metadata.namespace + "/" + .metadata.name
' /tmp/audit-pods.json | sort -u
```

- Workload pods without any probes - WARNING

## Step 5 - Default namespace check

```bash
jq -r '
  .items[] | select(.status.phase=="Running") |
  select(.metadata.namespace == "default") |
  .metadata.namespace + "/" + .metadata.name
' /tmp/audit-pods.json
```

- Workload pods in `default` namespace - WARNING (workloads should use dedicated namespaces)
- Gateway/infrastructure pods in `default` are acceptable (INFO)

## Step 6 - Network policies

**Get namespaces with network policies:**

```bash
kubectl --kubeconfig ~/.kube/homelab-claude.yaml get ciliumnetworkpolicies -A --no-headers 2>/dev/null | awk '{print $1}' | sort -u
kubectl --kubeconfig ~/.kube/homelab-claude.yaml get networkpolicies -A --no-headers 2>/dev/null | awk '{print $1}' | sort -u
```

**Get namespaces with running workload pods:**

```bash
jq -r '
  .items[] | select(.status.phase=="Running") | .metadata.namespace
' /tmp/audit-pods.json | sort -u | grep -vE '^(kube-system|kube-node-lease|kube-public|cilium-secrets|cert-manager)$'
```

Cross-reference: workload namespace without any network policy - WARNING.

## Step 7 - Secrets infrastructure health

Check that Vault and ESO are operational. A sealed Vault or broken SecretStore means
all ExternalSecrets will fail to sync - apps get stale or missing secrets silently.

**Vault pod health (seal status via readiness):**

> **Why not check annotations?** The `vault.hashicorp.com/initialized` / `vault.hashicorp.com/sealed`
> annotations are only set by the Vault agent injector on workload pods that opt into sidecar injection -
> they are NOT set on the `vault-0` pod itself (which has `annotations: null`). Reading them on the
> Vault pod always returns "not initialized, SEALED" even when healthy - a false positive.
>
> The correct signal: the Vault Helm chart configures an `exec` readiness probe that runs `vault status`.
> If Vault is sealed or down, the probe fails and `Ready` becomes `False`. Pod `Ready=True` is the
> authoritative seal check.

```bash
kubectl --kubeconfig ~/.kube/homelab-claude.yaml get pods -n vault \
  -l app.kubernetes.io/name=vault -o json | jq -r '
  .items[] |
  .metadata.name + " - phase=" + .status.phase +
  ", ready=" + (
    (.status.conditions[]? | select(.type=="Ready") | .status) // "Unknown"
  ) +
  ", restarts=" + (
    (.status.containerStatuses[]? | .restartCount | tostring) // "0"
  )
'
```

- `phase=Running, ready=True` - unsealed
- `ready=False` - CRITICAL - Vault is sealed or crashed (exec probe is failing `vault status`)
- Pod not found / not Running - CRITICAL
- High restarts (>3) - WARNING (repeated seal/unseal cycling)

**ClusterSecretStore connectivity:**

```bash
kubectl --kubeconfig ~/.kube/homelab-claude.yaml get clustersecretstore -o json | jq -r '
  .items[] |
  .metadata.name + " - " +
  ((.status.conditions[]? | select(.type=="Ready")) | if .status=="True" then "Ready" else "NOT READY: " + (.message // "unknown") end)
'
```

- Not Ready - CRITICAL (all ExternalSecrets will fail - Vault unreachable or auth broken)

**ExternalSecret sync status:**

> **Shell escaping note:** Do NOT use `!=` inside jq - it can be mangled by some shells.
> Use `== "True" | not` instead.

```bash
kubectl --kubeconfig ~/.kube/homelab-claude.yaml get externalsecret -A -o json | jq -r '
  .items[] |
  select(
    (.status.conditions[]? | select(.type=="Ready" and (.status == "True" | not))) or
    (.status.conditions | length == 0)
  ) |
  .metadata.namespace + "/" + .metadata.name + " - " +
  ((.status.conditions[]? | select(.type=="Ready")) | .message // "no status")
'
```

- Any ExternalSecret not Ready - WARNING (secret stale or missing - check Vault path and policy)
- If no output: all synced

**Report summary line:**
```
Secrets Infrastructure ... Vault unsealed, ClusterSecretStore ready, 30/30 ExternalSecrets synced
```
or
```
Secrets Infrastructure ... CRITICAL - Vault sealed (all ExternalSecrets failing)
Secrets Infrastructure ... WARNING  - 2 ExternalSecrets not synced
```

## Step 8 - RBAC review

**List all cluster-admin bindings:**

```bash
jq -r '
  .items[] | select(.roleRef.name == "cluster-admin") |
  .metadata.name + " -> " + (.subjects[]? | .kind + "/" + .name + " (" + (.namespace // "cluster-wide") + ")")
' /tmp/audit-crbs.json
```

**Classify each binding:**
- Names starting with `system:` or `kubeadm:` - INFO (expected system bindings)
- Helm/operator bindings (cilium, longhorn, prometheus, etc.) - INFO (review if list grows unexpectedly)
- Unexpected ServiceAccount with cluster-admin - CRITICAL
- Unknown bindings - WARNING (investigate)

Do not maintain a hardcoded "expected" list. Classify by pattern: system prefixes are
expected, operator names are expected, everything else needs review.

## Step 9 - Exposed services

**List all HTTPRoutes:**

```bash
# NOTE: Quote the custom-columns argument to prevent shell glob expansion on brackets
kubectl --kubeconfig ~/.kube/homelab-claude.yaml get httproute -A \
  -o 'custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,HOSTNAMES:.spec.hostnames[0],BACKEND:.spec.rules[0].backendRefs[0].name'
```

**List all LoadBalancer services:**

```bash
kubectl --kubeconfig ~/.kube/homelab-claude.yaml get svc -A -o json | jq -r '
  .items[] | select(.spec.type == "LoadBalancer") |
  .metadata.namespace + "\t" + .metadata.name + "\t" +
  (.status.loadBalancer.ingress[0].ip // "pending") + "\t" +
  ([.spec.ports[].port | tostring] | join(","))
'
```

**Cross-reference with Gateway.md:**

Read `docs/context/Gateway.md` "Exposed Services" table. Parse the table to extract
service names and namespaces. Compare:
- HTTPRoute in cluster but NOT in Gateway.md table - WARNING (undocumented exposure)
- HTTPRoute in Gateway.md but NOT in cluster - INFO (may be temporarily down)

## Step 10 - Image version drift

**Get running images with pod context (deduplicated by namespace+pod+image):**

```bash
jq -r '
  .items[] | select(.status.phase=="Running") |
  .metadata.namespace + "/" + .metadata.name + "\t" + (.spec.containers[].image)
' /tmp/audit-pods.json | sort -u
```

**Compare against VERSIONS.md:**

Read `VERSIONS.md`. For each tracked component, find the matching image in the pod output.

**Classification rules - apply in order:**

1. **Helm-bundled sidecar (different chart context)** - INFO, not drift.
   Some images are bundled independently by multiple Helm charts and legitimately exist at
   different versions. When the same image name appears at two versions, check which namespace
   each lives in.
   - If one is in `monitoring` (kube-prometheus-stack) and another in the same namespace but
     different pod (e.g., grafana/alloy DaemonSet), that is expected - each chart bundles its
     own pinned version.
   - Known multi-chart sidecar images (expect version diversity across pods):
     - `prometheus-operator/prometheus-config-reloader` - bundled by kube-prometheus-stack AND grafana/alloy at different versions
     - `kiwigrid/k8s-sidecar` - bundled by Grafana helm chart
     - `kube-rbac-proxy` - bundled by various operators independently
   - To identify which pod/chart owns which version: look at pod name prefix and labels, not just image alone

2. **Image not in VERSIONS.md** - INFO (system/infrastructure images, no tracking needed)

3. **Version mismatch for a tracked image, same chart context** - WARNING (may indicate untracked upgrade)

**When flagging a version mismatch, always include:**
- Which specific pod(s) have the mismatched version (namespace/pod-name)
- Which pod(s) have the expected version
- Whether the pod with the mismatch belongs to a different Helm chart than what VERSIONS.md tracks

**Do NOT recommend deleting a pod** as a remediation step unless you have first verified the replica count:

```bash
# Check replicas before recommending any pod deletion
kubectl --kubeconfig ~/.kube/homelab-claude.yaml get statefulset -n <namespace> <name> \
  -o jsonpath='{.spec.replicas}{"\n"}'
kubectl --kubeconfig ~/.kube/homelab-claude.yaml get deployment -n <namespace> <name> \
  -o jsonpath='{.spec.replicas}{"\n"}'
```

If replicas == 1, pod deletion causes a brief outage. State this explicitly. Let the user decide.

## Step 11 - Cleanup

```bash
rm -f /tmp/audit-pods.json /tmp/audit-namespaces.json /tmp/audit-crbs.json
```

## Step 12 - Generate report

**Format:**

```
Cluster Security Audit
======================
Date: YYYY-MM-DD
Cluster: 3 nodes, v1.35.x

Pod Security Standards .... [status]
Running Containers ........ [status]
Default Namespace ......... [status]
Network Policies .......... [status]
Secrets Infrastructure .... [status]
RBAC ...................... [status]
Exposed Services .......... [status]
Image Versions ............ [status]

Findings:
  INFO     kube-system/kube-proxy-abc - Running as root (expected for system component)
  WARNING  monitoring/prometheus-node-exporter-xyz - No readiness probe

Result: PASS (0 critical, 1 warning, 1 info)
```

**Severity levels:**
- CRITICAL - Privileged workload containers (non-system), unexpected cluster-admin SA, undocumented external exposure
- WARNING - Missing security context, no network policy, root containers (non-system), real image drift, workloads in default namespace
- INFO - System namespace defaults, expected operator bindings, temporarily missing services, Helm-bundled sidecar version diversity

**Pass/fail logic:**
- 0 critical = PASS
- 1+ critical = FAIL

**Expected findings (flag but do not alarm):**
- `kube-system` pods running as root - system components
- `kube-system` pods without probes - managed by kubelet
- System/operator ClusterRoleBindings - expected
- Gateway controller pods in `default` namespace - that is where the Gateway resource lives
- Multiple versions of `prometheus-config-reloader` - kube-prometheus-stack and grafana/alloy each bundle their own pinned version; both are correct
- Multiple versions of `k8s-sidecar` - Grafana helm chart bundles its own; other charts may too
- Network policies missing on Helm-managed namespaces (gitlab, monitoring, longhorn-system, tailscale, cert-manager) - policies may be configured in Helm values; use live cluster inspection to verify
- Vault pod `vault-0` may show no readiness probe in pod spec - liveness/readiness handled by Vault Helm chart via `vault status` exec probe; check via `kubectl --kubeconfig ~/.kube/homelab-claude.yaml describe pod vault-0 -n vault` if flagged

## Important rules

1. **Read-only** - Never modify cluster resources or files
2. **Never bare kubectl or helm** - always use `kubectl --kubeconfig ~/.kube/homelab-claude.yaml` (wrong cluster otherwise)
3. **Fetch once, reuse** - Collect pod/namespace/CRB JSON once, reuse across all checks
4. **Classify by pattern, not hardcoded lists** - System prefixes, operator names, etc.
5. **System vs workload** - Different expectations for kube-system vs application namespaces
6. **Evidence-based** - Show the actual data that led to each finding (namespace/pod-name for every finding)
7. **Verify before recommending destructive actions** - Always check replica count before suggesting pod deletion; if replicas == 1, note the outage risk and let user decide
8. **Multi-chart sidecars are not drift** - When the same sidecar image exists at two versions across different Helm chart pods, that is expected chart bundling, not version drift
9. **Cleanup temp files** - Remove /tmp/audit-*.json when done
