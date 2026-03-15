# Phase 5.2: RBAC & Secrets Hardening

> **Status:** ✅ Complete (all tasks executed 2026-03-15)
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

- [x] 5.2.1.3 ⛔ **Fix GitLab Runner ClusterRole — scope to namespace Role**
  > **DECISION (2026-03-15):** Fix now. `rbac.clusterWideAccess: false` in Helm values.
  > **✅ APPLIED (2026-03-15):** Helm upgrade rev 5 complete. ClusterRole deleted, namespace Role
  > created in `gitlab-runner`. Runner pod Running 1/1. Pipeline test pending (next CI run).
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

- [x] 5.2.1.6 ⚠️ **Fix version-check-cronjob — broken Nova auth (bug from Phase 5.0)**
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
  > **✅ APPLIED (2026-03-15):** Manifest updated, applied. Manual job confirmed:
  > `Summary: 11 outdated, 0 deprecated, 6 current` — Nova authenticating and detecting drift ✅
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

> **Encryption provider:** `secretbox` (XSalsa20-Poly1305). k8s docs: aescbc is "not recommended
> due to CBC's vulnerability to padding oracle attacks." Verified from k8s GitHub source.

> **Execution audit corrections (2026-03-15):**
> - ⛔ `sh` is NOT available in etcd:3.6.6-0 — pre-execution audit was wrong. Use `etcdctl` directly (no `sh -c`)
> - ⛔ StorageVersionMigration API is NOT available on this cluster — must use `kubectl replace` for re-encryption
> - ⛔ Re-encryption (`kubectl get secrets -A -o json`) pipes ALL secret data through terminal — user must run manually
> - ⛔ etcd snapshot save works: 104 MB, takes ~700ms. Save to `/var/lib/etcd/` (hostPath mounted)
> - ✅ etcdctl is available in pod (just not `sh` — exec `etcdctl` directly)
> - ✅ All 3 etcd members healthy and started
> - ✅ API server manifest pattern from Phase 5.1 confirmed (audit-policy volume/mount)

> **Rolling update strategy:**
> - Create EncryptionConfiguration on ALL 3 nodes BEFORE modifying any API server manifest
> - Rolling restart: CP1 → verification gate → 5-min soak → CP2 → gate → soak → CP3
> - Always 2/3 nodes healthy (same safety model as Phase 5.1)
> - No scp between nodes — create files directly on each node via SSH from WSL
> - Static pod restart takes ~30-45s. Monitor with `crictl ps` on the node.

### 5.2.2.0 Pre-flight checks

- [x] 5.2.2.0a Record baseline cluster state
  > **✅ EXECUTED (2026-03-15):** 3 nodes Ready, 0 non-Running pods, clean events (only cluster-janitor + Vault SecretStore validation).
  ```bash
  # Run from Claude Code — captures health state to compare against after changes
  kubectl-homelab get nodes -o wide
  kubectl-homelab get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
  kubectl-homelab get events -A --sort-by='.lastTimestamp' | tail -20
  ```

- [x] 5.2.2.0b Verify etcd cluster health
  > **✅ EXECUTED (2026-03-15):** 127.0.0.1:2379 healthy (8ms). All 3 members started.
  ```bash
  # Must use etcdctl directly — NO sh wrapper (distroless, sh not in PATH)
  ETCD_POD=$(kubectl-homelab get pods -n kube-system -l component=etcd \
    -o jsonpath='{.items[0].metadata.name}')

  kubectl-homelab exec -n kube-system "$ETCD_POD" -- \
    etcdctl endpoint health \
      --cacert=/etc/kubernetes/pki/etcd/ca.crt \
      --cert=/etc/kubernetes/pki/etcd/server.crt \
      --key=/etc/kubernetes/pki/etcd/server.key
  # Expected: "127.0.0.1:2379 is healthy"

  kubectl-homelab exec -n kube-system "$ETCD_POD" -- \
    etcdctl member list \
      --cacert=/etc/kubernetes/pki/etcd/ca.crt \
      --cert=/etc/kubernetes/pki/etcd/server.crt \
      --key=/etc/kubernetes/pki/etcd/server.key \
      --write-out=table
  # Expected: 3 members, all "started"
  ```

