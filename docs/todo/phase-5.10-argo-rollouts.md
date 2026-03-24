# Phase 5.10: Argo Rollouts & Progressive Delivery

> **Status:** Planned
> **Target:** v0.40.0
> **Prerequisite:** Phase 5.9 (v0.39.0 - Argo Workflows stable)
> **DevOps Topics:** Progressive delivery, canary deployment, blue-green, automated rollback
> **CKA Topics:** Deployment strategies, traffic management, health checks

> **Purpose:** Install Argo Rollouts and convert selected Deployments to Rollouts with
> progressive delivery strategies and Prometheus-driven automated analysis. Deploy as an
> ArgoCD-managed Application to continue dog-fooding GitOps.
>
> **Learning Goal:** Progressive delivery patterns, canary vs blue-green trade-offs,
> AnalysisTemplates with Prometheus, Rollout CRD lifecycle, and the operational difference
> between automated promotion and manual gating.

---

## 5.10.0 Pre-Installation

> **Gate:** ArgoCD must be stable and all Phase 5.9 workloads confirmed healthy
> before adding another CRD-heavy controller.

- [ ] 5.10.0.1 Verify ArgoCD is stable and all Applications are Synced/Healthy
  ```bash
  kubectl-homelab get applications -n argocd
  # Expected: all SYNCED and Healthy

  kubectl-homelab get pods -n argocd
  # Expected: all Running, no CrashLoopBackOff
  ```

- [ ] 5.10.0.2 Check cluster resource headroom
  ```bash
  kubectl-homelab top nodes
  # Argo Rollouts controller: ~100m CPU, ~128Mi memory (idle)
  # Blue-green adds a preview set at previewReplicaCount during rollout (transient)
  # Verify at least 200m CPU and 256Mi memory available across cluster
  ```

- [ ] 5.10.0.3 Verify argo Helm repo is available
  ```bash
  helm-homelab repo add argo https://argoproj.github.io/argo-helm
  helm-homelab repo update
  helm-homelab search repo argo/argo-rollouts --versions | head -10
  # Record: CHART_VERSION=<version> APP_VERSION=<version>
  ```

- [ ] 5.10.0.4 Verify VAP allows Argo Rollouts images (dry-run)
  ```bash
  kubectl-admin run test-rollouts \
    --image=quay.io/argoproj/argo-rollouts:<version> \
    --dry-run=server -n default
  # Expected: pod created (dry-run), no VAP denial
  ```

- [ ] 5.10.0.5 Install kubectl-argo-rollouts plugin on WSL2
  ```bash
  # Download the plugin binary
  curl -LO https://github.com/argoproj/argo-rollouts/releases/latest/download/kubectl-argo-rollouts-linux-amd64
  chmod +x kubectl-argo-rollouts-linux-amd64
  sudo mv kubectl-argo-rollouts-linux-amd64 /usr/local/bin/kubectl-argo-rollouts

  # Verify
  kubectl-argo-rollouts version
  ```

---

## 5.10.1 Installation

> **Namespace:** `argo-rollouts` (separate from `argocd` - different lifecycle and RBAC).
> **Dashboard:** Enabled but not externally exposed (port-forward for access). Saves
> external certificate/HTTPRoute overhead while keeping the visual rollout status useful.

- [ ] 5.10.1.1 Create namespace and PSS label
  ```bash
  kubectl-admin create namespace argo-rollouts
  kubectl-admin label namespace argo-rollouts \
    pod-security.kubernetes.io/enforce=baseline \
    pod-security.kubernetes.io/warn=restricted
  ```

- [ ] 5.10.1.2 Create LimitRange and ResourceQuota
  ```bash
  # manifests/argo-rollouts/limitrange.yaml
  # manifests/argo-rollouts/resourcequota.yaml
  # controller: 200m CPU request, 500m limit, 256Mi request, 512Mi limit
  # dashboard: 50m CPU request, 200m limit, 64Mi request, 128Mi limit
  ```

