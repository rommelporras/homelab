# Phase 5.2: RBAC & Secrets Hardening

> **Status:** 🔄 In Progress (RBAC audit executed 2026-03-15, etcd encryption pending)
> **Target:** v0.32.0
> **Prerequisite:** Phase 5.1 (v0.31.0 — control plane hardened, audit logging active)
> **DevOps Topics:** RBAC, etcd encryption, least-privilege access, defense in depth
> **CKA Topics:** RBAC, ServiceAccount, ClusterRoleBinding, EncryptionConfiguration

> **Purpose:** Lock down access control and protect secrets at rest
>
> **Learning Goal:** Kubernetes RBAC model and secrets encryption — defense in depth from API to storage

---

## Pre-Execution Audit (2026-03-15)

> Cluster state verified against plan assumptions. All commands run against live cluster.
> Findings below are categorized as: ✅ Verified, ⚠️ Corrected, ⛔ Blocked/Removed.

### Cluster Baseline

| Component | Value | Source |
|-----------|-------|--------|
| Kubernetes | v1.35.0 | `kubectl version` |
| etcd | 3.6.6-0 | etcd pod image |
| Nodes | 3 CP (Ready) | `kubectl get nodes` |
| ServiceAccounts | 110 | `kubectl get sa -A` |
| ClusterRoleBindings | 82 | `kubectl get clusterrolebindings` |
| Secrets | 126 total, 0 immutable | `kubectl get secrets -A` |
| etcd encryption | NOT configured | grep on all 3 API server manifests |
| Current kubeconfig | `kubernetes-admin` (client cert, system:masters) | `kubectl config view` |

### Assumption Corrections

| # | Original Assumption | Reality | Impact |
|---|---------------------|---------|--------|
| 1 | `aescbc` is a good encryption provider | k8s docs: "not recommended due to CBC's vulnerability to padding oracle attacks." **Use `secretbox`** (XSalsa20-Poly1305) | ⛔ Plan rewritten to use secretbox |
| 2 | `hexdump` works in etcd pod | etcd:3.6.6-0 is distroless — no `hexdump`, `ls`, or `which`. Only `etcdctl` and `sh` | ⚠️ Verification rewritten |
| 3 | Plan only mentions longhorn-support-bundle as RBAC risk | **GitLab Runner has `resources: ["*"], verbs: ["*"]` on core API** — full CRUD on ALL core resources | ⛔ New audit item added |
| 4 | Kubeconfig commands use `~/.kube/homelab.yaml` | This OVERWRITES the admin kubeconfig, locking out admin | ⛔ Separate file + alias update |
| 5 | `.claude/hooks.json` with pattern/action/message | Hooks are in `settings.json` under `hooks` key, using `type: "command"` shell scripts | ⛔ Hooks section rewritten |
| 6 | `secrets` verb `["list"]` prevents data exposure | `list` returns full Secret objects including `data` field. Hooks are ESSENTIAL, not optional | ⚠️ Defense-in-depth note added |
| 7 | version-check-cronjob is fine | Has `get`+`list` on secrets cluster-wide — investigate if needed | ⚠️ New audit item added |
| 8 | `mv phase-5.2-rbac-secrets.md` | Actual filename is `phase-5.2-rbac-and-encryption.md` | ⚠️ Fixed |

---

## 5.2.1 RBAC Audit

> **CKA Topic:** RBAC, ServiceAccount, ClusterRoleBinding

- [x] 5.2.1.1 Audit all ServiceAccounts and their bindings
  > **✅ VERIFIED (2026-03-15):** 3 cluster-admin bindings, all expected. No surprises.
  > - `cluster-admin → Group/system:masters` — kubeadm bootstrap ✅
  > - `kubeadm:cluster-admins → Group/kubeadm:cluster-admins` — kubeadm bootstrap ✅
  > - `longhorn-support-bundle → SA/longhorn-system/longhorn-support-bundle` — see 5.2.1.5 ✅
  ```bash
  kubectl-homelab get clusterrolebindings -o json | jq -r '
    .items[] | select(.roleRef.name == "cluster-admin") |
    .metadata.name + " -> " + (.subjects[]? | .kind + "/" + .name)
  '
  ```

