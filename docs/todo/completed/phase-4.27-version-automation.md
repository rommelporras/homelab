# Phase 4.27: Version Automation & Upgrade Runbooks

> **Status:** Planned
> **Target:** v0.26.0
> **Prerequisite:** Phase 4.26 complete (ARR Companions deployed), `:latest` images pinned (see below)
> **Priority:** Medium (operational tooling, not user-facing)
> **DevOps Topics:** Dependency management, observability, upgrade procedures, rollback strategies
> **CKA Topics:** CronJob, RBAC, ServiceAccount, ConfigMap, Secret, PrometheusRule, init containers

> **Purpose:** Automate version checking for all cluster services and dependencies, with Discord notifications and documented upgrade/rollback procedures per component type.
>
> **Why:** We don't know when upstream versions release (e.g., kube-vip had a major update we missed). Manual checking doesn't scale with 20+ services. Need proactive alerts + safe upgrade procedures.

---

## Prerequisites

### Pin `:latest` Images

Renovate **silently skips** `:latest` tags. version-checker falls back to SHA-based date comparison (no semver). These 7 images must be pinned to version tags before this phase:

| Image | Current Tag | Action |
|-------|-------------|--------|
| `lscr.io/linuxserver/bazarr` | `:latest` | Pin to version tag (e.g., `1.5.3`) |
| `lscr.io/linuxserver/radarr` | `:latest` | Pin to version tag |
| `lscr.io/linuxserver/sonarr` | `:latest` | Pin to version tag |
| `lscr.io/linuxserver/firefox` | `:latest` | Pin to version tag |
| `ghcr.io/thephaseless/byparr` | `:latest` | Add to Renovate ignore (no semver tags published) |
| `registry.k8s.rommelporras.com/0xwsh/portfolio` | `:latest` | Add to Renovate ignore (CI/CD-built) |
| `registry.k8s.rommelporras.com/0xwsh/invoicetron` | `:latest` | Add to Renovate ignore (CI/CD-built) |

> **Why pin?** Without version tags, ~20% of container images are invisible to the entire version tracking system. Renovate can't open PRs, version-checker can't do semver comparison, and Nova can't detect drift.

---

## Architecture

Three complementary tools covering different scopes:

```
┌────────────────────────────────────────────────────────────────┐
│  GitHub (repo-level)                                           │
│                                                                │
│  Renovate Bot (GitHub App)                                     │
│  - Scans manifests/ for image: tags                            │
│  - Opens weekly grouped PR with version bumps                  │
│  - Dependency Dashboard issue for manual approval              │
│  - NO cluster access needed                                    │
│  - GitOps-ready: merge PR → kubectl apply (now) or             │
│                  merge PR → ArgoCD/Flux sync (future)          │
└────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────┐
│  monitoring namespace (cluster-level)                          │
│                                                                │
│  ┌──────────────────────┐  ┌───────────────────────────────┐  │
│  │ version-checker       │  │ version-check CronJob         │  │
│  │ (Deployment)          │  │ (weekly)                       │  │
│  │                       │  │                                │  │
│  │ Checks ALL running    │  │ Runs Nova (Helm chart drift)  │  │
│  │ images vs registry    │  │ Formats Nova JSON → Discord   │  │
│  │ --test-all-containers │  │                                │  │
│  │ Exposes Prometheus    │  │ Init: Nova binary → emptyDir  │  │
│  │ metrics + K8s version │  │ Main: alpine + curl/jq        │  │
│  └───────────┬───────────┘  └───────────────┬────────────────┘ │
│              │                               │                  │
│              ▼                               ▼                  │
│  Prometheus → Grafana dashboard    Discord #version-alerts      │
│  PrometheusRule → Alertmanager                                  │
└────────────────────────────────────────────────────────────────┘
```

### Why Three Tools

| Tool | Scope | Strength |
|------|-------|----------|
| **Renovate** | Repo files (image tags) | Opens PRs with exact version bumps — actionable, GitOps-ready |
| **version-checker** | Running cluster images + K8s version | Catches drift between repo and cluster (e.g., forgot to apply) |
| **CronJob + Nova + Discord** | Helm chart drift + weekly digest | Human-readable digest — Helm charts aren't in Git, only Nova can check them |

### What Each Tool Does NOT Cover

| Gap | Why | Mitigation |
|-----|-----|------------|
| Renovate can't track Helm chart versions | No `Chart.yaml` or FluxCD `HelmRelease` in repo — charts installed imperatively | Nova covers Helm drift cluster-side |
| Renovate can't track private registry images | `portfolio` and `invoicetron` are CI/CD-built from GitLab | These use `:latest` by design — CI/CD handles freshness |
| version-checker has no semver for non-standard tags | linuxserver.io uses `version-ls123` format | `match-regex` annotations per image |
| CronJob can't track container image drift | Nova `--containers` checks running images but version-checker already covers this | version-checker handles continuous monitoring; CronJob focuses on Helm charts |