- [x] 5.2.2.0c Take etcd snapshot (pre-flight backup)
  > **✅ EXECUTED (2026-03-15):** 104 MB snapshot at /var/lib/etcd/pre-encryption-snapshot.db on CP1.
  ```bash
  # Save snapshot inside etcd pod to /var/lib/etcd (hostPath → persists on node)
  kubectl-homelab exec -n kube-system etcd-k8s-cp1 -- \
    etcdctl snapshot save /var/lib/etcd/pre-encryption-snapshot.db \
      --cacert=/etc/kubernetes/pki/etcd/ca.crt \
      --cert=/etc/kubernetes/pki/etcd/server.crt \
      --key=/etc/kubernetes/pki/etcd/server.key
  # Expected: "Snapshot saved at /var/lib/etcd/pre-encryption-snapshot.db" (~104 MB)

  # Verify snapshot exists on CP1's filesystem
  ssh wawashi@10.10.30.11 "ls -lh /var/lib/etcd/pre-encryption-snapshot.db"
  ```

- [x] 5.2.2.0d Back up API server manifests on all 3 nodes
  > **✅ EXECUTED (2026-03-15):** Backup at /etc/kubernetes/kube-apiserver.yaml.pre-encryption-backup (4545 bytes) on all 3 nodes.
  ```bash
  for node in 11 12 13; do
    echo "=== k8s-cp$((node-10)) ==="
    ssh wawashi@10.10.30.$node \
      "sudo cp /etc/kubernetes/manifests/kube-apiserver.yaml \
               /etc/kubernetes/kube-apiserver.yaml.pre-encryption-backup"
    ssh wawashi@10.10.30.$node \
      "ls -la /etc/kubernetes/kube-apiserver.yaml.pre-encryption-backup"
  done
  ```

### 5.2.2.1 Generate and deploy encryption key

> **⚠️ CLAUDE CODE MUST NOT RUN THIS STEP.**
> The encryption key must never flow through this terminal. Generate the script
> for the user to run in their safe terminal.

- [x] 5.2.2.1a Generate deployment script for user
  > **✅ EXECUTED (2026-03-15):** Script /tmp/deploy-enc-key.sh generated and improved (SSH pre-check, idempotency guard, key length validation, inline op save). User ran manually.
  ```bash
  # Claude Code generates this script as a file, user runs it manually.
  # The script:
  #   1. Generates a 32-byte secretbox key
  #   2. Deploys encryption-config.yaml to all 3 CP nodes
  #   3. Sets permissions to 600 (root only)
  #   4. Verifies file exists and checksums match on all 3 nodes
  #   5. Prints the 1Password backup command
  #
  # Script path: /tmp/deploy-encryption-config.sh
  # User runs: bash /tmp/deploy-encryption-config.sh
  ```

  Script content:
  ```bash
  #!/bin/bash
  set -euo pipefail

  # Generate encryption key
  ENCRYPTION_KEY=$(head -c 32 /dev/urandom | base64)
  echo "Generated encryption key (save this in 1Password):"
  echo "  $ENCRYPTION_KEY"
  echo ""

  # Deploy to all 3 CP nodes
  for node in 11 12 13; do
    echo "=== Deploying to k8s-cp$((node-10)) (10.10.30.$node) ==="
    ssh wawashi@10.10.30.$node "sudo tee /etc/kubernetes/encryption-config.yaml > /dev/null" <<EOFCONFIG
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
  EOFCONFIG
    ssh wawashi@10.10.30.$node "sudo chmod 600 /etc/kubernetes/encryption-config.yaml"
    echo "  Done."
  done

  echo ""
  echo "=== Verifying checksums ==="
  for node in 11 12 13; do
    CHECKSUM=$(ssh wawashi@10.10.30.$node "sudo sha256sum /etc/kubernetes/encryption-config.yaml")
    echo "  k8s-cp$((node-10)): $CHECKSUM"
  done

  echo ""
  echo "⚠️  Verify all 3 checksums above are IDENTICAL."
  echo ""
  echo "=== Back up key to 1Password ==="
  echo "Run this command:"
  echo "  op item create --vault=Kubernetes --title='etcd Encryption Key' \\"
  echo "    --category=password password='$ENCRYPTION_KEY'"
  ```