- [x] 5.2.1.2 Review GitLab deploy ServiceAccount
  > **✅ VERIFIED (2026-03-15):** Well-scoped in all 5 namespaces, no drift detected.
  > - portfolio-prod/dev/staging: `deployments(get/list/watch/patch/update)`, `replicasets(get/list/watch)`, `pods(get/list/watch)`
  > - invoicetron-prod/dev: same + `batch/jobs(get/list/watch/create/delete)` — for backup CronJob integration ✅
  > No secrets access. All bindings namespace-scoped to their own namespace. ✅
  ```bash
  for ns in portfolio-prod portfolio-dev portfolio-staging invoicetron-prod invoicetron-dev; do
    echo "=== $ns ==="
    kubectl-homelab get role gitlab-deploy -n "$ns" -o yaml
  done
  ```

- [ ] 5.2.1.3 ⛔ **Fix GitLab Runner ClusterRole — scope to namespace Role**
  > **DECISION (2026-03-15):** Fix now. `rbac.clusterWideAccess: false` in Helm values.
  > Runner config confirms `namespace = "gitlab-runner"` — all job pods created in that namespace.
  > Switching to namespace-scoped Role removes cluster-wide secrets/pods/services CRUD.
  > Helm chart default Role for the executor covers: pods, pods/log, pods/exec, pods/attach,
  > pods/status, secrets, configmaps, serviceaccounts in the runner namespace.
  ```bash
  # 1. Update helm/gitlab-runner/values.yaml: rbac.clusterWideAccess: true → false
  # 2. Helm upgrade (Helm will delete ClusterRole/ClusterRoleBinding, create Role/RoleBinding)
  helm-homelab upgrade gitlab-runner gitlab/gitlab-runner -n gitlab-runner \
    -f helm/gitlab-runner/values.yaml

  # 3. Verify: ClusterRole gone, namespace Role present
  kubectl-homelab get clusterrole gitlab-runner 2>&1         # expected: NotFound
  kubectl-homelab get role -n gitlab-runner                  # expected: namespace Role present

  # 4. Test: trigger a non-critical CI/CD pipeline and verify it completes
  # ⚠️ Rollback: set clusterWideAccess: true + helm upgrade if pipelines break
  ```

- [x] 5.2.1.4 Verify ESO ServiceAccount is properly scoped
  > **✅ VERIFIED (2026-03-15):** Correctly scoped for ESO's function.
  > - `secrets: get/list/watch/create/update/delete/patch` — all needed to sync Vault → K8s Secrets
  > - `configmaps/namespaces/serviceaccounts: get/list/watch` — read-only
  > - All ESO CRDs: full CRUD (ExternalSecrets, SecretStores, Generators)
  ```bash
  kubectl-homelab auth can-i --list \
    --as=system:serviceaccount:external-secrets:external-secrets
  ```

- [x] 5.2.1.5 Review longhorn-support-bundle cluster-admin binding
  > **✅ ACCEPTED (2026-03-15):** Helm-managed (longhorn-1.10.1). SA is only activated when
  > manually generating a support bundle via the Longhorn UI — not running continuously.
  > Removing breaks the support bundle feature. Document in Security.md as accepted risk.
  ```bash
  kubectl-homelab get clusterrolebinding longhorn-support-bundle -o yaml
  ```

