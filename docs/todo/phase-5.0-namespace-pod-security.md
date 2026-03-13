# Phase 5.0: Namespace & Pod Security

> **Status:** In Progress
> **Target:** v0.30.0
> **Prerequisite:** v0.29.0 (Vault + ESO)
> **DevOps Topics:** Pod Security Standards, secrets hardening, SecurityContext, service account tokens
> **CKA Topics:** PSS, SecurityContext, ServiceAccount, automountServiceAccountToken

> **Purpose:** Lock down pods, namespaces, and secrets infrastructure
>
> **Learning Goal:** Kubernetes security model — PSS enforcement, ESO hardening, service account token hygiene

---

## 5.0.1 Create Namespace Manifests

Foundation task — PSS labels, ESO labels, and NetworkPolicies (Phase 5.3) all depend on declarative namespace manifests.

**9 namespaces lack `namespace.yaml`:**

| Namespace | Has ExternalSecret | Helm-Managed | Needs `eso-enabled` |
|-----------|--------------------|--------------|---------------------|
| cert-manager | Yes | Yes (Helm) | Yes |
| cloudflare | Yes | No | Yes |
| gitlab | Yes | Yes (Helm) | Yes |
| gitlab-runner | Yes | Yes (Helm) | Yes |
| invoicetron-dev | Yes | No | Yes |
| invoicetron-prod | Yes | No | Yes |
| portfolio-dev | No | No | No |
| portfolio-prod | No | No | No |
| portfolio-staging | No | No | No |

> **Note:** There is no `portfolio` namespace — actual namespaces are `portfolio-dev`,
> `portfolio-prod`, `portfolio-staging`. All three lack `namespace.yaml`.
> Portfolio namespace manifests go into `manifests/portfolio/` (same directory as deployment/rbac).

> **Note:** `invoicetron-dev` and `invoicetron-prod` manifests live in a single `manifests/invoicetron/`
> directory (not separate `manifests/invoicetron-dev/` and `manifests/invoicetron-prod/` directories).
> Namespace manifests for both envs go into `manifests/invoicetron/`.

**Also need `eso-enabled` label added to existing namespace.yaml files:**
arr-stack, atuin, browser, ghost-dev, ghost-prod, home, karakeep

> **Note:** `ai` namespace has `namespace.yaml` but NO ExternalSecrets — does not get `eso-enabled`.
> `uptime-kuma`, `vault`, `tailscale` also have `namespace.yaml` but no ExternalSecrets.

**And these Helm-managed namespaces need `eso-enabled` applied imperatively + documented:**
kube-system, monitoring

> **Note:** `intel-device-plugins` and `node-feature-discovery` are Helm-managed but have
> NO ExternalSecrets — they do NOT get the `eso-enabled` label.

- [x] 5.0.1.1 Create `namespace.yaml` for each of the 9 namespaces above
  ```yaml
  # Template — adjust name, PSS level, and eso-enabled per namespace
  apiVersion: v1
  kind: Namespace
  metadata:
    name: <namespace>
    labels:
      pod-security.kubernetes.io/enforce: baseline
      pod-security.kubernetes.io/audit: restricted
      pod-security.kubernetes.io/warn: restricted
      eso-enabled: "true"  # Only if namespace has ExternalSecrets
  ```

  > **Exception — cloudflare:** Currently has `enforce: restricted` (set during v0.29.0).
  > Keep it at `restricted` — do NOT downgrade to `baseline`. cloudflared pods already
  > comply with restricted profile.

  > **Exception — gitlab & gitlab-runner:** Currently at `enforce: privileged` in cluster
  > (set during GitLab Helm install). The 5.0.2.1 audit will determine if they can be
  > downgraded to baseline. GitLab runner may need privileged if it spawns build pods
  > with elevated permissions. If audit fails, keep privileged and document why.

  > **Note on version labels:** Omitted from template. Kubernetes defaults to `latest`
  > when version labels are absent, which matches our intent. Existing `vault` namespace
  > has explicit version labels — normalize it to match the majority pattern (remove them).

