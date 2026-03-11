# Phase 4.31: Cluster Janitor + Discord Notification Restructure

> **Status:** ✅ Complete (ready for commit + release)
> **Target:** v0.28.2
> **Prerequisite:** None (fix release)
> **DevOps Topics:** CronJob, RBAC, cluster self-healing, alert routing
> **CKA Topics:** CronJob, ServiceAccount, ClusterRole, ClusterRoleBinding

> **Purpose:** Automate recurring cluster cleanup and restructure Discord notifications for signal over noise
>
> **Learning Goal:** Understand CronJob scheduling, RBAC scoping, alert routing, and defensive cluster automation
>
> **Note:** Longhorn settings tasks (4.31.3) supersede Phase 5.5.4 tasks 5.5.4.1 and 5.5.4.2.
> Phase 5.5.4.3 (manual recovery docs) and 5.5.4.4 (replica-soft-anti-affinity check) remain in Phase 5.

---

## Why This Matters

Every hard crash or power outage produces the same manual cleanup:

| Problem | Manual Fix | Frequency (last 7d) |
|---------|-----------|---------------------|
| Failed pods (UnexpectedAdmissionError) | `kubectl delete pods --field-selector=status.phase=Failed` | Every crash |
| Longhorn stopped replicas | Find + delete stopped replicas one by one | 12 LonghornVolumeDegraded alerts |
| Noisy Discord #status channel | 50+ warning types + MySpeed speedtests mixed together | Constant |

A single CronJob (`cluster-janitor`) running every 10 minutes eliminates the first two.
Restructured Discord channels eliminate the third.

---

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  CronJob: cluster-janitor (every 10 min)            │
│  Namespace: kube-system                             │
│  Image: alpine/k8s:1.35.0 (verify curl)        │
│                                                     │
│  Tasks:                                             │
│  1. Delete Failed pods (all namespaces)             │
│  2. Delete stopped Longhorn replicas                │
│     (only if volume has ≥1 healthy replica)         │
│  3. Post cleanup summary to Discord #janitor        │
│     (only when something was cleaned)               │
│                                                     │
│  RBAC: cluster-janitor ServiceAccount               │
│  ClusterRole: delete pods, get/delete replicas      │
└─────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────┐
│  Discord Channel Restructure                        │
│                                                     │
│  #incidents → severity: critical (unchanged)        │
│  #infra     → infra warnings (Longhorn, NVMe, etc.) │
│  #apps      → app warnings (renamed from #status)  │
│  #janitor   → cleanup summaries (new)               │
│  #speedtest → MySpeed results (moved from #status)  │
│  #versions  → weekly Helm drift (unchanged)         │
│  #arr       → media events (unchanged)              │
└─────────────────────────────────────────────────────┘
```

---

## Pre-work (completed)

- [x] 4.31.0.1 Discord channels created: `#infra`, `#janitor`, `#speedtest`
- [x] 4.31.0.2 `#status` renamed to `#apps` (existing webhook preserved)
- [x] 4.31.0.3 1Password consolidated: 3 items → 1 "Discord Webhooks" item with 6 fields
  - `op://Kubernetes/Discord Webhooks/{incidents,infra,apps,janitor,speedtest,versions}`
  - Old items (`Discord Webhook Incidents`, `Discord Webhook Status`, `Discord Webhook Versions`) deleted
- [x] 4.31.0.4 All 6 Discord webhooks tested and verified (test messages sent to each channel)

---

## Tasks

### 4.31.1 Create RBAC