- [ ] 5.10.1.3 Create Helm values file
  ```yaml
  # manifests/argo-rollouts/values.yaml
  controller:
    replicas: 1
    image:
      tag: <version>  # pin exact version
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
      limits:
        cpu: 500m
        memory: 512Mi
    securityContext:
      runAsNonRoot: true
      runAsUser: 1000
      allowPrivilegeEscalation: false
      capabilities:
        drop: ["ALL"]
    metrics:
      enabled: true
      serviceMonitor:
        enabled: false  # create manually for namespace selector control

  dashboard:
    enabled: true
    image:
      tag: <version>  # same version as controller
    resources:
      requests:
        cpu: 50m
        memory: 64Mi
      limits:
        cpu: 200m
        memory: 128Mi
    securityContext:
      runAsNonRoot: true
      runAsUser: 1000
      allowPrivilegeEscalation: false
      capabilities:
        drop: ["ALL"]
  ```

- [ ] 5.10.1.4 Create ArgoCD Application manifest
  ```yaml
  # manifests/argocd/apps/argo-rollouts.yaml
  apiVersion: argoproj.io/v1alpha1
  kind: Application
  metadata:
    name: argo-rollouts
    namespace: argocd
  spec:
    project: platform
    source:
      repoURL: https://argoproj.github.io/argo-helm
      chart: argo-rollouts
      targetRevision: <chart-version>
      helm:
        valueFiles:
          - $repo/manifests/argo-rollouts/values.yaml
    destination:
      server: https://kubernetes.default.svc
      namespace: argo-rollouts
    syncPolicy:
      automated:
        prune: true
        selfHeal: true
      syncOptions:
        - CreateNamespace=false
        - ServerSideApply=true
  ```

- [ ] 5.10.1.5 Deploy and verify controller is running
  ```bash
  kubectl-homelab get pods -n argo-rollouts
  # Expected: argo-rollouts (controller) Running 1/1
  #           argo-rollouts-dashboard Running 1/1

  kubectl-homelab get crd | grep rollout
  # Expected: rollouts.argoproj.io, analysisruns.argoproj.io,
  #           analysistemplates.argoproj.io, clusteranalysistemplates.argoproj.io,
  #           experiments.argoproj.io
  ```

- [ ] 5.10.1.6 Apply CiliumNetworkPolicy
  ```yaml
  # manifests/argo-rollouts/ciliumnetworkpolicy.yaml
  # Rules:
  # - controller egress to kube-apiserver:6443 (reconcile Rollout CRDs)
  # - controller egress to prometheus-operated.monitoring.svc:9090 (metric queries for AnalysisRuns)
  # - Prometheus ingress to controller:8090 (metrics scrape)
  # - ArgoCD repo-server egress to controller (health checks)
  # - dashboard ingress from WSL2 CIDR (port-forward access only - no HTTPRoute)
  ```

- [ ] 5.10.1.7 Verify dashboard is accessible via port-forward
  ```bash
  kubectl-homelab port-forward svc/argo-rollouts-dashboard -n argo-rollouts 3100:3100
  # Open http://localhost:3100 - should show empty Rollouts list
  ```

---

## 5.10.2 Service Evaluation

> **Criteria:** Services with 2+ replicas benefit most from progressive delivery.
> Single-replica services incur downtime during blue-green preview phase.
> Infrastructure services (cloudflared, CNI-adjacent) should not be disrupted.

### Full Deployment Evaluation

| Deployment | Replicas | Strategy | Reason | Verdict |
|------------|----------|----------|--------|---------|
| portfolio-prod | 2 | Blue-Green | CI/CD app, preview URL validates before cutover | **Wave 1** |
| ghost-prod | 1 | Blue-Green | Zero-downtime critical, MySQL settle time matters | **Wave 2** |
| homepage | 2 | Canary | Low risk, replica-based 50% split, good learning | **Wave 3** |
| invoicetron-prod | 2 | Blue-Green | CI/CD app, after portfolio proves the pattern | **Future** |
| cloudflared | 2 | SKIP | Infrastructure tunnel - disruption affects all ingress |
| ARR stack (all) | 1 | SKIP | Single-replica, downtime acceptable, no metrics |
| GitLab | varies | SKIP | Helm-managed complex chart, not a simple Deployment |
| Monitoring stack | varies | SKIP | Helm-managed, existing upgrade procedures work |

