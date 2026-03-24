# Phase 5.6: Pre-GitOps Validation

> **Status:** Planned
> **Target:** v0.36.0
> **Prerequisite:** Phase 5.5 (v0.35.0 - observability and version hardening in place)
> **DevOps Topics:** CIS compliance, admission control, supply chain security, GitOps readiness
> **CKA Topics:** ValidatingAdmissionPolicy, CIS Benchmark, security verification

> **Purpose:** Final security validation and GitOps preparation - verify all hardening is in place
> before handing cluster management to ArgoCD.
>
> **Next Phases:** Phase 5.7 (ArgoCD Installation & Bootstrap, v0.37.0) and
> Phase 5.8 (GitOps Migration, v0.38.0) continue from where this phase ends.
>
> **Learning Goal:** Kubernetes admission control (native VAP, not third-party), CIS compliance
> as continuous practice.

> **Why a separate phase?** Phases 5.0-5.4 implement security controls. This phase VERIFIES them
> and adds the final layer (admission control) that prevents GitOps from deploying non-compliant
> workloads. Think of it as the "pre-flight checklist" before handing the keys to ArgoCD.

> **ArgoCD details:** ArgoCD comparison, v3 compatibility, installation planning, and bootstrap
> strategy are documented in Phase 5.7. Helm release migration procedure is in Phase 5.8.
> Argo Workflows evaluation is in Phase 5.9.

---

## 5.6.0 Prerequisites - Phase 5.5 Remediation

> **Why first?** Phase 5.5-C committed 23 monitoring resources to git but never applied them
> to the cluster. These must be deployed before Phase 5.6 starts - ArgoCD will eventually
> manage them, so they need to be running and verified first.

- [ ] 5.6.0.1 Apply 10 unapplied blackbox probes
  ```bash
  kubectl-admin apply -f manifests/monitoring/probes/
  ```
  Missing: cert-manager-webhook, eso-webhook, garage, homepage, longhorn-ui, myspeed,
  prowlarr, radarr, recommendarr, sonarr. Verify with `kubectl-homelab get probes -n monitoring`.

- [ ] 5.6.0.2 Apply 3 GitLab ServiceMonitors
  ```bash
  kubectl-admin apply -f manifests/monitoring/servicemonitors/gitlab-servicemonitor.yaml
  ```
  Missing: gitlab-exporter, gitlab-postgresql, gitlab-redis. Verify Prometheus targets appear.

- [ ] 5.6.0.3 Apply 2 unapplied PrometheusRules
  ```bash
  kubectl-admin apply -f manifests/monitoring/alerts/gitlab-alerts.yaml
  kubectl-admin apply -f manifests/monitoring/alerts/home-alerts.yaml
  ```
  These depend on the probes/ServiceMonitors above.

- [ ] 5.6.0.4 Apply 8 unapplied Grafana dashboards
  ```bash
  for f in cert-manager eso ghost-prod gitlab home invoicetron-prod loki-storage uptime-kuma; do
    kubectl-admin apply -f manifests/monitoring/dashboards/${f}-dashboard-configmap.yaml
  done
  ```
  Verify all 23 custom dashboards visible in Grafana Homelab folder.