- [x] 4.31.1.1 Create ServiceAccount, ClusterRole, ClusterRoleBinding
  ```yaml
  # manifests/kube-system/cluster-janitor/rbac.yaml
  apiVersion: v1
  kind: ServiceAccount
  metadata:
    name: cluster-janitor
    namespace: kube-system
  ---
  apiVersion: rbac.authorization.k8s.io/v1
  kind: ClusterRole
  metadata:
    name: cluster-janitor
  rules:
    # Task 1: Delete Failed pods
    - apiGroups: [""]
      resources: ["pods"]
      verbs: ["get", "list", "delete"]
    # Task 2: Get/delete Longhorn replicas, get volumes
    - apiGroups: ["longhorn.io"]
      resources: ["replicas"]
      verbs: ["get", "list", "delete"]
    - apiGroups: ["longhorn.io"]
      resources: ["volumes"]
      verbs: ["get", "list"]
  ---
  apiVersion: rbac.authorization.k8s.io/v1
  kind: ClusterRoleBinding
  metadata:
    name: cluster-janitor
  subjects:
    - kind: ServiceAccount
      name: cluster-janitor
      namespace: kube-system
  roleRef:
    kind: ClusterRole
    name: cluster-janitor
    apiGroup: rbac.authorization.k8s.io
  ```

### 4.31.2 Create CronJob

- [x] 4.31.2.1 Create the CronJob manifest

  **Image choice:** `alpine/k8s:1.35.0` — pinned to match cluster version. Verified: includes kubectl, curl, and bash.
  Note: `bitnami/kubectl` dropped version tags (only `latest` + SHA digests). `alpine/k8s` provides pinned versions with kubectl + curl + bash.

  ```yaml
  # manifests/kube-system/cluster-janitor/cronjob.yaml
  apiVersion: batch/v1
  kind: CronJob
  metadata:
    name: cluster-janitor
    namespace: kube-system
  spec:
    schedule: "*/10 * * * *"
    concurrencyPolicy: Forbid
    successfulJobsHistoryLimit: 1
    failedJobsHistoryLimit: 3
    jobTemplate:
      spec:
        backoffLimit: 0
        activeDeadlineSeconds: 120
        template:
          metadata:
            labels:
              app: cluster-janitor
          spec:
            serviceAccountName: cluster-janitor
            restartPolicy: Never
            securityContext:
              runAsNonRoot: true
              runAsUser: 1000
              runAsGroup: 1000
            containers:
              - name: janitor
                image: alpine/k8s:1.35.0
                securityContext:
                  allowPrivilegeEscalation: false
                  capabilities:
                    drop: ["ALL"]
                  readOnlyRootFilesystem: true
                command: ["/bin/bash", "-c"]
                args:
                  - |
                    echo "=== Cluster Janitor $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
                    FAILED_PODS=0
                    STOPPED_REPLICAS=0

                    # Task 1: Delete Failed pods (UnexpectedAdmissionError, OOMKilled leftovers, etc.)
                    FAILED_PODS=$(kubectl get pods -A --field-selector=status.phase=Failed --no-headers 2>/dev/null | wc -l)
                    FAILED_PODS=${FAILED_PODS:-0}
                    if [ "$FAILED_PODS" -gt 0 ]; then
                      echo "[Task 1] Deleting $FAILED_PODS Failed pod(s)..."
                      kubectl delete pods -A --field-selector=status.phase=Failed || true
                    else
                      echo "[Task 1] No Failed pods found."
                    fi

                    # Task 2: Delete stopped Longhorn replicas (only if volume has ≥1 running replica)
                    echo "[Task 2] Checking for stopped Longhorn replicas..."
                    STOPPED_LIST=$(kubectl -n longhorn-system get replicas.longhorn.io \
                      -o jsonpath='{range .items[?(@.status.currentState=="stopped")]}{.metadata.name}{" "}{.spec.volumeName}{"\n"}{end}' 2>/dev/null || echo "")

                    if [ -n "$STOPPED_LIST" ]; then
                      # Use here-string (not pipe) to avoid subshell — variable updates persist
                      while read -r REPLICA VOLUME; do
                        [ -z "$REPLICA" ] && continue
                        # Count running replicas for this volume
                        RUNNING=$(kubectl -n longhorn-system get replicas.longhorn.io \
                          -l longhornvolume="$VOLUME" \
                          -o jsonpath='{range .items[?(@.status.currentState=="running")]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -c . || true)
                        RUNNING=${RUNNING:-0}
                        if [ "$RUNNING" -ge 1 ]; then
                          echo "  Deleting stopped replica $REPLICA (volume $VOLUME has $RUNNING healthy replica(s))"
                          kubectl -n longhorn-system delete replicas.longhorn.io "$REPLICA" || true
                          STOPPED_REPLICAS=$((STOPPED_REPLICAS + 1))
                        else
                          echo "  SKIPPING $REPLICA — volume $VOLUME has 0 running replicas (last replica with data)"
                        fi
                      done <<< "$STOPPED_LIST"
                    else
                      echo "[Task 2] No stopped replicas found."
                    fi

                    # Task 3: Post summary to Discord #janitor (only if something was cleaned)
                    TOTAL=$((FAILED_PODS + STOPPED_REPLICAS))
                    if [ "$TOTAL" -gt 0 ] && [ -f /etc/janitor/webhook-url ]; then
                      WEBHOOK_URL=$(cat /etc/janitor/webhook-url)
                      SUMMARY="Cluster Janitor cleaned ${FAILED_PODS} failed pod(s), ${STOPPED_REPLICAS} stopped replica(s)"
                      echo "[Task 3] Posting to Discord: $SUMMARY"
                      curl -sf -H "Content-Type: application/json" \
                        -d "{\"content\":\"**$SUMMARY** at $(date -u +%H:%M) UTC\"}" \
                        "$WEBHOOK_URL" || echo "  Warning: Discord notification failed"
                    fi

                    echo "=== Janitor complete ==="
                volumeMounts:
                  - name: discord-webhook
                    mountPath: /etc/janitor
                    readOnly: true
                resources:
                  requests:
                    cpu: 10m
                    memory: 32Mi
                  limits:
                    cpu: 100m
                    memory: 64Mi
            volumes:
              - name: discord-webhook
                secret:
                  secretName: discord-janitor-webhook
  ```

  **Script design notes:**
  - No `set -euo pipefail` — each task is independent, one failure shouldn't abort others
  - `|| true` after destructive commands — prevents exit on partial failures
  - Here-string (`<<< "$STOPPED_LIST"`) instead of pipe — avoids subshell, so `$STOPPED_REPLICAS` persists
  - `${VAR:-0}` default — protects against empty/whitespace from `wc -l` or `grep -c`
  - Discord post is conditional — zero noise when nothing is cleaned
  - `curl -sf` — silent + fail on HTTP errors, with fallback echo

