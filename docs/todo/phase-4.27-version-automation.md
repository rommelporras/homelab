# Phase 4.27: Version Automation & Upgrade Runbooks

> **Status:** Planned
> **Target:** v0.25.0
> **Prerequisite:** Phase 4.26 complete (ARR Companions deployed — maximizes service count for version tracking)
> **Priority:** Medium (operational tooling, not user-facing)
> **DevOps Topics:** Dependency management, observability, upgrade procedures, rollback strategies
> **CKA Topics:** CronJob, RBAC, ServiceAccount, ConfigMap, Secret, PrometheusRule

> **Purpose:** Automate version checking for all cluster services and dependencies, with Discord notifications and documented upgrade/rollback procedures per component type.
>
> **Why:** We don't know when upstream versions release (e.g., kube-vip had a major update we missed). Manual checking doesn't scale with 20+ services. Need proactive alerts + safe upgrade procedures.

---

## Architecture

Three complementary tools covering different scopes:

```
┌────────────────────────────────────────────────────────────────┐
│  GitHub (repo-level)                                           │
│                                                                │
│  Renovate Bot (GitHub App)                                     │
│  - Scans manifests/ for image: tags                            │
│  - Scans helm/ for chart versions                              │
│  - Opens weekly grouped PR with version bumps                  │
│  - Dependency Dashboard issue for manual approval              │
│  - NO cluster access needed                                    │
└────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────┐
│  monitoring namespace (cluster-level)                          │
│                                                                │
│  ┌──────────────────────┐  ┌───────────────────────────────┐  │
│  │ version-checker       │  │ version-check CronJob         │  │
│  │ (Deployment)          │  │ (weekly)                       │  │
│  │                       │  │                                │  │
│  │ Checks running images │  │ Runs nova + custom checks     │  │
│  │ vs registry latest    │  │ Sends Discord embed digest    │  │
│  │ Exposes Prometheus    │  │                                │  │
│  │ metrics               │  │ Image: alpine/curl+jq         │  │
│  └───────────┬───────────┘  └───────────────┬────────────────┘ │
│              │                               │                  │
│              ▼                               ▼                  │
│  Prometheus → Grafana dashboard    Discord webhook channel      │
│  PrometheusRule → Alertmanager                                  │
└────────────────────────────────────────────────────────────────┘
```

### Why Three Tools

| Tool | Scope | Strength |
|------|-------|----------|
| **Renovate** | Repo files (images + charts) | Opens PRs with exact version bumps — actionable |
| **version-checker** | Running cluster images | Catches drift between repo and cluster (e.g., forgot to apply) |
| **CronJob + Discord** | Everything (Helm, images, kubeadm, kube-vip) | Human-readable weekly digest — single glance |

---

## Components

| Component | Image/Tool | Namespace | Type |
|-----------|-----------|-----------|------|
| Renovate Bot | GitHub App (SaaS) | N/A | GitHub App |
| version-checker | `quay.io/jetstack/version-checker:v0.10.0` | monitoring | Deployment |
| Version check script | ConfigMap (shell script) | monitoring | CronJob |
| curl+jq runner | `dwdraju/alpine-curl-jq:latest` | monitoring | CronJob image |
| Nova | `quay.io/fairwinds/nova:v3.11.10` | monitoring | CronJob sidecar / init |

---

## Tool 1: Renovate Bot (GitHub App)

### What It Does
- Scans repo for outdated container images in `manifests/**/*.yaml` and Helm chart versions in `helm/**/values.yaml`
- Opens PRs with version bumps (grouped weekly)
- Creates a Dependency Dashboard issue listing all pending updates
- **No cluster access needed** — works entirely on repo files via GitHub API
- **Free** for public and private repos

### Setup

