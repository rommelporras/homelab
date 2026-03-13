# Phase 5.2: RBAC & Secrets Hardening

> **Status:** ⬜ Planned
> **Target:** v0.32.0
> **Prerequisite:** Phase 5.1 (v0.31.0 — control plane hardened, audit logging active)
> **DevOps Topics:** RBAC, etcd encryption, least-privilege access, defense in depth
> **CKA Topics:** RBAC, ServiceAccount, ClusterRoleBinding, EncryptionConfiguration

> **Purpose:** Lock down access control and protect secrets at rest
>
> **Learning Goal:** Kubernetes RBAC model and secrets encryption — defense in depth from API to storage

---

## 5.2.1 RBAC Audit

> **CKA Topic:** RBAC, ServiceAccount, ClusterRoleBinding

- [ ] 5.2.1.1 Audit all ServiceAccounts and their bindings
  ```bash
  kubectl-homelab get serviceaccounts -A
  kubectl-homelab get clusterrolebindings -o json | jq -r '
    .items[] | select(.roleRef.name == "cluster-admin") |
    .metadata.name + " -> " + (.subjects[]? | .kind + "/" + .name)
  '
  ```

- [ ] 5.2.1.2 Review GitLab deploy ServiceAccount
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

- [ ] 5.2.1.3 Verify ESO ServiceAccount is properly scoped
  ```bash
  # ESO role should only be bound to external-secrets:external-secrets SA
  kubectl-homelab auth can-i --list \
    --as=system:serviceaccount:external-secrets:external-secrets
  ```

- [ ] 5.2.1.4 Review longhorn-support-bundle cluster-admin binding
  ```bash
  # longhorn-support-bundle has a cluster-admin ClusterRoleBinding.
  # This is auto-created by Longhorn for support bundle generation.
  # Evaluate: is this acceptable, or should the binding be removed/scoped down?
  kubectl-homelab get clusterrolebinding longhorn-support-bundle -o yaml
  ```

---

## 5.2.2 etcd Encryption at Rest

> **CKA Topic:** EncryptionConfiguration — secrets in etcd are base64 by default, not encrypted

By default, kubeadm stores Secrets in etcd as plaintext base64. Anyone with etcd access can read all secrets. `EncryptionConfiguration` encrypts them at rest.

> **Rolling update strategy:**
> - etcd encryption requires adding `--encryption-provider-config` to the API server manifest on all 3 CP nodes
> - This requires a rolling restart: CP1 → verify → CP2 → verify → CP3
> - Same safety model as Phase 5.1 (always 2/3 nodes healthy)
> - The EncryptionConfiguration file must be created on ALL 3 nodes BEFORE adding the API server flag on any node
> - After all 3 API servers have the flag, re-encrypt all existing secrets with `kubectl-homelab get secrets -A -o json | kubectl-homelab replace -f -`

- [ ] 5.2.2.1 Create EncryptionConfiguration on all 3 control plane nodes
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

- [ ] 5.2.2.2 Update kube-apiserver on all 3 CP nodes
  ```bash
  # Edit /etc/kubernetes/manifests/kube-apiserver.yaml on each node
  # Add to spec.containers[0].command:
  #   --encryption-provider-config=/etc/kubernetes/encryption-config.yaml
  #
  # Add volume mount for the config file
  # API server will restart automatically (static pod)
  ```

- [ ] 5.2.2.3 Re-encrypt all existing secrets
  ```bash
  # After API server is back, re-encrypt all secrets
  kubectl-homelab get secrets -A -o json | kubectl-homelab replace -f -
  ```

- [ ] 5.2.2.4 Verify encryption works
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

- [ ] 5.2.2.5 Back up encryption key to 1Password
  ```bash
  # IMPORTANT: Do NOT run this command — generate it for the user to run in their safe terminal
  # op item create --vault=Kubernetes --title="etcd Encryption Key" --category=password password=$ENCRYPTION_KEY
  ```

---

## 5.2.3 Claude Code Restricted Kubeconfig

> **Why:** CLAUDE.md says "never read secret values" but this is policy, not technical
> enforcement. A restricted kubeconfig makes it impossible for Claude Code to read
> K8s Secret data, including Vault unseal keys and all ESO-synced secrets.

- [ ] 5.2.3.1 Create restricted ServiceAccount, ClusterRole, and ClusterRoleBinding
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

- [ ] 5.2.3.2 Generate kubeconfig for the ServiceAccount
  ```bash
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

---

## 5.2.4 Claude Code Hooks

> **Defense in depth:** Hooks provide fast feedback even before RBAC rejects the request.
> Blocks commands before they reach the cluster.

- [ ] 5.2.4.1 Add hooks to `.claude/hooks.json`
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

- [ ] 5.2.4.2 Verify hook works
  ```bash
  # This should be blocked by hook before reaching cluster:
  kubectl-homelab get secret vault-unseal-keys -n vault -o json
  # This should succeed (list mode, no data):
  kubectl-homelab get secrets -n vault
  ```

---

## 5.2.5 Documentation

- [ ] 5.2.5.1 Update `docs/context/Security.md` with:
  - RBAC audit results (ServiceAccounts, bindings, cluster-admin usage)
  - etcd encryption status and key management
  - Claude Code access restrictions
  - RBAC trust boundaries
- [ ] 5.2.5.2 Update `docs/reference/CHANGELOG.md`

---

## Verification Checklist

- [ ] RBAC audit complete — no unexpected cluster-admin bindings
- [ ] longhorn-support-bundle cluster-admin binding reviewed
- [ ] etcd encryption at rest enabled and verified (via etcd pod exec)
- [ ] Encryption key backed up to 1Password
- [ ] Restricted kubeconfig for Claude Code deployed (cannot `get secret -o json`)
- [ ] Claude Code hooks block secret read commands

---

## Rollback

**etcd encryption breaks API server:**
```bash
# On CP node: remove --encryption-provider-config from
# /etc/kubernetes/manifests/kube-apiserver.yaml
# API server will restart automatically and read unencrypted secrets
```

**API server manifest restore procedure:**
```bash
# If the API server fails to start after adding --encryption-provider-config:
# 1. SSH to the affected CP node
ssh wawashi@10.10.30.11

# 2. Check API server container logs
sudo crictl logs $(sudo crictl ps -a --name kube-apiserver -q | head -1)

# 3. Remove the encryption flag from the static pod manifest
sudo vi /etc/kubernetes/manifests/kube-apiserver.yaml
# Remove: --encryption-provider-config=/etc/kubernetes/encryption-config.yaml
# Remove: the volume and volumeMount for encryption-config.yaml

# 4. API server will restart automatically (static pod)
# 5. Verify API server is healthy
kubectl-homelab get nodes

# 6. Repeat on other CP nodes if they were also modified
# 7. Existing secrets remain readable (identity provider is the fallback)
```

**Restricted kubeconfig breaks Claude Code operations:**
```bash
# Restore the original admin kubeconfig
# The admin kubeconfig is the one originally set up by kubeadm
# Copy it back to ~/.kube/homelab.yaml
```

---

## Final: Commit and Release

- [ ] `/audit-security` then `/commit`
- [ ] `/audit-docs` then `/commit`
- [ ] `/release v0.32.0 "RBAC & Secrets Hardening"`
- [ ] `mv docs/todo/phase-5.2-rbac-secrets.md docs/todo/completed/`
