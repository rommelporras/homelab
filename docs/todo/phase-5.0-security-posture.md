# Phase 5.0: Security Posture

> **Status:** ⬜ Planned
> **Target:** v0.30.0
> **Prerequisite:** v0.29.0 (Vault + ESO)
> **DevOps Topics:** Pod Security Standards, secrets hardening, RBAC, etcd encryption
> **CKA Topics:** PSS, RBAC, EncryptionConfiguration, SecurityContext, ServiceAccount

> **Purpose:** Lock down pods, namespaces, and secrets infrastructure
>
> **Learning Goal:** Kubernetes security model — defense in depth from pod to etcd

---

## 5.0.1 Create Namespace Manifests

Foundation task — PSS labels, ESO labels, and NetworkPolicies (Phase 5.1) all depend on declarative namespace manifests.

**8 namespaces lack `namespace.yaml`:**

| Namespace | Has ExternalSecret | Helm-Managed | Needs `eso-enabled` |
|-----------|--------------------|--------------|---------------------|
| cert-manager | Yes | Yes (Helm) | Yes |
| cloudflare | Yes | No | Yes |
| gitlab | Yes | Yes (Helm) | Yes |
| gitlab-runner | Yes | Yes (Helm) | Yes |
| invoicetron-dev | Yes | No | Yes |
| invoicetron-prod | Yes | No | Yes |
| portfolio-dev | No | No | No |
| portfolio-staging | No | No | No |

> **Note:** `portfolio-prod` already has `namespace.yaml`. There is no `portfolio` namespace —
> actual namespaces are `portfolio-dev`, `portfolio-prod`, `portfolio-staging`.

> **Note:** `invoicetron-dev` and `invoicetron-prod` manifests live in a single `manifests/invoicetron/`
> directory (not separate `manifests/invoicetron-dev/` and `manifests/invoicetron-prod/` directories).
> Namespace manifests for both envs go into `manifests/invoicetron/`.

**Also need `eso-enabled` label added to existing namespace.yaml files:**
ai, arr-stack, atuin, browser, ghost-dev, ghost-prod, home, karakeep

**And these Helm-managed namespaces need the label applied imperatively + documented:**
intel-device-plugins, kube-system, monitoring, node-feature-discovery

- [ ] 5.0.1.1 Create `namespace.yaml` for each of the 8 namespaces above
  ```yaml
  # Template — adjust name, PSS level, and eso-enabled per namespace
  apiVersion: v1
  kind: Namespace
  metadata:
    name: <namespace>
    labels:
      pod-security.kubernetes.io/enforce: baseline
      pod-security.kubernetes.io/enforce-version: latest
      pod-security.kubernetes.io/warn: restricted
      pod-security.kubernetes.io/warn-version: latest
      eso-enabled: "true"  # Only if namespace has ExternalSecrets
  ```

  > **Exception:** `cloudflare` namespace currently has `enforce: restricted` (set during
  > v0.29.0). Keep it at `restricted` — do NOT downgrade to `baseline`. cloudflared pods
  > already comply with restricted profile.

- [ ] 5.0.1.2 Add `eso-enabled: "true"` label to existing namespace.yaml files
  - ai, arr-stack, atuin, browser, ghost-dev, ghost-prod, home, karakeep

- [ ] 5.0.1.3 Label Helm-managed namespaces imperatively
  ```bash
  # These namespaces are created by Helm, not by manifests
  for ns in intel-device-plugins kube-system monitoring node-feature-discovery; do
    kubectl-homelab label namespace "$ns" eso-enabled=true
  done
  ```

- [ ] 5.0.1.4 Apply all namespace manifests
  ```bash
  # Apply new and updated namespace manifests
  kubectl-homelab apply -f manifests/cert-manager/namespace.yaml
  kubectl-homelab apply -f manifests/cloudflare/namespace.yaml
  kubectl-homelab apply -f manifests/invoicetron/namespace-dev.yaml
  kubectl-homelab apply -f manifests/invoicetron/namespace-prod.yaml
  # ... etc for all 8 new + updated existing
  ```