### 4.31.3 Longhorn Settings Changes

These don't fix stopped replicas (the CronJob does) but improve overall crash recovery.
**Must also update `helm/longhorn/values.yaml`** to persist across Helm upgrades.

- [x] 4.31.3.1 Change `node-down-pod-deletion-policy` to `delete-both-statefulset-and-deployment-pod`
  ```bash
  # Apply immediately
  kubectl-homelab -n longhorn-system patch settings node-down-pod-deletion-policy \
    --type merge -p '{"value":"delete-both-statefulset-and-deployment-pod"}'
  ```
  - Allows Longhorn to force-delete pods stuck on a down node
  - Pods reschedule faster → volumes reattach sooner

- [x] 4.31.3.2 Enable `orphan-resource-auto-deletion`
  ```bash
  kubectl-homelab -n longhorn-system patch settings orphan-resource-auto-deletion \
    --type merge -p '{"value":"replica-data;instance"}'
  ```
  - `replica-data`: cleans up orphaned replica data directories on NVMe after crashes
  - `instance`: cleans up orphaned engine/replica runtime instances
  - Value is a semicolon-separated list (NOT a boolean)

- [x] 4.31.3.3 Update `helm/longhorn/values.yaml` to persist settings
  ```yaml
  # Add to defaultSettings section:
  defaultSettings:
    nodeDownPodDeletionPolicy: delete-both-statefulset-and-deployment-pod
    orphanResourceAutoDeletion: "replica-data;instance"
  ```
  **Note:** `nodeDownPodDeletionPolicy` (node goes **down**) ≠ `nodeDrainPolicy` (node is **drained**). These are different Longhorn settings.
  - Without this, a `helm upgrade` would revert to defaults

### 4.31.4 Observability