- [ ] 5.2.1.6 ⚠️ **Fix version-check-cronjob — broken Nova auth (bug from Phase 5.0)**
  > **BUG FOUND (2026-03-15):** `automountServiceAccountToken: false` was added during Phase 5.0
  > hardening without realizing Nova needs K8s API access to read Helm release secrets.
  >
  > **Evidence:**
  > - Last run (6d ago, job `version-check-29548800`) used OLD template — token WAS mounted,
  >   Nova worked correctly, detected **11 outdated charts**
  > - Current CronJob template: `automountServiceAccountToken: false`, no projected token volume
  > - Next Sunday's run: Nova fails auth → caught by `|| echo '[]'` → Discord reports
  >   "0 outdated, 0 deprecated, 0 current" **regardless of actual cluster state** (silent failure)
  >
  > **Why ClusterRole is legitimate:** Nova `find --helm` reads Helm release secrets cluster-wide
  > (`type: helm.sh/release.v1`). RBAC cannot filter by secret type. `get/list` is correct and needed.
  > Nova only reads release metadata (chart name, version) — never exposes secret values.
  >
  > **Fix:** Remove `automountServiceAccountToken: false` from the CronJob pod spec.
  ```bash
  # Edit manifests/monitoring/version-checker/version-check-cronjob.yaml:
  # Remove: automountServiceAccountToken: false
  kubectl-homelab apply -f manifests/monitoring/version-checker/version-check-cronjob.yaml

  # Verify next run works by triggering manually:
  kubectl-homelab create job version-check-test --from=cronjob/version-check -n monitoring
  kubectl-homelab logs -n monitoring -l job-name=version-check-test -c version-check -f
  # Expected: "Summary: X outdated, Y deprecated, Z current" (non-zero results if drift exists)
  kubectl-homelab delete job version-check-test -n monitoring
  ```

- [x] 5.2.1.7 Verify well-scoped SAs (quick check)
  > **✅ VERIFIED (2026-03-15):** All confirmed properly scoped.
  > - `homepage`: namespaces/pods/nodes, deployments/statefulsets/daemonsets/replicasets,
  >   ingresses, httproutes, metrics — read-only, **no secrets** ✅
  > - `cluster-janitor`: pods(get/list/delete), longhorn replicas(get/list/delete),
  >   longhorn volumes(get/list) — **no secrets** ✅
  > - `alloy`, `cert-manager`, `tailscale-operator`: confirmed in pre-execution audit ✅
  > No action needed — document in Security.md.

---

## 5.2.2 etcd Encryption at Rest

> **CKA Topic:** EncryptionConfiguration — secrets in etcd are base64 by default, not encrypted

By default, kubeadm stores Secrets in etcd as plaintext base64. Anyone with etcd access can read all secrets. `EncryptionConfiguration` encrypts them at rest.

> **⚠️ CORRECTED:** Plan originally used `aescbc`. Kubernetes docs state aescbc is "not recommended
> due to CBC's vulnerability to padding oracle attacks." Changed to `secretbox` (XSalsa20-Poly1305),
> which is stronger, faster, and recommended for new deployments.

> **Rolling update strategy:**
> - etcd encryption requires adding `--encryption-provider-config` to the API server manifest on all 3 CP nodes
> - This requires a rolling restart: CP1 → 5-min soak → verify → CP2 → 5-min soak → verify → CP3
> - Same safety model as Phase 5.1 (always 2/3 nodes healthy)
> - The EncryptionConfiguration file must be created on ALL 3 nodes BEFORE adding the API server flag on any node
> - After all 3 API servers have the flag, re-encrypt all existing secrets
> - **Phase 5.1 pattern:** No scp between nodes — create files directly on each node via SSH from WSL
> - **Phase 5.1 pattern:** Static pod restart takes ~30-45s. Monitor with `crictl ps` on the node.

- [ ] 5.2.2.1 Create EncryptionConfiguration on all 3 control plane nodes
  ```bash
  # Generate encryption key (run once, use same key on all nodes)
  # secretbox requires a 32-byte key, base64-encoded
  ENCRYPTION_KEY=$(head -c 32 /dev/urandom | base64)
  echo "Save this key securely: $ENCRYPTION_KEY"

  # Create config file on each CP node via SSH from WSL (no scp between nodes!)
  # Path: /etc/kubernetes/encryption-config.yaml
  # /etc/kubernetes/ is writable (drwxrwxr-x) on all nodes — verified
  for node in 11 12 13; do
    ssh wawashi@10.10.30.$node "sudo tee /etc/kubernetes/encryption-config.yaml" <<EOF
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
    providers:
      - secretbox:
          keys:
            - name: key1
              secret: ${ENCRYPTION_KEY}
      - identity: {}
EOF
    # Lock down permissions (only root should read the key)
    ssh wawashi@10.10.30.$node "sudo chmod 600 /etc/kubernetes/encryption-config.yaml"
  done

  # Verify file exists and has correct permissions on all nodes
  for node in 11 12 13; do
    echo "=== k8s-cp$((node-10)) ==="
    ssh wawashi@10.10.30.$node "sudo ls -la /etc/kubernetes/encryption-config.yaml"
  done
  ```
  > **⚠️ IMPORTANT:** The encryption key will be visible in the terminal. Run this in a secure
  > terminal, not through Claude Code. Generate the op item create command for the user.