- [x] 5.2.2.1b Verify encryption config deployed (Claude Code can verify — no key in output)
  > **✅ EXECUTED (2026-03-15):** All 3 nodes: 600 root:root 274 bytes. Checksums identical (61173152...).
  ```bash
  # Verify files exist with correct permissions (doesn't show key content)
  for node in 11 12 13; do
    echo "=== k8s-cp$((node-10)) ==="
    ssh wawashi@10.10.30.$node "sudo ls -la /etc/kubernetes/encryption-config.yaml"
  done

  # Verify checksums match across all nodes (checksums are safe to see)
  for node in 11 12 13; do
    ssh wawashi@10.10.30.$node "sudo sha256sum /etc/kubernetes/encryption-config.yaml"
  done
  # ⛔ STOP if checksums don't match — investigate before proceeding
  ```

### 5.2.2.2 Rolling API server manifest update

> **Per-node procedure:** Edit manifest → wait ~45s → verify API server restarted →
> verify all 3 nodes Ready → verify etcd healthy → verify no error events → wait 5 min → next node

- [x] 5.2.2.2a Edit API server manifest on CP1
  > **✅ EXECUTED (2026-03-15):** Added flag, volumeMount, volume. API server restarted (attempt 0, 10s after edit).
  ```bash
  # Python script to add encryption config (same pattern as Phase 5.1 audit-policy)
  ssh wawashi@10.10.30.11 "sudo python3 -c \"
import yaml

with open('/etc/kubernetes/manifests/kube-apiserver.yaml') as f:
    manifest = yaml.safe_load(f)

# Add --encryption-provider-config flag
cmd = manifest['spec']['containers'][0]['command']
flag = '--encryption-provider-config=/etc/kubernetes/encryption-config.yaml'
if flag not in cmd:
    cmd.append(flag)
    print(f'Added: {flag}')
else:
    print(f'Already present: {flag}')

# Add volumeMount
vmounts = manifest['spec']['containers'][0]['volumeMounts']
vm_entry = {
    'mountPath': '/etc/kubernetes/encryption-config.yaml',
    'name': 'encryption-config',
    'readOnly': True
}
if not any(vm.get('name') == 'encryption-config' for vm in vmounts):
    vmounts.append(vm_entry)
    print('Added volumeMount: encryption-config')
else:
    print('volumeMount already present')

# Add volume
vols = manifest['spec']['volumes']
vol_entry = {
    'hostPath': {'path': '/etc/kubernetes/encryption-config.yaml', 'type': 'File'},
    'name': 'encryption-config'
}
if not any(v.get('name') == 'encryption-config' for v in vols):
    vols.append(vol_entry)
    print('Added volume: encryption-config')
else:
    print('volume already present')

with open('/etc/kubernetes/manifests/kube-apiserver.yaml', 'w') as f:
    yaml.dump(manifest, f, default_flow_style=False, sort_keys=False)

print('Manifest updated. API server will restart automatically.')
\""
  ```

- [x] 5.2.2.2b Verify CP1 API server restarted and healthy
  > **✅ EXECUTED (2026-03-15):** crictl: Running attempt 0. All 3 nodes Ready. etcd healthy. Cilium-operator probe blips transient (restart window only).
  ```bash
  # Wait for restart (~45s), then verify
  sleep 45

  # Check API server container is running on CP1
  ssh wawashi@10.10.30.11 "sudo crictl ps --name kube-apiserver"
  # Expected: kube-apiserver RUNNING, age < 1 minute

  # Check all 3 nodes are Ready
  kubectl-homelab get nodes
  # Expected: all 3 Ready

  # Check etcd health
  kubectl-homelab exec -n kube-system etcd-k8s-cp1 -- \
    etcdctl endpoint health \
      --cacert=/etc/kubernetes/pki/etcd/ca.crt \
      --cert=/etc/kubernetes/pki/etcd/server.crt \
      --key=/etc/kubernetes/pki/etcd/server.key

  # Check for error events
  kubectl-homelab get events -n kube-system --sort-by='.lastTimestamp' \
    --field-selector=type=Warning | tail -10

  # ⛔ STOP if any node NotReady, API server not running, or etcd unhealthy
  # ⛔ ROLLBACK: restore backup manifest on CP1 (see Rollback section)
  echo "CP1 healthy. Wait 5 minutes before proceeding to CP2..."
  ```

