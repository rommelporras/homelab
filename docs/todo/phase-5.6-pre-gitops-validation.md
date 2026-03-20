# Phase 5.5: Pre-GitOps Validation

> **Status:** Planned
> **Target:** v0.35.0
> **Prerequisite:** Phase 5.4 (v0.34.0 — resilience and backup in place)
> **DevOps Topics:** CIS compliance, admission control, supply chain security, GitOps readiness
> **CKA Topics:** ValidatingAdmissionPolicy, CIS Benchmark, security verification

> **Purpose:** Final security validation and GitOps preparation — verify all hardening is in place before handing cluster management to a GitOps controller
>
> **Learning Goal:** Kubernetes admission control (native VAP, not third-party), CIS compliance as continuous practice, GitOps security model

> **Why a separate phase?** Phases 5.0-5.4 implement security controls. This phase VERIFIES them
> and adds the final layer (admission control) that prevents GitOps from deploying non-compliant workloads.
> Think of it as the "pre-flight checklist" before handing the keys to ArgoCD/FluxCD.

---

## 5.5.1 CIS Benchmark Final Scan

Run kube-bench as final verification. Compare against Phase 5.1 baseline.

- [ ] 5.5.1.1 Run kube-bench Job on all 3 CP nodes
  ```yaml
  # Same Job spec as Phase 5.1, but run on all nodes
  apiVersion: batch/v1
  kind: Job
  metadata:
    name: kube-bench-final
    namespace: kube-system
  spec:
    template:
      spec:
        hostPID: true
        nodeSelector:
          node-role.kubernetes.io/control-plane: ""
        tolerations:
          - key: node-role.kubernetes.io/control-plane
            effect: NoSchedule
        containers:
          - name: kube-bench
            image: aquasecurity/kube-bench:v0.10.6
            command: ["kube-bench", "run", "--targets", "master,node,policies"]
            volumeMounts:
              - name: var-lib-etcd
                mountPath: /var/lib/etcd
                readOnly: true
              - name: etc-kubernetes
                mountPath: /etc/kubernetes
                readOnly: true
              - name: etc-systemd
                mountPath: /etc/systemd
                readOnly: true
              - name: var-lib-kubelet
                mountPath: /var/lib/kubelet
                readOnly: true
        volumes:
          - name: var-lib-etcd
            hostPath: { path: /var/lib/etcd }
          - name: etc-kubernetes
            hostPath: { path: /etc/kubernetes }
          - name: etc-systemd
            hostPath: { path: /etc/systemd }
          - name: var-lib-kubelet
            hostPath: { path: /var/lib/kubelet }
        restartPolicy: Never
  ```

- [ ] 5.5.1.2 Document final CIS score and compare against Phase 5.1 baseline
  ```bash
  kubectl-homelab logs job/kube-bench-final -n kube-system | tail -20
  ```

- [ ] 5.5.1.3 Review remaining FAIL items — document justification for each
  ```
  Expected acceptable FAILs:
  - Items requiring different architecture (e.g., separate etcd cluster)
  - Items conflicting with Cilium (e.g., kube-proxy related)
  - Items that are overkill for homelab (e.g., multi-tenant admission)
  ```

---

## 5.5.2 Deploy kube-bench as Recurring CronJob

Continuous CIS compliance — detect regressions after future changes.