**Gateway API plugin status:** `argoproj-labs/rollouts-plugin-trafficrouter-gatewayapi`
is alpha as of March 2026. Skip for initial deployment - use replica-based canary first.
See section 5.10.9 for future evaluation criteria.

---

## 5.10.3 AnalysisTemplates

> **Scope:** ClusterAnalysisTemplates (cluster-scoped) so they can be referenced by
> Rollouts in any namespace. Prometheus address is consistent across all Rollouts.

- [ ] 5.10.3.1 Create http-success-rate ClusterAnalysisTemplate
  ```yaml
  # manifests/argo-rollouts/analysis/http-success-rate.yaml
  apiVersion: argoproj.io/v1alpha1
  kind: ClusterAnalysisTemplate
  metadata:
    name: http-success-rate
  spec:
    args:
      - name: service-name
      - name: namespace
    metrics:
      - name: success-rate
        interval: 60s
        successCondition: result[0] >= 0.95
        failureLimit: 3
        provider:
          prometheus:
            address: http://prometheus-operated.monitoring.svc.cluster.local:9090
            query: |
              sum(rate(probe_success{job="blackbox", instance=~".*{{args.service-name}}.*"}[5m]))
              /
              count(probe_success{job="blackbox", instance=~".*{{args.service-name}}.*"})
  ```

- [ ] 5.10.3.2 Create pod-restart-rate ClusterAnalysisTemplate
  ```yaml
  # manifests/argo-rollouts/analysis/pod-restart-rate.yaml
  apiVersion: argoproj.io/v1alpha1
  kind: ClusterAnalysisTemplate
  metadata:
    name: pod-restart-rate
  spec:
    args:
      - name: rollout-name
      - name: namespace
    metrics:
      - name: restart-rate
        interval: 60s
        successCondition: result[0] < 1
        failureLimit: 2
        provider:
          prometheus:
            address: http://prometheus-operated.monitoring.svc.cluster.local:9090
            query: |
              sum(increase(kube_pod_container_status_restarts_total{
                namespace="{{args.namespace}}",
                pod=~"{{args.rollout-name}}.*"
              }[5m]))
  ```

- [ ] 5.10.3.3 Apply ClusterAnalysisTemplates and verify
  ```bash
  kubectl-admin apply -f manifests/argo-rollouts/analysis/
  kubectl-homelab get clusteranalysistemplates
  # Expected: http-success-rate, pod-restart-rate
  ```

---

## 5.10.4 Wave 1 - portfolio-prod (Blue-Green)

> **Why portfolio first:** CI/CD-managed app, 2 replicas, blackbox probe already
> exists, and it's lower stakes than the blog. Proves the blue-green pattern before
> applying to ghost.

- [ ] 5.10.4.1 Verify blackbox probe exists for portfolio-prod
  ```bash
  kubectl-homelab get probe -n monitoring | grep portfolio
  # Expected: portfolio-prod probe present
  # If missing, create it in manifests/monitoring/probes/ first
  ```

- [ ] 5.10.4.2 Create preview Service for portfolio-prod
  ```yaml
  # manifests/portfolio/service-preview.yaml
  apiVersion: v1
  kind: Service
  metadata:
    name: portfolio-preview
    namespace: portfolio
  spec:
    selector:
      app: portfolio
    ports:
      - port: 80
        targetPort: 3000
  # This service is updated by Rollouts to point at the preview (new) ReplicaSet.
  # The existing portfolio service continues pointing at active (old) ReplicaSet.
  ```