---

## 5.0.2 Pod Security Standards

> **CKA Topic:** PSS is the replacement for deprecated PodSecurityPolicy

| Level | Use Case | Namespaces |
|-------|----------|------------|
| **Privileged** | System components | monitoring (node-exporter needs hostNetwork/hostPID), longhorn-system |
| **Baseline** | Most applications | All app namespaces |
| **Restricted** | Sensitive workloads | cloudflare (already restricted), vault, external-secrets |

> **Current state:** `external-secrets` has NO PSS labels at all. `vault` has `enforce: baseline`.
> Before setting `restricted` on vault and external-secrets, run the 5.0.2.1 audit to confirm
> their pods actually pass restricted validation. If they don't, keep baseline and document why.

> **Also missing PSS labels entirely:** intel-device-plugins, node-feature-discovery (Helm-managed).
> These need at least `enforce: baseline` + `warn: restricted` applied imperatively.

- [ ] 5.0.2.1 Audit all namespaces with `warn=restricted` dry-run
  ```bash
  # Check which pods would violate restricted profile
  for ns in $(kubectl-homelab get ns -o jsonpath='{.items[*].metadata.name}'); do
    echo "=== $ns ==="
    kubectl-homelab label namespace "$ns" \
      pod-security.kubernetes.io/warn=restricted \
      --dry-run=server -o yaml 2>&1 | grep -A2 "warning"
  done
  ```

- [ ] 5.0.2.2 Fix pod security violations
  - Add `securityContext` to pods that lack it:
    ```yaml
    spec:
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
        - securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
    ```
  - Identify pods that CANNOT run as non-root (some need writable root FS, etc.)
  - Document exceptions

- [ ] 5.0.2.3 Enforce baseline on all application namespaces
  ```bash
  # All app namespaces — enforce baseline, warn restricted
  APP_NS="ai arr-stack atuin browser ghost-dev ghost-prod \
    home invoicetron-dev invoicetron-prod gitlab gitlab-runner \
    karakeep portfolio-dev portfolio-prod portfolio-staging uptime-kuma"
  for ns in $APP_NS; do
    kubectl-homelab label namespace "$ns" \
      pod-security.kubernetes.io/enforce=baseline \
      pod-security.kubernetes.io/warn=restricted \
      --overwrite
  done

  # cloudflare already has enforce=restricted — skip (don't downgrade)
  # Verify: kubectl-homelab get ns cloudflare --show-labels

  # Helm-managed namespaces without PSS labels
  for ns in intel-device-plugins node-feature-discovery; do
    kubectl-homelab label namespace "$ns" \
      pod-security.kubernetes.io/enforce=baseline \
      pod-security.kubernetes.io/warn=restricted \
      --overwrite
  done
  ```

---

## 5.0.3 Disable automountServiceAccountToken

> **CKA Topic:** Limiting service account token exposure reduces blast radius of pod compromise

Most app pods don't need the Kubernetes API. Currently only 10 manifests set `automountServiceAccountToken`.