- [ ] 5.6.0.5 Resolve 6 blocking GitOps gaps
  These architectural issues must be addressed before ArgoCD can manage the cluster:

  **Gap 1: Invoicetron CI/CD `kubectl set image` pattern**
  The manifest has a hardcoded prod image tag that CI/CD patches imperatively.
  ArgoCD would revert every CI/CD deploy on the next sync cycle.
  Fix options: (a) Kustomize image overlay patched by CI pipeline,
  (b) ArgoCD Image Updater, (c) commit image tag to Git in CI pipeline.
  See `docs/todo/deferred.md` "Invoicetron CI/CD Image Tag Alignment" for details.

  **Gap 2: NFD Helm release has no tracked values file**
  `node-feature-discovery` was installed but has no `helm/nfd/values.yaml`.
  Create a values file capturing current install flags.

  **Gap 3: Namespace-less multi-target manifests**
  `manifests/invoicetron/` and `manifests/portfolio/` are applied to multiple
  namespaces via `-n` flag. ArgoCD needs explicit `targetNamespace` per Application.
  Fix: split into per-environment directories or use Kustomize overlays.

  **Gap 4: Prometheus upgrade script uses runtime secrets**
  `scripts/monitoring/upgrade-prometheus.sh` reads secrets from K8s at runtime
  into a temp file. ArgoCD cannot replicate this. Fix: reference ESO-managed
  K8s Secrets directly in `helm/prometheus/values.yaml` via `existingSecret` fields.

  **Gap 5: vault-unseal-keys imperative Secret**
  Created manually, not via ESO. ArgoCD must never prune vault namespace Secrets.
  Exclude with `argocd.argoproj.io/compare-options: IgnoreExtraneous` or
  resource exclusion in argocd-cm.

  **Gap 6: Intel GPU operator has no separate values file**
  Both intel releases share `helm/intel-gpu-plugin/values.yaml`.
  Create `helm/intel-device-plugins-operator/values.yaml` for the operator release.

  **Gap 7: 18 existing Helm releases need adoption strategy**
  ArgoCD uses `helm template`, not `helm install` - it does not create Helm releases.
  When ArgoCD takes over a Helm-managed service, two owners exist simultaneously
  until the old Helm release is removed. Each of the 18 Helm releases needs:
  (1) a tracked values file in `helm/<chart>/values.yaml` (most already exist),
  (2) an ArgoCD Application manifest pointing at the chart + values,
  (3) a handover procedure to remove the old `helm install` release.
  Phase 5.8 handles the actual migration. Pre-validate: ensure every Helm release
  has a corresponding values file in the repo.
  ```bash
  # Verify values files exist for all releases
  helm --kubeconfig ~/.kube/homelab.yaml list -A -o json | jq -r '.[].name' | while read rel; do
    if [ ! -d "helm/$rel" ]; then echo "MISSING: helm/$rel/"; fi
  done
  ```

---

## 5.6.1 CIS Benchmark Final Scan

Run kube-bench as final verification. Compare against Phase 5.1 baseline (20 FAIL -> 13 FAIL).

> **Known intentional FAILs from Phase 5.1:**
> - CIS 1.3.7/1.4.2: `--bind-address=0.0.0.0` on controller-manager/scheduler (required for Prometheus scraping)
> - CIS 1.2.1: `--anonymous-auth=false` exception (breaks API server liveness probes in k8s 1.35)

- [ ] 5.6.1.1 Run kube-bench on all 3 CP nodes

  > **Why not a single Job?** A Job with `nodeSelector: control-plane` schedules on ONE node.
  > To scan all 3 CP nodes, use separate Jobs with `nodeName` affinity per node.
  > All 3 nodes are control-plane (no dedicated workers), so `--targets master,node,policies`
  > covers both roles on every node.

  ```bash
  # Run on each node individually
  for NODE in k8s-cp1 k8s-cp2 k8s-cp3; do
    cat <<EOF | kubectl-admin apply -f -
  apiVersion: batch/v1
  kind: Job
  metadata:
    name: kube-bench-final-${NODE}
    namespace: kube-system
  spec:
    backoffLimit: 0
    activeDeadlineSeconds: 300
    template:
      spec:
        hostPID: true
        nodeName: ${NODE}
        tolerations:
          - key: node-role.kubernetes.io/control-plane
            effect: NoSchedule
        automountServiceAccountToken: false
        containers:
          - name: kube-bench
            image: aquasec/kube-bench:v0.10.6
            command: ["kube-bench", "run", "--targets", "master,node,policies"]
            resources:
              requests: { cpu: 100m, memory: 128Mi }
              limits: { cpu: 500m, memory: 256Mi }
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
  EOF
  done
  ```

  > **Image note:** The correct Docker Hub org is `aquasec` (not `aquasecurity`).
  > Phase 5.1 used `aquasec/kube-bench:v0.10.6`. Verify the tag still exists before running:
  > `docker manifest inspect aquasec/kube-bench:v0.10.6`

- [ ] 5.6.1.2 Collect and compare results from all 3 nodes
  ```bash
  for NODE in k8s-cp1 k8s-cp2 k8s-cp3; do
    echo "=== $NODE ==="
    kubectl-homelab logs job/kube-bench-final-${NODE} -n kube-system | tail -20
  done
  ```