- [ ] 5.2.2.2 Update kube-apiserver on all 3 CP nodes (rolling)
  ```bash
  # Rolling update: CP1 → verify → CP2 → verify → CP3
  # Each node: edit manifest, wait for restart, verify health
  #
  # Add to spec.containers[0].command:
  #   --encryption-provider-config=/etc/kubernetes/encryption-config.yaml
  #
  # Add volumeMount (same pattern as audit-policy from Phase 5.1):
  #   - mountPath: /etc/kubernetes/encryption-config.yaml
  #     name: encryption-config
  #     readOnly: true
  #
  # Add volume:
  #   - hostPath:
  #       path: /etc/kubernetes/encryption-config.yaml
  #       type: File
  #     name: encryption-config
  #
  # ⚠️ Use Python yaml.safe_load/yaml.dump to edit (Phase 5.1 pattern) — not sed/vi
  # ⚠️ Static pod restart takes ~30-45s. Check with: sudo crictl ps --name kube-apiserver
  # ⚠️ After restart, verify: kubectl-homelab get nodes (all 3 Ready)
  # ⚠️ Wait 5 minutes and check events before proceeding to next node
  ```

- [ ] 5.2.2.3 Re-encrypt all existing secrets
  ```bash
  # 126 secrets total (38 have ownerReferences — these are ESO-managed and safe to replace)
  # No immutable secrets — verified
  #
  # Re-encrypt all secrets so they use the new encryption provider:
  kubectl-homelab get secrets -A -o json | kubectl-homelab replace -f -
  #
  # ⚠️ RISK: This is a heavy operation touching 126 secrets.
  # ownerReferences won't cause issues — replace doesn't change metadata.
  # If any secret fails, it will show in the output — investigate individually.
  #
  # Alternative (safer, available in k8s 1.30+):
  # Use StorageVersionMigration API to trigger server-side re-encryption
  # https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/#configure-automatic-reloading
  # Evaluate during execution which approach is better.
  ```

- [ ] 5.2.2.4 Verify encryption works
  ```bash
  # Create a test secret
  kubectl-homelab create secret generic encryption-test \
    -n default --from-literal=test=encrypted-value

  # VERIFIED: etcdctl 3.6.6 IS available in etcd pod
  # ⛔ CORRECTED: hexdump is NOT available (distroless image)
  # Use raw etcdctl output instead — look for "k8s:enc:secretbox:v1:key1" prefix
  ETCD_POD=$(kubectl-homelab get pods -n kube-system -l component=etcd \
    -o jsonpath='{.items[0].metadata.name}')

  # Read directly from etcd — output should show encrypted prefix, not plaintext
  kubectl-homelab exec -n kube-system "$ETCD_POD" -- sh -c \
    "ETCDCTL_API=3 etcdctl get /registry/secrets/default/encryption-test \
      --cacert=/etc/kubernetes/pki/etcd/ca.crt \
      --cert=/etc/kubernetes/pki/etcd/server.crt \
      --key=/etc/kubernetes/pki/etcd/server.key" 2>&1

  # Expected: binary data with "k8s:enc:secretbox:v1:key1" prefix visible
  # If you see plaintext "encrypted-value" → encryption is NOT working

  kubectl-homelab delete secret encryption-test -n default
  ```

- [ ] 5.2.2.5 Back up encryption key to 1Password
  ```bash
  # IMPORTANT: Do NOT run this command — generate it for the user to run in their safe terminal
  # op item create --vault=Kubernetes --title="etcd Encryption Key" \
  #   --category=password password=$ENCRYPTION_KEY
  ```