- [ ] 5.5.2.1 Create kube-bench CronJob
  ```yaml
  apiVersion: batch/v1
  kind: CronJob
  metadata:
    name: kube-bench-weekly
    namespace: kube-system
  spec:
    schedule: "0 20 * * 0"       # Weekly Sunday 04:00 Manila time
    timeZone: "Asia/Manila"
    successfulJobsHistoryLimit: 1
    failedJobsHistoryLimit: 1
    jobTemplate:
      spec:
        backoffLimit: 0
        activeDeadlineSeconds: 300
        template:
          spec:
            hostPID: true
            nodeSelector:
              node-role.kubernetes.io/control-plane: ""
            tolerations:
              - key: node-role.kubernetes.io/control-plane
                effect: NoSchedule
            automountServiceAccountToken: false
            containers:
              - name: kube-bench
                image: aquasecurity/kube-bench:v0.10.6
                command: ["/bin/sh", "-c"]
                args:
                  - |
                    RESULT=$(kube-bench run --targets master,node,policies 2>&1)
                    echo "$RESULT"
                    # Extract summary line
                    SUMMARY=$(echo "$RESULT" | grep -E "^\d+ checks (PASS|FAIL|WARN|INFO)")
                    FAILS=$(echo "$RESULT" | grep -oP '\d+(?= checks FAIL)' || echo "0")
                    if [ "$FAILS" -gt 5 ]; then
                      echo "WARNING: $FAILS CIS checks failing — regression detected"
                      if [ -n "$DISCORD_WEBHOOK_URL" ]; then
                        curl -H "Content-Type: application/json" \
                          -d "{\"content\":\"kube-bench: $FAILS CIS checks failing (threshold: 5). Run kube-bench manually to investigate.\"}" \
                          "$DISCORD_WEBHOOK_URL"
                      fi
                    fi
                env:
                  - name: DISCORD_WEBHOOK_URL
                    valueFrom:
                      secretKeyRef:
                        name: kube-bench-discord
                        key: webhook-url
                        optional: true
                resources:
                  requests: { cpu: 100m, memory: 128Mi }
                  limits: { cpu: 500m, memory: 256Mi }
                securityContext:
                  readOnlyRootFilesystem: true
                volumeMounts:
                  - name: var-lib-etcd
                    mountPath: /var/lib/etcd
                    readOnly: true
                  - name: etc-kubernetes
                    mountPath: /etc/kubernetes
                    readOnly: true
                  - name: etc-systemd
                    mountPath: /etc/systemd
                    readOnly: true
                  - name: var-lib-kubelet
                    mountPath: /var/lib/kubelet
                    readOnly: true
            volumes:
              - name: var-lib-etcd
                hostPath: { path: /var/lib/etcd }
              - name: etc-kubernetes
                hostPath: { path: /etc/kubernetes }
              - name: etc-systemd
                hostPath: { path: /etc/systemd }
              - name: var-lib-kubelet
                hostPath: { path: /var/lib/kubelet }
            restartPolicy: Never
  ```

- [ ] 5.5.2.2 Set initial FAIL threshold based on final scan results (adjust the `5` in the script)

- [ ] 5.5.2.3 Run CronJob manually to verify Discord notification works

---

## 5.5.3 Image Registry Restriction (ValidatingAdmissionPolicy)

> **Why ValidatingAdmissionPolicy (VAP) instead of Kyverno?**
> VAP is built into Kubernetes since v1.30 (GA). No external dependencies, no CRD operators,
> no extra attack surface. CKA-relevant skill. Shows understanding of the native admission chain.
>
> **Why before GitOps?** ArgoCD/FluxCD will deploy whatever manifests are in Git. If someone
> pushes a manifest referencing an untrusted registry, it deploys without question.
> This policy prevents that at the admission level.

- [ ] 5.5.3.1 Create ValidatingAdmissionPolicy for trusted registries
  ```yaml
  apiVersion: admissionregistration.k8s.io/v1
  kind: ValidatingAdmissionPolicy
  metadata:
    name: restrict-image-registries
  spec:
    failurePolicy: Fail
    matchConstraints:
      resourceRules:
        - apiGroups: [""]
          apiVersions: ["v1"]
          operations: ["CREATE", "UPDATE"]
          resources: ["pods"]
        - apiGroups: ["apps"]
          apiVersions: ["v1"]
          operations: ["CREATE", "UPDATE"]
          resources: ["deployments", "statefulsets", "daemonsets", "replicasets"]
    validations:
      - expression: >-
          object.spec.?containers.orValue([]).all(c,
            c.image.startsWith('docker.io/') ||
            c.image.startsWith('ghcr.io/') ||
            c.image.startsWith('registry.k8s.io/') ||
            c.image.startsWith('quay.io/') ||
            c.image.startsWith('registry.gitlab.k8s.rommelporras.com/') ||
            c.image.startsWith('aquasecurity/') ||
            c.image.startsWith('hashicorp/') ||
            c.image.startsWith('grafana/') ||
            c.image.startsWith('prom/') ||
            c.image.startsWith('curlimages/') ||
            !c.image.contains('/')
          )
        message: "Container image must be from a trusted registry (docker.io, ghcr.io, registry.k8s.io, quay.io, or GitLab registry)"
      - expression: >-
          object.spec.?initContainers.orValue([]).all(c,
            c.image.startsWith('docker.io/') ||
            c.image.startsWith('ghcr.io/') ||
            c.image.startsWith('registry.k8s.io/') ||
            c.image.startsWith('quay.io/') ||
            c.image.startsWith('registry.gitlab.k8s.rommelporras.com/') ||
            c.image.startsWith('aquasecurity/') ||
            c.image.startsWith('hashicorp/') ||
            c.image.startsWith('grafana/') ||
            c.image.startsWith('prom/') ||
            c.image.startsWith('curlimages/') ||
            !c.image.contains('/')
          )
        message: "Init container image must be from a trusted registry"
  ---
  apiVersion: admissionregistration.k8s.io/v1
  kind: ValidatingAdmissionPolicyBinding
  metadata:
    name: restrict-image-registries-binding
  spec:
    policyName: restrict-image-registries
    validationActions:
      - Warn       # Start with Warn to catch issues before enforcing
    matchResources:
      namespaceSelector:
        matchExpressions:
          - key: kubernetes.io/metadata.name
            operator: NotIn
            values: ["kube-system", "kube-node-lease", "kube-public"]   # Exempt system namespaces
  ```

  > **Important:** Start with `validationActions: [Warn]` (not `Deny`). This logs warnings
  > without blocking deployments. After verifying no false positives for 1 week, switch to `Deny`.

  > **Registry list:** The trusted registries above cover all images currently deployed in
  > the cluster. Before enforcing, audit all running images:
  > ```bash
  > kubectl-homelab get pods -A -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{range .spec.initContainers[*]}{.image}{"\n"}{end}{end}' | sort -u
  > ```

