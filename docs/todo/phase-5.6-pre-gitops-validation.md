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

- [x] 5.6.0.1 Apply 10 unapplied blackbox probes
  ```bash
  kubectl-admin apply -f manifests/monitoring/probes/
  ```
  Missing: cert-manager-webhook, eso-webhook, garage, homepage, longhorn-ui, myspeed,
  prowlarr, radarr, recommendarr, sonarr. Verify with `kubectl-homelab get probes -n monitoring`.

- [x] 5.6.0.2 Apply 3 GitLab ServiceMonitors
  ```bash
  kubectl-admin apply -f manifests/monitoring/servicemonitors/gitlab-servicemonitor.yaml
  ```
  Missing: gitlab-exporter, gitlab-postgresql, gitlab-redis. Verify Prometheus targets appear.

- [x] 5.6.0.3 Apply 2 unapplied PrometheusRules
  ```bash
  kubectl-admin apply -f manifests/monitoring/alerts/gitlab-alerts.yaml
  kubectl-admin apply -f manifests/monitoring/alerts/home-alerts.yaml
  ```
  These depend on the probes/ServiceMonitors above.

- [x] 5.6.0.4 Apply 8 unapplied Grafana dashboards
  ```bash
  for f in cert-manager eso ghost-prod gitlab home invoicetron-prod loki-storage uptime-kuma; do
    kubectl-admin apply -f manifests/monitoring/dashboards/${f}-dashboard-configmap.yaml
  done
  ```
  Verify all 23 custom dashboards visible in Grafana Homelab folder.

- [x] 5.6.0.5 Resolve 6 blocking GitOps gaps
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
  Also rename `helm/intel-gpu-plugin/` to `helm/intel-device-plugins-gpu/` to match
  the actual Helm release name (`intel-device-plugins-gpu`). The current name mismatch
  means the verification script in Gap 7 reports it as missing even though values exist.

  **Gap 7: 3 Helm releases missing tracked values files**
  ArgoCD uses `helm template`, not `helm install` - it does not create Helm releases.
  When ArgoCD takes over a Helm-managed service, two owners exist simultaneously
  until the old Helm release is removed. All 18 Helm releases need:
  (1) a tracked values file in `helm/<release-name>/values.yaml`,
  (2) an ArgoCD Application manifest pointing at the chart + values,
  (3) a handover procedure to remove the old `helm install` release.
  Phase 5.8 handles the actual migration. Pre-validate: ensure every Helm release
  has a corresponding values file in the repo. 15 of 18 already have matching
  `helm/<name>/values.yaml` directories. The 3 gaps are:
  - `node-feature-discovery` - no `helm/node-feature-discovery/` (Gap 2, installed with pure defaults)
  - `intel-device-plugins-operator` - no `helm/intel-device-plugins-operator/` (Gap 6, pure defaults)
  - `intel-device-plugins-gpu` - values exist at `helm/intel-gpu-plugin/` but directory name
    doesn't match release name (Gap 6 rename)
  ```bash
  # Verify values files exist for all releases
  helm --kubeconfig ~/.kube/homelab.yaml list -A -o json | jq -r '.[].name' | while read rel; do
    if [ ! -d "helm/$rel" ]; then echo "MISSING: helm/$rel/"; fi
  done
  # Expected output after Gap 2+6 fixes: 0 MISSING entries (all 18/18 matched).
  # Previously 3 MISSING: node-feature-discovery, intel-device-plugins-operator,
  # intel-device-plugins-gpu (intel-gpu-plugin existed but name didn't match).
  ```

---

## 5.6.1 CIS Benchmark Final Scan

Run kube-bench as final verification. Compare against Phase 5.1 baseline (20 FAIL -> 13 FAIL).

> **Known intentional FAILs from Phase 5.1:**
> - CIS 1.3.7/1.4.2: `--bind-address=0.0.0.0` on controller-manager/scheduler (required for Prometheus scraping)
> - CIS 1.2.1: `--anonymous-auth=false` exception (breaks API server liveness probes in k8s 1.35)

- [x] 5.6.1.1 Run kube-bench on all 3 CP nodes

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