- [ ] 5.2.2.6 Bake encryption into Ansible rebuild playbook
  ```bash
  # Update ansible/playbooks/03-init-cluster.yml to include:
  # 1. Task to deploy encryption-config.yaml BEFORE kubeadm init
  # 2. extraArgs: --encryption-provider-config=/etc/kubernetes/encryption-config.yaml
  # 3. extraVolumes for the encryption config file
  #
  # ⚠️ The encryption KEY is not in Ansible — it must be provided at runtime
  # or read from 1Password. Add a variable placeholder.
  ```

---

## 5.2.3 Claude Code Restricted Kubeconfig

> **Why:** CLAUDE.md says "never read secret values" but this is policy, not technical
> enforcement. A restricted kubeconfig makes it impossible for Claude Code to read
> K8s Secret data, including Vault unseal keys and all ESO-synced secrets.

> **⚠️ IMPORTANT: `list` verb on secrets DOES return full data field.**
> RBAC alone with `verbs: ["list"]` does NOT prevent secret data exposure.
> `kubectl get secrets -n vault -o yaml` uses `list` and shows all data.
> The hooks (5.2.4) are an ESSENTIAL defense layer, not optional.

- [ ] 5.2.3.1 Create restricted ServiceAccount, ClusterRole, and ClusterRoleBinding
  ```yaml
  # manifests/kube-system/claude-code-rbac.yaml
  apiVersion: v1
  kind: ServiceAccount
  metadata:
    name: claude-code
    namespace: kube-system
  ---
  # ClusterRole: full read access EXCEPT secrets
  # ⚠️ CORRECTED: Added missing API groups (metrics, coordination, events, discovery)
  # ⚠️ NOTE: Even with list-only on secrets, data is still exposed.
  #          Hooks (5.2.4) provide the actual enforcement.
  apiVersion: rbac.authorization.k8s.io/v1
  kind: ClusterRole
  metadata:
    name: claude-code-role
  rules:
    # Core API resources (EXCLUDING secrets — handled separately)
    - apiGroups: [""]
      resources: ["pods", "services", "endpoints", "configmaps", "namespaces",
                  "nodes", "persistentvolumes", "persistentvolumeclaims",
                  "events", "serviceaccounts", "resourcequotas", "limitranges",
                  "replicationcontrollers"]
      verbs: ["get", "list", "watch"]
    # Secrets: list only (shows names/metadata in table format)
    # ⚠️ list still exposes data via -o yaml/json — hooks block this
    - apiGroups: [""]
      resources: ["secrets"]
      verbs: ["list"]
    # Apps, batch, policy
    - apiGroups: ["apps"]
      resources: ["*"]
      verbs: ["get", "list", "watch"]
    - apiGroups: ["batch"]
      resources: ["*"]
      verbs: ["get", "list", "watch"]
    - apiGroups: ["policy"]
      resources: ["*"]
      verbs: ["get", "list", "watch"]
    # RBAC (for auditing)
    - apiGroups: ["rbac.authorization.k8s.io"]
      resources: ["*"]
      verbs: ["get", "list", "watch"]
    # Storage
    - apiGroups: ["storage.k8s.io"]
      resources: ["*"]
      verbs: ["get", "list", "watch"]
    # Networking
    - apiGroups: ["networking.k8s.io"]
      resources: ["*"]
      verbs: ["get", "list", "watch"]
    # Metrics (for kubectl top)
    - apiGroups: ["metrics.k8s.io"]
      resources: ["*"]
      verbs: ["get", "list"]
    # Coordination (leases — kube-vip debugging)
    - apiGroups: ["coordination.k8s.io"]
      resources: ["*"]
      verbs: ["get", "list", "watch"]
    # Events API (newer)
    - apiGroups: ["events.k8s.io"]
      resources: ["*"]
      verbs: ["get", "list", "watch"]
    # Discovery (EndpointSlices)
    - apiGroups: ["discovery.k8s.io"]
      resources: ["*"]
      verbs: ["get", "list", "watch"]
    # CRDs needed for homelab operations
    - apiGroups: ["external-secrets.io", "cilium.io", "longhorn.io",
                  "gateway.networking.k8s.io", "monitoring.coreos.com"]
      resources: ["*"]
      verbs: ["get", "list", "watch"]
    # Node Feature Discovery
    - apiGroups: ["nfd.k8s-sigs.io"]
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
  # ⛔ CORRECTED: Use SEPARATE kubeconfig file — do NOT overwrite admin kubeconfig!
  # Original plan would overwrite ~/.kube/homelab.yaml, locking out admin.

  # 1. Apply the SA + ClusterRole + Binding
  kubectl-homelab apply -f manifests/kube-system/claude-code-rbac.yaml

  # 2. Create a long-lived token (SA tokens are not auto-created in K8s 1.24+)
  # --duration is a REQUEST — server may return different duration. Verify actual expiry.
  # No --service-account-max-token-expiration set on API server — should honor our request.
  kubectl-homelab create token claude-code -n kube-system --duration=8760h > /tmp/cc-token

  # 3. Build SEPARATE kubeconfig (NOT ~/.kube/homelab.yaml!)
  CLAUDE_KUBECONFIG=~/.kube/homelab-claude.yaml
  # Copy CA cert from admin kubeconfig
  kubectl --kubeconfig ~/.kube/homelab.yaml config view --raw \
    -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | \
    base64 -d > /tmp/homelab-ca.crt

  kubectl config set-cluster homelab \
    --server=https://api.k8s.rommelporras.com:6443 \
    --certificate-authority=/tmp/homelab-ca.crt \
    --embed-certs=true \
    --kubeconfig=$CLAUDE_KUBECONFIG
  kubectl config set-credentials claude-code \
    --token=$(cat /tmp/cc-token) \
    --kubeconfig=$CLAUDE_KUBECONFIG
  kubectl config set-context homelab-claude \
    --cluster=homelab --user=claude-code \
    --kubeconfig=$CLAUDE_KUBECONFIG
  kubectl config use-context homelab-claude --kubeconfig=$CLAUDE_KUBECONFIG
  rm /tmp/cc-token /tmp/homelab-ca.crt

  # 4. Update kubectl-homelab alias to use restricted kubeconfig
  # In ~/.zshrc, change:
  #   alias kubectl-homelab='kubectl --kubeconfig ~/.kube/homelab.yaml'
  # To:
  #   alias kubectl-homelab='kubectl --kubeconfig ~/.kube/homelab-claude.yaml'
  #   alias kubectl-admin='kubectl --kubeconfig ~/.kube/homelab.yaml'
  # This way Claude Code uses restricted access, user has kubectl-admin for full access.

  # 5. Test: should return Forbidden
  kubectl --kubeconfig $CLAUDE_KUBECONFIG get secret vault-unseal-keys -n vault -o json
  # Expected: Error from server (Forbidden)

  # 6. Test: should work (list shows names only in table format)
  kubectl --kubeconfig $CLAUDE_KUBECONFIG get secrets -n vault
  # Expected: NAME, TYPE, DATA, AGE columns (no secret data shown)

  # ⚠️ NOTE: kubectl get secrets -n vault -o yaml WILL still show data via list verb.
  # This is why hooks (5.2.4) are ESSENTIAL — they block -o json/yaml on secrets.
  ```