- [ ] 5.10.4.3 Convert Deployment to Rollout
  ```yaml
  # manifests/portfolio/rollout.yaml (replaces deployment.yaml)
  apiVersion: argoproj.io/v1alpha1
  kind: Rollout
  metadata:
    name: portfolio
    namespace: portfolio
  spec:
    replicas: 2
    selector:
      matchLabels:
        app: portfolio
    template:
      # ... same pod spec as existing Deployment ...
    strategy:
      blueGreen:
        activeService: portfolio          # existing Service
        previewService: portfolio-preview # new preview Service
        previewReplicaCount: 1            # save resources during preview
        autoPromotionEnabled: false       # manual gate for first rollout
        scaleDownDelaySeconds: 30         # keep old ReplicaSet briefly after promotion
        prePromotionAnalysis:
          templates:
            - templateName: http-success-rate
              clusterScope: true
          args:
            - name: service-name
              value: portfolio
            - name: namespace
              value: portfolio
  ```

- [ ] 5.10.4.4 Delete old Deployment and apply Rollout
  ```bash
  # Delete Deployment (Rollout creates its own ReplicaSets)
  kubectl-admin delete deployment portfolio -n portfolio

  # Apply Rollout and preview Service
  kubectl-admin apply -f manifests/portfolio/rollout.yaml
  kubectl-admin apply -f manifests/portfolio/service-preview.yaml
  ```

- [ ] 5.10.4.5 Verify initial Rollout is Healthy
  ```bash
  kubectl-argo-rollouts get rollout portfolio -n portfolio
  # Expected: Status: Healthy, 2 active replicas, no preview replicas

  kubectl-homelab get rollout portfolio -n portfolio
  # Expected: DESIRED=2, READY=2, STATUS=Healthy
  ```

- [ ] 5.10.4.6 Test blue-green promotion flow
  ```bash
  # Trigger a rollout by updating the image (use a new tag)
  kubectl-admin set image rollout/portfolio portfolio=<new-image> -n portfolio

  # Watch rollout progress
  kubectl-argo-rollouts get rollout portfolio -n portfolio --watch

  # Expected sequence:
  # 1. Preview ReplicaSet created (1 pod)
  # 2. prePromotionAnalysis starts (http-success-rate against preview Service)
  # 3. Status: Paused (waiting for manual promotion after analysis)

  # Check preview is accessible via port-forward
  kubectl-homelab port-forward svc/portfolio-preview -n portfolio 8080:80
  # curl http://localhost:8080 - should return new version

  # Manually promote after validation
  kubectl-argo-rollouts promote portfolio -n portfolio

  # Expected: active Service switches to new ReplicaSet, old scales down after delay
  ```

- [ ] 5.10.4.7 Verify ArgoCD shows correct state
  ```bash
  kubectl-homelab get application portfolio -n argocd
  # Note: after manual promotion ArgoCD may show OutOfSync if image was set imperatively
  # This is expected - sync forward in Git by updating the image tag in rollout.yaml
  ```

---

## 5.10.5 Wave 2 - ghost-prod (Blue-Green)

> **Why ghost:** Zero-downtime matters for the blog. MySQL is shared so postPromotion
> analysis verifies the blog is serving correctly after the active switch - MySQL settle
> time is the key concern.

- [ ] 5.10.5.1 Verify blackbox probe exists for ghost-prod
  ```bash
  kubectl-homelab get probe -n monitoring | grep ghost
  # Expected: ghost-prod probe present
  ```

- [ ] 5.10.5.2 Create preview Service for ghost-prod
  ```yaml
  # manifests/ghost/service-preview.yaml
  apiVersion: v1
  kind: Service
  metadata:
    name: ghost-preview
    namespace: ghost
  spec:
    selector:
      app: ghost
    ports:
      - port: 2368
        targetPort: 2368
  ```