- [x] 5.2.2.2c Wait 5-minute soak for CP1
  > **✅ EXECUTED (2026-03-15):** 5 min soak passed. CP1 apiserver Running 0 restarts. All nodes Ready.
  ```bash
  # After 5 minutes, re-verify before moving to CP2
  kubectl-homelab get nodes
  kubectl-homelab get pods -n kube-system | grep -E "apiserver|etcd"
  # All Running, 0 restarts since the intentional restart
  ```

- [x] 5.2.2.2d Edit CP2 manifest, verify, and soak
  > **✅ EXECUTED (2026-03-15):** API server Running attempt 0. kube-scheduler restarted once (expected — API disconnect during restart window). No new warnings after recovery. 5 min soak passed.
  ```bash
  # Same Python script as CP1, targeting CP2
  ssh wawashi@10.10.30.12 "sudo python3 -c \"
import yaml

with open('/etc/kubernetes/manifests/kube-apiserver.yaml') as f:
    manifest = yaml.safe_load(f)

cmd = manifest['spec']['containers'][0]['command']
flag = '--encryption-provider-config=/etc/kubernetes/encryption-config.yaml'
if flag not in cmd:
    cmd.append(flag)

vmounts = manifest['spec']['containers'][0]['volumeMounts']
vm_entry = {'mountPath': '/etc/kubernetes/encryption-config.yaml', 'name': 'encryption-config', 'readOnly': True}
if not any(vm.get('name') == 'encryption-config' for vm in vmounts):
    vmounts.append(vm_entry)

vols = manifest['spec']['volumes']
vol_entry = {'hostPath': {'path': '/etc/kubernetes/encryption-config.yaml', 'type': 'File'}, 'name': 'encryption-config'}
if not any(v.get('name') == 'encryption-config' for v in vols):
    vols.append(vol_entry)

with open('/etc/kubernetes/manifests/kube-apiserver.yaml', 'w') as f:
    yaml.dump(manifest, f, default_flow_style=False, sort_keys=False)
print('CP2 manifest updated.')
\""

  # Then: sleep 45, crictl check, kubectl get nodes, etcd health, events, 5-min soak
  # Same verification steps as CP1 (5.2.2.2b + 5.2.2.2c)
  ```

- [x] 5.2.2.2e Edit CP3 manifest, verify, and soak
  > **✅ EXECUTED (2026-03-15):** API server Running attempt 0. Readiness probe blip at 52s (restart window only). Recovered within 30s. 5 min soak passed.
  ```bash
  # Same Python script targeting CP3 (10.10.30.13)
  # Same verification steps
  # After CP3: all 3 API servers now have --encryption-provider-config
  ```

- [x] 5.2.2.2f Final verification — all 3 API servers have encryption config
  > **✅ EXECUTED (2026-03-15):** All 3 manifests confirmed: --encryption-provider-config=/etc/kubernetes/encryption-config.yaml. All API servers Running 0 restarts.
  ```bash
  # Confirm the flag is present on all 3 nodes
  for node in 11 12 13; do
    echo "=== k8s-cp$((node-10)) ==="
    ssh wawashi@10.10.30.$node \
      "sudo grep 'encryption-provider-config' /etc/kubernetes/manifests/kube-apiserver.yaml"
  done
  # Expected: all 3 show --encryption-provider-config=/etc/kubernetes/encryption-config.yaml

  # Final health check
  kubectl-homelab get nodes
  kubectl-homelab get pods -n kube-system | grep -E "apiserver|etcd"
  ```

### 5.2.2.3 Verify encryption works

- [x] 5.2.2.3a Create test secret and verify in etcd
  > **✅ EXECUTED (2026-03-15):** etcd prefix confirmed: `k8s:enc:secretbox:v1:key1:`. API server decrypts correctly. Test secret deleted.
  ```bash
  # Create a test secret
  kubectl-homelab create secret generic encryption-test \
    -n default --from-literal=test=encrypted-value

  # Read directly from etcd — NO sh wrapper (distroless image, sh not in PATH)
  ETCD_POD=$(kubectl-homelab get pods -n kube-system -l component=etcd \
    -o jsonpath='{.items[0].metadata.name}')

  kubectl-homelab exec -n kube-system "$ETCD_POD" -- \
    etcdctl get /registry/secrets/default/encryption-test \
      --cacert=/etc/kubernetes/pki/etcd/ca.crt \
      --cert=/etc/kubernetes/pki/etcd/server.crt \
      --key=/etc/kubernetes/pki/etcd/server.key \
      --print-value-only 2>&1 | head -5

  # Expected: binary data starting with "k8s:enc:secretbox:v1:key1"
  # ⛔ FAIL if you see plaintext "encrypted-value" — encryption NOT working

  kubectl-homelab delete secret encryption-test -n default
  ```

