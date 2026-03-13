# Phase 5.1: Control Plane Hardening

> **Status:** Planned
> **Target:** v0.31.0
> **Prerequisite:** Phase 5.0 (v0.30.0 — namespace & pod security in place)
> **DevOps Topics:** API server hardening, kubelet security, audit logging, CIS compliance, certificate lifecycle
> **CKA Topics:** API server flags, KubeletConfiguration, audit policy, certificate rotation

> **Purpose:** Harden the control plane components — API server, kubelet, controller-manager, scheduler
>
> **Learning Goal:** CIS Kubernetes Benchmark compliance for control plane — the foundation everything else rests on

---

## Rolling Update Strategy

> **ALL changes that touch static pod manifests or kubelet config are applied ONE NODE AT A TIME.**

| Order | Node | IP |
|-------|------|----|
| 1 | CP1 | 10.10.30.11 |
| 2 | CP2 | 10.10.30.12 |
| 3 | CP3 | 10.10.30.13 |

**Procedure:** CP1 change → lockout gate → CP2 change → lockout gate → CP3 change → lockout gate

**Why this is safe:**
- kube-vip VIP (10.10.30.10) fails over in ~2 seconds — always 2/3 nodes serving
- etcd quorum needs 2/3 — always maintained when only 1 node is down
- SSH access is independent of Kubernetes — even if API server crashes, SSH still works
- Backups are taken before every change — rollback is always `cp backup original`

**Abort criteria:** If CP1 change fails and revert doesn't fix within 5 minutes, **STOP** — do not touch CP2/CP3.

### Pre-flight: Verify access before ANY changes

Run this ONCE before starting. If any check fails, fix it first.
```bash
# 1. Verify SSH access to all 3 nodes (independent of Kubernetes)
ssh wawashi@10.10.30.11 "hostname && uptime"
ssh wawashi@10.10.30.12 "hostname && uptime"
ssh wawashi@10.10.30.13 "hostname && uptime"

# 2. Verify kubectl via VIP works
kubectl-homelab get nodes
kubectl-homelab get --raw /healthz

# 3. Verify kubectl via DIRECT node IPs works (bypass VIP — emergency fallback)
kubectl --kubeconfig ~/.kube/homelab.yaml --server https://10.10.30.11:6443 get --raw /healthz
kubectl --kubeconfig ~/.kube/homelab.yaml --server https://10.10.30.12:6443 get --raw /healthz
kubectl --kubeconfig ~/.kube/homelab.yaml --server https://10.10.30.13:6443 get --raw /healthz
```

> **Why direct-IP checks matter:** If kube-vip fails over during a change, `kubectl-homelab`
> (which uses the VIP) still works — but you can't tell WHICH node is serving. Direct-IP
> checks confirm each individual node's API server is healthy.

### Lockout gate (run between EVERY node)

**ALL checks must pass before touching the next node.** Copy-paste this block.
```bash
# === LOCKOUT GATE — do NOT proceed if any check fails ===

# 1. Can I still reach the cluster via VIP? (most important — this is how we work)
kubectl-homelab get nodes
kubectl-homelab get --raw /healthz

# 2. Are all 3 nodes Ready?
kubectl-homelab get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}'

# 3. Are kube-system pods healthy? (look for CrashLoopBackOff, Error, Pending)
kubectl-homelab get pods -n kube-system | grep -v Running | grep -v Completed

# 4. Can I still SSH to all 3 nodes? (escape hatch if kubectl breaks)
ssh wawashi@10.10.30.11 "echo CP1-OK"
ssh wawashi@10.10.30.12 "echo CP2-OK"
ssh wawashi@10.10.30.13 "echo CP3-OK"

# === If any check above fails: STOP. Rollback the last change. Do NOT touch next node. ===
```

### Emergency recovery (if locked out of kubectl)

If `kubectl-homelab` stops responding after a change, SSH is your escape hatch:
```bash
# SSH to the node you just changed (SSH is independent of Kubernetes)
ssh wawashi@10.10.30.1X

# Check what happened
sudo crictl ps -a | grep kube-apiserver    # Is API server running or crash-looping?
sudo journalctl -u kubelet --since "5 min ago" | tail -30  # Kubelet errors?

# Rollback API server manifest (most common issue)
sudo cp /etc/kubernetes/kube-apiserver.yaml.backup /etc/kubernetes/manifests/kube-apiserver.yaml
# Wait 30s, API server auto-restarts

# Rollback kubelet config
sudo cp /var/lib/kubelet/config.yaml.backup /var/lib/kubelet/config.yaml
sudo systemctl restart kubelet

# After rollback, verify from WSL
kubectl-homelab get nodes
```