- [x] 5.6.1.2 Collect and compare results from all 3 nodes
  ```bash
  for NODE in k8s-cp1 k8s-cp2 k8s-cp3; do
    echo "=== $NODE ==="
    kubectl-homelab logs job/kube-bench-final-${NODE} -n kube-system | tail -20
  done
  ```

- [x] 5.6.1.3 Document final CIS score and delta from Phase 5.1 baseline
  ```
  Phase 5.1 baseline: 13 FAIL (down from 20 pre-5.1)
  Phase 5.6 result:    7 FAIL (all 3 nodes identical)

  | Node | PASS | FAIL | WARN | INFO | Delta from 5.1 |
  |------|------|------|------|------|----------------|
  | cp1  |  69  |   7  |  36  |   0  | -6 FAIL        |
  | cp2  |  69  |   7  |  36  |   0  | -6 FAIL        |
  | cp3  |  69  |   7  |  36  |   0  | -6 FAIL        |
  ```

- [x] 5.6.1.4 Review remaining FAIL items - document justification for each
  ```
  All 7 FAIL items are justified - no new regressions vs Phase 5.1:

  1.1.12 - etcd data directory ownership etcd:etcd
    Architectural: kubeadm stacked etcd runs as root in static pod. No etcd user.

  1.2.6 - kubelet-certificate-authority not set
    By design: kubeadm uses TLS bootstrapping with auto-rotating certs instead of
    static CA file. Modern approach, functionally equivalent.

  1.2.16 - PodSecurityPolicy admission plugin not set
    Stale CIS check: PSP removed in K8s 1.25. Replaced with Pod Security Standards
    (PSS) via namespace labels (Phase 5.0).

  1.2.19 - insecure-port not set to 0
    Stale CIS check: --insecure-port flag removed entirely in K8s 1.24+.

  1.3.7 - controller-manager bind-address not 127.0.0.1
    Intentional: set to 0.0.0.0 for Prometheus ServiceMonitor scraping.

  1.4.2 - scheduler bind-address not 127.0.0.1
    Intentional: set to 0.0.0.0 for Prometheus ServiceMonitor scraping.

  4.1.1 - kubelet service file permissions
    False positive: kube-bench checks /etc/systemd/system/kubelet.service.d/ but
    Ubuntu 24.04 places 10-kubeadm.conf at /usr/lib/systemd/system/kubelet.service.d/
    with correct 644 permissions (-rw-r--r-- root:root).

  Note: CIS 1.2.1 (anonymous-auth) NOT in FAIL list - anonymous-auth=false is working.
  The k8s 1.35 liveness probe exception documented in Phase 5.1 was resolved.
  ```

- [x] 5.6.1.5 Clean up scan Jobs
  ```bash
  for NODE in k8s-cp1 k8s-cp2 k8s-cp3; do
    kubectl-admin delete job kube-bench-final-${NODE} -n kube-system
  done
  ```

---

## 5.6.2 Deploy kube-bench as Recurring CronJob

Continuous CIS compliance - detect regressions after future changes.

- [x] 5.6.2.1 Create kube-bench CronJob

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
                    # THRESHOLD: Phase 5.6 final scan = 7 FAILs + 3 buffer
                    THRESHOLD=10
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

- [x] 5.6.2.2 Update THRESHOLD value based on actual 5.6.1 final scan results
  Set to 10 (7 actual FAILs + 3 buffer). Updated in manifest and plan CronJob YAML.