- [x] 4.31.4.1 Add PrometheusRule for janitor failures
  ```yaml
  # manifests/monitoring/alerts/cluster-janitor-alerts.yaml
  apiVersion: monitoring.coreos.com/v1
  kind: PrometheusRule
  metadata:
    name: cluster-janitor-alerts
    namespace: monitoring
    labels:
      release: prometheus
  spec:
    groups:
      - name: cluster-janitor
        rules:
          - alert: ClusterJanitorFailing
            expr: |
              kube_job_failed{namespace="kube-system", job_name=~"cluster-janitor-.*"} > 0
            for: 30m
            labels:
              severity: warning
            annotations:
              summary: "Cluster Janitor CronJob has been failing for 30+ minutes"
              description: "The cluster-janitor CronJob in kube-system has failed jobs. Check logs: kubectl logs -n kube-system -l app=cluster-janitor --tail=50"
  ```

### 4.31.5 Discord Notification Restructure

**Problem:** `#status` was a firehose — 50+ warning alert types, MySpeed speedtests every 4h, and cluster janitor would add more noise. No separation between infrastructure and application issues.

**Channel layout (channels and webhooks already created — see Pre-work):**

| Channel | Purpose | Alert Routing |
|---------|---------|---------------|
| #incidents | Critical production issues (unchanged) | `severity: critical` |
| #infra | Infrastructure warnings (new) | Longhorn, NVMe, etcd, kube-vip, cert, node, UPS alerts |
| #apps | Application warnings (renamed from #status) | Service down/up, high memory, restarts, queue stalls |
| #janitor | Cluster janitor activity (new) | CronJob cleanup summaries (only when it cleans) |
| #speedtest | MySpeed results (new) | Move MySpeed webhook here |
| #versions | Weekly Helm drift (unchanged) | Nova CronJob |
| #arr | ARR media events (unchanged) | Sonarr/Radarr app webhooks |

#### 4.31.5.1 Update Alertmanager routing

Update `helm/prometheus/values.yaml` alertmanager config:

```yaml
# Receivers (replace discord-status with infra + apps)
receivers:
  - name: discord-incidents-email
    discord_configs:
      - webhook_url: 'SET_VIA_HELM'  # op://Kubernetes/Discord Webhooks/incidents
        send_resolved: true
    email_configs:
      # ... unchanged ...
  - name: discord-infra
    discord_configs:
      - webhook_url: 'SET_VIA_HELM'  # op://Kubernetes/Discord Webhooks/infra
        send_resolved: true
  - name: discord-apps
    discord_configs:
      - webhook_url: 'SET_VIA_HELM'  # op://Kubernetes/Discord Webhooks/apps
        send_resolved: true

# Routes — split warnings by label matching
route:
  routes:
    # ... existing silenced routes (KubeProxyDown, etcdInsufficient, etc.) ...
    - match:
        severity: critical
      receiver: discord-incidents-email
    # Infrastructure warnings
    - match:
        severity: warning
      match_re:
        alertname: '(Longhorn.*|NVMe.*|etcd.*|KubeVip.*|Certificate.*|Node.*|UPS.*|NetworkInterface.*|KubePersistent.*|SmartCTL.*|KubeApiserver.*|CPUThrottling.*|Alloy.*|Loki.*|ClusterJanitor.*)'
      receiver: discord-infra
    # Application warnings (everything else — catch-all for warnings)
    - match:
        severity: warning
      receiver: discord-apps
```

**Infra alert regex explained:** Matches infrastructure concerns — storage (Longhorn, NVMe, SmartCTL, KubePersistent), networking (KubeVip, NetworkInterface), control plane (etcd, KubeApiserver), security (Certificate), power (UPS), logging (Loki, Alloy), resource (CPUThrottling), and the janitor itself (ClusterJanitor). Everything else is an application concern.

- [x] 4.31.5.1.1 Update `helm/prometheus/values.yaml` with new receivers and routes (done in pre-work)
  - Added `discord-infra` and `discord-apps` receivers (replaced `discord-status`)
  - Added infra regex route for warning alerts (Longhorn, NVMe, Loki, Alloy, certs, nodes, UPS, etc.)
  - Default route changed from `discord-status` → `discord-apps`