1. Install [Renovate GitHub App](https://github.com/apps/renovate) on the `rommelporras/homelab` repo
2. Merge the auto-generated onboarding PR
3. Replace the default `renovate.json` with our config

### Configuration

File: `renovate.json` (repo root)

```json
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": ["config:recommended"],
  "timezone": "Asia/Manila",
  "dependencyDashboard": true,
  "dependencyDashboardApproval": true,
  "prConcurrentLimit": 5,
  "prHourlyLimit": 2,
  "kubernetes": {
    "fileMatch": ["^manifests/.+\\.yaml$"]
  },
  "helm-values": {
    "fileMatch": ["^helm/.+/values\\.yaml$"]
  },
  "packageRules": [
    {
      "description": "Group all K8s and Helm updates into one weekly PR",
      "matchManagers": ["kubernetes", "helm-values", "helmv3"],
      "groupName": "kubernetes-weekly",
      "schedule": ["before 6am on sunday"]
    },
    {
      "description": "Never automerge critical infrastructure",
      "matchPackagePatterns": ["longhorn", "cilium", "kube-prometheus-stack", "cert-manager"],
      "automerge": false
    }
  ]
}
```

### Key Behaviors

| Behavior | Setting |
|----------|---------|
| PR schedule | Weekly (Sunday before 6am PHT) |
| PR grouping | All K8s/Helm updates in one PR |
| Manual approval | Dependency Dashboard checkbox required |
| Concurrent PRs | Max 5 |
| Image detection | Auto-detects `image:` fields in YAML (no annotations needed) |
| Tag requirement | Only tracks versioned tags (e.g., `v1.2.3`), ignores `latest` |

### Gotchas

| Issue | Detail |
|-------|--------|
| `fileMatch` required for K8s | Renovate does NOT auto-detect K8s YAML — must configure explicitly |
| `latest` tags ignored | Images using `latest` or rolling tags won't be tracked |
| Docker Hub rate limits | Anonymous: 100 pulls/6hrs per IP — usually fine for weekly scans |
| Onboarding PR | Must merge (or close) the auto-generated onboarding PR to activate |

---

## Tool 2: version-checker (Cluster Deployment)

### What It Does
- Runs as a Deployment in `monitoring` namespace
- Checks all running container images against upstream registries
- Exposes Prometheus metric: `version_checker_is_latest_version` (1=current, 0=outdated)
- Grafana dashboard shows which pods are outdated at a glance

### Container Image

| Item | Value |
|------|-------|
| Image | `quay.io/jetstack/version-checker:v0.10.0` |
| Port | 8080 (metrics) |
| Health | `/readyz` on port 8080 |

### Resource Limits

| Resource | Request | Limit |
|----------|---------|-------|
| CPU | 50m | 100m |
| Memory | 64Mi | 128Mi |

### Security Context

```yaml
securityContext:
  runAsNonRoot: true
  allowPrivilegeEscalation: false
  capabilities:
    drop: [ALL]
  seccompProfile:
    type: RuntimeDefault
  readOnlyRootFilesystem: true
automountServiceAccountToken: true  # Needs K8s API access
```

### RBAC

version-checker needs read access to pods across all namespaces:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: version-checker
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["deployments", "statefulsets", "daemonsets"]
    verbs: ["get", "list", "watch"]
```

### Prometheus Integration

**ServiceMonitor** to scrape metrics:
```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: version-checker
  namespace: monitoring
spec:
  selector:
    matchLabels:
      app: version-checker
  endpoints:
    - port: metrics
      interval: 1h  # No need for frequent scrapes
```

**PrometheusRule** for alerting:
```yaml
- alert: ContainerImageOutdated
  expr: version_checker_is_latest_version == 0
  for: 7d  # Only alert if outdated for 7+ days
  labels:
    severity: warning
  annotations:
    summary: "{{ $labels.image }} in {{ $labels.namespace }} is outdated"
    description: "Running {{ $labels.current_version }}, latest is {{ $labels.latest_version }}"
```

### Grafana Dashboard

Community dashboard: [Grafana #12833](https://grafana.com/grafana/dashboards/12833-version-checker/) — import via ID.

---

## Tool 3: Weekly Discord Digest (CronJob)

### What It Does
- Runs weekly (Sunday 8am PHT)
- Checks Helm chart versions, container images, kubeadm, and kube-vip
- Sends a color-coded Discord embed with version status
- Green = all current, Yellow = minor/patch updates, Red = major updates or security fixes

### Discord Setup

1. Create a `#version-alerts` channel in your Discord server
2. Server Settings → Integrations → Create Webhook → select `#version-alerts`
3. Copy webhook URL
4. Store in 1Password: `op://Kubernetes/Discord Webhook/version-alerts-url`

### Discord Embed Format

```json
{
  "embeds": [
    {
      "title": "Homelab Version Check — Weekly Digest",
      "description": "Checked on 2026-02-11",
      "color": 5763719,
      "fields": [
        { "name": "Kubernetes", "value": "v1.35.0 (current)", "inline": true },
        { "name": "Cilium", "value": "1.18.6 (current)", "inline": true },
        { "name": "Longhorn", "value": "1.10.1 (current)", "inline": true }
      ]
    },
    {
      "title": "Outdated Components",
      "color": 16705372,
      "fields": [
        { "name": "kube-vip", "value": "v0.8.9 → v0.9.1", "inline": true }
      ]
    }
  ]
}
```

**Color codes (decimal):**
- Green (current): `5763719` (#57F287)
- Yellow (outdated): `16705372` (#FEE75C)
- Red (critical): `15548997` (#ED4245)

### CronJob Design

| Item | Value |
|------|-------|
| Schedule | `0 0 * * 0` (Sunday 00:00 UTC = 08:00 PHT) |
| Image | `dwdraju/alpine-curl-jq:latest` |
| Script | ConfigMap-mounted shell script |
| Secret | Discord webhook URL via env var from K8s Secret |
| ServiceAccount | `version-checker-cronjob` (needs Helm list + pod read) |
| Timeout | `activeDeadlineSeconds: 300` |
| History | `successfulJobsHistoryLimit: 3`, `failedJobsHistoryLimit: 3` |

### Version Check Script Logic

The script checks these sources:

| Check | Method | Source |
|-------|--------|--------|
| Helm charts | `helm list -A -o json` vs `helm search repo` | Helm repos |
| Container images | version-checker Prometheus metrics (curl) | Registry APIs |
| Kubernetes | `kubectl version -o json` vs GitHub API | kubernetes/kubernetes releases |
| kube-vip | Current static pod manifest vs GitHub API | kube-vip/kube-vip releases |

### Resource Limits (CronJob)

| Resource | Request | Limit |
|----------|---------|-------|
| CPU | 50m | 200m |
| Memory | 32Mi | 128Mi |

### 1Password Items

```bash
op item create \
  --vault "Kubernetes" \
  --category "Login" \
  --title "Discord Webhook" \
  --field "version-alerts-url=https://discord.com/api/webhooks/..."
```

---

## Manual Check Commands

Quick commands to check versions on-demand (no tools required):

```bash
# Check all Helm releases vs upstream
# (install nova first: brew install fairwindsops/tap/nova)
nova find --format table

# Check container images too
nova find --containers --format table

# Check Kubernetes version
kubectl-homelab version -o json | jq '.serverVersion.gitVersion'

# Check kubeadm available versions
ssh wawashi@cp1.k8s.rommelporras.com "apt list -a kubeadm 2>/dev/null | head -5"

# Check kube-vip latest release
curl -s https://api.github.com/repos/kube-vip/kube-vip/releases/latest | jq -r .tag_name

# Check all running images
kubectl-homelab get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.spec.containers[*].image}{"\n"}{end}' | sort

# Check Longhorn latest
curl -s https://api.github.com/repos/longhorn/longhorn/releases/latest | jq -r .tag_name

# Check Cilium latest
curl -s https://api.github.com/repos/cilium/cilium/releases/latest | jq -r .tag_name
```

---

## Upgrade/Rollback Procedures

### Pre-Upgrade Checklist (EVERY upgrade)

```bash
# 1. etcd snapshot backup
ssh wawashi@cp1.k8s.rommelporras.com "sudo etcdctl snapshot save /tmp/etcd-pre-upgrade-$(date +%Y%m%d).db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key"

# 2. Verify all nodes Ready
kubectl-homelab get nodes

# 3. Verify Longhorn volume health
kubectl-homelab -n longhorn-system get volumes.longhorn.io

# 4. Verify all PVCs bound
kubectl-homelab get pvc -A | grep -v Bound

# 5. Read upstream release notes for breaking changes
```

### By Component Type

#### Helm Charts (Prometheus, Grafana, Loki, Alloy, cert-manager, etc.)

```bash
# Upgrade
helm-homelab upgrade <release> <chart> -n <namespace> -f helm/<chart>/values.yaml

# Verify
kubectl-homelab -n <namespace> rollout status deployment/<name>

# Rollback (to previous revision)
helm-homelab rollback <release> <revision> -n <namespace>
helm-homelab history <release> -n <namespace>  # find revision number
```

**Risk:** Low — Helm tracks revisions. PVC data persists across rollback.

#### Raw Manifests (Karakeep, Ghost, AdGuard, Homepage, etc.)

```bash
# Upgrade (bump image tag in manifest, then apply)
kubectl-homelab apply -f manifests/<service>/

# Verify
kubectl-homelab -n <namespace> rollout status deployment/<name>

# Rollback
kubectl-homelab -n <namespace> rollout undo deployment/<name>
kubectl-homelab -n <namespace> rollout history deployment/<name>  # check history
```

**Risk:** Low — rollout undo restores previous ReplicaSet. PVC data persists.

#### Kubernetes (kubeadm)

```bash
# MUST upgrade 1 minor version at a time (e.g., 1.35 → 1.36, never 1.35 → 1.37)
# Upgrade control planes first, then workers (we have 3 CPs, no dedicated workers)

# On FIRST control plane (cp1):
sudo apt-mark unhold kubeadm && sudo apt-get update && sudo apt-get install -y kubeadm=<version>
sudo kubeadm upgrade plan
sudo kubeadm upgrade apply v<version>
sudo apt-mark unhold kubelet kubectl && sudo apt-get install -y kubelet=<version> kubectl=<version>
sudo systemctl daemon-reload && sudo systemctl restart kubelet
sudo apt-mark hold kubeadm kubelet kubectl

# On REMAINING control planes (cp2, cp3):
# Same apt steps, but use: sudo kubeadm upgrade node (NOT upgrade apply)

# Verify
kubectl-homelab get nodes  # all should show new version
```

**Risk:** HIGH — hard to roll back. etcd backup is critical. Always `kubeadm upgrade plan` first.

#### kube-vip (Static Pod)

```bash
# On EACH control plane node:
# 1. Edit the static pod manifest
sudo vi /etc/kubernetes/manifests/kube-vip.yaml
# 2. Change image tag to new version
# 3. kubelet auto-restarts the pod

# Verify
kubectl-homelab -n kube-system get pods | grep kube-vip

# Rollback
# Edit manifest back to previous tag on each node
```

**Risk:** Medium — VIP may briefly drop during pod restart. Update one node at a time.

#### Longhorn

```bash
# Upgrade via Helm
helm-homelab upgrade longhorn longhorn/longhorn -n longhorn-system -f helm/longhorn/values.yaml

# Verify
kubectl-homelab -n longhorn-system get pods
kubectl-homelab -n longhorn-system get volumes.longhorn.io
```

**Risk:** HIGHEST — **Longhorn CANNOT be downgraded.** Always read release notes. Test in a non-critical namespace first if possible. Backup all critical PVCs before upgrading.

#### Cilium

```bash
# Upgrade via Helm
helm-homelab upgrade cilium cilium/cilium -n kube-system -f helm/cilium/values.yaml

# Verify
cilium status
kubectl-homelab -n kube-system get pods -l app.kubernetes.io/part-of=cilium

# Rollback
helm-homelab rollback cilium <revision> -n kube-system
```

**Risk:** Medium-High — brief network disruption during rollout. NetworkPolicies may temporarily not enforce.

### Upgrade Risk Summary

| Component | Upgrade Method | Rollback | Risk | Notes |
|-----------|---------------|----------|------|-------|
| Helm charts | `helm upgrade` | `helm rollback` | Low | PVC data persists |
| Raw manifests | `kubectl apply` | `kubectl rollout undo` | Low | PVC data persists |
| Kubernetes | `kubeadm upgrade` | etcd restore (manual) | **High** | 1 minor at a time |
| kube-vip | Edit static pod | Edit manifest back | Medium | VIP brief drop |
| Longhorn | `helm upgrade` | **Cannot downgrade** | **Highest** | Read release notes! |
| Cilium | `helm upgrade` | `helm rollback` | Medium-High | Brief network disruption |

---

## Files to Create

| File | Type | Purpose |
|------|------|---------|
| `renovate.json` | Config | Renovate Bot configuration (repo root) |
| `manifests/monitoring/version-checker-deployment.yaml` | Deployment | version-checker + Service |
| `manifests/monitoring/version-checker-rbac.yaml` | RBAC | ClusterRole + ClusterRoleBinding + ServiceAccount |
| `manifests/monitoring/version-checker-servicemonitor.yaml` | ServiceMonitor | Prometheus scrape config |
| `manifests/monitoring/version-checker-alerts.yaml` | PrometheusRule | ContainerImageOutdated alert |
| `manifests/monitoring/version-check-cronjob.yaml` | CronJob | Weekly Discord digest |
| `manifests/monitoring/version-check-script.yaml` | ConfigMap | Version check shell script |
| `docs/context/Upgrades.md` | Documentation | Upgrade/rollback runbook per component |

## Files to Modify

| File | Change |
|------|--------|
| `docs/context/_Index.md` | Add Upgrades.md to Quick Links table |
| Grafana | Import dashboard #12833 (version-checker) |

---

## Tasks

### 4.27.1 Install Renovate Bot

- [ ] 4.27.1.1 Install [Renovate GitHub App](https://github.com/apps/renovate) on `rommelporras/homelab` repo
- [ ] 4.27.1.2 Merge the auto-generated onboarding PR
- [ ] 4.27.1.3 Create `renovate.json` with homelab config (weekly grouped PRs, dependency dashboard)
- [ ] 4.27.1.4 Verify Renovate creates Dependency Dashboard issue
- [ ] 4.27.1.5 Verify Renovate detects images in `manifests/` and chart versions in `helm/`
- [ ] 4.27.1.6 Commit `renovate.json`

### 4.27.2 Deploy version-checker

- [ ] 4.27.2.1 Create `manifests/monitoring/version-checker-rbac.yaml`
  - ServiceAccount, ClusterRole (pods + deployments read), ClusterRoleBinding
- [ ] 4.27.2.2 Create `manifests/monitoring/version-checker-deployment.yaml`
  - Image: `quay.io/jetstack/version-checker:v0.10.0`
  - Port 8080, readiness/liveness on `/readyz`
  - Security context: runAsNonRoot, drop ALL, readOnlyRootFilesystem
  - Resource limits: 50m/100m CPU, 64Mi/128Mi memory
- [ ] 4.27.2.3 Create `manifests/monitoring/version-checker-servicemonitor.yaml`
  - Scrape interval: 1h (no need for frequent checks)
- [ ] 4.27.2.4 Create `manifests/monitoring/version-checker-alerts.yaml`
  - Alert: `ContainerImageOutdated` (fires after 7d outdated)
  - Alert: `VersionCheckerDown` (fires after 15m)
- [ ] 4.27.2.5 Apply all manifests:
  ```bash
  kubectl-homelab apply \
    -f manifests/monitoring/version-checker-rbac.yaml \
    -f manifests/monitoring/version-checker-deployment.yaml \
    -f manifests/monitoring/version-checker-servicemonitor.yaml \
    -f manifests/monitoring/version-checker-alerts.yaml
  ```
- [ ] 4.27.2.6 Verify pod running:
  ```bash
  kubectl-homelab -n monitoring get pods -l app=version-checker
  ```
- [ ] 4.27.2.7 Verify metrics exposed:
  ```bash
  kubectl-homelab -n monitoring port-forward deploy/version-checker 8080:8080 &
  curl -s http://localhost:8080/metrics | grep version_checker_is_latest_version
  ```
- [ ] 4.27.2.8 Import Grafana dashboard #12833 (version-checker)

### 4.27.3 Create Discord Webhook

- [ ] 4.27.3.1 Create `#version-alerts` channel in Discord server
- [ ] 4.27.3.2 Create webhook: Server Settings → Integrations → Create Webhook → select channel
- [ ] 4.27.3.3 Store webhook URL in 1Password:
  ```bash
  op item create \
    --vault "Kubernetes" \
    --category "Login" \
    --title "Discord Webhook" \
    --field "version-alerts-url=<webhook-url>"
  ```
- [ ] 4.27.3.4 Create K8s Secret:
  ```bash
  kubectl-homelab -n monitoring create secret generic discord-webhook \
    --from-literal=webhook-url="$(op read 'op://Kubernetes/Discord Webhook/version-alerts-url')"
  ```
- [ ] 4.27.3.5 Test webhook manually:
  ```bash
  curl -X POST "$(op read 'op://Kubernetes/Discord Webhook/version-alerts-url')" \
    -H "Content-Type: application/json" \
    -d '{"embeds":[{"title":"Test","description":"Version check webhook working","color":5763719}]}'
  ```

### 4.27.4 Deploy Version Check CronJob

- [ ] 4.27.4.1 Create `manifests/monitoring/version-check-script.yaml` (ConfigMap with shell script)
  - Script checks: Helm releases, container images (via version-checker metrics), kubeadm, kube-vip
  - Builds Discord embed JSON with color-coded status
  - Sends via `curl` to Discord webhook
- [ ] 4.27.4.2 Create `manifests/monitoring/version-check-cronjob.yaml`
  - Schedule: `0 0 * * 0` (Sunday 00:00 UTC = 08:00 PHT)
  - Image: `dwdraju/alpine-curl-jq:latest`
  - Mount: ConfigMap script + Secret webhook URL
  - ServiceAccount with Helm list + pod read permissions
  - `activeDeadlineSeconds: 300`
  - Security context: runAsNonRoot, drop ALL
- [ ] 4.27.4.3 Apply:
  ```bash
  kubectl-homelab apply \
    -f manifests/monitoring/version-check-script.yaml \
    -f manifests/monitoring/version-check-cronjob.yaml
  ```
- [ ] 4.27.4.4 Trigger manual run to test:
  ```bash
  kubectl-homelab -n monitoring create job --from=cronjob/version-check version-check-manual
  kubectl-homelab -n monitoring logs job/version-check-manual -f
  ```
- [ ] 4.27.4.5 Verify Discord message received with correct formatting

### 4.27.5 Write Upgrade Runbook

- [ ] 4.27.5.1 Create `docs/context/Upgrades.md` with:
  - Pre-upgrade checklist (etcd backup, node health, PVC status, Longhorn volume health)
  - Upgrade/rollback procedures for each component type (Helm, manifests, kubeadm, kube-vip, Longhorn, Cilium)
  - Risk matrix
  - Emergency rollback procedures
- [ ] 4.27.5.2 Update `docs/context/_Index.md` — add Upgrades.md to Quick Links

### 4.27.6 Install Nova CLI (Local)

- [ ] 4.27.6.1 Install Nova on local machine:
  ```bash
  brew install fairwindsops/tap/nova
  ```
- [ ] 4.27.6.2 Test:
  ```bash
  KUBECONFIG=~/.kube/homelab.yaml nova find --format table
  KUBECONFIG=~/.kube/homelab.yaml nova find --containers --format table
  ```

### 4.27.7 Security & Commit

- [ ] 4.27.7.1 `/audit-security`
- [ ] 4.27.7.2 `/commit` (infrastructure)

### 4.27.8 Documentation & Release

> Second commit: documentation updates and audit.

- [ ] 4.27.8.1 Update `docs/todo/README.md` — add Phase 4.27 to phase index + release mapping
- [ ] 4.27.8.2 Update `README.md` (root) — add version-checker to services list
- [ ] 4.27.8.3 Update `VERSIONS.md` — add version-checker, Renovate, Nova versions
- [ ] 4.27.8.4 Update `docs/reference/CHANGELOG.md` — add version automation entry
- [ ] 4.27.8.5 Update `docs/context/Monitoring.md` — add version-checker + CronJob
- [ ] 4.27.8.6 Update `docs/context/Secrets.md` — add Discord Webhook 1Password item
- [ ] 4.27.8.7 Create `docs/rebuild/v0.25.0-version-automation.md`
- [ ] 4.27.8.8 `/audit-docs`
- [ ] 4.27.8.9 `/commit` (documentation)
- [ ] 4.27.8.10 `/release v0.25.0 "Version Automation & Upgrade Runbooks"`
- [ ] 4.27.8.11 Move this file to `docs/todo/completed/`

---

## Verification Checklist

- [ ] Renovate GitHub App installed and creating Dependency Dashboard issue
- [ ] Renovate detects image tags in `manifests/` YAML files
- [ ] Renovate detects Helm chart versions in `helm/` values files
- [ ] version-checker pod running in `monitoring` namespace
- [ ] version-checker Prometheus metrics visible (`version_checker_is_latest_version`)
- [ ] Grafana dashboard #12833 imported and showing data
- [ ] `ContainerImageOutdated` PrometheusRule created
- [ ] Discord webhook test message received
- [ ] Weekly CronJob runs and sends Discord digest
- [ ] Discord embed shows color-coded version status (green/yellow/red)
- [ ] Nova CLI works locally (`nova find --format table`)
- [ ] `docs/context/Upgrades.md` complete with all component types
- [ ] Pre-upgrade checklist documented and tested

---

## Rollback

```bash
# Remove version-checker
kubectl-homelab delete deployment version-checker -n monitoring
kubectl-homelab delete servicemonitor version-checker -n monitoring
kubectl-homelab delete prometheusrule version-checker-alerts -n monitoring
kubectl-homelab delete clusterrole version-checker
kubectl-homelab delete clusterrolebinding version-checker
kubectl-homelab delete serviceaccount version-checker -n monitoring

# Remove CronJob
kubectl-homelab delete cronjob version-check -n monitoring
kubectl-homelab delete configmap version-check-script -n monitoring
kubectl-homelab delete secret discord-webhook -n monitoring

# Renovate: disable via GitHub App settings (no cluster changes)
# Nova: just a local CLI binary, uninstall via brew
```

---

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Renovate over Dependabot | Renovate | Better K8s manifest support, weekly grouping, dependency dashboard |
| version-checker over custom script | version-checker | Maintained project, Prometheus-native, Grafana dashboard |
| CronJob over Alertmanager-only | CronJob + Discord | Weekly digest is more actionable than per-image alerts |
| Discord over email | Discord | Already use Discord for alerts, richer formatting (embeds) |
| Namespace | monitoring | Operational tooling, co-located with Prometheus/Grafana |
| Nova as CLI only | CLI (not CronJob) | Ad-hoc checks, no need for continuous monitoring |
| `dwdraju/alpine-curl-jq` | Lightweight image | ~15MB, has curl+jq+bash — all we need for the script |

---

## CKA Learnings

| Topic | Concept |
|-------|---------|
| CronJob | Scheduled workload with history limits, active deadlines, manual triggers |
| RBAC | ClusterRole for cross-namespace pod read access (version-checker) |
| ServiceAccount | Dedicated SA for CronJob with minimal permissions |
| ConfigMap | Mounting shell scripts as ConfigMap volumes |
| Secret | Discord webhook URL stored as K8s Secret (from 1Password) |
| ServiceMonitor | Custom Prometheus scrape config for version-checker |
| PrometheusRule | Alert on version drift (7-day threshold) |

---

## Research Sources

| Topic | Source |
|-------|--------|
| Renovate GitHub App | [github.com/apps/renovate](https://github.com/apps/renovate) |
| Renovate K8s manager | [docs.renovatebot.com/modules/manager/kubernetes](https://docs.renovatebot.com/modules/manager/kubernetes/) |
| Renovate Helm values manager | [docs.renovatebot.com/modules/manager/helm-values](https://docs.renovatebot.com/modules/manager/helm-values/) |
| Renovate noise reduction | [docs.renovatebot.com/noise-reduction](https://docs.renovatebot.com/noise-reduction/) |
| version-checker | [github.com/jetstack/version-checker](https://github.com/jetstack/version-checker) |
| version-checker Grafana dashboard | [Grafana #12833](https://grafana.com/grafana/dashboards/12833-version-checker/) |
| Fairwinds Nova | [github.com/FairwindsOps/nova](https://github.com/FairwindsOps/nova) |
| Nova docs | [nova.docs.fairwinds.com](https://nova.docs.fairwinds.com/) |
| Discord webhooks guide | [birdie0.github.io/discord-webhooks-guide](https://birdie0.github.io/discord-webhooks-guide/) |
| Discord embed colors | [gist.github.com/thomasbnt](https://gist.github.com/thomasbnt/b6f455e2c7d743b796917fa3c205f812) |
| Alertmanager Discord native | [promlabs.com](https://promlabs.com/blog/2022/12/23/sending-prometheus-alerts-to-discord-with-alertmanager-v0-25-0/) |