- [ ] 5.6.1.3 Document final CIS score and delta from Phase 5.1 baseline
  ```
  Expected format:
  | Node | PASS | FAIL | WARN | INFO | Delta from 5.1 |
  |------|------|------|------|------|----------------|
  | cp1  |  XX  |  XX  |  XX  |  XX  | +X/-X          |
  | cp2  |  XX  |  XX  |  XX  |  XX  | +X/-X          |
  | cp3  |  XX  |  XX  |  XX  |  XX  | +X/-X          |
  ```

- [ ] 5.6.1.4 Review remaining FAIL items - document justification for each
  ```
  Known acceptable FAILs:
  - CIS 1.3.7/1.4.2: --bind-address=0.0.0.0 (Prometheus scraping requirement)
  - CIS 1.2.1: anonymous-auth probe exception (k8s 1.35 liveness probe requirement)
  - Items requiring separate etcd cluster (architectural - 3-node HA uses stacked etcd)
  - Items conflicting with Cilium replacing kube-proxy
  Any NEW FAILs vs Phase 5.1 must be investigated and either fixed or justified.
  ```

- [ ] 5.6.1.5 Clean up scan Jobs
  ```bash
  for NODE in k8s-cp1 k8s-cp2 k8s-cp3; do
    kubectl-admin delete job kube-bench-final-${NODE} -n kube-system
  done
  ```

---

## 5.6.2 Deploy kube-bench as Recurring CronJob

Continuous CIS compliance - detect regressions after future changes.

- [ ] 5.6.2.1 Create kube-bench CronJob

  > **Gotchas fixed from original plan:**
  > - `readOnlyRootFilesystem` removed - kube-bench writes temp files during scan
  > - FAIL threshold set dynamically based on 5.6.1 results (not hardcoded to 5)
  > - grep uses POSIX-compatible patterns (kube-bench image may lack GNU grep `-P`)
  > - curl available in kube-bench image (Alpine-based)
  > - nodeSelector schedules on a single CP node per run (acceptable for weekly regression check)

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
                image: aquasec/kube-bench:v0.10.6
                command: ["/bin/sh", "-c"]
                args:
                  - |
                    RESULT=$(kube-bench run --targets master,node,policies 2>&1)
                    echo "$RESULT"
                    # Extract FAIL count using POSIX grep (no -P flag)
                    FAILS=$(echo "$RESULT" | grep -c '\[FAIL\]' || true)
                    # THRESHOLD: set to final scan FAIL count + 3 buffer
                    # Update this after 5.6.1 completes (current baseline: 13 FAILs)
                    THRESHOLD=16
                    echo "FAIL count: $FAILS (threshold: $THRESHOLD)"
                    if [ "$FAILS" -gt "$THRESHOLD" ]; then
                      echo "WARNING: $FAILS CIS checks failing - regression detected"
                      if [ -n "$DISCORD_WEBHOOK_URL" ]; then
                        curl -s -H "Content-Type: application/json" \
                          -d "{\"content\":\"kube-bench: $FAILS CIS checks failing (threshold: $THRESHOLD). Run kube-bench manually to investigate.\"}" \
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

- [ ] 5.6.2.2 Update THRESHOLD value based on actual 5.6.1 final scan results

- [ ] 5.6.2.3 Create Discord webhook secret (or reuse existing infra webhook via ESO)
  ```bash
  # Option A: dedicated secret (if kube-bench-discord doesn't exist)
  # Create ExternalSecret referencing op://Kubernetes/Discord Webhooks/infra
  # Option B: reuse cluster-janitor's pattern (same Discord #infra channel)
  ```

- [ ] 5.6.2.4 Run CronJob manually to verify
  ```bash
  kubectl-admin create job kube-bench-test --from=cronjob/kube-bench-weekly -n kube-system
  kubectl-homelab logs -f job/kube-bench-test -n kube-system
  kubectl-admin delete job kube-bench-test -n kube-system
  ```

---

## 5.6.3 Image Registry Restriction (ValidatingAdmissionPolicy)