**Pods that NEED API access (don't disable):**
- ESO controller, webhook, cert-controller (reads/writes Secrets)
- Vault (Kubernetes auth backend)
- Prometheus, kube-state-metrics (scrapes cluster)
- Alloy (ships logs)
- node-exporter (host metrics)
- Cluster Janitor CronJob (deletes pods/replicas)
- cert-manager (manages certificates)
- Cilium (CNI)

**Pods that DON'T need API access (disable):**
- Ghost, Ghost Analytics, MySQL (ghost-dev, ghost-prod)
- Invoicetron, PostgreSQL (invoicetron-dev, invoicetron-prod)
- Atuin, PostgreSQL
- AdGuard, Homepage, MySpeed
- Firefox browser
- Cloudflared (cloudflare namespace — 2 pods)
- Karakeep, Meilisearch, Chrome, Byparr
- ARR apps (Sonarr, Radarr, Prowlarr, qBittorrent, Jellyfin, Bazarr, Seerr, Tdarr,
  Recommendarr, Unpackerr, qBittorrent-Exporter, Scraparr)
- Uptime Kuma
- Portfolio
- Ollama (ai namespace)

- [ ] 5.0.3.1 Add `automountServiceAccountToken: false` to all app pod specs
  ```yaml
  spec:
    automountServiceAccountToken: false
    # ... rest of pod spec
  ```

- [ ] 5.0.3.2 Verify apps still work after disabling
  ```bash
  kubectl-homelab get pods -A | grep -v Running
  # All pods should be Running — none should be CrashLooping from missing token
  ```

---

## 5.0.4 ESO Helm Hardening

> **Source:** ESO [Security Best Practices](https://external-secrets.io/latest/guides/security-best-practices/), [Threat Model](https://external-secrets.io/latest/guides/threat-model/)

- [ ] 5.0.4.1 Add resource limits to `helm/external-secrets/values.yaml`
  ```yaml
  resources:
    requests:
      cpu: 50m
      memory: 128Mi
    limits:
      cpu: 200m
      memory: 256Mi

  webhook:
    resources:
      requests:
        cpu: 25m
        memory: 64Mi
      limits:
        cpu: 100m
        memory: 128Mi

  certController:
    resources:
      requests:
        cpu: 25m
        memory: 64Mi
      limits:
        cpu: 100m
        memory: 128Mi
  ```

- [ ] 5.0.4.2 Disable unused CRD reconcilers (ESO threat model C05)
  ```yaml
  # Not using ClusterExternalSecret or PushSecret
  processClusterExternalSecret: false
  processPushSecret: false
  ```

- [ ] 5.0.4.3 Restrict webhook TLS ciphers
  ```yaml
  webhook:
    extraArgs:
      tls-ciphers: "TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256,TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256"
  ```

- [ ] 5.0.4.4 Helm upgrade ESO
  ```bash
  helm-homelab upgrade external-secrets external-secrets/external-secrets \
    --namespace external-secrets \
    --version 2.1.0 \
    --values helm/external-secrets/values.yaml
  ```

- [ ] 5.0.4.5 Verify ESO pods have limits after upgrade
  ```bash
  kubectl-homelab get pods -n external-secrets -o json | jq -r '
    .items[] | .metadata.name + ": " +
    (.spec.containers[0].resources | tostring)
  '
  ```

---

## 5.0.5 ClusterSecretStore Namespace Restrictions

> **ESO docs:** Use `namespaceSelector` to restrict which namespaces can reference a ClusterSecretStore

Currently any namespace can reference `vault-backend`. After this change, only namespaces with `eso-enabled: "true"` can sync secrets.

- [ ] 5.0.5.1 Add `namespaceSelector` to `manifests/vault/clustersecretstore.yaml`
  ```yaml
  spec:
    conditions:
      - namespaceSelector:
          matchLabels:
            eso-enabled: "true"
    provider:
      vault: ...  # existing config unchanged
  ```

- [ ] 5.0.5.2 Apply and verify all 30 ExternalSecrets still sync
  ```bash
  kubectl-homelab apply -f manifests/vault/clustersecretstore.yaml

  # Check all ExternalSecrets are synced
  kubectl-homelab get externalsecret -A -o json | jq -r '
    .items[] |
    .metadata.namespace + "/" + .metadata.name + " — " +
    ((.status.conditions[]? | select(.type=="Ready")) | .status)
  '
  # All should show "True"
  ```

- [ ] 5.0.5.3 Verify unlabeled namespace is blocked
  ```bash
  kubectl-homelab create namespace eso-test
  cat <<'EOF' | kubectl-homelab apply -f -
  apiVersion: external-secrets.io/v1
  kind: ExternalSecret
  metadata:
    name: test-blocked
    namespace: eso-test
  spec:
    refreshInterval: 1h
    secretStoreRef:
      name: vault-backend
      kind: ClusterSecretStore
    data:
      - secretKey: test
        remoteRef:
          key: ghost-prod/mysql
          property: root-password
  EOF
  # Should fail or show SecretSynced=False
  kubectl-homelab delete namespace eso-test
  ```

---

## 5.0.6 RBAC Audit

> **CKA Topic:** RBAC, ServiceAccount, ClusterRoleBinding

- [ ] 5.0.6.1 Audit all ServiceAccounts and their bindings
  ```bash
  kubectl-homelab get serviceaccounts -A
  kubectl-homelab get clusterrolebindings -o json | jq -r '
    .items[] | select(.roleRef.name == "cluster-admin") |
    .metadata.name + " -> " + (.subjects[]? | .kind + "/" + .name)
  '
  ```

- [ ] 5.0.6.2 Review GitLab deploy ServiceAccount
  ```bash
  # Already well-scoped: deployments(get/list/watch/patch/update),
  # replicasets(get/list/watch), pods(get/list/watch).
  # Exists in 5 namespaces (portfolio-prod, invoicetron-prod, etc.)
  # Verify bindings haven't drifted:
  for ns in portfolio-prod portfolio-dev portfolio-staging invoicetron-prod invoicetron-dev; do
    echo "=== $ns ==="
    kubectl-homelab get rolebinding -n "$ns" -o yaml 2>/dev/null | grep -A5 "roleRef"
  done
  ```

- [ ] 5.0.6.3 Verify ESO ServiceAccount is properly scoped
  ```bash
  # ESO role should only be bound to external-secrets:external-secrets SA
  kubectl-homelab auth can-i --list \
    --as=system:serviceaccount:external-secrets:external-secrets
  ```

- [ ] 5.0.6.4 Review longhorn-support-bundle cluster-admin binding
  ```bash
  # longhorn-support-bundle has a cluster-admin ClusterRoleBinding.
  # This is auto-created by Longhorn for support bundle generation.
  # Evaluate: is this acceptable, or should the binding be removed/scoped down?
  kubectl-homelab get clusterrolebinding longhorn-support-bundle -o yaml
  ```

- [ ] 5.0.6.5 Create restricted kubeconfig for Claude Code
  > **Why:** CLAUDE.md says "never read secret values" but this is policy, not technical
  > enforcement. A restricted kubeconfig makes it impossible for Claude Code to read
  > K8s Secret data, including Vault unseal keys and all ESO-synced secrets.

  ```yaml
  # ServiceAccount for Claude Code
  apiVersion: v1
  kind: ServiceAccount
  metadata:
    name: claude-code
    namespace: kube-system
  ---
  # ClusterRole: full read access EXCEPT get on secrets
  apiVersion: rbac.authorization.k8s.io/v1
  kind: ClusterRole
  metadata:
    name: claude-code-role
  rules:
    # Read all standard resources
    - apiGroups: ["", "apps", "batch", "networking.k8s.io", "policy",
                  "rbac.authorization.k8s.io", "storage.k8s.io"]
      resources: ["*"]
      verbs: ["get", "list", "watch"]
    # Override: secrets — list only (shows names/metadata, not data)
    - apiGroups: [""]
      resources: ["secrets"]
      verbs: ["list"]
    # CRDs needed for homelab operations
    - apiGroups: ["external-secrets.io", "cilium.io", "longhorn.io",
                  "gateway.networking.k8s.io", "monitoring.coreos.com"]
      resources: ["*"]
      verbs: ["get", "list", "watch"]
  ---
  apiVersion: rbac.authorization.k8s.io/v1
  kind: ClusterRoleBinding
  metadata:
    name: claude-code-binding
  roleRef:
    apiGroup: rbac.authorization.k8s.io
    kind: ClusterRole
    name: claude-code-role
  subjects:
    - kind: ServiceAccount
      name: claude-code
      namespace: kube-system
  ```

  ```bash
  # Generate kubeconfig for the SA
  # 1. Apply the SA + ClusterRole + Binding
  kubectl-homelab apply -f manifests/kube-system/claude-code-rbac.yaml

  # 2. Create a long-lived token (SA tokens are not auto-created in K8s 1.24+)
  kubectl-homelab create token claude-code -n kube-system --duration=8760h > /tmp/cc-token

  # 3. Build kubeconfig
  kubectl config set-cluster homelab \
    --server=https://10.10.30.10:6443 \
    --certificate-authority=/etc/kubernetes/pki/ca.crt \
    --kubeconfig=~/.kube/homelab.yaml
  kubectl config set-credentials claude-code \
    --token=$(cat /tmp/cc-token) \
    --kubeconfig=~/.kube/homelab.yaml
  kubectl config set-context homelab \
    --cluster=homelab --user=claude-code \
    --kubeconfig=~/.kube/homelab.yaml
  kubectl config use-context homelab --kubeconfig=~/.kube/homelab.yaml
  rm /tmp/cc-token

  # 4. Test: should return Forbidden
  kubectl-homelab get secret vault-unseal-keys -n vault -o json
  # 5. Test: should work (list shows names only)
  kubectl-homelab get secrets -n vault
  ```

- [ ] 5.0.6.6 Add Claude Code hooks to block secret reads
  > **Defense in depth:** Hooks provide fast feedback even before RBAC rejects the request.
  > Blocks commands before they reach the cluster.

  Add to `.claude/hooks.json`:
  ```json
  {
    "hooks": [
      {
        "event": "before_tool_call",
        "tool": "Bash",
        "pattern": "kubectl.*get\\s+secret.*-o\\s+(json|yaml|jsonpath)",
        "action": "block",
        "message": "Blocked: reading secret values is not allowed. Use 'kubectl get secrets' (no -o flag) to list names only."
      }
    ]
  }
  ```

  Verify hook works:
  ```bash
  # This should be blocked by hook before reaching cluster:
  kubectl-homelab get secret vault-unseal-keys -n vault -o json
  # This should succeed (list mode, no data):
  kubectl-homelab get secrets -n vault
  ```

---

## 5.0.7 etcd Encryption at Rest

> **CKA Topic:** EncryptionConfiguration — secrets in etcd are base64 by default, not encrypted

By default, kubeadm stores Secrets in etcd as plaintext base64. Anyone with etcd access can read all secrets. `EncryptionConfiguration` encrypts them at rest.

- [ ] 5.0.7.1 Create EncryptionConfiguration on all 3 control plane nodes
  ```bash
  # Generate encryption key (run once, use same key on all nodes)
  ENCRYPTION_KEY=$(head -c 32 /dev/urandom | base64)
  echo "Save this key securely: $ENCRYPTION_KEY"

  # Create config file on each CP node
  # Path: /etc/kubernetes/encryption-config.yaml
  cat <<EOF
  apiVersion: apiserver.config.k8s.io/v1
  kind: EncryptionConfiguration
  resources:
    - resources:
        - secrets
      providers:
        - aescbc:
            keys:
              - name: key1
                secret: ${ENCRYPTION_KEY}
        - identity: {}  # Fallback: read unencrypted secrets
  EOF
  ```

- [ ] 5.0.7.2 Update kube-apiserver on all 3 CP nodes
  ```bash
  # Edit /etc/kubernetes/manifests/kube-apiserver.yaml on each node
  # Add to spec.containers[0].command:
  #   --encryption-provider-config=/etc/kubernetes/encryption-config.yaml
  #
  # Add volume mount for the config file
  # API server will restart automatically (static pod)
  ```

- [ ] 5.0.7.3 Re-encrypt all existing secrets
  ```bash
  # After API server is back, re-encrypt all secrets
  kubectl-homelab get secrets -A -o json | kubectl-homelab replace -f -
  ```

- [ ] 5.0.7.4 Verify encryption works
  ```bash
  # Create a test secret
  kubectl-homelab create secret generic encryption-test \
    -n default --from-literal=test=encrypted-value

  # IMPORTANT: etcdctl is NOT installed on nodes — must exec into the etcd pod.
  # Find etcd pod on any CP node:
  ETCD_POD=$(kubectl-homelab get pods -n kube-system -l component=etcd -o jsonpath='{.items[0].metadata.name}')

  # Read directly from etcd — the value should NOT be readable as plaintext
  kubectl-homelab exec -n kube-system "$ETCD_POD" -- sh -c \
    "ETCDCTL_API=3 etcdctl get /registry/secrets/default/encryption-test \
      --cacert=/etc/kubernetes/pki/etcd/ca.crt \
      --cert=/etc/kubernetes/pki/etcd/server.crt \
      --key=/etc/kubernetes/pki/etcd/server.key" | hexdump -C | head

  # Should see "k8s:enc:aescbc:v1:key1" prefix, not plaintext

  kubectl-homelab delete secret encryption-test -n default
  ```

---

## 5.0.8 Documentation

- [ ] 5.0.8.1 Create `docs/context/Security.md`
  ```
  Document:
  - PSS levels per namespace (table)
  - RBAC roles and bindings (audit results)
  - ESO hardening decisions and known trade-offs
  - Vault + ESO trust boundaries
  - etcd encryption status
  ```

  **ESO known trade-offs to document:**

  | Decision | Rationale |
  |----------|-----------|
  | HTTP Vault connection (not HTTPS) | In-cluster only, no external exposure. mTLS adds cert overhead for minimal gain. |
  | Single ClusterSecretStore | Simpler ops. Acceptable for single admin. Revisit if adding untrusted tenants. |
  | Broad `eso-policy` (`secret/data/*`) | ESO is the only Vault consumer. Per-namespace policies = 15 roles, significant rework. |
  | No policy engine (Kyverno/OPA) | Overkill for single-admin. `namespaceSelector` provides sufficient restriction. |

- [ ] 5.0.8.2 Update `docs/reference/CHANGELOG.md`

---

## Verification Checklist

- [ ] All namespaces have declarative `namespace.yaml` (or are Helm-managed)
- [ ] PSS baseline enforced on all application namespaces (including ai, portfolio-dev/staging)
- [ ] PSS warn=restricted on all namespaces (for visibility)
- [ ] cloudflare namespace kept at `enforce: restricted` (not downgraded)
- [ ] Helm-managed namespaces (intel-device-plugins, node-feature-discovery) have PSS labels
- [ ] vault and external-secrets PSS level validated (restricted if compliant, baseline if not)
- [ ] `automountServiceAccountToken: false` on all app pods that don't need API access
- [ ] ESO pods have resource requests/limits
- [ ] Unused CRD reconcilers disabled (`ClusterExternalSecret`, `PushSecret`)
- [ ] Webhook TLS ciphers restricted to modern suites
- [ ] ClusterSecretStore has `namespaceSelector` restricting to labeled namespaces
- [ ] All 15 ESO-consuming namespaces labeled `eso-enabled=true`
- [ ] Unlabeled namespace cannot sync ExternalSecrets (tested)
- [ ] RBAC audit complete — no unexpected cluster-admin bindings
- [ ] longhorn-support-bundle cluster-admin binding reviewed
- [ ] Restricted kubeconfig for Claude Code deployed (cannot `get secret -o json`)
- [ ] Claude Code hooks block secret read commands
- [ ] etcd encryption at rest enabled and verified (via etcd pod exec, not host etcdctl)
- [ ] Security.md created with all decisions documented

---

## Rollback

**ESO namespaceSelector breaks all ExternalSecrets:**
```bash
# Emergency: remove the conditions block and re-apply
# Edit manifests/vault/clustersecretstore.yaml — remove spec.conditions
kubectl-homelab apply -f manifests/vault/clustersecretstore.yaml
```

**PSS blocks pods from starting:**
```bash
kubectl-homelab label namespace <ns> \
  pod-security.kubernetes.io/enforce=privileged \
  --overwrite
# Fix pod securityContext, then re-apply baseline
```

**etcd encryption breaks API server:**
```bash
# On CP node: remove --encryption-provider-config from
# /etc/kubernetes/manifests/kube-apiserver.yaml
# API server will restart automatically and read unencrypted secrets
```

---

## Final: Commit and Release

- [ ] `/audit-security` then `/commit`
- [ ] `/audit-docs` then `/commit`
- [ ] `/release v0.30.0 "Security Posture"`
- [ ] `mv docs/todo/phase-5.0-security-posture.md docs/todo/completed/`