- [ ] 5.10.5.3 Convert Deployment to Rollout
  ```yaml
  # manifests/ghost/rollout.yaml (replaces deployment.yaml)
  apiVersion: argoproj.io/v1alpha1
  kind: Rollout
  metadata:
    name: ghost
    namespace: ghost
  spec:
    replicas: 1
    selector:
      matchLabels:
        app: ghost
    template:
      # ... same pod spec as existing Deployment ...
    strategy:
      blueGreen:
        activeService: ghost
        previewService: ghost-preview
        previewReplicaCount: 1
        autoPromotionEnabled: false
        scaleDownDelaySeconds: 60   # MySQL needs more settle time than portfolio
        postPromotionAnalysis:      # verify after switch (MySQL connection check)
          templates:
            - templateName: http-success-rate
              clusterScope: true
            - templateName: pod-restart-rate
              clusterScope: true
          args:
            - name: service-name
              value: ghost
            - name: namespace
              value: ghost
            - name: rollout-name
              value: ghost
  ```

- [ ] 5.10.5.4 Apply Rollout and preview Service
  ```bash
  kubectl-admin delete deployment ghost -n ghost
  kubectl-admin apply -f manifests/ghost/rollout.yaml
  kubectl-admin apply -f manifests/ghost/service-preview.yaml
  ```

- [ ] 5.10.5.5 Verify Rollout is Healthy and run a test promotion
  ```bash
  kubectl-argo-rollouts get rollout ghost -n ghost
  # Expected: Status: Healthy

  # Trigger with a minor config change to test the full flow
  # Promote manually, confirm postPromotionAnalysis passes
  kubectl-argo-rollouts promote ghost -n ghost
  ```

---

## 5.10.6 Wave 3 - homepage (Canary)

> **Why homepage:** 2 replicas means canary gets 50% traffic (1 of 2 pods) without
> any traffic router. Simple replica-based split is the right starting point before
> introducing the Gateway API plugin. Low stakes if the canary degrades.

> **NOTE on Gateway API plugin:** Skipped for now - plugin is alpha. With only 2
> replicas, precise weight control (e.g. 10%) would require the plugin. The replica-based
> approach at 50% is acceptable for homepage. See 5.10.9 for future work.

- [ ] 5.10.6.1 Convert Deployment to Rollout
  ```yaml
  # manifests/home/homepage/rollout.yaml (replaces deployment.yaml)
  apiVersion: argoproj.io/v1alpha1
  kind: Rollout
  metadata:
    name: homepage
    namespace: homepage
  spec:
    replicas: 2
    selector:
      matchLabels:
        app: homepage
    template:
      # ... same pod spec as existing Deployment ...
    strategy:
      canary:
        steps:
          - setWeight: 50          # 1 of 2 pods gets new version
          - pause:
              duration: 5m         # observe for 5 minutes
          - analysis:
              templates:
                - templateName: http-success-rate
                  clusterScope: true
              args:
                - name: service-name
                  value: homepage
                - name: namespace
                  value: homepage
          - setWeight: 100         # promote all replicas
  ```

- [ ] 5.10.6.2 Apply Rollout
  ```bash
  kubectl-admin delete deployment homepage -n homepage

  # homepage uses kustomize - update kustomization.yaml to reference rollout.yaml
  # instead of deployment.yaml, then apply
  kubectl-admin apply -k manifests/home/homepage/
  ```

- [ ] 5.10.6.3 Verify Rollout is Healthy
  ```bash
  kubectl-argo-rollouts get rollout homepage -n homepage
  # Expected: Status: Healthy, 2 replicas
  ```

- [ ] 5.10.6.4 Test canary flow
  ```bash
  # Trigger by updating image
  kubectl-admin set image rollout/homepage homepage=<new-image> -n homepage

  kubectl-argo-rollouts get rollout homepage -n homepage --watch
  # Expected sequence:
  # 1. setWeight 50 - 1 pod updated, 1 pod old
  # 2. pause 5m
  # 3. analysis runs http-success-rate
  # 4. setWeight 100 - all pods updated on success
  # OR: automatic rollback if analysis fails (abort)
  ```

---

## 5.10.7 Monitoring

### 5.10.7.1 ServiceMonitor