> **Why ValidatingAdmissionPolicy (VAP) instead of Kyverno?**
> VAP is built into Kubernetes since v1.30 (GA). No external dependencies, no CRD operators,
> no extra attack surface. CKA-relevant skill. Shows understanding of the native admission chain.
>
> **Why before GitOps?** ArgoCD deploys whatever manifests are in Git. If someone pushes a
> manifest referencing an untrusted registry, it deploys without question. This policy prevents
> that at the admission level.
>
> **ArgoCD interaction:** VAP will also validate ArgoCD's own syncs. This is desirable -
> ArgoCD will report clear sync failures when a VAP rejects a resource. ArgoCD's images
> (`quay.io/argoproj/`, `ghcr.io/dexidp/`) are already in the trusted list below.

- [ ] 5.6.3.1 Audit all running images to build trusted registry list
  ```bash
  # Get every unique image prefix currently running
  kubectl-homelab get pods -A -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{range .spec.initContainers[*]}{.image}{"\n"}{end}{end}' | sort -u
  # Group by registry/org prefix to build the allowlist
  ```

  > **Live audit results (as of 2026-03-21) - registries the VAP MUST allow:**
  >
  > Explicit registry prefixes (contain a dot or slash):
  > - `docker.io/` - Docker Hub (explicit prefix form)
  > - `ghcr.io/` - GitHub Container Registry
  > - `registry.k8s.io/` - Kubernetes official
  > - `quay.io/` - Red Hat Quay (ArgoCD lives here)
  > - `registry.k8s.rommelporras.com/` - self-hosted GitLab container registry
  > - `registry.gitlab.com/` - GitLab upstream (GitLab CE components)
  > - `lscr.io/` - LinuxServer.io (Bazarr, Prowlarr, Radarr, Sonarr)
  > - `gcr.io/` - Google Container Registry (alpine-chrome)
  >
  > Docker Hub short names (no dot, have slash - resolve to `docker.io/<org>/`):
  > - `adguard/`, `alpine/`, `aquasec/`, `cloudflare/`, `curlimages/`
  > - `dxflrs/`, `esanchezm/`, `germannewsmaker/`, `getmeili/`
  > - `ghost/`, `grafana/`, `hashicorp/`, `homeylab/`, `intel/`
  > - `jellyfin/`, `longhornio/`, `louislam/`, `ollama/`, `otel/`
  > - `prom/`, `tailscale/`, `tannermiddleton/`, `velero/`
  >
  > Bare images (no slash - resolve to `docker.io/library/`):
  > - `alpine`, `busybox`, `ghost`, `mysql`, `python`, `redis`
  > - Caught by `!c.image.contains('/')` rule
  >
  > **CEL gotcha:** Docker Hub images may appear in pod specs as either
  > `grafana/grafana:11.6.0` (short) or `docker.io/grafana/grafana:11.6.0` (normalized).
  > The CEL expression must handle BOTH forms. The approach below allows any Docker Hub
  > short name by checking: if it has no dot before the first slash, it's a Docker Hub
  > short name and is allowed. This is simpler and more maintainable than listing every org.