---

## Components

| Component | Image/Tool | Namespace | Type |
|-----------|-----------|-----------|------|
| Renovate Bot | GitHub App (SaaS) | N/A | GitHub App |
| version-checker | `quay.io/jetstack/version-checker:v0.10.0` | monitoring | Deployment |
| Nova | `quay.io/fairwinds/nova:v3.11.10` | monitoring | CronJob init container |
| Version check script | ConfigMap (shell script) | monitoring | CronJob |
| CronJob runner | `alpine:3.21` | monitoring | CronJob main container |

---

## Tool 1: Renovate Bot (GitHub App)

### What It Does
- Scans repo for outdated container images in `manifests/**/*.yaml`
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
  "labels": ["renovate", "dependencies"],
  "dependencyDashboard": true,
  "dependencyDashboardApproval": true,
  "prConcurrentLimit": 5,
  "prHourlyLimit": 2,
  "kubernetes": {
    "managerFilePatterns": ["/^manifests/.+\\.ya?ml$/"]
  },
  "ignorePaths": ["ansible/**", "docs/**", "scripts/**"],
  "packageRules": [
    {
      "description": "Major bumps: separate PR, never automerge, needs manual review",
      "matchUpdateTypes": ["major"],
      "groupName": null,
      "automerge": false,
      "labels": ["breaking-change"],
      "prBodyNotes": ["**MAJOR VERSION** - Check upgrade path in docs/context/Upgrades.md before merging. Read upstream release notes for breaking changes, database migrations, and deprecations."],
      "schedule": ["before 6am on sunday"]
    },
    {
      "description": "Group minor/patch updates into one weekly PR",
      "matchManagers": ["kubernetes"],
      "matchUpdateTypes": ["minor", "patch", "digest"],
      "groupName": "kubernetes-weekly-minor-patch",
      "schedule": ["before 6am on sunday"]
    },
    {
      "description": "Group all linuxserver.io images together",
      "matchDatasources": ["docker"],
      "matchPackagePrefixes": ["lscr.io/linuxserver/"],
      "groupName": "linuxserver.io images"
    },
    {
      "description": "Never automerge critical infrastructure (any update type)",
      "matchPackagePatterns": ["longhorn", "cilium", "kube-prometheus-stack", "cert-manager"],
      "automerge": false
    },
    {
      "description": "Skip CI/CD-built images from private registry",
      "matchDatasources": ["docker"],
      "matchPackagePrefixes": ["registry.k8s.rommelporras.com/"],
      "enabled": false
    }
  ]
}
```

### Key Behaviors

| Behavior | Setting |
|----------|---------|
| PR schedule | Weekly (Sunday before 6am PHT) |
| **Major bumps** | **Separate PR per package, `breaking-change` label, upgrade path warning** |
| Minor/patch | Grouped into one weekly PR |
| Manual approval | Dependency Dashboard checkbox required |
| Concurrent PRs | Max 5 |
| Image detection | Auto-detects `image:` fields in K8s YAML once `managerFilePatterns` is set |
| Tag requirement | Only tracks versioned tags (e.g., `v1.2.3`), ignores `latest` |
| Private registry | Skipped (CI/CD-built images) |

### Gotchas

| Issue | Detail |
|-------|--------|
| `managerFilePatterns` required | Renovate does NOT auto-detect K8s YAML — Kubernetes manager has **empty default file patterns** |
| `latest` tags ignored | Images using `latest` or rolling tags won't be tracked — must pin first |
| Docker Hub rate limits | Anonymous: 100 pulls/6hrs per IP — usually fine for weekly scans |
| Onboarding PR | Must merge (or close) the auto-generated onboarding PR to activate |
| No Helm chart tracking | Renovate needs `Chart.yaml` or FluxCD `HelmRelease` to track chart versions — we don't have either |
| `helm-values` manager not needed | Our `helm/*/values.yaml` files contain chart config only (replica counts, feature flags) — no `image.repository`/`image.tag` fields |

---

## Tool 2: version-checker (Cluster Deployment)

### What It Does
- Runs as a Deployment in `monitoring` namespace
- Checks **all** running container images against upstream registries (using `--test-all-containers` flag)
- Checks Kubernetes cluster version against latest release (v0.10.0 feature)
- Exposes Prometheus metrics:
  - `version_checker_is_latest_version` (1=current, 0=outdated) per container
  - `version_checker_is_latest_kube_version` (1=current, 0=update available)
- Grafana dashboard shows which pods are outdated at a glance

### Container Image

| Item | Value |
|------|-------|
| Image | `quay.io/jetstack/version-checker:v0.10.0` |
| Port | 8080 (metrics) |
| Health | `/readyz` on port 8080 |
| Key flag | `--test-all-containers` (scan everything, no per-pod opt-in annotations needed) |

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

### Deployment Args

```yaml
args:
  - --test-all-containers  # Scan all containers without requiring annotations
  - --log-level=info
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

### Annotations for Non-Standard Image Tags

Most images use standard semver tags and work automatically. linuxserver.io images use a non-standard format (`version-ls123`) that requires `match-regex` annotations on the pod spec:

```yaml
# Example: Sonarr deployment annotations (after pinning from :latest)
metadata:
  annotations:
    match-regex.version-checker.io/sonarr: "^\\d+\\.\\d+\\.\\d+\\.\\d+-ls\\d+$"
```

| Image Pattern | Regex | Notes |
|---------------|-------|-------|
| linuxserver.io ARR apps | `^\d+\.\d+\.\d+\.\d+-ls\d+$` | 4-part version + ls suffix |
| linuxserver.io firefox | `^\d+\.\d+-ls\d+$` | 2-part version + ls suffix |
| Standard semver (`v1.2.3`) | Not needed | Works by default |

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
groups:
  - name: version-checker
    rules:
      - alert: ContainerImageOutdated
        expr: version_checker_is_latest_version == 0
        for: 7d  # Only alert if outdated for 7+ days
        labels:
          severity: warning
        annotations:
          summary: "{{ $labels.image }} in {{ $labels.namespace }} is outdated"
          description: "Running {{ $labels.current_version }}, latest is {{ $labels.latest_version }}"
      - alert: KubernetesVersionOutdated
        expr: version_checker_is_latest_kube_version == 0
        for: 14d  # K8s upgrades need planning
        labels:
          severity: info
        annotations:
          summary: "Kubernetes update available"
          description: "Running {{ $labels.current_version }}, latest is {{ $labels.latest_version }}"
      - alert: VersionCheckerDown
        expr: up{job="version-checker"} == 0
        for: 15m
        labels:
          severity: warning
        annotations:
          summary: "version-checker is down"
          description: "version-checker has been unreachable for 15 minutes"
```

### Grafana Dashboard

Download [Grafana dashboard #12833](https://grafana.com/grafana/dashboards/12833-version-checker/) JSON and create a ConfigMap following the existing pattern:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: version-checker-dashboard
  namespace: monitoring
  labels:
    grafana_dashboard: "1"
    app.kubernetes.io/name: grafana
    app.kubernetes.io/part-of: kube-prometheus-stack
data:
  version-checker.json: |
    { ... downloaded dashboard JSON ... }
```

---

## Tool 3: Weekly Discord Digest (CronJob)

### What It Does
- Runs weekly (Sunday 8am PHT)
- Uses **Nova** to check Helm chart drift (installed charts vs upstream latest)
- Formats Nova's JSON output into color-coded Discord embeds
- Sends via webhook to `#version-alerts` channel

### Why Nova Instead of Custom Script

The previous plan had a complex shell script that reimplemented version comparison in bash (semver parsing, `helm search repo`, GitHub API calls for changelogs, upgrade registry lookups). This was fragile and redundant.

**Nova already handles all the hard parts:**
- Checks installed Helm releases against upstream repos (ArtifactHub)
- Checks container images against registries
- Classifies updates as outdated/deprecated
- Outputs structured JSON
- Handles all registry authentication and version comparison logic

The CronJob script becomes ~40 lines: run Nova → parse JSON with jq → build Discord embed → curl to webhook.

### Discord Setup

1. Create a `#version-alerts` channel in your Discord server
2. Server Settings → Integrations → Create Webhook → select `#version-alerts`
3. Copy webhook URL
4. Store in 1Password: `op://Kubernetes/Discord Webhook/version-alerts-url`

### Discord Embed Format

The script sends a single message with up to 3 embeds:

```json
{
  "embeds": [
    {
      "title": "Outdated Helm Charts",
      "description": "These charts have newer versions available upstream.",
      "color": 16705372,
      "fields": [
        { "name": "cilium", "value": "1.18.6 → 1.18.7", "inline": true },
        { "name": "loki", "value": "6.49.0 → 6.50.1", "inline": true }
      ]
    },
    {
      "title": "Deprecated Charts",
      "description": "These charts are marked as deprecated upstream. Find replacements.",
      "color": 15548997,
      "fields": [
        { "name": "example-chart", "value": "Deprecated since v2.0.0", "inline": true }
      ]
    },
    {
      "title": "Homelab Version Digest",
      "description": "2026-02-18 | 2 outdated, 0 deprecated, 11 current\nUpgrade runbook: docs/context/Upgrades.md",
      "color": 5763719
    }
  ]
}
```

**Color codes (decimal):**
- Red (deprecated): `15548997` (#ED4245)
- Yellow (outdated): `16705372` (#FEE75C)
- Green (summary/all current): `5763719` (#57F287)

### CronJob Design

| Item | Value |
|------|-------|
| Schedule | `0 0 * * 0` (Sunday 00:00 UTC = 08:00 PHT) |
| Init container image | `quay.io/fairwinds/nova:v3.11.10` (copies binary to shared volume) |
| Main container image | `alpine:3.21` (installs curl + jq at runtime via apk) |
| Script | ConfigMap-mounted shell script |
| Secret | Discord webhook URL via env var from K8s Secret |
| ServiceAccount | `version-check-cronjob` (needs Helm release + pod read) |
| Timeout | `activeDeadlineSeconds: 300` |
| History | `successfulJobsHistoryLimit: 3`, `failedJobsHistoryLimit: 3` |

### CronJob Architecture

```yaml
# Init container copies Nova binary to shared emptyDir
initContainers:
  - name: nova
    image: quay.io/fairwinds/nova:v3.11.10
    command: ["cp", "/usr/local/bin/nova", "/shared/nova"]
    volumeMounts:
      - name: shared
        mountPath: /shared

# Main container runs the script with Nova available
containers:
  - name: version-check
    image: alpine:3.21
    command: ["/bin/sh", "/scripts/version-check.sh"]
    env:
      - name: DISCORD_WEBHOOK_URL
        valueFrom:
          secretKeyRef:
            name: discord-webhook
            key: webhook-url
    volumeMounts:
      - name: shared
        mountPath: /shared
      - name: script
        mountPath: /scripts
```

### Version Check Script Logic

The script is simple because Nova does the heavy lifting:

```bash
#!/bin/sh
set -e

# Install dependencies (adds ~3 seconds)
apk add --no-cache curl jq -q

# Run Nova for Helm chart drift
NOVA_OUTPUT=$(/shared/nova find --helm --format=json 2>/dev/null || echo '{"helm_releases":[]}')

# Parse Nova output into Discord embed fields
OUTDATED=$(echo "$NOVA_OUTPUT" | jq -r '[.helm_releases[] | select(.outdated == true)] | ...')
DEPRECATED=$(echo "$NOVA_OUTPUT" | jq -r '[.helm_releases[] | select(.deprecated == true)] | ...')

# Build Discord embed JSON and send
# (full jq template in the ConfigMap — builds embeds array, sends via curl)
curl -s -X POST "$DISCORD_WEBHOOK_URL" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD"
```

### RBAC for CronJob

Nova needs to read Helm release secrets and pod information:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: version-check-cronjob
rules:
  # Helm stores releases as secrets (driver=secrets, default)
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "list"]
  # Nova --containers needs pod read (optional, not using in CronJob)
  # Keeping minimal: Helm chart drift only
```

### Resource Limits (CronJob)

| Resource | Request | Limit |
|----------|---------|-------|
| CPU | 50m | 200m |
| Memory | 64Mi | 256Mi |

### 1Password Items

```bash
# Add to existing "Discord Webhook" item, or create new one
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
# Check all Helm releases vs upstream (install nova first: brew install fairwindsops/tap/nova)
KUBECONFIG=~/.kube/homelab.yaml nova find --helm --format table

# Show only outdated Helm charts
KUBECONFIG=~/.kube/homelab.yaml nova find --helm --format table --show-old

# Check container images too
KUBECONFIG=~/.kube/homelab.yaml nova find --containers --format table

# JSON output for scripting
KUBECONFIG=~/.kube/homelab.yaml nova find --helm --format json | jq '.helm_releases[] | select(.outdated == true)'

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
# On EACH control plane node (one at a time):
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

## Future GitOps Compatibility

> This section documents what changes when ArgoCD or FluxCD is adopted (planned post-Phase 6 CKA).

### What Stays As-Is

| Component | Why |
|-----------|-----|
| **Renovate** | Already GitOps-native — opens PRs, you merge, GitOps controller syncs. Zero changes needed. |
| **version-checker** | Deployment with Prometheus metrics. GitOps-neutral — works with any deployment method. |
| **Grafana dashboard ConfigMap** | Just a ConfigMap — ArgoCD/Flux will manage it like any other manifest. |
| **Upgrade runbook** | Documentation — deployment method doesn't change upgrade procedures. |

### What Changes

| Component | Current | With GitOps |
|-----------|---------|-------------|
| **Renovate config** | `kubernetes` manager only | Add `argocd` or `flux` manager to track `Application`/`HelmRelease` CRDs |
| **Helm chart tracking** | Not in Git (installed imperatively) | Declare `HelmRelease` CRDs (Flux) or `Application` manifests (Argo) — Renovate can then track chart versions |
| **CronJob digest** | Nova checks cluster-side Helm drift | May become redundant if all Helm releases are declared in Git (Renovate covers them) |
| **Discord notifications** | CronJob + webhook | ArgoCD Notifications or Flux Notification Controller — native event-driven alerts |
| **kubectl apply workflow** | Manual `kubectl apply` after merging Renovate PR | Automatic — merge PR triggers sync |

### Migration Path

1. **Adopt ArgoCD/FluxCD** (Phase post-CKA)
2. **Convert Helm releases to Git-declared CRDs** (`HelmRelease` for Flux or `Application` for Argo)
3. **Update `renovate.json`** — add `argocd` or `flux` manager with `managerFilePatterns`
4. **Evaluate CronJob** — if all versions are now tracked in Git, the Nova CronJob may only be needed for drift detection (Git vs cluster)
5. **Replace CronJob Discord** with GitOps-native notifications

> **Design principle:** Keep the CronJob simple and easily replaceable. Don't over-invest in it — it's a bridge to GitOps-native notifications.

---

## Files to Create

| File | Type | Purpose |
|------|------|---------|
| `renovate.json` | Config | Renovate Bot configuration (repo root) |
| `manifests/monitoring/version-checker-deployment.yaml` | Deployment + Service | version-checker with `--test-all-containers` |
| `manifests/monitoring/version-checker-rbac.yaml` | RBAC | ClusterRole + ClusterRoleBinding + ServiceAccount |
| `manifests/monitoring/version-checker-servicemonitor.yaml` | ServiceMonitor | Prometheus scrape config (1h interval) |
| `manifests/monitoring/version-checker-alerts.yaml` | PrometheusRule | ContainerImageOutdated + KubernetesVersionOutdated + VersionCheckerDown |
| `manifests/monitoring/version-checker-dashboard-configmap.yaml` | ConfigMap | Grafana dashboard (downloaded from #12833) |
| `manifests/monitoring/version-check-cronjob.yaml` | CronJob | Weekly Discord digest (Nova init container + alpine) |
| `manifests/monitoring/version-check-script.yaml` | ConfigMap | Version check shell script |
| `manifests/monitoring/version-check-rbac.yaml` | RBAC | ClusterRole + ClusterRoleBinding + ServiceAccount for CronJob |
| `docs/context/Upgrades.md` | Documentation | Upgrade/rollback runbook per component |

## Files to Modify

| File | Change |
|------|--------|
| `docs/context/_Index.md` | Add Upgrades.md to Quick Links table |
| ARR stack deployments | Add `match-regex` annotations for linuxserver.io images |
| ARR stack deployments | Pin `:latest` tags to version tags (prerequisite) |

---

## Tasks

### 4.27.0 Prerequisites

- [x] 4.27.0.1 Pin linuxserver.io images to version tags:
  - `bazarr:v1.5.5-ls338`, `radarr:6.0.4.10291-ls293`, `sonarr:4.0.16.2944-ls303`, `firefox:1147.0.3build1-1xtradeb1.2404.1-ls69`
- [x] 4.27.0.2 ~~Pin `byparr` to version tag~~ — byparr only publishes `latest`/`main`/`nightly` tags (no semver). Added to Renovate ignore list instead.
- [x] 4.27.0.3 Add `match-regex` version-checker annotations to linuxserver.io deployments
- [x] 4.27.0.4 Apply updated manifests and verify pods restart successfully

### 4.27.1 Install Renovate Bot

- [x] 4.27.1.1 Install [Renovate GitHub App](https://github.com/apps/renovate) on `rommelporras/homelab` repo (Mend registration + Renovate Only + Scan and Alert)
- [ ] 4.27.1.2 Close the auto-generated onboarding PR (our `renovate.json` is already in repo)
- [x] 4.27.1.3 Create `renovate.json` with homelab config (corrected `managerFilePatterns`, `ignorePaths`, package rules, byparr ignore)
- [ ] 4.27.1.4 Verify Renovate creates Dependency Dashboard issue
- [ ] 4.27.1.5 Verify Renovate detects images in `manifests/` (check Dashboard issue lists discovered dependencies)
- [x] 4.27.1.6 Commit `renovate.json` (will be committed with infra changes)

### 4.27.2 Deploy version-checker

- [x] 4.27.2.1 Create `manifests/monitoring/version-checker-rbac.yaml`
  - ServiceAccount, ClusterRole (pods + deployments read), ClusterRoleBinding
- [x] 4.27.2.2 Create `manifests/monitoring/version-checker-deployment.yaml`
  - Image: `quay.io/jetstack/version-checker:v0.10.0`
  - Args: `--test-all-containers` (scan all pods without annotation opt-in)
  - Port 8080, readiness/liveness on `/readyz`
  - Security context: runAsUser 65534 (image runs as root, must set explicit UID), drop ALL, readOnlyRootFilesystem
  - Resource limits: 50m/100m CPU, 64Mi/128Mi memory
- [x] 4.27.2.3 Create `manifests/monitoring/version-checker-servicemonitor.yaml`
  - Scrape interval: 1h (no need for frequent checks)
- [x] 4.27.2.4 Create `manifests/monitoring/version-checker-alerts.yaml`
  - Alert: `ContainerImageOutdated` (fires after 7d outdated)
  - Alert: `KubernetesVersionOutdated` (fires after 14d, severity: info)
  - Alert: `VersionCheckerDown` (fires after 15m)
- [x] 4.27.2.5 Download Grafana dashboard #12833 JSON and create `manifests/monitoring/version-checker-dashboard-configmap.yaml`
  - Labels: `grafana_dashboard: "1"`, `app.kubernetes.io/part-of: kube-prometheus-stack`
- [x] 4.27.2.6 Applied all manifests
- [x] 4.27.2.7 Verified pod running
- [x] 4.27.2.8 Verified metrics exposed (both container and K8s version metrics working)
- [ ] 4.27.2.9 Verify Grafana dashboard shows data (allow 1h for first scrape)

### 4.27.3 Create Discord Webhook

- [x] 4.27.3.1 Create `#versions` channel in Discord server (under Notification group)
- [x] 4.27.3.2 Create webhook: Server Settings → Integrations → Create Webhook → select channel
- [x] 4.27.3.3 Store webhook URL in 1Password (`Discord Webhook Versions` → `credential` field):
  ```bash
  op item create \
    --vault "Kubernetes" \
    --category "Login" \
    --title "Discord Webhook" \
    --field "version-alerts-url=<webhook-url>"
  ```
- [x] 4.27.3.4 Create K8s Secret:
  ```bash
  kubectl-homelab -n monitoring create secret generic discord-webhook \
    --from-literal=webhook-url="$(op read 'op://Kubernetes/Discord Webhook/version-alerts-url')"
  ```
- [x] 4.27.3.5 Test webhook manually:
  ```bash
  curl -X POST "$(op read 'op://Kubernetes/Discord Webhook/version-alerts-url')" \
    -H "Content-Type: application/json" \
    -d '{"embeds":[{"title":"Test","description":"Version check webhook working","color":5763719}]}'
  ```

### 4.27.4 Deploy Version Check CronJob

- [x] 4.27.4.1 Create `manifests/monitoring/version-check-rbac.yaml`
  - ServiceAccount `version-check-cronjob`
  - ClusterRole: read secrets (Helm release data)
  - ClusterRoleBinding
- [x] 4.27.4.2 Create `manifests/monitoring/version-check-script.yaml` (ConfigMap with shell script)
  - Install curl + jq via apk (~3 seconds overhead)
  - Run `/shared/nova find --helm --format=json` for Helm chart drift
  - Parse JSON with jq: extract outdated and deprecated charts
  - Build Discord embed JSON (yellow=outdated, red=deprecated, green=summary)
  - Send via curl to `$DISCORD_WEBHOOK_URL`
- [x] 4.27.4.3 Create `manifests/monitoring/version-check-cronjob.yaml`
  - Schedule: `0 0 * * 0` (Sunday 00:00 UTC = 08:00 PHT)
  - Init container: `quay.io/fairwinds/nova:v3.11.10` → copies `/usr/local/bin/nova` to `/shared/`
  - Main container: `alpine:3.21` → runs script from ConfigMap mount
  - Mount: script ConfigMap + Secret webhook URL + shared emptyDir
  - `activeDeadlineSeconds: 300`
  - Security context: runAsNonRoot (65534), drop ALL
- [x] 4.27.4.4 Applied manifests (CronJob created, awaiting Discord webhook secret)
  ```bash
  kubectl-homelab apply \
    -f manifests/monitoring/version-check-rbac.yaml \
    -f manifests/monitoring/version-check-script.yaml \
    -f manifests/monitoring/version-check-cronjob.yaml
  ```
- [x] 4.27.4.5 Trigger manual run to test:
  ```bash
  kubectl-homelab -n monitoring create job --from=cronjob/version-check version-check-manual
  kubectl-homelab -n monitoring logs job/version-check-manual -f
  ```
- [x] 4.27.4.6 Verify Discord message received (8 outdated, 0 deprecated, 6 current)

### 4.27.5 Write Upgrade Runbook

- [x] 4.27.5.1 Create `docs/context/Upgrades.md` with all component types, risk matrix, emergency rollback, service-specific warnings
- [x] 4.27.5.2 Update `docs/context/_Index.md` — add Upgrades.md to Quick Links

### 4.27.6 Install Nova CLI (Local)

- [x] 4.27.6.1 Install Nova on local machine (GitHub release binary to `~/.local/bin/nova`):
  ```bash
  curl -sL https://github.com/FairwindsOps/nova/releases/download/v3.11.10/nova_3.11.10_linux_amd64.tar.gz -o /tmp/nova.tar.gz
  tar xzf /tmp/nova.tar.gz -C /tmp nova && chmod +x /tmp/nova && mv /tmp/nova ~/.local/bin/nova
  ```
- [x] 4.27.6.2 Test (8 outdated charts found):
  ```bash
  KUBECONFIG=~/.kube/homelab.yaml nova find --helm --format table
  KUBECONFIG=~/.kube/homelab.yaml nova find --containers --format table
  ```

### 4.27.7 Security & Commit

- [x] 4.27.7.1 `/audit-security` — PASS (0 critical, 3 warnings, 7 info)
- [x] 4.27.7.2 `/commit` (infrastructure) — `f0f65ec`

### 4.27.8 Documentation & Release

> Second commit: documentation updates and audit.

- [x] 4.27.8.1 Update `docs/todo/README.md` — add Phase 4.27 to phase index + release mapping
- [x] 4.27.8.2 Update `README.md` (root) — add version-checker, Renovate, Nova to services list
- [x] 4.27.8.3 Update `VERSIONS.md` — add version-checker, Nova versions; pin bazarr/radarr/sonarr/firefox
- [x] 4.27.8.4 Update `docs/reference/CHANGELOG.md` — add version automation entry
- [x] 4.27.8.5 Update `docs/context/Monitoring.md` — add version-checker + CronJob + Renovate
- [x] 4.27.8.6 Update `docs/context/Secrets.md` — add Discord Webhook Versions 1Password item
- [x] 4.27.8.7 Create `docs/rebuild/v0.26.0-version-automation.md`
- [x] 4.27.8.8 `/audit-docs` — 6 issues in rebuild/README.md (all fixed)
- [x] 4.27.8.9 `/commit` (documentation) — `c67fe76`
- [x] 4.27.8.10 `/release v0.26.0 "Version Automation & Upgrade Runbooks"`
- [x] 4.27.8.11 Move this file to `docs/todo/completed/`

---

## Verification Checklist

- [ ] `:latest` images pinned to version tags (prerequisite)
- [ ] linuxserver.io deployments have `match-regex` annotations
- [ ] Renovate GitHub App installed and creating Dependency Dashboard issue
- [ ] Renovate detects image tags in `manifests/` YAML files
- [ ] version-checker pod running in `monitoring` namespace with `--test-all-containers`
- [ ] version-checker Prometheus metrics visible (`version_checker_is_latest_version`)
- [ ] version-checker Kubernetes version metric visible (`version_checker_is_latest_kube_version`)
- [ ] Grafana dashboard ConfigMap deployed and showing data
- [ ] `ContainerImageOutdated` PrometheusRule created
- [ ] `KubernetesVersionOutdated` PrometheusRule created
- [ ] Discord webhook test message received
- [ ] Weekly CronJob runs and sends Discord digest with Nova output
- [ ] Nova CLI works locally (`nova find --helm --format table`)
- [ ] `docs/context/Upgrades.md` complete with all component types
- [ ] Pre-upgrade checklist documented

---

## Rollback

```bash
# Remove version-checker
kubectl-homelab delete deployment version-checker -n monitoring
kubectl-homelab delete service version-checker -n monitoring
kubectl-homelab delete servicemonitor version-checker -n monitoring
kubectl-homelab delete prometheusrule version-checker-alerts -n monitoring
kubectl-homelab delete configmap version-checker-dashboard -n monitoring
kubectl-homelab delete clusterrole version-checker
kubectl-homelab delete clusterrolebinding version-checker
kubectl-homelab delete serviceaccount version-checker -n monitoring

# Remove CronJob
kubectl-homelab delete cronjob version-check -n monitoring
kubectl-homelab delete configmap version-check-script -n monitoring
kubectl-homelab delete clusterrole version-check-cronjob
kubectl-homelab delete clusterrolebinding version-check-cronjob
kubectl-homelab delete serviceaccount version-check-cronjob -n monitoring
kubectl-homelab delete secret discord-webhook -n monitoring

# Renovate: disable via GitHub App settings (no cluster changes)
# Nova: just a local CLI binary, uninstall via brew
```

---

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Renovate over Dependabot | Renovate | Better K8s manifest support (`managerFilePatterns`), weekly grouping, dependency dashboard. Dependabot has no K8s manifest support. |
| version-checker over custom script | version-checker | Maintained project (v0.10.0, Nov 2025), Prometheus-native, includes K8s version tracking |
| `--test-all-containers` over annotations | Flag | Simpler — no need to annotate every pod. Can still use `match-regex` per-image for non-standard tags. |
| CronJob uses Nova over custom shell | Nova | Nova handles Helm chart + container version comparison, outputs JSON. Eliminates brittle bash semver parsing, `helm search repo` in-pod, and GitHub API rate limits. |
| `alpine:3.21` over `dwdraju/alpine-curl-jq` | Official Alpine | `dwdraju/alpine-curl-jq` is an unmaintained personal image (6 commits, no verified publisher). It's literally `alpine + apk add curl jq bash`. Use the official base directly. |
| Init container for Nova binary | Init container pattern | Avoids building a custom image. Nova official image copies binary to shared emptyDir. CKA-relevant pattern. |
| No upgrade registry ConfigMap | Removed | Static warning text belongs in `docs/context/Upgrades.md` runbook, not in a ConfigMap that a script reads. Simpler, easier to maintain. |
| No `helm-values` Renovate manager | Removed | Our `helm/*/values.yaml` contain chart config only (replicas, features) — no Docker image references. Nothing for Renovate to detect. |
| `ignorePaths` in Renovate | Added | Prevents scanning `ansible/`, `docs/`, `scripts/` — only `manifests/` has container images. |
| Pin `:latest` as prerequisite | Required | Without version tags, Renovate skips silently, version-checker falls back to SHA comparison. ~20% of images invisible otherwise. |
| Renovate major PR separation | One PR per major bump | Each major bump needs individual review, not grouped with safe patches |
| Namespace | monitoring | Operational tooling, co-located with Prometheus/Grafana |
| Discord over email | Discord | Already use Discord for alerts, richer formatting (embeds) |
| GitOps-forward design | Documented migration path | CronJob kept simple and replaceable. Renovate is already GitOps-ready. Clear notes on what changes with ArgoCD/FluxCD. |

---

## CKA Learnings

| Topic | Concept |
|-------|---------|
| CronJob | Scheduled workload with history limits, active deadlines, manual triggers via `--from=cronjob` |
| Init containers | Copy binary from one image to shared emptyDir for use in main container |
| RBAC | ClusterRole for cross-namespace pod read (version-checker) + Helm secret read (CronJob) |
| ServiceAccount | Dedicated SA per workload with minimal permissions |
| ConfigMap | Mounting shell scripts as ConfigMap volumes |
| Secret | Discord webhook URL stored as K8s Secret (from 1Password) |
| ServiceMonitor | Custom Prometheus scrape config for version-checker (1h interval) |
| PrometheusRule | Alert on version drift (7-day threshold), K8s version (14-day), and service health |
| emptyDir volumes | Shared writable volume between init and main containers (ephemeral) |

---

## Research Sources

| Topic | Source |
|-------|--------|
| Renovate GitHub App | [github.com/apps/renovate](https://github.com/apps/renovate) |
| Renovate K8s manager | [docs.renovatebot.com/modules/manager/kubernetes](https://docs.renovatebot.com/modules/manager/kubernetes/) |
| Renovate `managerFilePatterns` | [docs.renovatebot.com/configuration-options/#managerfilepatterns](https://docs.renovatebot.com/configuration-options/#managerfilepatterns) |
| Renovate ArgoCD manager | [docs.renovatebot.com/modules/manager/argocd](https://docs.renovatebot.com/modules/manager/argocd/) |
| Renovate FluxCD manager | [docs.renovatebot.com/modules/manager/flux](https://docs.renovatebot.com/modules/manager/flux/) |
| Renovate noise reduction | [docs.renovatebot.com/noise-reduction](https://docs.renovatebot.com/noise-reduction/) |
| version-checker | [github.com/jetstack/version-checker](https://github.com/jetstack/version-checker) |
| version-checker v0.10.0 (K8s version) | [github.com/jetstack/version-checker/releases/tag/v0.10.0](https://github.com/jetstack/version-checker/releases/tag/v0.10.0) |
| version-checker Grafana dashboard | [Grafana #12833](https://grafana.com/grafana/dashboards/12833-version-checker/) |
| version-checker annotations | [github.com/jetstack/version-checker#annotations](https://github.com/jetstack/version-checker#annotations) |
| Fairwinds Nova | [github.com/FairwindsOps/nova](https://github.com/FairwindsOps/nova) |
| Nova docs | [nova.docs.fairwinds.com](https://nova.docs.fairwinds.com/) |
| Nova v3.11.10 | [github.com/FairwindsOps/nova/releases/tag/v3.11.10](https://github.com/FairwindsOps/nova/releases/tag/v3.11.10) |
| Discord webhooks guide | [birdie0.github.io/discord-webhooks-guide](https://birdie0.github.io/discord-webhooks-guide/) |
| Discord embed colors | [gist.github.com/thomasbnt](https://gist.github.com/thomasbnt/b6f455e2c7d743b796917fa3c205f812) |
| ArgoCD Notifications | [argo-cd.readthedocs.io/en/stable/operator-manual/notifications](https://argo-cd.readthedocs.io/en/stable/operator-manual/notifications/) |
| Flux Notification Controller | [fluxcd.io/flux/components/notification](https://fluxcd.io/flux/components/notification/) |