- [ ] 5.10.7.1a Create ServiceMonitor for Argo Rollouts controller
  ```yaml
  # manifests/monitoring/servicemonitors/argo-rollouts-servicemonitor.yaml
  apiVersion: monitoring.coreos.com/v1
  kind: ServiceMonitor
  metadata:
    name: argo-rollouts-controller
    namespace: monitoring
    labels:
      release: prometheus
  spec:
    namespaceSelector:
      matchNames:
        - argo-rollouts
    selector:
      matchLabels:
        app.kubernetes.io/name: argo-rollouts
    endpoints:
      - port: metrics
        interval: 30s
  ```

### 5.10.7.2 PrometheusRules

- [ ] 5.10.7.2a Create alert rules
  ```yaml
  # manifests/monitoring/alerts/argo-rollouts-alerts.yaml
  apiVersion: monitoring.coreos.com/v1
  kind: PrometheusRule
  metadata:
    name: argo-rollouts-alerts
    namespace: monitoring
    labels:
      release: prometheus
  spec:
    groups:
      - name: argo-rollouts
        rules:
          - alert: RolloutAborted
            expr: |
              sum by (name, namespace) (rollout_info{phase="Aborted"}) > 0
            for: 1m
            labels:
              severity: warning
              category: infra
            annotations:
              summary: "Rollout {{ $labels.name }} aborted"
              description: "Rollout {{ $labels.name }} in {{ $labels.namespace }} has been aborted. Manual intervention required to fix forward in Git."

          - alert: RolloutDegraded
            expr: |
              sum by (name, namespace) (rollout_info{phase="Degraded"}) > 0
            for: 5m
            labels:
              severity: critical
              category: infra
            annotations:
              summary: "Rollout {{ $labels.name }} is degraded"
              description: "Rollout {{ $labels.name }} in {{ $labels.namespace }} is degraded for 5 minutes. Check pod events and logs."

          - alert: AnalysisRunFailed
            expr: |
              sum by (name, namespace) (analysis_run_info{phase="Failed"}) > 0
            for: 1m
            labels:
              severity: warning
              category: infra
            annotations:
              summary: "AnalysisRun {{ $labels.name }} failed"
              description: "AnalysisRun {{ $labels.name }} in {{ $labels.namespace }} failed. Rollout may be blocked or rolling back."

          - alert: ArgoRolloutsControllerDown
            expr: |
              absent(up{job=~".*argo-rollouts.*"} == 1)
            for: 5m
            labels:
              severity: critical
              category: infra
            annotations:
              summary: "Argo Rollouts controller is down"
              description: "Rollouts controller unreachable for 5 minutes. All in-progress rollouts are stalled."
  ```

### 5.10.7.3 Grafana Dashboard

- [ ] 5.10.7.3a Create Grafana dashboard ConfigMap
  ```yaml
  # manifests/monitoring/dashboards/argo-rollouts-dashboard.json (mounted via ConfigMap)
  # Rows:
  # 1. Pod Status - controller pod status, replica counts per Rollout
  # 2. Rollout Phases - active/preview/canary ReplicaSet counts, phase breakdown
  # 3. Analysis Results - AnalysisRun success/failure rates per template
  # 4. Resource Usage - controller CPU/memory with dashed request/limit lines
  #
  # ConfigMap labels: grafana_dashboard: "1"
  # ConfigMap annotations: grafana_folder: "Homelab"
  # Description on every panel and row
  ```

---

## 5.10.8 Notifications

> **Argo Rollouts notifications are separate from ArgoCD notifications** - different
> ConfigMap/Secret even though they use the same notification engine under the hood.
> Reuses the existing ArgoCD Discord webhook from Vault.

- [ ] 5.10.8.1 Create ESO ExternalSecret for notification webhook
  ```yaml
  # manifests/argo-rollouts/externalsecret-notifications.yaml
  apiVersion: external-secrets.io/v1beta1
  kind: ExternalSecret
  metadata:
    name: argo-rollouts-notifications-secret
    namespace: argo-rollouts
  spec:
    refreshInterval: 1h
    secretStoreRef:
      name: vault-backend
      kind: ClusterSecretStore
    target:
      name: argo-rollouts-notification-secret
    data:
      - secretKey: discord-gitops-webhook
        remoteRef:
          key: argocd
          property: discord-webhook-url
  ```