- [ ] 5.5.3.2 Apply VAP in Warn mode
  ```bash
  kubectl-homelab apply -f manifests/kube-system/image-registry-policy.yaml
  ```

- [ ] 5.5.3.3 Verify warnings appear for test deployment with untrusted registry
  ```bash
  # This should generate a warning (not block, since we're in Warn mode)
  kubectl-homelab run test-untrusted --image=evil-registry.example.com/backdoor:latest \
    --dry-run=server -n default
  # Should show: Warning: Container image must be from a trusted registry
  ```

- [ ] 5.5.3.4 Audit all existing images against trusted registry list
  ```bash
  # Identify any images that would be blocked
  kubectl-homelab get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}: {range .spec.containers[*]}{.image}{", "}{end}{"\n"}{end}' | \
    grep -vE '(docker\.io|ghcr\.io|registry\.k8s\.io|quay\.io|registry\.gitlab)' | \
    grep '/'
  # Any matches need their registry added to the trusted list or the image needs updating
  ```

- [ ] 5.5.3.5 After 1 week of clean warnings, switch to Deny mode
  ```bash
  # Edit the binding: change Warn to Deny
  kubectl-homelab patch validatingadmissionpolicybinding restrict-image-registries-binding \
    --type=merge -p '{"spec":{"validationActions":["Deny"]}}'
  ```

---

## 5.5.4 GitOps Namespace Preparation

Prepare the namespace, RBAC, and NetworkPolicy for ArgoCD/FluxCD. Don't deploy the GitOps controller yet — that's Phase 6.

- [ ] 5.5.4.1 Create GitOps namespace manifest
  ```yaml
  apiVersion: v1
  kind: Namespace
  metadata:
    name: argocd        # or fluxcd — decide in Phase 6
    labels:
      pod-security.kubernetes.io/enforce: baseline
      pod-security.kubernetes.io/enforce-version: latest
      pod-security.kubernetes.io/warn: restricted
      pod-security.kubernetes.io/warn-version: latest
      eso-enabled: "true"  # If GitOps controller needs secrets from Vault
  ```

- [ ] 5.5.4.2 Plan GitOps controller RBAC (DO NOT apply yet — plan only)
  ```yaml
  # ArgoCD defaults to cluster-admin. This is too broad.
  # Plan a scoped ClusterRole that only manages:
  # - Application namespaces (not kube-system, monitoring, etc.)
  # - Standard resources (Deployments, Services, ConfigMaps, etc.)
  # - CRDs needed for homelab (ExternalSecrets, HTTPRoutes, etc.)
  #
  # The actual RBAC will be refined during Phase 6 (ArgoCD deployment)
  # based on the specific GitOps controller chosen.
  #
  # Key decisions to make in Phase 6:
  # - ArgoCD vs FluxCD (different RBAC models)
  # - Which namespaces are GitOps-managed vs manually managed
  # - Whether to use ArgoCD Projects for namespace isolation
  # - Whether to use FluxCD's multi-tenancy (--no-cross-namespace-refs)
  ```

- [ ] 5.5.4.3 Document GitOps security model
  ```
  Document in Security.md:
  - Which registries are trusted (and why)
  - GitOps controller RBAC approach (scoped, not cluster-admin)
  - Git source verification plan (GPG/Cosign — evaluate in Phase 6)
  - Drift detection strategy (ArgoCD auto-sync vs manual sync)
  - Secret handling: Vault + ESO ExternalSecrets in Git (never raw Secrets)
  ```

---

## 5.5.5 Full Cluster Security Audit

Final comprehensive audit before GitOps adoption.