- [x] 5.0.1.2 Add `eso-enabled: "true"` label to existing namespace.yaml files
  - arr-stack, atuin, browser, ghost-dev, ghost-prod, home, karakeep
  - Also normalize vault namespace.yaml: remove `-version: latest` labels, add `audit: restricted`

- [x] 5.0.1.3 Label Helm-managed namespaces imperatively (eso-enabled only)
  ```bash
  # Only kube-system and monitoring have ExternalSecrets
  for ns in kube-system monitoring; do
    kubectl-homelab label namespace "$ns" eso-enabled=true --overwrite
  done
  ```

- [x] 5.0.1.4 Apply all namespace manifests
  ```bash
  # Apply new namespace manifests (9 new)
  kubectl-homelab apply -f manifests/cert-manager/namespace.yaml
  kubectl-homelab apply -f manifests/cloudflare/namespace.yaml
  kubectl-homelab apply -f manifests/gitlab/namespace.yaml
  kubectl-homelab apply -f manifests/gitlab-runner/namespace.yaml
  kubectl-homelab apply -f manifests/invoicetron/namespace-dev.yaml
  kubectl-homelab apply -f manifests/invoicetron/namespace-prod.yaml
  kubectl-homelab apply -f manifests/portfolio/namespace-dev.yaml
  kubectl-homelab apply -f manifests/portfolio/namespace-prod.yaml
  kubectl-homelab apply -f manifests/portfolio/namespace-staging.yaml

  # Apply updated existing namespace manifests (8 updated: 7 + eso-enabled, vault normalized)
  kubectl-homelab apply -f manifests/arr-stack/namespace.yaml
  kubectl-homelab apply -f manifests/atuin/namespace.yaml
  kubectl-homelab apply -f manifests/browser/namespace.yaml
  kubectl-homelab apply -f manifests/ghost-dev/namespace.yaml
  kubectl-homelab apply -f manifests/ghost-prod/namespace.yaml
  kubectl-homelab apply -f manifests/home/namespace.yaml
  kubectl-homelab apply -f manifests/karakeep/namespace.yaml
  kubectl-homelab apply -f manifests/vault/namespace.yaml
  ```

---

## 5.0.2 Pod Security Standards

> **CKA Topic:** PSS is the replacement for deprecated PodSecurityPolicy

| Level | Use Case | Namespaces |
|-------|----------|------------|
| **Privileged** | System components | monitoring, longhorn-system, tailscale, kube-system, intel-device-plugins, node-feature-discovery, gitlab-runner |
| **Baseline** | Most applications | All app namespaces including gitlab, external-secrets (see below) |
| **Restricted** | Sensitive workloads | cloudflare (already restricted) |

> **Current cluster state (audit):**
>
> | Status | Namespaces |
> |--------|------------|
> | enforce=baseline + audit/warn=restricted | ai, arr-stack, atuin, browser, ghost-dev, ghost-prod, home, karakeep, uptime-kuma |
> | enforce=baseline only (missing audit/warn) | invoicetron-dev, invoicetron-prod, portfolio-dev, portfolio-prod, portfolio-staging |
> | enforce=baseline + warn=restricted (no audit) | vault |
> | enforce=restricted | cloudflare |
> | enforce=privileged | gitlab, gitlab-runner, longhorn-system, monitoring, tailscale |
> | NO PSS labels | cert-manager, cilium-secrets, default, external-secrets, intel-device-plugins, kube-node-lease, kube-public, kube-system, node-feature-discovery |
>
> **Goal:** Every namespace gets at minimum `enforce` + `audit: restricted` + `warn: restricted`.