### 5.2.2.4 Re-encrypt all existing secrets

> **⚠️ CLAUDE CODE MUST NOT RUN THIS STEP.**
> `kubectl get secrets -A -o json` outputs ALL secret data through the terminal.
> StorageVersionMigration is NOT available on this cluster (verified).
> The user must run this in their safe terminal.

- [x] 5.2.2.4a Generate re-encryption script for user
  > **✅ EXECUTED (2026-03-15):** /tmp/re-encrypt-secrets.sh generated. User ran manually. Verified 2 pre-existing secrets (cert-manager + vault Helm releases) now have `k8s:enc:secretbox:v1:key1:` prefix in etcd.
  ```bash
  # Claude Code generates this script, user runs it in safe terminal.
  # Script path: /tmp/re-encrypt-secrets.sh

  #!/bin/bash
  set -euo pipefail
  export KUBECONFIG=~/.kube/homelab.yaml

  echo "Re-encrypting all secrets with new encryption provider..."
  echo "This reads+writes all secrets so they're stored with secretbox."
  echo ""

  # Count secrets first
  TOTAL=$(kubectl get secrets -A --no-headers | wc -l)
  echo "Total secrets to re-encrypt: $TOTAL"
  echo ""

  # Re-encrypt
  kubectl get secrets -A -o json | kubectl replace -f -

  echo ""
  echo "Re-encryption complete. Verify a sample in etcd:"
  echo "  kubectl exec -n kube-system etcd-k8s-cp1 -- \\"
  echo "    etcdctl get /registry/secrets/<namespace>/<name> \\"
  echo "      --cacert=/etc/kubernetes/pki/etcd/ca.crt \\"
  echo "      --cert=/etc/kubernetes/pki/etcd/server.crt \\"
  echo "      --key=/etc/kubernetes/pki/etcd/server.key \\"
  echo "      --print-value-only | head -5"
  echo ""
  echo "Expected: binary data with 'k8s:enc:secretbox:v1:key1' prefix"
  ```

- [x] 5.2.2.4b Verify re-encryption (Claude Code can verify — etcd raw data is binary, not secret values)
  > **✅ EXECUTED (2026-03-15):** cert-manager/sh.helm.release.v1.cert-manager.v1 → k8s:enc:secretbox:v1:key1: ✅. vault/sh.helm.release.v1.vault.v1 → k8s:enc:secretbox:v1:key1: ✅.
  ```bash
  # Check a known secret in etcd to confirm encrypted prefix
  # Pick a non-sensitive secret (e.g., a cert-manager token or Helm release secret)
  kubectl-homelab exec -n kube-system etcd-k8s-cp1 -- \
    etcdctl get /registry/secrets/kube-system/bootstrap-token-$(
      kubectl-homelab get secrets -n kube-system --no-headers | \
      grep bootstrap-token | head -1 | awk '{print $1}' | sed 's/bootstrap-token-//'
    ) \
      --cacert=/etc/kubernetes/pki/etcd/ca.crt \
      --cert=/etc/kubernetes/pki/etcd/server.crt \
      --key=/etc/kubernetes/pki/etcd/server.key \
      --print-value-only 2>&1 | head -3
  # Expected: starts with "k8s:enc:secretbox:v1:key1" (not plaintext)
  ```

### 5.2.2.5 Back up encryption key to 1Password

> **Claude Code MUST NOT run `op` commands.** Generate the command for user.

- [x] 5.2.2.5a Print 1Password backup command
  > **✅ EXECUTED (2026-03-15):** Key saved automatically by deploy-enc-key.sh via inline `op item create`. Item ID: 3q2a5mdcpskdjmj7q4hwkkkcmu in Kubernetes vault, title "etcd Encryption Key".
  ```bash
  # Tell user to run (already printed by deploy-encryption-config.sh):
  # op item create --vault=Kubernetes --title="etcd Encryption Key" \
  #   --category=password password='<the key from deployment>'
  ```

### 5.2.2.6 Bake encryption into Ansible rebuild playbook