- [x] 4.31.5.1.2 Update `scripts/upgrade-prometheus.sh` with new `op://` paths (done in pre-work)
  - Changed `Discord Webhook Incidents/credential` → `Discord Webhooks/incidents`
  - Changed `Discord Webhook Status/credential` → `Discord Webhooks/apps`
  - Added `discord-infra` receiver with `Discord Webhooks/infra`
  - Removed old `discord-status` receiver references
- [x] 4.31.5.1.3 Run Helm upgrade with new webhook URLs (requires safe terminal for `op read`)

#### 4.31.5.2 Create janitor webhook Secret

- [x] 4.31.5.2.1 Create `discord-janitor-webhook` Secret in `kube-system`
  ```bash
  # In safe terminal:
  kubectl-homelab create secret generic discord-janitor-webhook \
    -n kube-system \
    --from-literal=webhook-url="$(op read 'op://Kubernetes/Discord Webhooks/janitor')"
  ```

#### 4.31.5.3 Move MySpeed webhook

- [x] 4.31.5.3.1 In MySpeed web UI (Settings → Notifications → Discord):
  - Replace the webhook URL with the `#speedtest` channel webhook
  - Read from 1Password: `op read "op://Kubernetes/Discord Webhooks/speedtest"`
  - This is stored in MySpeed's internal SQLite config, not a K8s Secret

#### 4.31.5.4 Update Version Check CronJob webhook (if needed)

The `#versions` webhook URL didn't change (same channel, same webhook). The only change is the 1Password path. The `discord-webhook` Secret in `monitoring` namespace already has the correct URL. **No action needed unless the Secret was deleted.**

### 4.31.6 Testing

- [x] 4.31.6.1 Deploy and verify RBAC
  ```bash
  kubectl-homelab apply -f manifests/kube-system/cluster-janitor/rbac.yaml

  # Verify permissions
  kubectl-homelab auth can-i delete pods --all-namespaces \
    --as=system:serviceaccount:kube-system:cluster-janitor
  kubectl-homelab auth can-i delete replicas.longhorn.io -n longhorn-system \
    --as=system:serviceaccount:kube-system:cluster-janitor
  kubectl-homelab auth can-i delete deployments --all-namespaces \
    --as=system:serviceaccount:kube-system:cluster-janitor
  # Last one should be "no" — verify least privilege
  ```

- [x] 4.31.6.2 Deploy CronJob and trigger manual run
  ```bash
  kubectl-homelab apply -f manifests/kube-system/cluster-janitor/cronjob.yaml

  # Trigger immediate run
  kubectl-homelab create job --from=cronjob/cluster-janitor cluster-janitor-test -n kube-system

  # Watch it
  kubectl-homelab logs -n kube-system -l app=cluster-janitor -f
  ```

- [x] 4.31.6.3 Verify safety guard
  ```bash
  # The janitor should NOT delete a stopped replica if it's the last one
  # Check logs for "SKIPPING" messages
  kubectl-homelab logs -n kube-system -l app=cluster-janitor --tail=20
  ```

- [x] 4.31.6.4 Verify Discord notification posts to #janitor
  ```bash
  # After a manual run that cleaned something, check #janitor channel
  # If nothing to clean, temporarily create a Failed pod to test:
  kubectl-homelab run test-fail --image=busybox --restart=Never -- /bin/false
  # Wait for it to fail, then trigger janitor
  kubectl-homelab create job --from=cronjob/cluster-janitor cluster-janitor-test2 -n kube-system
  ```

- [x] 4.31.6.5 Apply Longhorn settings changes (update Helm values FIRST, then kubectl patch for immediate effect)
  ```bash
  # 1. Update helm/longhorn/values.yaml (4.31.3.3) — persists across upgrades
  #    Add to defaultSettings section:
  #      nodeDownPodDeletionPolicy: delete-both-statefulset-and-deployment-pod
  #      orphanResourceAutoDeletion: "replica-data;instance"

  # 2. Apply immediately via kubectl patch (takes effect without Helm upgrade)
  kubectl-homelab -n longhorn-system patch settings node-down-pod-deletion-policy \
    --type merge -p '{"value":"delete-both-statefulset-and-deployment-pod"}'
  kubectl-homelab -n longhorn-system patch settings orphan-resource-auto-deletion \
    --type merge -p '{"value":"replica-data;instance"}'

  # 3. Verify
  kubectl-homelab -n longhorn-system get settings node-down-pod-deletion-policy -o jsonpath='{.value}'
  echo ""
  kubectl-homelab -n longhorn-system get settings orphan-resource-auto-deletion -o jsonpath='{.value}'
  ```