- [ ] 5.10.8.2 Create notifications ConfigMap
  ```yaml
  # manifests/argo-rollouts/notifications-cm.yaml
  apiVersion: v1
  kind: ConfigMap
  metadata:
    name: argo-rollouts-notification-configmap
    namespace: argo-rollouts
  data:
    service.webhook.discord-gitops: |
      url: $discord-gitops-webhook
      headers:
        - name: Content-Type
          value: application/json
    template.rollout-completed: |
      webhook:
        discord-gitops:
          method: POST
          body: |
            {
              "content": "Rollout **{{.rollout.metadata.name}}** completed successfully in `{{.rollout.metadata.namespace}}`."
            }
    template.rollout-aborted: |
      webhook:
        discord-gitops:
          method: POST
          body: |
            {
              "content": ":warning: Rollout **{{.rollout.metadata.name}}** aborted in `{{.rollout.metadata.namespace}}`. Fix forward in Git."
            }
    template.analysis-run-failed: |
      webhook:
        discord-gitops:
          method: POST
          body: |
            {
              "content": ":x: AnalysisRun **{{.analysisRun.metadata.name}}** failed in `{{.analysisRun.metadata.namespace}}`. Rollout may be rolling back."
            }
    trigger.on-rollout-completed: |
      - send: [rollout-completed]
        when: rollout.status.phase == 'Healthy' && rollout.status.currentPodHash == rollout.status.stableRS
    trigger.on-rollout-aborted: |
      - send: [rollout-aborted]
        when: rollout.status.phase == 'Aborted'
    trigger.on-analysis-run-failed: |
      - send: [analysis-run-failed]
        when: analysisRun.status.phase == 'Failed'
    defaultTriggers: |
      - on-rollout-completed
      - on-rollout-aborted
      - on-analysis-run-failed
  ```

- [ ] 5.10.8.3 Verify notification arrives in Discord on next rollout
  ```bash
  # Trigger a no-op rollout on homepage to test
  kubectl-admin annotate rollout homepage \
    rollout.argoproj.io/restart-at="$(date +%Y-%m-%dT%H:%M:%SZ)" \
    -n homepage
  # Expected: Discord #gitops message when rollout completes
  ```

---

## 5.10.9 Future: Gateway API Plugin

> **Not implemented in this phase.** Document here for evaluation when the plugin
> matures.

The `argoproj-labs/rollouts-plugin-trafficrouter-gatewayapi` plugin enables weight-based
traffic splitting via HTTPRoute - independent of replica count. This unlocks precise
canary percentages (e.g. 5% -> 10% -> 25% -> 100%) without scaling up replicas.

**Current blocker:** Plugin is alpha as of March 2026. Cilium Gateway API integration
with Rollouts has limited community validation.

**Installation approach (when ready):**
```yaml
# Add to values.yaml when plugin reaches beta
controller:
  trafficRouterPlugins: |
    - name: argoproj-labs/gatewayAPI
      location: https://github.com/argoproj-labs/rollouts-plugin-trafficrouter-gatewayapi/releases/download/<version>/gatewayapi-plugin-linux-amd64
```

**Homepage canary upgrade path:**
- Replace replica-based setWeight steps with HTTPRoute weight steps
- Enables 10% -> 25% -> 50% -> 100% progression on a 2-replica Deployment
- Requires `ReferenceGrant` in homepage namespace allowing Rollouts to patch HTTPRoutes

**Evaluate when:**
- Plugin reaches beta or v1.0
- Cilium Gateway API support is validated in community
- A service is added with 3+ replicas where fine-grained traffic control matters

---

## Verification Checklist