> **Key insight:** You can NEVER lose SSH access from Kubernetes changes. SSH runs on the OS,
> not in the cluster. Even if all 3 API servers crash-loop simultaneously, SSH works.
> The only way to lose SSH is a network/firewall change (not in this phase's scope).

> **Note:** All SSH commands use `ssh wawashi@10.10.30.1X` (user is `wawashi`, not root).

> **Note:** Static pod changes auto-restart (kubelet watches `/etc/kubernetes/manifests/`).
> Kubelet config changes require `sudo systemctl restart kubelet`.

---

## 5.1.1 Pre-flight: kube-bench Baseline Scan

Run kube-bench as a Kubernetes Job to establish current CIS score before making changes.

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: kube-bench-baseline
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
          image: aquasec/kube-bench:v0.10.6
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

- [ ] 5.1.1.1 Run kube-bench on one CP node, capture baseline score
- [ ] 5.1.1.2 Document current FAIL/WARN items as the "before" baseline

---

## 5.1.2 Kubelet Hardening

Changes to `/var/lib/kubelet/config.yaml` (KubeletConfiguration) on each node, then `sudo systemctl restart kubelet`.

**Rolling: CP1 → verify → CP2 → verify → CP3**

> **Audit (2026-03-14):** kubeadm already sets `authentication.anonymous.enabled: false`,
> `authentication.webhook.enabled: true`, `authorization.mode: Webhook`, and
> `rotateCertificates: true` on all 3 nodes. Read-only port 10255 is already closed
> (connection refused). Only the settings below need to be added.

Settings to add:
```yaml
# Add to /var/lib/kubelet/config.yaml on each node
readOnlyPort: 0             # CIS 4.2.4 — explicitly disable (port already closed, but CIS requires explicit setting)
protectKernelDefaults: true  # CIS 4.2.6 — sysctl params verified present via Ansible 01-prerequisites.yml (2026-03-14)
eventRecordQPS: 5           # CIS 4.2.8 — set explicitly for CIS compliance
```

Settings to verify only (already set by kubeadm — do NOT re-add):
```yaml
# These should already exist in /var/lib/kubelet/config.yaml
authentication:
  anonymous:
    enabled: false          # CIS 4.2.1 — kubeadm default (NOT raw kubelet default)
  webhook:
    enabled: true           # CIS 4.2.5 — kubeadm default
authorization:
  mode: Webhook             # CIS 4.2.2 — kubeadm default (NOT raw kubelet default)
rotateCertificates: true    # CIS 4.2.11 — kubeadm default
```

- [ ] 5.1.2.1 SSH to CP1, verify kubeadm-managed settings are present, back up config
  ```bash
  ssh wawashi@10.10.30.11
  sudo grep -E 'anonymous|webhook|Webhook|rotateCertificates' /var/lib/kubelet/config.yaml
  sudo cp /var/lib/kubelet/config.yaml /var/lib/kubelet/config.yaml.backup
  ```

- [ ] 5.1.2.2 Add missing settings on CP1 (`readOnlyPort`, `protectKernelDefaults`, `eventRecordQPS`)

- [ ] 5.1.2.3 Restart kubelet on CP1: `sudo systemctl restart kubelet`

- [ ] 5.1.2.4 Verify CP1 from WSL (get nodes, get pods, cluster-info)

- [ ] 5.1.2.5 Verify kubelet security from another node:
  ```bash
  # Should return 401 Unauthorized (already blocked — verifying, not changing)
  ssh wawashi@10.10.30.12 "curl -sk https://10.10.30.11:10250/pods"
  # Read-only port should be closed (connection refused)
  ssh wawashi@10.10.30.12 "curl -s http://10.10.30.11:10255/pods --max-time 3"
  ```

- [ ] 5.1.2.6 **Run lockout gate** (see Rolling Update Strategy — all checks must pass before touching CP2)

- [ ] 5.1.2.7 Apply same changes to CP2, restart kubelet, verify, **run lockout gate**

- [ ] 5.1.2.8 Apply same changes to CP3, restart kubelet, verify, **run lockout gate**

**Rollback:** Restore from backup: `sudo cp /var/lib/kubelet/config.yaml.backup /var/lib/kubelet/config.yaml && sudo systemctl restart kubelet`

---

## 5.1.3 API Server Flag Hardening

Changes to `/etc/kubernetes/manifests/kube-apiserver.yaml` on each node. Static pod auto-restarts.

**Rolling: CP1 → verify → CP2 → verify → CP3**

Add to `spec.containers[0].command`:
```
--anonymous-auth=false                    # CIS 1.2.1 — disable anonymous requests
--profiling=false                         # CIS 1.2.18 — disable profiling endpoint
--audit-log-path=/var/log/kubernetes/audit/audit.log    # (Section 5.1.5)
--audit-policy-file=/etc/kubernetes/audit-policy.yaml   # (Section 5.1.5)
--audit-log-maxage=30                     # Rotate audit logs after 30 days
--audit-log-maxbackup=10                  # Keep 10 rotated files
--audit-log-maxsize=100                   # Max 100MB per file
```

> **Note on `--anonymous-auth=false`:** kubeadm default is `true`. Currently anonymous requests
> get 403 (RBAC blocks `system:anonymous`). With `--anonymous-auth=false`, they get 401 (rejected
> at the authentication layer instead). Health check endpoints (`/healthz`, `/readyz`, `/livez`)
> still work (handled before authentication). Verify after applying:
> - `kubectl-homelab` still works (uses client cert auth — unaffected)
> - kube-vip leader election works (uses ServiceAccount token — unaffected)
> - Prometheus API server scraping works (uses ServiceAccount token — unaffected)

> **Warning:** Do NOT add `--enable-admission-plugins` unless you know exactly which plugins are
> already enabled. kubeadm enables a default set. Adding this flag REPLACES the defaults,
> potentially breaking the cluster. Instead, verify defaults are correct:
> ```bash
> kubectl-homelab exec -n kube-system kube-apiserver-k8s-cp1 -- kube-apiserver --help 2>&1 | grep enable-admission
> ```

Volume mounts needed for audit logging (add in same step):
```yaml
volumeMounts:
  - name: audit-policy
    mountPath: /etc/kubernetes/audit-policy.yaml
    readOnly: true
  - name: audit-log
    mountPath: /var/log/kubernetes/audit
volumes:
  - name: audit-policy
    hostPath:
      path: /etc/kubernetes/audit-policy.yaml
      type: File
  - name: audit-log
    hostPath:
      path: /var/log/kubernetes/audit
      type: DirectoryOrCreate
```

> **RISK: This is the most dangerous step in Phase 5.1.** If the audit policy file is missing,
> malformed, or the volume mount path is wrong, the API server will crash-loop and not recover
> until the manifest is fixed. The rolling strategy protects you — only 1 node at a time — but
> validate everything before placing the manifest.

- [ ] 5.1.3.1 Create audit policy file on CP1 (see 5.1.5 for policy content — create this FIRST)

- [ ] 5.1.3.2 Create audit log directory: `sudo mkdir -p /var/log/kubernetes/audit`

- [ ] 5.1.3.3 **Validate prerequisites exist before touching the manifest:**
  ```bash
  ssh wawashi@10.10.30.11 "
    # Audit policy file must exist and be valid YAML
    sudo python3 -c 'import yaml; yaml.safe_load(open(\"/etc/kubernetes/audit-policy.yaml\"))' && echo 'AUDIT POLICY: OK' || echo 'AUDIT POLICY: INVALID'
    # Audit log directory must exist
    sudo test -d /var/log/kubernetes/audit && echo 'AUDIT DIR: OK' || echo 'AUDIT DIR: MISSING'
  "
  # BOTH must show OK before proceeding. If either fails, DO NOT edit the manifest.
  ```

- [ ] 5.1.3.4 Back up API server manifest on CP1:
  ```bash
  ssh wawashi@10.10.30.11 "sudo cp /etc/kubernetes/manifests/kube-apiserver.yaml /etc/kubernetes/kube-apiserver.yaml.backup"
  ```

- [ ] 5.1.3.5 Edit API server manifest on CP1 (add flags + volume mounts)
  > **Tip:** Edit the backup copy first, validate it, then move it into place:
  > ```bash
  > ssh wawashi@10.10.30.11
  > sudo cp /etc/kubernetes/kube-apiserver.yaml.backup /tmp/kube-apiserver-new.yaml
  > # Edit /tmp/kube-apiserver-new.yaml (add flags + volume mounts)
  > # Validate YAML syntax before deploying:
  > sudo python3 -c 'import yaml; yaml.safe_load(open("/tmp/kube-apiserver-new.yaml"))' && echo 'YAML VALID' || echo 'YAML INVALID — DO NOT DEPLOY'
  > # Only if VALID: move into manifests/ (triggers restart)
  > sudo cp /tmp/kube-apiserver-new.yaml /etc/kubernetes/manifests/kube-apiserver.yaml
  > ```

- [ ] 5.1.3.6 Watch API server restart (should come back within 60s):
  ```bash
  # From WSL — watch the API server pod status on CP1
  ssh wawashi@10.10.30.11 "sudo crictl ps | grep kube-apiserver"
  # If not running after 60s, check why:
  ssh wawashi@10.10.30.11 "sudo crictl logs \$(sudo crictl ps -a --name kube-apiserver -q | head -1) 2>&1 | tail -20"
  # If crash-looping: IMMEDIATELY rollback
  # ssh wawashi@10.10.30.11 "sudo cp /etc/kubernetes/kube-apiserver.yaml.backup /etc/kubernetes/manifests/kube-apiserver.yaml"
  ```

- [ ] 5.1.3.7 **Run lockout gate** (see Rolling Update Strategy — all checks must pass)

- [ ] 5.1.3.8 Verify anonymous auth is disabled:
  ```bash
  # Should return 401 (was 403 before)
  ssh wawashi@10.10.30.11 "curl -sk https://localhost:6443/api"
  ```

- [ ] 5.1.3.9 Verify audit log is being written:
  ```bash
  ssh wawashi@10.10.30.11 "sudo ls -la /var/log/kubernetes/audit/"
  ssh wawashi@10.10.30.11 "sudo tail -5 /var/log/kubernetes/audit/audit.log | head -1 | python3 -m json.tool"
  ```

- [ ] 5.1.3.10 Verify kube-vip and Prometheus still work:
  ```bash
  # kube-vip: VIP still responds
  kubectl-homelab get --raw /healthz
  # Prometheus: API server target still UP (give it 1-2 scrape intervals)
  kubectl-homelab exec -n monitoring $(kubectl-homelab get pod -n monitoring -l app.kubernetes.io/name=prometheus -o name | head -1) -- wget -qO- 'http://localhost:9090/api/v1/targets?state=active' 2>/dev/null | grep -o '"health":"up"' | wc -l
  ```

- [ ] 5.1.3.11 Apply same changes to CP2 (repeat 5.1.3.1-5.1.3.10, substitute 10.10.30.12)

- [ ] 5.1.3.12 Apply same changes to CP3 (repeat 5.1.3.1-5.1.3.10, substitute 10.10.30.13)

**Rollback:** Restore from backup: `sudo cp /etc/kubernetes/kube-apiserver.yaml.backup /etc/kubernetes/manifests/kube-apiserver.yaml` (API server auto-restarts)

---

## 5.1.4 Controller-Manager & Scheduler Hardening

Changes to static pod manifests on each node.

**Rolling: CP1 → verify → CP2 → verify → CP3**

Controller-manager (`/etc/kubernetes/manifests/kube-controller-manager.yaml`):
```
--profiling=false    # CIS 1.3.2
```

Scheduler (`/etc/kubernetes/manifests/kube-scheduler.yaml`):
```
--profiling=false    # CIS 1.4.1
```

- [ ] 5.1.4.1 Back up both manifests on CP1

- [ ] 5.1.4.2 Add `--profiling=false` to controller-manager on CP1

- [ ] 5.1.4.3 Add `--profiling=false` to scheduler on CP1

- [ ] 5.1.4.4 Verify from WSL (pods restarting, cluster healthy), **run lockout gate**

- [ ] 5.1.4.5 Apply to CP2, verify, **run lockout gate**

- [ ] 5.1.4.6 Apply to CP3, verify, **run lockout gate**

**Rollback:** Restore from backup, static pods auto-restart.

---

## 5.1.4a Control Plane Metrics Scraping

> **Moved from:** [deferred.md](../deferred.md) (originally deferred in Phase 3.9, 2026-01-20)

> **Audit (2026-03-14):** Bind-address changes, etcd metrics URL, and ServiceMonitors are
> already in place. All 9 control plane targets (3 components x 3 nodes) are UP in Prometheus.
> Only the Alertmanager silence removal remains.

**Already done (verified on all 3 nodes, 2026-03-14):**
- [x] Controller-manager `--bind-address=0.0.0.0` — already set
- [x] Scheduler `--bind-address=0.0.0.0` — already set
- [x] etcd `--listen-metrics-urls=http://0.0.0.0:2381` — already set
- [x] kube-prometheus-stack ServiceMonitors exist for controller-manager, scheduler, etcd
- [x] All Prometheus targets UP (controller-manager:10257, scheduler:10259, etcd:2381)

**Note:** kube-proxy is not running — Cilium replaces it (`kubeProxyReplacement: true`). The `KubeProxyDown` silence stays permanently.

### Alertmanager silence removal

- [ ] 5.1.4a.1 Remove silence routes from `helm/prometheus/values.yaml` (alertmanager.config.route.routes):
  - Remove `etcdInsufficientMembers` silence
  - Remove `etcdMembersDown` silence
  - Remove `TargetDown` silence for kube-scheduler, kube-controller-manager, kube-etcd
  - **Keep** `KubeProxyDown` silence (Cilium replaces kube-proxy — this is permanent)

- [ ] 5.1.4a.2 Add audit alert routing to Alertmanager config (see 5.1.6)

- [ ] 5.1.4a.3 Upgrade Prometheus Helm release with updated values

- [ ] 5.1.4a.4 Verify previously-silenced alerts do not fire (targets are healthy — they shouldn't)

**Rollback:** Re-add silence routes to `helm/prometheus/values.yaml`, upgrade Helm release.

---

## 5.1.5 API Server Audit Policy

The audit policy file referenced in 5.1.3. Create BEFORE adding the API server flags.

```yaml
# /etc/kubernetes/audit-policy.yaml
# Deploy to all 3 CP nodes (identical file)
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
  # Don't log requests to the following read-only URLs
  - level: None
    nonResourceURLs:
      - /healthz*
      - /readyz*
      - /livez*
      - /metrics

  # Don't log watch requests (very noisy)
  - level: None
    verbs: ["watch"]

  # Don't log kube-proxy/cilium configmap leader election
  - level: None
    resources:
      - group: ""
        resources: ["endpoints", "configmaps", "leases"]
    verbs: ["get", "update"]
    users:
      - system:kube-controller-manager
      - system:kube-scheduler

  # Log Secret access at Metadata level (who accessed, not what)
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets"]

  # Log RBAC changes at RequestResponse level
  - level: RequestResponse
    resources:
      - group: "rbac.authorization.k8s.io"
        resources: ["clusterroles", "clusterrolebindings", "roles", "rolebindings"]

  # Log pod exec/attach/portforward at RequestResponse level
  - level: Request
    resources:
      - group: ""
        resources: ["pods/exec", "pods/attach", "pods/portforward"]

  # Catch-all: log everything else at Metadata level
  - level: Metadata
    stages:
      - ResponseComplete
    omitStages:
      - RequestReceived
```

> **Sizing note:** At Metadata level with watch excluded, audit logs for a homelab-sized cluster
> are typically 10-50MB/day. With `maxsize=100` and `maxbackup=10`, worst case is ~1GB on disk
> per node. Negligible for 512GB NVMe.

- [ ] 5.1.5.1 Create audit policy file on CP1

- [ ] 5.1.5.2 Copy identical file to CP2 and CP3
  ```bash
  # From CP1
  sudo scp /etc/kubernetes/audit-policy.yaml wawashi@10.10.30.12:/tmp/
  sudo scp /etc/kubernetes/audit-policy.yaml wawashi@10.10.30.13:/tmp/
  # On CP2 and CP3
  sudo mv /tmp/audit-policy.yaml /etc/kubernetes/audit-policy.yaml
  ```

---

## 5.1.6 Audit Log Shipping to Loki

Ship API server audit logs from all 3 nodes to Loki via Grafana Alloy.

> **Why:** On-node logs are useless if you can't search them. Loki + Grafana gives you a
> single pane of glass for investigating security events.

> **Audit (2026-03-14):** Alloy DaemonSet currently has NO hostPath mounts for `/var/log`.
> Both the hostPath volume and volumeMount MUST be added to the Alloy Helm values.
> Audit logs only exist on CP nodes — Alloy pods on workers will simply find no file.

- [ ] 5.1.6.1 Add hostPath volume mount to Alloy DaemonSet for audit logs
  Add to `helm/alloy/values.yaml` (verify exact paths match chart version with `helm show values`):
  ```yaml
  alloy:
    mounts:
      extra:
        - name: audit-logs
          mountPath: /var/log/kubernetes/audit
          readOnly: true
    controller:
      volumes:
        extra:
          - name: audit-logs
            hostPath:
              path: /var/log/kubernetes/audit
              type: DirectoryOrCreate
  ```

- [ ] 5.1.6.2 Add Alloy config block to scrape audit log files
  ```yaml
  # Add to Alloy config in helm/alloy/values.yaml
  local.file_match "audit_logs" {
    path_targets = [{"__path__" = "/var/log/kubernetes/audit/audit.log"}]
    sync_period  = "5s"
  }

  loki.source.file "audit_logs" {
    targets       = local.file_match.audit_logs.targets
    forward_to    = [loki.write.default.receiver]
    tail_from_end = true
  }
  ```

- [ ] 5.1.6.3 Upgrade Alloy Helm release and verify pods restart with new mounts
  ```bash
  kubectl-homelab get pods -n monitoring -l app.kubernetes.io/name=alloy
  # Verify 3/3 Running, check logs for audit file discovery
  kubectl-homelab logs -n monitoring daemonset/alloy --tail=20 | grep audit
  ```

- [ ] 5.1.6.4 Verify audit logs appear in Grafana → Explore → Loki
  ```
  {filename="/var/log/kubernetes/audit/audit.log"} | json | verb != "watch"
  ```

- [ ] 5.1.6.5 Create audit alerting rules (Loki ruler or PrometheusRule with LogQL)
  ```yaml
  # manifests/monitoring/alerts/audit-alerts.yaml
  groups:
    - name: audit-security
      rules:
        - alert: AuditSecretAccessByNonSystem
          expr: |
            count_over_time({filename="/var/log/kubernetes/audit/audit.log"}
              | json
              | objectRef_resource = "secrets"
              | user_username !~ "system:.*"
              [5m]) > 0
          for: 0m
          labels:
            severity: warning
          annotations:
            summary: "Non-system user accessed secrets"

        - alert: AuditPodExec
          expr: |
            count_over_time({filename="/var/log/kubernetes/audit/audit.log"}
              | json
              | objectRef_subresource = "exec"
              [5m]) > 0
          for: 0m
          labels:
            severity: warning
          annotations:
            summary: "Pod exec session detected"

        - alert: AuditRBACChange
          expr: |
            count_over_time({filename="/var/log/kubernetes/audit/audit.log"}
              | json
              | objectRef_apiGroup = "rbac.authorization.k8s.io"
              | verb =~ "create|update|patch|delete"
              [5m]) > 0
          for: 0m
          labels:
            severity: warning
          annotations:
            summary: "RBAC resource modified"

        - alert: AuditHighAuthFailureRate
          expr: |
            count_over_time({filename="/var/log/kubernetes/audit/audit.log"}
              | json
              | responseStatus_code >= 401
              | responseStatus_code <= 403
              [5m]) > 50
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "High rate of authentication/authorization failures (>50 in 5m)"
  ```

- [ ] 5.1.6.6 Add audit alert routing to Alertmanager config
  Add to `helm/prometheus/values.yaml` alertmanager routes (combine with 5.1.4a silence removal):
  ```yaml
  - match_re:
      alertname: 'Audit.*'
    receiver: 'discord-infra'
  ```

- [ ] 5.1.6.7 Verify audit alerts are routable (trigger a test exec and confirm alert fires)
  ```bash
  # Trigger a pod exec (should fire AuditPodExec)
  kubectl-homelab exec -n kube-system deploy/coredns -- whoami
  # Check Loki for the event, then Alertmanager for the alert
  ```

### Useful Loki queries for audit investigation

```
# Who accessed this secret?
{filename="/var/log/kubernetes/audit/audit.log"} | json | objectRef_resource = "secrets" | objectRef_name = "<secret-name>"

# All exec sessions in last 24h
{filename="/var/log/kubernetes/audit/audit.log"} | json | objectRef_subresource = "exec"

# What happened in the 5 minutes before a pod was deleted?
{filename="/var/log/kubernetes/audit/audit.log"} | json | objectRef_name = "<pod-name>" | verb =~ "delete|update|patch"

# All RBAC changes
{filename="/var/log/kubernetes/audit/audit.log"} | json | objectRef_apiGroup = "rbac.authorization.k8s.io" | verb =~ "create|update|patch|delete"
```

---

## 5.1.7 Certificate Expiry Monitoring

kubeadm certificates expire in 1 year. Existing PrometheusRule `cert-alerts` covers
**cert-manager certificates** only (TLS certs for ingress, webhooks). This CronJob monitors
**kubeadm PKI certificates** (CA-signed certs for API server, etcd, kubelet client auth, etc.)
which are NOT managed by cert-manager.

> **Audit (2026-03-14):** All kubeadm certs expire ~Jan 15, 2027 (~307 days). CAs expire ~2036.
> `registry.k8s.io/kubeadm:v1.35.0` does NOT exist as a container image — kubeadm is a host
> binary only. Using `alpine:3.21` with `openssl` to check cert expiry directly.

- [ ] 5.1.7.1 Create CronJob to check certificate expiry
  ```yaml
  apiVersion: batch/v1
  kind: CronJob
  metadata:
    name: cert-expiry-check
    namespace: kube-system
  spec:
    schedule: "0 20 * * 0"      # Weekly Sunday 04:00 Manila time
    timeZone: "Asia/Manila"
    successfulJobsHistoryLimit: 1
    failedJobsHistoryLimit: 1
    jobTemplate:
      spec:
        backoffLimit: 0
        template:
          spec:
            nodeSelector:
              node-role.kubernetes.io/control-plane: ""
            tolerations:
              - key: node-role.kubernetes.io/control-plane
                effect: NoSchedule
            automountServiceAccountToken: false
            containers:
              - name: check-certs
                image: alpine:3.21
                command: ["/bin/sh", "-c"]
                args:
                  - |
                    apk add --no-cache openssl curl
                    WARN=0
                    for CERT in /etc/kubernetes/pki/*.crt /etc/kubernetes/pki/etcd/*.crt; do
                      [ -f "$CERT" ] || continue
                      EXPIRY=$(openssl x509 -enddate -noout -in "$CERT" 2>/dev/null | cut -d= -f2)
                      EXPIRY_EPOCH=$(date -d "$EXPIRY" +%s 2>/dev/null)
                      NOW_EPOCH=$(date +%s)
                      DAYS_LEFT=$(( (EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))
                      echo "$CERT: expires in ${DAYS_LEFT}d ($EXPIRY)"
                      if [ "$DAYS_LEFT" -lt 30 ]; then
                        echo "WARNING: $CERT expires in ${DAYS_LEFT} days!"
                        WARN=1
                      fi
                    done
                    if [ "$WARN" -eq 1 ] && [ -n "$DISCORD_WEBHOOK_URL" ]; then
                      curl -H "Content-Type: application/json" \
                        -d "{\"content\":\"kubeadm PKI certificate expiring within 30 days. Run: sudo kubeadm certs renew all\"}" \
                        "$DISCORD_WEBHOOK_URL"
                      exit 1
                    fi
                env:
                  - name: DISCORD_WEBHOOK_URL
                    valueFrom:
                      secretKeyRef:
                        name: cert-expiry-discord
                        key: webhook-url
                        optional: true
                resources:
                  requests: { cpu: 50m, memory: 64Mi }
                  limits: { cpu: 100m, memory: 128Mi }
                volumeMounts:
                  - name: kubernetes-pki
                    mountPath: /etc/kubernetes/pki
                    readOnly: true
            volumes:
              - name: kubernetes-pki
                hostPath:
                  path: /etc/kubernetes/pki
            restartPolicy: Never
  ```

- [ ] 5.1.7.2 Run the job manually once to verify baseline cert expiry dates
  ```bash
  # Alternative: run kubeadm certs check-expiration directly on a CP node
  ssh wawashi@10.10.30.11 "sudo kubeadm certs check-expiration"
  ```

- [ ] 5.1.7.3 Document cert expiry dates and renewal procedure

---

## 5.1.8 kubeadm PKI Backup

Back up `/etc/kubernetes/pki/` — CA keys, API server certs, etcd certs. Losing these = rebuild from scratch (etcd backup alone is not enough).

- [ ] 5.1.8.1 Create NFS directory for PKI backup
  ```bash
  ssh wawashi@10.10.30.11 "sudo mount -t nfs4 10.10.30.4:/Kubernetes/Backups /tmp/nfs && \
    sudo mkdir -p /tmp/nfs/pki && sudo umount /tmp/nfs"
  ```

- [ ] 5.1.8.2 Create PKI backup CronJob
  ```yaml
  apiVersion: batch/v1
  kind: CronJob
  metadata:
    name: pki-backup
    namespace: kube-system
  spec:
    schedule: "0 20 * * 0"       # Weekly Sunday 04:00 Manila time
    timeZone: "Asia/Manila"
    successfulJobsHistoryLimit: 1
    failedJobsHistoryLimit: 1
    jobTemplate:
      spec:
        backoffLimit: 0
        template:
          spec:
            nodeSelector:
              node-role.kubernetes.io/control-plane: ""
            tolerations:
              - key: node-role.kubernetes.io/control-plane
                effect: NoSchedule
            automountServiceAccountToken: false
            containers:
              - name: backup
                image: alpine:3.21
                command: ["/bin/sh", "-c"]
                args:
                  - |
                    BACKUP_DIR="/backup/pki-$(date +%Y%m%d-%H%M%S)"
                    cp -a /etc/kubernetes/pki "$BACKUP_DIR"
                    cp /etc/kubernetes/admin.conf "$BACKUP_DIR/"
                    echo "PKI backup created: $BACKUP_DIR"
                    ls -la "$BACKUP_DIR/"
                    # Prune backups older than 90 days
                    find /backup -name "pki-*" -type d -mtime +90 -exec rm -rf {} +
                resources:
                  requests: { cpu: 50m, memory: 64Mi }
                  limits: { cpu: 100m, memory: 128Mi }
                securityContext:
                  readOnlyRootFilesystem: true
                volumeMounts:
                  - name: pki
                    mountPath: /etc/kubernetes/pki
                    readOnly: true
                  - name: admin-conf
                    mountPath: /etc/kubernetes/admin.conf
                    readOnly: true
                  - name: backup
                    mountPath: /backup
            volumes:
              - name: pki
                hostPath: { path: /etc/kubernetes/pki }
              - name: admin-conf
                hostPath: { path: /etc/kubernetes/admin.conf }
              - name: backup
                nfs:
                  server: 10.10.30.4
                  path: /Kubernetes/Backups/pki
            restartPolicy: Never
  ```

- [ ] 5.1.8.3 Run manually once and verify backup is restorable
  ```bash
  ssh wawashi@10.10.30.11 "sudo mount -t nfs4 10.10.30.4:/Kubernetes/Backups /tmp/nfs && \
    ls -la /tmp/nfs/pki/ && \
    ls /tmp/nfs/pki/pki-*/ca.crt /tmp/nfs/pki/pki-*/ca.key && \
    sudo umount /tmp/nfs"
  ```

---

## 5.1.9 Post-flight: kube-bench Verification

Run kube-bench again after all changes. Compare against baseline from 5.1.1.

- [ ] 5.1.9.1 Run kube-bench again (same Job as 5.1.1)

- [ ] 5.1.9.2 Compare FAIL/WARN counts against baseline

- [ ] 5.1.9.3 Document remaining FAIL items with justification (e.g., items that require different architecture)

---

## 5.1.10 Documentation

- [ ] 5.1.10.1 Update `docs/context/Security.md` with:
  - Control plane hardening decisions
  - kube-bench scores (before/after)
  - Audit logging architecture
  - Certificate lifecycle management

- [ ] 5.1.10.2 Update `docs/reference/CHANGELOG.md`

- [ ] 5.1.10.3 Bake hardening into kubeadm config (rebuild-safe)
  Update the kubeadm config template used by Ansible so `kubeadm init`/`kubeadm join` produce
  hardened manifests from day one:
  ```yaml
  # Add to kubeadm ClusterConfiguration (used by Ansible)
  apiServer:
    extraArgs:
      anonymous-auth: "false"
      profiling: "false"
      audit-log-path: /var/log/kubernetes/audit/audit.log
      audit-policy-file: /etc/kubernetes/audit-policy.yaml
      audit-log-maxage: "30"
      audit-log-maxbackup: "10"
      audit-log-maxsize: "100"
    extraVolumes:
      - name: audit-policy
        hostPath: /etc/kubernetes/audit-policy.yaml
        mountPath: /etc/kubernetes/audit-policy.yaml
        readOnly: true
        pathType: File
      - name: audit-log
        hostPath: /var/log/kubernetes/audit
        mountPath: /var/log/kubernetes/audit
        pathType: DirectoryOrCreate
  controllerManager:
    extraArgs:
      profiling: "false"
  scheduler:
    extraArgs:
      profiling: "false"
  ---
  apiVersion: kubelet.config.k8s.io/v1beta1
  kind: KubeletConfiguration
  readOnlyPort: 0
  protectKernelDefaults: true
  eventRecordQPS: 5
  ```

- [ ] 5.1.10.4 Add audit policy file deployment to Ansible
  Add a task to copy `audit-policy.yaml` to `/etc/kubernetes/` on all CP nodes before
  `kubeadm init`. This file must exist before the API server starts or it will crash-loop.

- [ ] 5.1.10.5 Create hardening verification playbook (`playbooks/09-verify-hardening.yml`)
  Ansible playbook that checks (not applies) hardening settings on all CP nodes. Re-runnable
  anytime as a drift detection tool:
  ```yaml
  # playbooks/09-verify-hardening.yml
  # Checks that hardening settings are in place — fails if any are missing
  - name: Verify control plane hardening
    hosts: control_plane
    become: true
    tasks:
      - name: Verify kubelet config settings
        ansible.builtin.shell: |
          grep -q 'readOnlyPort: 0' /var/lib/kubelet/config.yaml &&
          grep -q 'protectKernelDefaults: true' /var/lib/kubelet/config.yaml &&
          grep -q 'eventRecordQPS: 5' /var/lib/kubelet/config.yaml
        changed_when: false

      - name: Verify kubelet anonymous auth disabled
        ansible.builtin.shell: |
          grep -A2 'anonymous:' /var/lib/kubelet/config.yaml | grep -q 'enabled: false'
        changed_when: false

      - name: Verify API server flags
        ansible.builtin.shell: |
          grep -q 'anonymous-auth=false' /etc/kubernetes/manifests/kube-apiserver.yaml &&
          grep -q 'profiling=false' /etc/kubernetes/manifests/kube-apiserver.yaml &&
          grep -q 'audit-log-path' /etc/kubernetes/manifests/kube-apiserver.yaml
        changed_when: false

      - name: Verify controller-manager profiling disabled
        ansible.builtin.shell: |
          grep -q 'profiling=false' /etc/kubernetes/manifests/kube-controller-manager.yaml
        changed_when: false

      - name: Verify scheduler profiling disabled
        ansible.builtin.shell: |
          grep -q 'profiling=false' /etc/kubernetes/manifests/kube-scheduler.yaml
        changed_when: false

      - name: Verify audit policy exists
        ansible.builtin.stat:
          path: /etc/kubernetes/audit-policy.yaml
        register: audit_policy
        failed_when: not audit_policy.stat.exists

      - name: Verify audit log directory exists
        ansible.builtin.stat:
          path: /var/log/kubernetes/audit
        register: audit_dir
        failed_when: not audit_dir.stat.exists

      - name: Verify sysctl params for protectKernelDefaults
        ansible.builtin.shell: |
          sysctl -n net.bridge.bridge-nf-call-iptables | grep -q 1 &&
          sysctl -n net.bridge.bridge-nf-call-ip6tables | grep -q 1 &&
          sysctl -n net.ipv4.ip_forward | grep -q 1
        changed_when: false
  ```
  Run with: `ansible-playbook -i inventory/homelab playbooks/09-verify-hardening.yml`

---

## Verification Checklist

**Already verified (2026-03-14) — confirm unchanged during execution:**
- [x] Kubelet `anonymous-auth: false` on all 3 nodes (kubeadm default)
- [x] Kubelet `authorization.mode: Webhook` on all 3 nodes (kubeadm default)
- [x] Kubelet `rotateCertificates: true` on all 3 nodes (kubeadm default)
- [x] Controller-manager `--bind-address=0.0.0.0` on all 3 nodes
- [x] Scheduler `--bind-address=0.0.0.0` on all 3 nodes
- [x] etcd `--listen-metrics-urls=http://0.0.0.0:2381` on all 3 nodes
- [x] Prometheus scraping controller-manager, scheduler, and etcd targets (all 9/9 UP)

**New work:**
- [ ] kube-bench baseline scan completed and documented
- [ ] Kubelet `readOnlyPort: 0` explicitly set on all 3 nodes
- [ ] Kubelet `protectKernelDefaults: true` on all 3 nodes
- [ ] Kubelet `eventRecordQPS: 5` on all 3 nodes
- [ ] API server `--anonymous-auth=false` on all 3 nodes (changes 403 → 401)
- [ ] API server `--profiling=false` on all 3 nodes
- [ ] Controller-manager `--profiling=false` on all 3 nodes
- [ ] Scheduler `--profiling=false` on all 3 nodes
- [ ] Alertmanager silence routes removed (except KubeProxyDown)
- [ ] Audit policy file deployed to all 3 nodes
- [ ] Audit logs being written to `/var/log/kubernetes/audit/`
- [ ] Audit logs contain actual API server requests (not empty files)
- [ ] Alloy hostPath mount added for audit log directory
- [ ] Audit logs shipped to Loki via Alloy (visible in Grafana → Explore → Loki)
- [ ] Audit alert rules deployed (secret access, pod exec, RBAC changes, auth failures)
- [ ] Audit alert routing added to Alertmanager config (discord-infra)
- [ ] Certificate expiry CronJob deployed and tested (kubeadm PKI, not cert-manager)
- [ ] kubeadm PKI backup to NFS deployed and tested (restore verified)
- [ ] kube-bench post-hardening scan shows improvement
- [ ] All 3 nodes Ready, all pods Running after all changes
- [ ] Anonymous kubelet API access blocked (verified from another node)
- [ ] Anonymous API server access returns 401 (verified)
- [ ] kube-vip leader election still works after anonymous-auth change
- [ ] Prometheus API server scraping still works after anonymous-auth change
- [ ] kubeadm config template updated with hardening extraArgs (rebuild-safe)
- [ ] Audit policy file deployment added to Ansible
- [ ] Hardening verification playbook created and passes on all 3 nodes
- [ ] No physical access (monitor/keyboard) was needed at any point

---

## Rollback

Each section has its own rollback (restore from backup). General principle:

```bash
# If a node's API server won't start after manifest change:
ssh wawashi@10.10.30.1X
sudo cp /etc/kubernetes/kube-apiserver.yaml.backup /etc/kubernetes/manifests/kube-apiserver.yaml
# API server auto-restarts within 30s

# If kubelet won't start after config change:
ssh wawashi@10.10.30.1X
sudo cp /var/lib/kubelet/config.yaml.backup /var/lib/kubelet/config.yaml
sudo systemctl restart kubelet

# VIP and other 2 nodes are unaffected — cluster stays up
```

---

## Final: Commit and Release

- [ ] `/audit-security` then `/commit`
- [ ] `/audit-docs` then `/commit`
- [ ] `/release v0.31.0 "Control Plane Hardening"`
- [ ] `mv docs/todo/phase-5.1-control-plane-hardening.md docs/todo/completed/`