- [ ] 5.6.3.2 Create ValidatingAdmissionPolicy for trusted registries
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
        - apiGroups: ["batch"]
          apiVersions: ["v1"]
          operations: ["CREATE", "UPDATE"]
          resources: ["jobs", "cronjobs"]
    validations:
      # Helper: a function-like CEL expression that checks if an image is from
      # a trusted registry. An image is trusted if:
      # 1. It starts with a known registry FQDN (contains dot before first slash)
      # 2. It's a Docker Hub short name (org/image - no dot before first slash)
      # 3. It's a bare library image (no slash at all - docker.io/library/*)
      - expression: >-
          object.spec.?containers.orValue([]).all(c,
            c.image.startsWith('docker.io/') ||
            c.image.startsWith('ghcr.io/') ||
            c.image.startsWith('registry.k8s.io/') ||
            c.image.startsWith('quay.io/') ||
            c.image.startsWith('registry.k8s.rommelporras.com/') ||
            c.image.startsWith('registry.gitlab.com/') ||
            c.image.startsWith('lscr.io/') ||
            c.image.startsWith('gcr.io/') ||
            c.image.startsWith('public.ecr.aws/') ||
            !c.image.contains('/') ||
            !c.image.split('/')[0].contains('.')
          )
        message: >-
          Container image must be from a trusted registry. Allowed: docker.io, ghcr.io,
          registry.k8s.io, quay.io, lscr.io, gcr.io, public.ecr.aws, registry.k8s.rommelporras.com,
          registry.gitlab.com, or any Docker Hub org (short name without dot).
      - expression: >-
          object.spec.?initContainers.orValue([]).all(c,
            c.image.startsWith('docker.io/') ||
            c.image.startsWith('ghcr.io/') ||
            c.image.startsWith('registry.k8s.io/') ||
            c.image.startsWith('quay.io/') ||
            c.image.startsWith('registry.k8s.rommelporras.com/') ||
            c.image.startsWith('registry.gitlab.com/') ||
            c.image.startsWith('lscr.io/') ||
            c.image.startsWith('gcr.io/') ||
            c.image.startsWith('public.ecr.aws/') ||
            !c.image.contains('/') ||
            !c.image.split('/')[0].contains('.')
          )
        message: "Init container image must be from a trusted registry"
      - expression: >-
          object.spec.?ephemeralContainers.orValue([]).all(c,
            c.image.startsWith('docker.io/') ||
            c.image.startsWith('ghcr.io/') ||
            c.image.startsWith('registry.k8s.io/') ||
            c.image.startsWith('quay.io/') ||
            c.image.startsWith('registry.k8s.rommelporras.com/') ||
            c.image.startsWith('registry.gitlab.com/') ||
            c.image.startsWith('lscr.io/') ||
            c.image.startsWith('gcr.io/') ||
            c.image.startsWith('public.ecr.aws/') ||
            !c.image.contains('/') ||
            !c.image.split('/')[0].contains('.')
          )
        message: "Ephemeral container image must be from a trusted registry"
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
            values: ["kube-system", "kube-node-lease", "kube-public"]
  ```

  > **Design decisions:**
  > - `!c.image.split('/')[0].contains('.')` allows ALL Docker Hub short names (e.g.,
  >   `grafana/grafana`, `velero/velero`). This avoids maintaining a list of 25+ Docker Hub
  >   orgs that changes whenever we add a new service. The tradeoff: any Docker Hub org is
  >   trusted, but Docker Hub itself is a major registry with abuse reporting.
  > - `public.ecr.aws/` included for ArgoCD Redis (Helm chart default image is
  >   `ecr-public.aws.com/docker/library/redis` - the `ecr-public.aws.com` prefix maps to
  >   `public.ecr.aws/` in some contexts, ensure both are covered).
  > - `ephemeralContainers` added (missing from original plan - debug containers bypass
  >   if not validated).
  > - `batch/v1` Jobs/CronJobs added to matchConstraints (original only matched pods and apps).
  > - **CEL path behavior:** `object.spec.?containers.orValue([])` validates the `spec.containers`
  >   path which exists on Pods but NOT on Deployments/StatefulSets (where it's
  >   `spec.template.spec.containers`). For non-Pod resources, the expression returns empty
  >   array and `all()` is vacuously true. **Pod-level admission is the real enforcement gate** -
  >   when a controller creates a Pod from a workload, the Pod admission catches bad images.
  >   The workload-level matching is included so that `kubectl --dry-run=server` on Deployments
  >   still works for testing. This is an intentional simplification over adding type-specific
  >   CEL paths for every workload kind.
  > - `kube-system` exempted because it runs kube-bench, etcd-backup, and other privileged
  >   system Jobs with diverse images. Control plane images are managed by kubeadm, not GitOps.

- [ ] 5.6.3.3 Apply VAP in Warn mode
  ```bash
  kubectl-admin apply -f manifests/kube-system/image-registry-policy.yaml
  ```

- [ ] 5.6.3.4 Verify warnings for untrusted registry
  ```bash
  # Should generate a warning (not block)
  kubectl-admin run test-untrusted --image=evil-registry.example.com/backdoor:latest \
    --dry-run=server -n default
  # Expected: Warning: Container image must be from a trusted registry...

  # Should NOT generate a warning (Docker Hub short name)
  kubectl-admin run test-trusted --image=grafana/grafana:11.6.0 \
    --dry-run=server -n default
  # Expected: no warning
  ```

- [ ] 5.6.3.5 Audit all existing images against the policy
  ```bash
  # Re-run the full image audit and cross-reference against VAP rules
  # Any image that would be blocked needs investigation
  kubectl-homelab get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}: {range .spec.containers[*]}{.image}{", "}{end}{"\n"}{end}' | sort
  ```

- [ ] 5.6.3.6 After 1 week of clean Warn-mode operation, switch to Deny
  ```bash
  kubectl-admin patch validatingadmissionpolicybinding restrict-image-registries-binding \
    --type=merge -p '{"spec":{"validationActions":["Deny"]}}'
  ```

---

## 5.6.4 Full Cluster Security Audit

Final comprehensive audit before GitOps adoption.

- [ ] 5.6.4.1 Verify all Phase 5.0-5.4 controls are in place
  ```bash
  echo "=== Phase 5.0: Namespace & Pod Security ==="
  # All namespaces have PSS labels
  kubectl-homelab get ns -o json | jq -r '.items[] | .metadata.name + ": enforce=" + (.metadata.labels["pod-security.kubernetes.io/enforce"] // "NONE")'
  # Expected: all namespaces have labels EXCEPT cilium-secrets, default, kube-node-lease, kube-public (empty/system, accepted)

  # automountServiceAccountToken disabled on app pods
  kubectl-homelab get pods -A -o json | jq -r '
    .items[] |
    select(.spec.automountServiceAccountToken != false) |
    select(.metadata.namespace | test("^(kube-|longhorn|cilium|monitoring|external-secrets|cert-manager|vault)") | not) |
    .metadata.namespace + "/" + .metadata.name + " - automount: " + (.spec.automountServiceAccountToken | tostring)
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
  kubectl-homelab get secret encryption-test -n default 2>/dev/null && echo "exists" || echo "Create test secret to verify"

  # Cluster-admin bindings (expect exactly 4: system:masters, kubeadm, longhorn-support-bundle, velero-server)
  kubectl-homelab get clusterrolebindings -o json | jq -r '.items[] | select(.roleRef.name == "cluster-admin") | .metadata.name + " -> " + (.subjects[0].kind + "/" + .subjects[0].name)'

  echo "=== Phase 5.3: Network Policies ==="
  # CiliumNetworkPolicies per namespace (NOT vanilla NetworkPolicy - cluster uses Cilium)
  for ns in $(kubectl-homelab get ns -o jsonpath='{.items[*].metadata.name}'); do
    CNP=$(kubectl-homelab get ciliumnetworkpolicy -n "$ns" --no-headers 2>/dev/null | wc -l)
    echo "$ns: $CNP CiliumNPs"
  done
  # Known gaps: longhorn-system (0), intel-device-plugins (0), node-feature-discovery (0)
  # These are privileged system namespaces - document as accepted risk

  echo "=== Phase 5.4: Resilience ==="
  # Backup CronJobs running
  kubectl-homelab get cronjobs -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,SCHEDULE:.spec.schedule,LAST:.status.lastSuccessfulTime

  # ResourceQuotas in place (14 namespaces have them)
  kubectl-homelab get resourcequota -A

  # PDBs in place
  kubectl-homelab get pdb -A
  ```

- [ ] 5.6.4.2 Verify ESO health (all ExternalSecrets synced)
  ```bash
  # All ExternalSecrets must be SecretSynced=True before GitOps handoff
  kubectl-homelab get externalsecrets -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,STATUS:.status.conditions[0].reason
  # Any non-SecretSynced entries must be fixed before Phase 5.7
  ```

- [ ] 5.6.4.3 Verify Vault is healthy and unsealed
  ```bash
  kubectl-homelab get pods -n vault
  # vault-0 should be 1/1 Running, vault-unsealer should be 1/1 Running
  ```

- [ ] 5.6.4.4 Check for `:latest` tags (supply chain risk)
  ```bash
  kubectl-homelab get pods -A -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' | grep ':latest' | sort -u
  # Known: registry.k8s.rommelporras.com/0xwsh/portfolio:latest
  # Decision: pin to SHA digest or specific tag before GitOps handoff
  ```

- [ ] 5.6.4.5 Generate security posture summary document
  ```
  | Control            | Status     | Coverage              | Evidence          | Known Gaps                         |
  |--------------------|------------|-----------------------|-------------------|------------------------------------|
  | PSS                | Enforced   | 28/32 namespaces      | kubectl output    | 4 empty/system ns without labels   |
  | CiliumNP           | Default-deny| 24+ app namespaces   | kubectl output    | longhorn-system, NFD, intel-dp     |
  | RBAC               | Audited    | All SAs reviewed      | Audit doc         | velero-server cluster-admin (accepted) |
  | etcd encryption    | Active     | All secrets           | etcdctl verify    |                                    |
  | Audit logging      | Active     | All API calls         | Loki query        | Audit alerts deferred (needs Ruler)|
  | Backup             | 3-layer    | Longhorn+Velero+etcd  | CronJob status    |                                    |
  | CIS benchmark      | XX/YY pass | All 3 CP nodes        | Job output        | Intentional FAILs documented       |
  | Image restriction  | VAP Warn/Deny | All non-system ns  | Policy status     |                                    |
  | ESO                | Healthy    | 33 ExternalSecrets    | Status check      |                                    |
  | Supply chain       | Partial    | Tag pinning           | Image audit       | portfolio:latest needs fix         |
  ```

---

## 5.6.5 Documentation

- [ ] 5.6.5.1 Update `docs/context/Security.md` with:
  - Final CIS benchmark score (per-node results)
  - Image registry restriction policy (VAP design and trusted list)
  - GitOps security model: trusted registries, Git source (self-hosted GitLab, deploy token
    with read_repository scope), drift detection (manual sync initially), secret handling
    (Vault + ESO, never raw Secrets in Git), network isolation (CiliumNetworkPolicy deny-default)
  - Complete security posture summary table
  - Document `velero-server` cluster-admin as accepted risk with justification

- [ ] 5.6.5.2 Update `docs/reference/CHANGELOG.md`

- [ ] 5.6.5.3 Update `VERSIONS.md` if new components added (kube-bench CronJob)

---

## Verification Checklist

**CIS Benchmark:**
- [ ] kube-bench final scan completed on all 3 CP nodes
- [ ] Per-node results documented and compared to Phase 5.1 baseline
- [ ] CIS score improved or stable from Phase 5.1 (13 FAIL baseline)
- [ ] All remaining FAIL items justified and documented
- [ ] kube-bench weekly CronJob deployed with Discord alerting
- [ ] CronJob FAIL threshold set based on actual final scan results

**Admission Control:**
- [ ] ValidatingAdmissionPolicy for image registries deployed
- [ ] VAP tested in Warn mode - no false positives for any running workload
- [ ] VAP covers containers, initContainers, and ephemeralContainers
- [ ] VAP tested against ArgoCD image registries (quay.io, ghcr.io, docker.io, ecr-public.aws.com)
- [ ] VAP switched to Deny mode after 1-week verification period

**Cluster Security Audit:**
- [ ] Full cluster security audit passed (all Phase 5.0-5.4 controls verified)
- [ ] All 33 ExternalSecrets in SecretSynced state
- [ ] Vault healthy and unsealed
- [ ] `:latest` tags identified and remediation planned
- [ ] Security posture summary document generated with known gaps documented
- [ ] `velero-server` cluster-admin documented in Security.md

---

## Rollback

**VAP blocks legitimate deployments:**
```bash
# Switch back to Warn mode immediately
kubectl-admin patch validatingadmissionpolicybinding restrict-image-registries-binding \
  --type=merge -p '{"spec":{"validationActions":["Warn"]}}'

# Or delete entirely
kubectl-admin delete validatingadmissionpolicybinding restrict-image-registries-binding
kubectl-admin delete validatingadmissionpolicy restrict-image-registries
```

**kube-bench CronJob issues:**
```bash
kubectl-admin delete cronjob kube-bench-weekly -n kube-system
```

---

## Final: Commit and Release

- [ ] `/audit-security` then `/commit`
- [ ] `/audit-docs` then `/commit`
- [ ] `/release v0.36.0 "Pre-GitOps Validation"`
- [ ] `mv docs/todo/phase-5.6-pre-gitops-validation.md docs/todo/completed/`
- [ ] Proceed to Phase 5.7 (ArgoCD Installation & Bootstrap, v0.37.0)