---

## 5.2.4 Claude Code Hooks

> **Defense in depth:** Hooks provide fast feedback even before RBAC rejects the request.
> Blocks commands before they reach the cluster.

> **⛔ CORRECTED:** Original plan used wrong file (`.claude/hooks.json`) and wrong format
> (`pattern/action/message`). Claude Code hooks are defined in `settings.json` under the
> `hooks` key, using `type: "command"` pointing to shell scripts. Exit code 2 = block.
>
> This project already has `.claude/hooks/protect-sensitive.sh` with PreToolUse hooks
> in `.claude/settings.json`. Extend the existing hook script instead of creating new files.

- [ ] 5.2.4.1 Add secret-read blocking to `.claude/hooks/protect-sensitive.sh`
  ```bash
  # Add to the COMMAND PROTECTION section of protect-sensitive.sh:

  # Block reading secret data via kubectl
  if echo "$COMMAND" | grep -qE 'kubectl.*get\s+secrets?\s.*-o\s+(json|yaml|jsonpath)'; then
    echo "BLOCKED: Reading secret values is not allowed." >&2
    echo "   Use 'kubectl get secrets' (no -o flag) to list names only." >&2
    exit 2
  fi

  # Block kubectl describe secret (shows data in base64)
  if echo "$COMMAND" | grep -qE 'kubectl.*describe\s+secrets?\s'; then
    echo "BLOCKED: Describing secrets exposes base64 data." >&2
    echo "   Use 'kubectl get secrets' (no -o flag) to list names only." >&2
    exit 2
  fi
  ```

