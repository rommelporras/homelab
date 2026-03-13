# Phase 5.0: Namespace & Pod Security

> **Status:** Planned
> **Target:** v0.30.0
> **Prerequisite:** v0.29.0 (Vault + ESO)
> **DevOps Topics:** Pod Security Standards, secrets hardening, SecurityContext, service account tokens
> **CKA Topics:** PSS, SecurityContext, ServiceAccount, automountServiceAccountToken

> **Purpose:** Lock down pods, namespaces, and secrets infrastructure
>
> **Learning Goal:** Kubernetes security model — PSS enforcement, ESO hardening, service account token hygiene

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

## 5.0.6 Documentation

- [ ] 5.0.6.1 Create `docs/context/Security.md`
  ```
  Document:
  - PSS levels per namespace (table)
  - ESO hardening decisions and known trade-offs
  - Vault + ESO trust boundaries
  - automountServiceAccountToken decisions (which pods need it and why)
  ```

  **ESO known trade-offs to document:**

  | Decision | Rationale |
  |----------|-----------|
  | HTTP Vault connection (not HTTPS) | In-cluster only, no external exposure. mTLS adds cert overhead for minimal gain. |
  | Single ClusterSecretStore | Simpler ops. Acceptable for single admin. Revisit if adding untrusted tenants. |
  | Broad `eso-policy` (`secret/data/*`) | ESO is the only Vault consumer. Per-namespace policies = 15 roles, significant rework. |
  | No policy engine (Kyverno/OPA) | Overkill for single-admin. `namespaceSelector` provides sufficient restriction. |

- [ ] 5.0.6.2 Update `docs/reference/CHANGELOG.md`

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
- [ ] Security.md created with PSS levels, ESO hardening, and automountServiceAccountToken decisions

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

---

## Final: Commit and Release

- [ ] `/audit-security` then `/commit`
- [ ] `/audit-docs` then `/commit`
- [ ] `/release v0.30.0 "Namespace & Pod Security"`
- [ ] `mv docs/todo/phase-5.0-namespace-pod-security.md docs/todo/completed/`