- [x] 4.31.6.6 Deploy alert rule and verify
  ```bash
  kubectl-homelab apply -f manifests/monitoring/alerts/cluster-janitor-alerts.yaml

  # Verify rule loaded
  kubectl-homelab exec -n monitoring prometheus-prometheus-kube-prometheus-prometheus-0 -- \
    promtool query instant http://localhost:9090 'ALERTS{alertname="ClusterJanitorFailing"}'
  ```

- [x] 4.31.6.7 Verify Alertmanager routing after Helm upgrade
  ```bash
  # Send a test alert to verify routing
  # Check that infra alerts go to #infra and app alerts go to #apps
  kubectl-homelab exec -n monitoring alertmanager-prometheus-kube-prometheus-alertmanager-0 -- \
    amtool alert query --alertmanager.url=http://localhost:9093
  ```

### 4.31.7 Update Documentation

- [x] 4.31.7.1 Update `docs/context/Secrets.md` (done in pre-work)
  - Replaced 3 Discord webhook items with 1 consolidated "Discord Webhooks" item
  - Updated all `op://` paths (6 fields)
  - **Still TODO:** Add `discord-janitor-webhook` Secret reference (kube-system namespace) after CronJob is deployed

- [x] 4.31.7.2 Update `docs/context/ExternalServices.md` (done in pre-work)
  - Documented new Discord channel layout (7 channels)
  - **Still TODO:** Document alert routing logic (infra regex vs catch-all apps) after Alertmanager is updated

- [x] 4.31.7.3 Update other docs referencing old Discord webhook items (done in pre-work)
  - Updated `docs/context/Monitoring.md`, `docs/context/Conventions.md`, `VERSIONS.md`
  - Updated `docs/rebuild/v0.5.0-alerting.md`, `v0.13.0-uptime-kuma.md`, `v0.16.0-myspeed.md`, `v0.26.0-version-automation.md`, `README.md`
  - Updated `docs/reference/CHANGELOG.md`
  - Updated `manifests/monitoring/alerts/test-alert.yaml`

- [x] 4.31.7.4 Update `docs/todo/phase-5-hardening.md`
  - Add note to 5.5.4.1 and 5.5.4.2: "Done in Phase 4.31 (v0.28.2)"
  - Keep 5.5.4.3 (manual recovery docs) and 5.5.4.4 (anti-affinity check) as-is

- [x] 4.31.7.5 Update `VERSIONS.md`
  - Add cluster-janitor CronJob entry

- [x] 4.31.7.6 Create `manifests/kube-system/cluster-janitor/secret.yaml` documentation placeholder
  - Per Secret File Convention: commented `kubectl create secret` command with `op://` reference
  - **Note:** `manifests/kube-system/` directory does not exist yet — create it

---

## Design Decisions

| Decision | Choice | Why |
|----------|--------|-----|
| Namespace | `kube-system` | Cluster-wide utility, not app-specific |
| Schedule | Every 10 min | Fast enough to clear alerts, not so frequent it's noisy |
| Image | `alpine/k8s:1.35.0` | Pinned version, matches cluster kubectl. Includes kubectl + curl + bash. |
| No `set -e` | Tasks are independent | One failure shouldn't abort others — partial cleanup is better than none |
| Safety guard | Skip if 0 running replicas | Never delete the last replica — data loss prevention |
| `concurrencyPolicy: Forbid` | Prevent overlapping runs | Avoids race conditions on replica deletion |
| `backoffLimit: 0` | Don't retry failures | If it fails, wait for next scheduled run |
| `successfulJobsHistoryLimit: 1` | Keep 1 successful job | Minimize pod clutter from the janitor itself |
| Discord split | #infra vs #apps | Infrastructure and application concerns have different audiences and urgency |
| 1Password consolidation | 1 item, 6 fields | Matches ARR Stack pattern — one service, multiple credentials |
| Janitor posts to #janitor | Only when it cleans | Zero noise — no "nothing to clean" messages |
| MySpeed → #speedtest | Dedicated channel | Stops polluting warning alerts with periodic speedtests |
| Persist Longhorn settings in Helm | `helm/longhorn/values.yaml` | kubectl patch is imperative — lost on `helm upgrade` |