- [ ] 5.2.4.2 Verify hook works
  ```bash
  # These should be blocked by hook before reaching cluster:
  kubectl-homelab get secret vault-unseal-keys -n vault -o json
  kubectl-homelab get secrets -n vault -o yaml
  kubectl-homelab describe secret vault-unseal-keys -n vault

  # These should succeed (table format, no data):
  kubectl-homelab get secrets -n vault
  kubectl-homelab get secrets -A
  ```

---

## 5.2.5 Documentation

- [ ] 5.2.5.1 Update `docs/context/Security.md` with:
  - RBAC audit results (ServiceAccounts, bindings, cluster-admin usage)
  - GitLab Runner ClusterRole decision and rationale
  - etcd encryption status and key management
  - Claude Code access restrictions (RBAC + hooks)
  - RBAC trust boundaries diagram
- [ ] 5.2.5.2 Update `docs/reference/CHANGELOG.md`

---

## Verification Checklist

- [x] RBAC audit complete — all ServiceAccounts reviewed (2026-03-15)
- [ ] GitLab Runner ClusterRole replaced with namespace-scoped Role (`clusterWideAccess: false` + helm upgrade + pipeline test)
- [x] longhorn-support-bundle cluster-admin binding reviewed — accepted, document in Security.md
- [ ] version-check-cronjob `automountServiceAccountToken: false` bug fixed (remove from pod spec, verify manual run)
- [ ] etcd encryption at rest enabled with **secretbox** (not aescbc)
- [ ] Encryption verified via etcdctl (see `k8s:enc:secretbox:v1:key1` prefix)
- [ ] Encryption key backed up to 1Password
- [ ] Encryption baked into Ansible rebuild playbook
- [ ] Restricted kubeconfig for Claude Code deployed (separate file, not overwriting admin)
- [ ] kubectl-homelab alias updated to use restricted kubeconfig
- [ ] Claude Code hooks block `get secret -o json/yaml` and `describe secret`
- [ ] All existing secrets re-encrypted with new provider

---

## Rollback

**etcd encryption breaks API server:**
```bash
# On CP node: remove --encryption-provider-config from
# /etc/kubernetes/manifests/kube-apiserver.yaml
# Also remove the encryption-config volume and volumeMount
# API server will restart automatically and read unencrypted secrets
# Existing secrets remain readable (identity provider is the fallback)

# Use Python to safely edit the manifest (Phase 5.1 pattern):
ssh wawashi@10.10.30.11
sudo python3 -c "
import yaml
with open('/etc/kubernetes/manifests/kube-apiserver.yaml') as f:
    manifest = yaml.safe_load(f)
# Remove the flag, volume, and volumeMount
# ... (specific removal code during execution)
"
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
# Remove: the volume and volumeMount for encryption-config

# 4. API server will restart automatically (static pod) — takes ~30-45s
# 5. Verify API server is healthy
kubectl-homelab get nodes

# 6. Repeat on other CP nodes if they were also modified
# 7. Existing secrets remain readable (identity provider is the fallback)
```

**Restricted kubeconfig breaks Claude Code operations:**
```bash
# Restore admin kubeconfig for Claude Code:
# In ~/.zshrc, change kubectl-homelab alias back to:
#   alias kubectl-homelab='kubectl --kubeconfig ~/.kube/homelab.yaml'
# Then: source ~/.zshrc

# The admin kubeconfig (~/.kube/homelab.yaml) is never modified by this phase.
# The restricted kubeconfig (~/.kube/homelab-claude.yaml) can be deleted safely.
```

---

## Final: Commit and Release

- [ ] `/audit-security` then `/commit`
- [ ] `/audit-docs` then `/commit`
- [ ] `/release v0.32.0 "RBAC & Secrets Hardening"`
- [ ] `mv docs/todo/phase-5.2-rbac-and-encryption.md docs/todo/completed/`