> **vault and external-secrets:** Plan originally targeted `enforce: restricted` for both.
> Vault has known issue (vault-helm#1035) preventing restricted compliance. external-secrets
> has NO PSS labels at all. Run 5.0.2.1 audit to determine actual compliance. If restricted
> fails, keep baseline and document why.

- [x] 5.0.2.1 Audit all namespaces with `warn=restricted` dry-run
  ```bash
  # Check which pods would violate restricted profile
  for ns in $(kubectl-homelab get ns -o jsonpath='{.items[*].metadata.name}'); do
    echo "=== $ns ==="
    kubectl-homelab label namespace "$ns" \
      pod-security.kubernetes.io/warn=restricted \
      --dry-run=server -o yaml 2>&1 | grep -A2 "warning"
  done
  ```

- [x] 5.0.2.2 Fix pod security violations
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

  > **Already good:** Most manifests already have seccompProfile, allowPrivilegeEscalation,
  > and capabilities drop. The main gaps are `runAsNonRoot` on some ARR apps (Bazarr, Byparr,
  > Jellyfin, Prowlarr, qBittorrent, Radarr, Recommendarr, Scraparr, Seerr, Sonarr, Unpackerr),
  > Browser (Firefox), and Home apps (AdGuard, Homepage, MySpeed).
  >
  > **Known non-root exceptions (already documented in manifests):**
  > - Karakeep: s6-overlay requires root for init
  > - Meilisearch: image runs as root
  > - Ollama: upstream PR #8259 not merged
  > - Tdarr: expects root init then drops privileges

- [x] 5.0.2.3 Enforce PSS on all namespaces

  ```bash
  # App namespaces — enforce baseline, audit + warn restricted
  APP_NS="ai arr-stack atuin browser cert-manager ghost-dev ghost-prod \
    home invoicetron-dev invoicetron-prod \
    karakeep portfolio-dev portfolio-prod portfolio-staging uptime-kuma"
  for ns in $APP_NS; do
    kubectl-homelab label namespace "$ns" \
      pod-security.kubernetes.io/enforce=baseline \
      pod-security.kubernetes.io/audit=restricted \
      pod-security.kubernetes.io/warn=restricted \
      --overwrite
  done

  # cloudflare already has enforce=restricted — only add audit/warn
  kubectl-homelab label namespace cloudflare \
    pod-security.kubernetes.io/audit=restricted \
    pod-security.kubernetes.io/warn=restricted \
    --overwrite
  # Verify: kubectl-homelab get ns cloudflare --show-labels

  # gitlab / gitlab-runner — ONLY downgrade from privileged if 5.0.2.1 audit passes
  # If audit shows violations, keep privileged and add warn/audit for visibility:
  for ns in gitlab gitlab-runner; do
    kubectl-homelab label namespace "$ns" \
      pod-security.kubernetes.io/enforce=baseline \
      pod-security.kubernetes.io/audit=restricted \
      pod-security.kubernetes.io/warn=restricted \
      --overwrite
  done
  # ^^^ If baseline breaks GitLab, immediately revert:
  #   kubectl-homelab label namespace gitlab pod-security.kubernetes.io/enforce=privileged --overwrite
  #   kubectl-homelab label namespace gitlab-runner pod-security.kubernetes.io/enforce=privileged --overwrite

  # Infrastructure namespaces — external-secrets gets baseline (or restricted if audit passes)
  kubectl-homelab label namespace external-secrets \
    pod-security.kubernetes.io/enforce=baseline \
    pod-security.kubernetes.io/audit=restricted \
    pod-security.kubernetes.io/warn=restricted \
    --overwrite

  # Helm-managed namespaces without PSS labels
  for ns in intel-device-plugins node-feature-discovery; do
    kubectl-homelab label namespace "$ns" \
      pod-security.kubernetes.io/enforce=baseline \
      pod-security.kubernetes.io/audit=restricted \
      pod-security.kubernetes.io/warn=restricted \
      --overwrite
  done

  # System namespaces — privileged (run host-level components)
  for ns in kube-system; do
    kubectl-homelab label namespace "$ns" \
      pod-security.kubernetes.io/enforce=privileged \
      pod-security.kubernetes.io/audit=restricted \
      pod-security.kubernetes.io/warn=restricted \
      --overwrite
  done

  # Skip these (managed by Kubernetes/Helm, low risk):
  #   cilium-secrets — Cilium-managed, no user pods
  #   default — unused
  #   kube-node-lease — system lease objects only
  #   kube-public — system, no pods
  ```

---

## 5.0.3 Disable automountServiceAccountToken

> **CKA Topic:** Limiting service account token exposure reduces blast radius of pod compromise

Most app pods don't need the Kubernetes API.

**Already set to `false` (9 manifests — no changes needed):**
- `manifests/ai/ollama-deployment.yaml`
- `manifests/atuin/backup-cronjob.yaml`
- `manifests/atuin/postgres-deployment.yaml`
- `manifests/atuin/server-deployment.yaml`
- `manifests/karakeep/chrome-deployment.yaml`
- `manifests/karakeep/karakeep-deployment.yaml`
- `manifests/karakeep/meilisearch-deployment.yaml`
- `manifests/arr-stack/stall-resolver/cronjob.yaml`
- `manifests/monitoring/otel/otel-collector.yaml`

**Already set to `true` (needs API access — no changes needed):**
- `manifests/monitoring/version-checker/version-checker-deployment.yaml`

**Pods that NEED API access (don't disable — managed by Helm or already set):**
- ESO controller, webhook, cert-controller (reads/writes Secrets)
- Vault (Kubernetes auth backend)
- Prometheus, kube-state-metrics (scrapes cluster)
- Alloy (ships logs)
- node-exporter (host metrics)
- cert-manager (manages certificates)
- Cilium (CNI)
- version-checker (queries container versions)

**Pods that NEED API access (our manifests — add `automountServiceAccountToken: true` explicitly):**
- Cluster Janitor CronJob (deletes pods/replicas) — `manifests/kube-system/cluster-janitor/cronjob.yaml`

**Pods that DON'T need API access (add `automountServiceAccountToken: false`):**

| Namespace | Manifests to update |
|-----------|-------------------|
| arr-stack | bazarr, byparr, configarr (CronJob), jellyfin, prowlarr, qbittorrent, qbittorrent-exporter, radarr, recommendarr, scraparr, seerr, sonarr, tdarr, tdarr-exporter, unpackerr |
| browser | deployment.yaml (Firefox) |
| cloudflare | deployment.yaml (cloudflared) |
| ghost-dev | ghost-deployment.yaml, mysql-statefulset.yaml |
| ghost-prod | analytics-deployment.yaml, ghost-deployment.yaml, mysql-statefulset.yaml |
| home | adguard/deployment.yaml, homepage/deployment.yaml, myspeed/deployment.yaml |
| invoicetron | ~~deployment.yaml~~ (deferred), postgresql.yaml (StatefulSet), backup-cronjob.yaml |
| monitoring | exporters/nut-exporter.yaml, version-checker/version-check-cronjob.yaml |
| portfolio | deployment.yaml |
| uptime-kuma | statefulset.yaml |
| vault | snapshot-cronjob.yaml, unsealer.yaml |

> **Note:** Vault unsealer calls Vault's HTTP API (not K8s API). Vault snapshot CronJob
> calls `vault operator raft snapshot` via HTTP. Neither needs a K8s service account token.

- [x] 5.0.3.1 Add `automountServiceAccountToken: false` to all pod specs listed above
  ```yaml
  spec:
    automountServiceAccountToken: false
    # ... rest of pod spec
  ```

  > **Deferred:** `invoicetron/deployment.yaml` — image `registry.k8s.rommelporras.com/0xwsh/invoicetron:latest`
  > not found in registry. Adding automountServiceAccountToken triggers a rollout which causes
  > ImagePullBackOff. Change commented out in manifest. Apply when image registry is fixed.

- [x] 5.0.3.2 Add `automountServiceAccountToken: true` to cluster-janitor CronJob (explicit)

- [x] 5.0.3.3 Verify apps still work after disabling
  ```bash
  kubectl-homelab get pods -A | grep -v Running | grep -v Completed
  # Should show only header — no CrashLooping pods from missing token
  ```

---

## 5.0.4 ESO Helm Hardening

> **Source:** ESO [Security Best Practices](https://external-secrets.io/latest/guides/security-best-practices/), [Threat Model](https://external-secrets.io/latest/guides/threat-model/)

> **Current state:** ESO pods have NO resource requests/limits. All 3 pods (controller,
> webhook, cert-controller) run with empty `resources: {}`.

- [x] 5.0.4.1 Add resource limits to `helm/external-secrets/values.yaml`
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

- [x] 5.0.4.2 Disable unused CRD reconcilers (ESO threat model C05)
  ```yaml
  # Not using ClusterExternalSecret or PushSecret (confirmed: 0 references in codebase)
  processClusterExternalSecret: false
  processPushSecret: false
  ```

- [x] 5.0.4.3 Restrict webhook TLS ciphers
  ```yaml
  webhook:
    extraArgs:
      tls-ciphers: "TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256,TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256"
  ```

- [x] 5.0.4.4 Helm upgrade ESO
  ```bash
  helm-homelab upgrade external-secrets external-secrets/external-secrets \
    --namespace external-secrets \
    --version 2.1.0 \
    --values helm/external-secrets/values.yaml
  ```

- [x] 5.0.4.5 Verify ESO pods have limits after upgrade
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

**15 ESO-consuming namespaces** (must all have `eso-enabled: "true"` before applying):
arr-stack, atuin, browser, cert-manager, cloudflare, ghost-dev, ghost-prod, gitlab,
gitlab-runner, home, invoicetron-dev, invoicetron-prod, karakeep, kube-system, monitoring

- [x] 5.0.5.1 Add `namespaceSelector` to `manifests/vault/clustersecretstore.yaml`
  ```yaml
  spec:
    conditions:
      - namespaceSelector:
          matchLabels:
            eso-enabled: "true"
    provider:
      vault: ...  # existing config unchanged
  ```

- [x] 5.0.5.2 Verify all eso-enabled labels are applied before restricting
  ```bash
  # Confirm all 15 ESO namespaces have the label
  for ns in arr-stack atuin browser cert-manager cloudflare ghost-dev ghost-prod \
    gitlab gitlab-runner home invoicetron-dev invoicetron-prod karakeep kube-system monitoring; do
    echo -n "$ns: "
    kubectl-homelab get ns "$ns" -o jsonpath='{.metadata.labels.eso-enabled}'
    echo
  done
  # All should show "true"
  ```

- [x] 5.0.5.3 Apply and verify all 30 ExternalSecrets still sync
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

- [x] 5.0.5.4 Verify unlabeled namespace is blocked
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

## 5.0.6 Add Vault to Homepage Portal

> **Why here:** Phase 5.0 hardens vault infrastructure — having seal status visible on the
> dashboard is operational visibility for what we're hardening. Pairs with the Kubernetes
> group (Grafana, Prometheus, Alertmanager, Longhorn) on the Infrastructure tab.

> **No new secrets needed.** Vault's `/v1/sys/health` endpoint is unauthenticated by design
> (returns seal status, version, cluster info). Same endpoint Prometheus already scrapes.

- [x] 5.0.6.1 Add Vault to `manifests/home/homepage/config/services.yaml`

  Add to **Infrastructure tab → Kubernetes group** (alongside Grafana, Prometheus, Alertmanager):

  ```yaml
  - Vault:
      icon: vault
      href: https://vault.k8s.rommelporras.com
      description: Secrets Management
      siteMonitor: http://vault.vault.svc.cluster.local:8200/v1/sys/health
      widget:
        type: customapi
        url: http://vault.vault.svc.cluster.local:8200/v1/sys/health
        mappings:
          - field: sealed
            label: Sealed
            format: text
          - field: version
            label: Version
            format: text
          - field: cluster_name
            label: Cluster
            format: text
  ```

  > **Note:** `siteMonitor` uses the internal K8s service URL (not the external hostname).
  > The health endpoint returns `200` when unsealed, `503` when sealed — siteMonitor will
  > show red/green status accordingly.

- [x] 5.0.6.2 Update Homepage layout in `manifests/home/homepage/config/settings.yaml`
  > No change needed — columns: 4 handles 7 items (2 rows) cleanly

  Adjust the Kubernetes group column count if needed to accommodate the new Vault tile.

- [x] 5.0.6.3 Apply and verify
  ```bash
  kubectl-homelab apply -k manifests/home/homepage/
  # Wait for rollout (ConfigMap hash change triggers restart)
  kubectl-homelab rollout status deployment/homepage -n home
  # Verify Vault tile appears on Infrastructure tab with seal status
  ```

---

## 5.0.7 Documentation

- [x] 5.0.7.1 Create `docs/context/Security.md`
  ```
  Document:
  - PSS levels per namespace (table — all 30 namespaces)
  - ESO hardening decisions and known trade-offs
  - Vault + ESO trust boundaries
  - automountServiceAccountToken decisions (which pods need it and why)
  - Known non-root exceptions (Karakeep, Meilisearch, Ollama, Tdarr)
  ```

  **ESO known trade-offs to document:**

  | Decision | Rationale |
  |----------|-----------|
  | HTTP Vault connection (not HTTPS) | In-cluster only, no external exposure. mTLS adds cert overhead for minimal gain. |
  | Single ClusterSecretStore | Simpler ops. Acceptable for single admin. Revisit if adding untrusted tenants. |
  | Broad `eso-policy` (`secret/data/*`) | ESO is the only Vault consumer. Per-namespace policies = 15 roles, significant rework. |
  | No policy engine (Kyverno/OPA) | Overkill for single-admin. `namespaceSelector` provides sufficient restriction. |

- [x] 5.0.7.2 Update `docs/reference/CHANGELOG.md`

---

## Verification Checklist

- [ ] All namespaces have declarative `namespace.yaml` (or are Helm-managed/system-managed)
- [ ] PSS enforce label on every namespace (baseline for apps, privileged for system, restricted for cloudflare)
- [ ] PSS audit=restricted + warn=restricted on all namespaces (for visibility)
- [ ] cloudflare namespace kept at `enforce: restricted` (not downgraded)
- [ ] gitlab/gitlab-runner PSS level validated (baseline if audit passes, privileged if not — documented)
- [ ] Helm-managed namespaces (intel-device-plugins, node-feature-discovery) have PSS labels
- [ ] external-secrets PSS level validated (baseline or restricted based on audit)
- [ ] kube-system set to `enforce: privileged`
- [ ] vault namespace.yaml normalized (version labels removed, audit label added)
- [ ] `automountServiceAccountToken: false` on all app pods that don't need API access
- [ ] `automountServiceAccountToken: true` explicit on cluster-janitor
- [ ] ESO pods have resource requests/limits
- [ ] Unused CRD reconcilers disabled (`ClusterExternalSecret`, `PushSecret`)
- [ ] Webhook TLS ciphers restricted to modern suites
- [ ] ClusterSecretStore has `namespaceSelector` restricting to labeled namespaces
- [ ] All 15 ESO-consuming namespaces labeled `eso-enabled=true` (verified before CSS restriction)
- [ ] Unlabeled namespace cannot sync ExternalSecrets (tested)
- [ ] Security.md created with PSS levels, ESO hardening, and automountServiceAccountToken decisions
- [ ] Vault tile on Homepage Infrastructure tab showing seal status via `customapi` widget

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

**automountServiceAccountToken breaks a pod:**
```bash
# Edit the manifest to remove the line, then re-apply
kubectl-homelab apply -f manifests/<ns>/<manifest>.yaml
# Or patch directly:
kubectl-homelab patch deployment <name> -n <ns> \
  --type json -p '[{"op":"remove","path":"/spec/template/spec/automountServiceAccountToken"}]'
```

---

## Final: Commit and Release

- [ ] `/audit-security` then `/commit`
- [ ] `/audit-docs` then `/commit`
- [ ] `/release v0.30.0 "Namespace & Pod Security"`
- [ ] `mv docs/todo/phase-5.0-namespace-pod-security.md docs/todo/completed/`