**Deployment:**
- [ ] Controller pod Running 1/1 in argo-rollouts namespace
- [ ] Dashboard pod Running 1/1, accessible via port-forward
- [ ] All 5 Rollout CRDs present (rollouts, analysisruns, analysistemplates, clusteranalysistemplates, experiments)
- [ ] ClusterAnalysisTemplates http-success-rate and pod-restart-rate created
- [ ] ArgoCD Application argo-rollouts is Synced/Healthy

**Wave 1 - portfolio-prod:**
- [ ] Rollout created, status Healthy
- [ ] preview Service exists (portfolio-preview)
- [ ] Blue-green test promotion completed without downtime
- [ ] prePromotionAnalysis passed (http-success-rate)
- [ ] Old ReplicaSet scaled down after scaleDownDelaySeconds

**Wave 2 - ghost-prod:**
- [ ] Rollout created, status Healthy
- [ ] preview Service exists (ghost-preview)
- [ ] postPromotionAnalysis passes after switch
- [ ] Blog accessible throughout promotion

**Wave 3 - homepage:**
- [ ] Rollout created, status Healthy
- [ ] Canary step progression completes successfully
- [ ] Analysis passes at 50% weight step
- [ ] All replicas updated after full promotion

**Monitoring:**
- [ ] ServiceMonitor scraping controller metrics
- [ ] All 4 alert rules loaded in Prometheus
- [ ] Grafana dashboard deployed and displaying data

**Notifications:**
- [ ] Discord #gitops receives rollout-completed notification
- [ ] Discord #gitops receives rollout-aborted notification on forced abort test

**Security:**
- [ ] Controller runs as non-root (runAsUser: 1000)
- [ ] CiliumNetworkPolicy applied with minimal egress rules
- [ ] No secrets in Rollout specs (all via ExternalSecret/secretKeyRef)
- [ ] PSS baseline enforced on argo-rollouts namespace

---

## Rollback

**Remove Argo Rollouts entirely:**
```bash
# Delete ArgoCD Application (removes all managed resources)
kubectl-admin delete application argo-rollouts -n argocd

# If ArgoCD Application is gone, uninstall Helm release directly
helm-homelab uninstall argo-rollouts -n argo-rollouts

# Remove CRDs
kubectl-admin delete crd \
  rollouts.argoproj.io \
  analysisruns.argoproj.io \
  analysistemplates.argoproj.io \
  clusteranalysistemplates.argoproj.io \
  experiments.argoproj.io

# Remove namespace
kubectl-admin delete namespace argo-rollouts
```

**Convert Rollouts back to Deployments:**
```bash
# For each converted service (portfolio, ghost, homepage):
# 1. kubectl-admin delete rollout <name> -n <namespace>
# 2. kubectl-admin apply -f manifests/<service>/deployment.yaml
# 3. kubectl-admin delete service <name>-preview -n <namespace>  # remove preview Services

# Example for portfolio
kubectl-admin delete rollout portfolio -n portfolio
kubectl-admin apply -f manifests/portfolio/deployment.yaml
kubectl-admin delete service portfolio-preview -n portfolio
```

**ArgoCD shows OutOfSync after auto-rollback:**
```bash
# Argo Rollouts auto-rollback changes cluster state without changing Git.
# ArgoCD will show OutOfSync - this is expected. Do NOT sync from ArgoCD.
# Fix: update the image tag in rollout.yaml to the stable version, commit, let ArgoCD sync.
kubectl-argo-rollouts get rollout <name> -n <namespace>
# Check stableRS field to identify which image hash is stable
```

**CiliumNP too restrictive (analysis Prometheus queries failing):**
```bash
# If AnalysisRuns fail with connection refused to Prometheus:
kubectl-admin delete ciliumnetworkpolicy argo-rollouts-default-deny -n argo-rollouts
# Re-apply after fixing egress rule for prometheus-operated.monitoring.svc:9090
```

---

## Final: Commit and Release

- [ ] `/audit-security` then `/commit`
- [ ] `/audit-docs` then `/commit`
- [ ] `/release v0.40.0 "Argo Rollouts & Progressive Delivery"`
- [ ] `mv docs/todo/phase-5.10-argo-rollouts.md docs/todo/completed/`