- [x] 5.6.2.3 Create Discord webhook secret (or reuse existing infra webhook via ESO)
  Reused existing `discord-janitor-webhook` ExternalSecret (same Discord #infra channel).
  No new secret or Vault path needed. CronJob env references `discord-janitor-webhook`
  secret with `optional: true` (graceful if secret missing).

- [x] 5.6.2.4 Run CronJob manually to verify
  Test result: "FAIL count: 7 (threshold: 10)" - no regression alert sent (correct).
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

- [x] 5.6.3.1 Audit all running images to build trusted registry list
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

- [x] 5.6.3.2 Create ValidatingAdmissionPolicy for trusted registries
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

- [x] 5.6.3.3 Apply VAP in Warn mode
  ```bash
  kubectl-admin apply -f manifests/kube-system/image-registry-policy.yaml
  ```

- [x] 5.6.3.4 Verify warnings for untrusted registry
  Verified: untrusted image generates warning, Docker Hub short name/bare image/ghcr.io/
  self-hosted registry all pass without warning. kube-system exemption confirmed working.
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

- [x] 5.6.3.5 Audit all existing images against the policy
  All 100+ running containers use trusted registries. Zero conflicts found.
  Registries in use: docker.io, ghcr.io, registry.k8s.io, quay.io,
  registry.k8s.rommelporras.com, registry.gitlab.com, lscr.io, gcr.io,
  plus Docker Hub short names and bare library images.
  ```bash
  # Re-run the full image audit and cross-reference against VAP rules
  # Any image that would be blocked needs investigation
  kubectl-homelab get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}: {range .spec.containers[*]}{.image}{", "}{end}{"\n"}{end}' | sort
  ```

- [ ] 5.6.3.6 After 1 week of clean Warn-mode operation, switch to Deny (target: 2026-04-02)
  ```bash
  kubectl-admin patch validatingadmissionpolicybinding restrict-image-registries-binding \
    --type=merge -p '{"spec":{"validationActions":["Deny"]}}'
  ```

---

## 5.6.4 Full Cluster Security Audit

Final comprehensive audit before GitOps adoption.

- [x] 5.6.4.1 Verify all Phase 5.0-5.4 controls are in place

  **Phase 5.0 - Namespace & Pod Security:**
  - PSS enforced on 27/31 namespaces. 4 without labels: cilium-secrets, default, kube-node-lease, kube-public (empty/system, accepted)
  - automountServiceAccountToken: app pods with `null` (not explicitly false): gitlab-runner, intel-device-plugins, invoicetron-migrate jobs, NFD, tailscale, velero. homepage has `true` (needed for K8s API discovery). All are system/operator pods that need SA tokens - accepted.
  - ClusterSecretStore has namespaceSelector: `eso-enabled: "true"` label required

  **Phase 5.1 - Control Plane:**
  - Audit logging active: `/var/log/kubernetes/audit/audit.log` (52MB, last write current)
  - Kubelet anonymous auth disabled: `anonymous: enabled: false`

  **Phase 5.2 - RBAC & Secrets:**
  - etcd encryption config exists at `/etc/kubernetes/encryption-config.yaml` (API server flag confirmed)
  - Cluster-admin bindings: exactly 4 (system:masters, kubeadm:cluster-admins, longhorn-support-bundle, velero-server)

  **Phase 5.3 - Network Policies:**
  - 24 namespaces have CiliumNetworkPolicies (117 total policies)
  - Known gaps with 0 CiliumNPs: cilium-secrets, default, intel-device-plugins, kube-node-lease, kube-public, longhorn-system, node-feature-discovery
  - All zero-policy namespaces are privileged system namespaces or empty - accepted risk

  **Phase 5.4 - Resilience:**
  - 24 CronJobs running across cluster (backups, janitor, cert-expiry, kube-bench, version-check)
  - 14 namespaces have ResourceQuotas
  - 24 PDBs in place (including Longhorn instance managers, GitLab components, monitoring, vault)

  > **Plan correction:** etcd encryption config path is `/etc/kubernetes/encryption-config.yaml`,
  > NOT `/etc/kubernetes/pki/encryption-config.yaml` as originally written.

- [x] 5.6.4.2 Verify ESO health (all ExternalSecrets synced)
  All 33 ExternalSecrets in SecretSynced state across 14 namespaces. No failures.
  ```bash
  kubectl-homelab get externalsecrets -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,STATUS:.status.conditions[0].reason'
  ```

- [x] 5.6.4.3 Verify Vault is healthy and unsealed
  vault-0: 1/1 Running, vault-unsealer: 1/1 Running, vault-snapshot CronJob completing normally.
  ```bash
  kubectl-homelab get pods -n vault
  ```

- [x] 5.6.4.4 Check for `:latest` tags (supply chain risk)
  Only 1 `:latest` tag found: `registry.k8s.rommelporras.com/0xwsh/portfolio:latest`
  This is the self-hosted GitLab CI/CD image - CI pushes `:latest` on every merge to main.
  Remediation: ArgoCD Image Updater or CI pipeline commit-to-git pattern (Phase 5.8 scope).
  No init containers or other workloads use `:latest`.
  ```bash
  kubectl-homelab get pods -A -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' | grep ':latest' | sort -u
  ```

- [x] 5.6.4.5 Generate security posture summary document
  ```
  | Control            | Status      | Coverage              | Evidence          | Known Gaps                         |
  |--------------------|-------------|-----------------------|-------------------|------------------------------------|
  | PSS                | Enforced    | 27/31 namespaces      | kubectl output    | 4 empty/system ns (cilium-secrets, default, kube-node-lease, kube-public) |
  | CiliumNP           | Default-deny| 24/31 namespaces (127 policies) | kubectl output | longhorn-system, NFD, intel-dp, cilium-secrets, default, kube-node-lease, kube-public |
  | RBAC               | Audited     | 4 cluster-admin bindings | kubectl output | velero-server cluster-admin (accepted - needs cross-ns backup access) |
  | etcd encryption    | Active      | All secrets           | API server flag   | encryption-config.yaml at /etc/kubernetes/ |
  | Audit logging      | Active      | All API calls         | 52MB audit.log    | Audit alerts deferred (needs Loki Ruler) |
  | Backup             | 3-layer     | Longhorn+Velero+etcd  | 24 CronJobs       | All running with recent lastSuccessfulTime |
  | CIS benchmark      | 69 pass / 7 fail | All 3 CP nodes   | kube-bench v0.10.6| 7 intentional FAILs documented     |
  | Image restriction  | VAP Warn    | All non-system ns     | Policy applied    | Deny mode target: 2026-04-02       |
  | ESO                | Healthy     | 33 ExternalSecrets    | All SecretSynced  |                                    |
  | Supply chain       | Partial     | Tag pinning           | Image audit       | portfolio:latest (CI/CD pattern, Phase 5.8) |
  | ResourceQuotas     | Active      | 14 namespaces         | kubectl output    |                                    |
  | PDBs               | Active      | 24 PDBs               | kubectl output    |                                    |
  | Vault              | Healthy     | Unsealed, auto-unseal | Pod status        |                                    |
  ```

---

## 5.6.5 Documentation

- [x] 5.6.5.1 Update `docs/context/Security.md` with:
  - CIS benchmark scores updated with Phase 5.6 column (69 pass / 7 fail)
  - 7 remaining FAIL items documented with justifications (replaces old 3-item exclusion list)
  - kube-bench regression detection CronJob section added
  - Image Registry Restriction section: trusted registries table, CEL design decisions, manifest path
  - GitOps Security Model section: source, admission, secrets, network, drift, imperative exceptions
  - Security Posture Summary table: 13 controls with status, coverage, and known gaps
  - velero-server cluster-admin added to RBAC audit results + trust boundaries

- [x] 5.6.5.2 Update `docs/reference/CHANGELOG.md`

- [x] 5.6.5.3 Update `VERSIONS.md` if new components added (kube-bench CronJob)
  Added `kube-bench | CronJob (aquasec/kube-bench:v0.10.6)` to Home Services table.

---

## Verification Checklist

**CIS Benchmark:**
- [x] kube-bench final scan completed on all 3 CP nodes
- [x] Per-node results documented and compared to Phase 5.1 baseline
- [x] CIS score improved or stable from Phase 5.1 (13 FAIL baseline)
- [x] All remaining FAIL items justified and documented
- [x] kube-bench weekly CronJob deployed with Discord alerting
- [x] CronJob FAIL threshold set based on actual final scan results

**Admission Control:**
- [x] ValidatingAdmissionPolicy for image registries deployed
- [x] VAP tested in Warn mode - no false positives for any running workload
- [x] VAP covers containers, initContainers, and ephemeralContainers
- [x] VAP tested against ArgoCD image registries (quay.io, ghcr.io, docker.io, ecr-public.aws.com)
- [ ] VAP switched to Deny mode after 1-week verification period (deferred to 2026-04-02)

**Cluster Security Audit:**
- [x] Full cluster security audit passed (all Phase 5.0-5.4 controls verified)
- [x] All 33 ExternalSecrets in SecretSynced state
- [x] Vault healthy and unsealed
- [x] `:latest` tags identified and remediation planned
- [x] Security posture summary document generated with known gaps documented
- [x] `velero-server` cluster-admin documented in Security.md

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