---

## Future Expansion

The cluster-janitor pattern is designed to grow. Add new tasks to the script as needed:

| Task | Trigger | When to Add |
|------|---------|-------------|
| Delete orphaned PVCs | PVC bound but no pod mounting | Phase 5+ |
| Clean stale Helm secrets | `sh.helm.release.v1` secrets from failed upgrades | When Helm usage grows |
| Prune completed Jobs | CronJob pods older than 24h | When job count grows |
| Certificate expiry check | cert-manager certs nearing expiry | Phase 5+ |
| Node drain reminder | Node cordoned for >1h without drain | Maintenance automation |
| New Discord channel | New alert category emerges | Add field to "Discord Webhooks" 1Password item |

---

## Verification Checklist

- [x] Discord channels created (#infra, #janitor, #speedtest)
- [x] `#status` renamed to `#apps` (reuses existing webhook)
- [x] 1Password consolidated (3 items → 1 "Discord Webhooks" item with 6 fields)
- [x] All 6 Discord webhooks tested and verified
- [x] ServiceAccount created with least-privilege RBAC
- [x] CronJob deployed and running on schedule
- [x] Failed pods cleaned up automatically
- [x] Stopped Longhorn replicas cleaned up (with safety guard)
- [x] Safety guard verified — last replica is never deleted
- [x] Discord #janitor receives cleanup summaries
- [x] Longhorn `node-down-pod-deletion-policy` updated (kubectl + Helm values)
- [x] Longhorn `orphan-resource-auto-deletion` enabled (kubectl + Helm values)
- [x] PrometheusRule deployed and alert fires on failure
- [x] Alertmanager routes updated (warnings split to #infra and #apps)
- [x] `scripts/upgrade-prometheus.sh` updated with new `op://` paths and `discord-infra` receiver
- [x] All docs referencing old Discord webhook items updated (Secrets, ExternalServices, Monitoring, Conventions, VERSIONS, rebuild guides, CHANGELOG, test-alert.yaml)
- [x] MySpeed webhook moved to #speedtest
- [x] `discord-janitor-webhook` Secret reference added to Secrets.md
- [x] `manifests/kube-system/cluster-janitor/secret.yaml` placeholder created
- [x] Phase 5.5.4 cross-referenced (4.31 supersedes 5.5.4.1 and 5.5.4.2)
- [x] Manual test run verified via `kubectl create job --from=cronjob/`

---

## Rollback

```bash
# Suspend the CronJob (doesn't delete, just stops scheduling)
kubectl-homelab patch cronjob cluster-janitor -n kube-system -p '{"spec":{"suspend":true}}'

# Or delete everything
kubectl-homelab delete -f manifests/kube-system/cluster-janitor/
kubectl-homelab delete -f manifests/monitoring/alerts/cluster-janitor-alerts.yaml

# Revert Longhorn settings (both kubectl and helm/longhorn/values.yaml)
kubectl-homelab -n longhorn-system patch settings node-down-pod-deletion-policy \
  --type merge -p '{"value":"do-nothing"}'
kubectl-homelab -n longhorn-system patch settings orphan-resource-auto-deletion \
  --type merge -p '{"value":""}'

# Revert Alertmanager (re-point all warnings back to #apps/old #status)
# Update helm/prometheus/values.yaml, run scripts/upgrade-prometheus.sh
```

---

## Final: Commit and Release

- [ ] Commit changes
  ```bash
  /commit
  ```

- [ ] Release v0.28.2
  ```bash
  /release v0.28.2 'Cluster Janitor + Discord Notification Restructure'
  ```

- [ ] Move this file to completed folder
  ```bash
  mv docs/todo/phase-4.31-cluster-janitor.md docs/todo/completed/
  ```