- [x] 5.2.2.6a Update 03-init-cluster.yml
  > **✅ EXECUTED (2026-03-15):** Added deploy task (before kubeadm init), encryption-provider-config extraArg, and encryption-config extraVolume. Key passed at runtime via `--extra-vars "etcd_encryption_key=$(op read ...)"`.

  ```yaml
  # Add BEFORE the "Create kubeadm config file" task:

  # =========================================
  # Deploy encryption configuration (must exist BEFORE kubeadm init)
  # =========================================
  - name: Deploy encryption configuration
    ansible.builtin.copy:
      content: |
        apiVersion: apiserver.config.k8s.io/v1
        kind: EncryptionConfiguration
        resources:
          - resources:
              - secrets
            providers:
              - secretbox:
                  keys:
                    - name: key1
                      secret: "{{ etcd_encryption_key }}"
              - identity: {}
      dest: /etc/kubernetes/encryption-config.yaml
      mode: '0600'
    when: cluster_needs_init

  # Add to kubeadm ClusterConfiguration apiServer section:
  #   extraArgs:
  #     encryption-provider-config: /etc/kubernetes/encryption-config.yaml
  #   extraVolumes:
  #     - name: encryption-config
  #       hostPath: /etc/kubernetes/encryption-config.yaml
  #       mountPath: /etc/kubernetes/encryption-config.yaml
  #       readOnly: true
  #       pathType: File
  ```

  ```bash
  # The variable etcd_encryption_key must be provided at runtime.
  # Options:
  # A. ansible-playbook --extra-vars "etcd_encryption_key=$(op read 'op://Kubernetes/etcd Encryption Key/password')"
  # B. Add to group_vars/control_plane.yml as ansible-vault encrypted variable
  # C. Prompt at runtime with vars_prompt
  #
  # Recommended: Option A (reads from 1Password at runtime, key never stored in git)
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

- [x] 5.2.3.1 Create restricted ServiceAccount, ClusterRole, and ClusterRoleBinding
  > **✅ EXECUTED (2026-03-15):** SA + ClusterRole + ClusterRoleBinding applied. Manifest at manifests/kube-system/claude-code-rbac.yaml.
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

- [x] 5.2.3.2 Generate kubeconfig for the ServiceAccount
  > **✅ EXECUTED (2026-03-15):** Permanent Secret-based token (claude-code-token). homelab-claude.yaml built with embedded CA.
  > Both kubeconfigs saved to 1Password "Kubeconfig" (ID: npgphvdw3yf22uyxsxidsgmo7i) — fields: admin-kubeconfig, claude-kubeconfig.
  > kubectl-homelab alias → homelab-claude.yaml (restricted). kubectl-admin alias → homelab.yaml (admin).
  > RBAC verified: get secret → Forbidden ✅, list secrets → allowed ✅, get nodes → allowed ✅.
  ```bash
  # ⛔ CORRECTED: Use SEPARATE kubeconfig file — do NOT overwrite admin kubeconfig!
  # ⛔ CORRECTED: Use permanent Secret-based token, NOT time-limited token.
  #   kubectl create token --duration=8760h expires after 1 year — breaks all synced devices.
  #   A read-only SA with no secret access is low-risk enough for a permanent token.

  # 1. Apply the SA + ClusterRole + Binding
  kubectl --kubeconfig ~/.kube/homelab.yaml apply -f manifests/kube-system/claude-code-rbac.yaml

  # 2. Create permanent token Secret (k8s 1.24+ doesn't auto-create SA tokens)
  kubectl --kubeconfig ~/.kube/homelab.yaml apply -f - <<EOF
  apiVersion: v1
  kind: Secret
  metadata:
    name: claude-code-token
    namespace: kube-system
    annotations:
      kubernetes.io/service-account.name: claude-code
  type: kubernetes.io/service-account-token
  EOF

  # Wait for token to be populated by the token controller (~5s)
  sleep 5
  kubectl --kubeconfig ~/.kube/homelab.yaml get secret claude-code-token -n kube-system
  # Expected: Opaque, age=few seconds

  # 3. Build restricted kubeconfig (NOT ~/.kube/homelab.yaml!)
  CLAUDE_KUBECONFIG=~/.kube/homelab-claude.yaml
  TOKEN=$(kubectl --kubeconfig ~/.kube/homelab.yaml get secret claude-code-token \
    -n kube-system -o jsonpath='{.data.token}' | base64 -d)
  CA_DATA=$(kubectl --kubeconfig ~/.kube/homelab.yaml config view --raw \
    -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')

  kubectl config set-cluster homelab \
    --server=https://api.k8s.rommelporras.com:6443 \
    --certificate-authority-data="$CA_DATA" \
    --kubeconfig=$CLAUDE_KUBECONFIG
  kubectl config set-credentials claude-code \
    --token="$TOKEN" \
    --kubeconfig=$CLAUDE_KUBECONFIG
  kubectl config set-context homelab-claude \
    --cluster=homelab --user=claude-code \
    --kubeconfig=$CLAUDE_KUBECONFIG
  kubectl config use-context homelab-claude --kubeconfig=$CLAUDE_KUBECONFIG
  unset TOKEN CA_DATA

  # 4. Save BOTH kubeconfigs to 1Password — one item, two fields
  # Retrieve on any device:
  #   op item get 'Kubeconfig' --vault=Kubernetes --fields admin-kubeconfig > ~/.kube/homelab.yaml
  #   op item get 'Kubeconfig' --vault=Kubernetes --fields claude-kubeconfig > ~/.kube/homelab-claude.yaml
  op item create \
    --vault=Kubernetes \
    --title='Kubeconfig' \
    --category='Secure Note' \
    "admin-kubeconfig[text]=$(cat ~/.kube/homelab.yaml)" \
    "claude-kubeconfig[text]=$(cat ~/.kube/homelab-claude.yaml)"

  # 5. Update kubectl-homelab alias to use restricted kubeconfig
  # In ~/.zshrc, change:
  #   alias kubectl-homelab='kubectl --kubeconfig ~/.kube/homelab.yaml'
  # To:
  #   alias kubectl-homelab='kubectl --kubeconfig ~/.kube/homelab-claude.yaml'
  #   alias kubectl-admin='kubectl --kubeconfig ~/.kube/homelab.yaml'

  # 6. Test restricted access — should return Forbidden
  kubectl --kubeconfig $CLAUDE_KUBECONFIG get secret vault-unseal-keys -n vault -o json
  # Expected: Error from server (Forbidden)

  # 7. Test list access — should work (names/metadata only in table format)
  kubectl --kubeconfig $CLAUDE_KUBECONFIG get secrets -n vault
  # Expected: NAME, TYPE, DATA, AGE columns (no secret values)

  # ⚠️ NOTE: kubectl get secrets -n vault -o yaml WILL still show data via list verb.
  # This is why hooks (5.2.4) are ESSENTIAL — they block -o json/yaml on secrets.
  ```

  > **Token rotation:** if token is ever compromised, delete the `claude-code-token` Secret
  > (k8s immediately revokes it), create a new one, rebuild kubeconfig, update 1Password item.

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

- [x] 5.2.4.1 Add secret-read blocking to `.claude/hooks/protect-sensitive.sh`
  > **✅ EXECUTED (2026-03-15):** Two patterns added — blocks `get secret -o json/yaml/jsonpath` and `describe secret`. Tightened regex handles flags in any position.
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

- [x] 5.2.4.2 Verify hook works
  > **✅ EXECUTED (2026-03-15):** Hook blocked its own test command (pattern in Bash text triggered correctly). Allowed cases pass: `get secrets` (no -o), `get pods -o json`. RBAC + hook = two independent layers.
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

- [x] 5.2.5.1 Update `docs/context/Security.md` with:
  > **✅ EXECUTED (2026-03-15):** Added RBAC Hardening section (audit results, GitLab Runner + longhorn decisions, trust boundaries), etcd Encryption section (secretbox config, verification, rotation, rebuild), and Claude Code Access Restrictions section (RBAC layer, hook layer, alias mapping, token rotation).
- [x] 5.2.5.2 Update `docs/reference/CHANGELOG.md`
  > **✅ EXECUTED (2026-03-15):** v0.32.0 entry added — summary, all changes, key decisions, gotchas.

---

## Verification Checklist

- [x] RBAC audit complete — all ServiceAccounts reviewed (2026-03-15)
- [x] GitLab Runner ClusterRole replaced with namespace-scoped Role (`clusterWideAccess: false` + helm upgrade rev 5)
- [x] longhorn-support-bundle cluster-admin binding reviewed — accepted, document in Security.md
- [x] version-check-cronjob `automountServiceAccountToken: false` bug fixed — Nova confirmed working (11 outdated detected)
- [x] Pre-flight: etcd snapshot saved (104 MB), API server manifests backed up on all 3 nodes (2026-03-15)
- [x] Encryption key generated and deployed to all 3 nodes — checksums identical (2026-03-15)
- [x] Rolling API server update: CP1 → soak → CP2 → soak → CP3 — all 3 Running 0 restarts (2026-03-15)
- [x] Encryption verified via etcdctl — `k8s:enc:secretbox:v1:key1:` prefix confirmed on new secrets (2026-03-15)
- [x] All existing secrets re-encrypted — user ran manually, sample verified (cert-manager + vault Helm releases) (2026-03-15)
- [x] Encryption key backed up to 1Password — "etcd Encryption Key" in Kubernetes vault (2026-03-15)
- [x] Encryption baked into Ansible rebuild playbook (03-init-cluster.yml) — deploy task + extraArg + extraVolume (2026-03-15)
- [x] Restricted kubeconfig for Claude Code deployed — permanent SA token, saved to 1Password "Kubeconfig" (2026-03-15)
- [x] kubectl-homelab alias → homelab-claude.yaml (restricted); kubectl-admin alias → homelab.yaml (admin) (2026-03-15)
- [x] Claude Code hooks block `get secret -o json/yaml` and `describe secret` (2026-03-15)

---

## Rollback

**Option 1 — Restore from backup manifest (fastest):**
```bash
# If API server fails after manifest edit, restore the pre-encryption backup:
NODE_IP=10.10.30.11  # change for CP2 (.12) or CP3 (.13)
ssh wawashi@$NODE_IP \
  "sudo cp /etc/kubernetes/kube-apiserver.yaml.pre-encryption-backup \
           /etc/kubernetes/manifests/kube-apiserver.yaml"
# API server will restart automatically (~30-45s)
# Verify: ssh wawashi@$NODE_IP "sudo crictl ps --name kube-apiserver"
```

**Option 2 — Python rollback (if backup is missing):**
```bash
# Complete Python script to remove encryption config from API server manifest
NODE_IP=10.10.30.11  # change for each node
ssh wawashi@$NODE_IP "sudo python3 -c \"
import yaml

with open('/etc/kubernetes/manifests/kube-apiserver.yaml') as f:
    manifest = yaml.safe_load(f)

# Remove --encryption-provider-config flag
cmd = manifest['spec']['containers'][0]['command']
flag = '--encryption-provider-config=/etc/kubernetes/encryption-config.yaml'
if flag in cmd:
    cmd.remove(flag)
    print(f'Removed: {flag}')

# Remove volumeMount
vmounts = manifest['spec']['containers'][0]['volumeMounts']
manifest['spec']['containers'][0]['volumeMounts'] = [
    vm for vm in vmounts if vm.get('name') != 'encryption-config'
]
print('Removed volumeMount: encryption-config')

# Remove volume
vols = manifest['spec']['volumes']
manifest['spec']['volumes'] = [
    v for v in vols if v.get('name') != 'encryption-config'
]
print('Removed volume: encryption-config')

with open('/etc/kubernetes/manifests/kube-apiserver.yaml', 'w') as f:
    yaml.dump(manifest, f, default_flow_style=False, sort_keys=False)

print('Manifest reverted. API server will restart automatically (~30-45s).')
\""
```

**After rollback verification:**
```bash
# Wait for API server restart
sleep 45
ssh wawashi@$NODE_IP "sudo crictl ps --name kube-apiserver"
kubectl-homelab get nodes  # all 3 Ready
# Existing secrets remain readable — identity provider is the fallback
# in EncryptionConfiguration (reads unencrypted secrets, identity: {} is last provider)
```

**etcd snapshot restore (nuclear option — only if etcd is corrupted):**
```bash
# The pre-encryption snapshot is at /var/lib/etcd/pre-encryption-snapshot.db on CP1
# This is a full etcd restore — consult k8s docs before using
# https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/#restoring-an-etcd-cluster
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

- [x] `/audit-security` then `/commit` (2026-03-15)
- [x] `/audit-docs` then `/commit` (2026-03-15)
- [x] `/release v0.32.0 "RBAC & Secrets Hardening"` (2026-03-15)
- [x] `mv docs/todo/phase-5.2-rbac-and-encryption.md docs/todo/completed/` (2026-03-15)