- [ ] 5.5.5.1 Verify all Phase 5.0-5.4 controls are in place
  ```bash
  echo "=== Phase 5.0: Namespace & Pod Security ==="
  # All namespaces have PSS labels
  kubectl-homelab get ns -o json | jq -r '.items[] | .metadata.name + ": enforce=" + (.metadata.labels["pod-security.kubernetes.io/enforce"] // "NONE")'

  # automountServiceAccountToken disabled on app pods
  kubectl-homelab get pods -A -o json | jq -r '
    .items[] |
    select(.spec.automountServiceAccountToken != false) |
    select(.metadata.namespace | test("^(kube-|longhorn|cilium|monitoring|external-secrets|cert-manager|vault)") | not) |
    .metadata.namespace + "/" + .metadata.name + " — automount: " + (.spec.automountServiceAccountToken | tostring)
  '

  # ClusterSecretStore has namespaceSelector
  kubectl-homelab get clustersecretstore vault-backend -o json | jq '.spec.conditions'

  echo "=== Phase 5.1: Control Plane ==="
  # Audit logging active
  ssh wawashi@10.10.30.11 "sudo ls -la /var/log/kubernetes/audit/audit.log"

  # Anonymous auth disabled on kubelet
  ssh wawashi@10.10.30.11 "sudo grep -A2 'anonymous:' /var/lib/kubelet/config.yaml"

  echo "=== Phase 5.2: RBAC & Secrets ==="
  # etcd encryption active
  kubectl-homelab get secret encryption-test -n default -o json 2>/dev/null || echo "Create test secret to verify"

  # No unexpected cluster-admin bindings
  kubectl-homelab get clusterrolebindings -o json | jq -r '.items[] | select(.roleRef.name == "cluster-admin") | .metadata.name'

  echo "=== Phase 5.3: Network Policies ==="
  # All namespaces have default-deny
  for ns in $(kubectl-homelab get ns -o jsonpath='{.items[*].metadata.name}'); do
    POLICIES=$(kubectl-homelab get networkpolicy -n "$ns" --no-headers 2>/dev/null | wc -l)
    echo "$ns: $POLICIES NetworkPolicies"
  done

  echo "=== Phase 5.4: Resilience ==="
  # Backup CronJobs running
  kubectl-homelab get cronjobs -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,SCHEDULE:.spec.schedule,LAST:.status.lastSuccessfulTime

  # ResourceQuotas in place
  kubectl-homelab get resourcequota -A

  # PDBs in place
  kubectl-homelab get pdb -A
  ```

- [ ] 5.5.5.2 Generate security posture summary document
  ```
  Table showing:
  | Control | Status | Coverage | Evidence |
  |---------|--------|----------|----------|
  | PSS | Enforced | 100% namespaces | kubectl output |
  | NetworkPolicy | Default-deny | 100% app namespaces | kubectl output |
  | RBAC | Audited | All SAs reviewed | Audit doc |
  | etcd encryption | Active | All secrets | etcdctl verify |
  | Audit logging | Active | All API calls | Loki query |
  | Backup | 3-layer | Longhorn+Velero+etcd | CronJob status |
  | CIS benchmark | XX/YY pass | kube-bench score | Job output |
  | Image restriction | VAP enforced | All namespaces | Policy status |
  ```

---

## 5.5.6 Documentation

- [ ] 5.5.6.1 Update `docs/context/Security.md` with:
  - Final CIS benchmark score
  - Image registry restriction policy
  - GitOps security model
  - Complete security posture summary

- [ ] 5.5.6.2 Update `docs/reference/CHANGELOG.md`

- [ ] 5.5.6.3 Update `VERSIONS.md` if new components added

---

## Verification Checklist

- [ ] kube-bench final scan completed and documented
- [ ] kube-bench weekly CronJob deployed with Discord alerting
- [ ] CIS score improved from Phase 5.1 baseline
- [ ] All remaining FAIL items justified and documented
- [ ] ValidatingAdmissionPolicy for image registries deployed
- [ ] VAP tested in Warn mode — no false positives
- [ ] VAP switched to Deny mode after verification period
- [ ] GitOps namespace manifest created (not applied yet)
- [ ] GitOps RBAC approach documented (not applied yet)
- [ ] Full cluster security audit passed
- [ ] Security posture summary document generated
- [ ] All Phase 5.0-5.4 controls verified as active

---

## Rollback

**VAP blocks legitimate deployments:**
```bash
# Switch back to Warn mode immediately
kubectl-homelab patch validatingadmissionpolicybinding restrict-image-registries-binding \
  --type=merge -p '{"spec":{"validationActions":["Warn"]}}'

# Or delete entirely
kubectl-homelab delete validatingadmissionpolicybinding restrict-image-registries-binding
kubectl-homelab delete validatingadmissionpolicy restrict-image-registries
```

**kube-bench CronJob issues:**
```bash
kubectl-homelab delete cronjob kube-bench-weekly -n kube-system
```

---

## Final: Commit and Release

- [ ] `/audit-security` then `/commit`
- [ ] `/audit-docs` then `/commit`
- [ ] `/release v0.35.0 "Pre-GitOps Validation"`
- [ ] `mv docs/todo/phase-5.5-pre-gitops-validation.md docs/todo/completed/`
