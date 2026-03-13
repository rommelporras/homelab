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

**Procedure:** CP1 change → verify → CP2 change → verify → CP3 change → verify

**Why this is safe:**
- kube-vip VIP (10.10.30.10) fails over in ~2 seconds — always 2/3 nodes serving
- etcd quorum needs 2/3 — always maintained when only 1 node is down

**Abort criteria:** If CP1 change fails and revert doesn't fix within 5 minutes, **STOP** — do not touch CP2/CP3.

**Verification between each node:**
```bash
# Run from WSL after each node change
kubectl-homelab get nodes                    # All 3 Ready?
kubectl-homelab get pods -n kube-system      # All Running?
kubectl-homelab get cs 2>/dev/null || kubectl-homelab cluster-info  # API healthy?
kubectl-homelab get --raw /healthz           # API server healthz
```

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

- [ ] 5.1.1.1 Run kube-bench on one CP node, capture baseline score
- [ ] 5.1.1.2 Document current FAIL/WARN items as the "before" baseline

---

## 5.1.2 Kubelet Hardening

Changes to `/var/lib/kubelet/config.yaml` (KubeletConfiguration) on each node, then `sudo systemctl restart kubelet`.

**Rolling: CP1 → verify → CP2 → verify → CP3**

Settings to add/change:
```yaml
# Add to /var/lib/kubelet/config.yaml on each node
authentication:
  anonymous:
    enabled: false          # CIS 4.2.1 — default is true
  webhook:
    enabled: true           # Should already be true (kubeadm default)
authorization:
  mode: Webhook             # CIS 4.2.2 — default is AlwaysAllow
readOnlyPort: 0             # CIS 4.2.4 — disable unauthenticated read-only port 10255
protectKernelDefaults: false # CIS 4.2.6 — set to true only if sysctl params are pre-set (verify first)
eventRecordQPS: 5           # CIS 4.2.8 — default is 5 (verify, don't change if already set)
rotateCertificates: true    # CIS 4.2.11 — enable automatic cert rotation
```

> **Note on `protectKernelDefaults`:** Before setting to `true`, verify that the required sysctl
> params (`net.bridge.bridge-nf-call-iptables=1`, etc.) are already set via `/etc/sysctl.d/k8s.conf`
> (they are — set in Ansible playbook 01-prerequisites.yml). If kubelet starts with
> `protectKernelDefaults: true` and the params aren't set, kubelet won't start.

- [ ] 5.1.2.1 SSH to CP1, back up existing kubelet config
  ```bash
  ssh wawashi@10.10.30.11
  sudo cp /var/lib/kubelet/config.yaml /var/lib/kubelet/config.yaml.backup
  ```

- [ ] 5.1.2.2 Edit kubelet config on CP1 (add the settings above)

- [ ] 5.1.2.3 Restart kubelet on CP1: `sudo systemctl restart kubelet`

- [ ] 5.1.2.4 Verify CP1 from WSL (get nodes, get pods, cluster-info)

- [ ] 5.1.2.5 Verify kubelet API is no longer accessible anonymously:
  ```bash
  # From another node — should return 401 Unauthorized (not pod data)
  ssh wawashi@10.10.30.12 "curl -sk https://10.10.30.11:10250/pods"
  # Should also fail on read-only port (port closed)
  ssh wawashi@10.10.30.12 "curl -s http://10.10.30.11:10255/pods --max-time 3"
  ```

- [ ] 5.1.2.6 Apply same changes to CP2, verify

- [ ] 5.1.2.7 Apply same changes to CP3, verify

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

> **Note on `--anonymous-auth=false`:** kubeadm default is `true`. With this set to `false`,
> unauthenticated requests to the API server are rejected. Health check endpoints (`/healthz`,
> `/readyz`, `/livez`) still work because they're handled before authentication. Verify after
> applying that `kubectl-homelab` still works (it uses client cert auth, unaffected).

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

- [ ] 5.1.3.1 Create audit policy file on CP1 (see 5.1.5 for policy content — create this FIRST before adding the API server flag)

- [ ] 5.1.3.2 Create audit log directory: `sudo mkdir -p /var/log/kubernetes/audit`

- [ ] 5.1.3.3 Back up API server manifest on CP1:
  ```bash
  sudo cp /etc/kubernetes/manifests/kube-apiserver.yaml /etc/kubernetes/kube-apiserver.yaml.backup
  ```

- [ ] 5.1.3.4 Edit API server manifest on CP1 (add flags + volume mounts)

- [ ] 5.1.3.5 Wait for API server to restart (~30s), verify from WSL

- [ ] 5.1.3.6 Verify anonymous auth is disabled:
  ```bash
  # Should return 401, not 200
  ssh wawashi@10.10.30.11 "curl -sk https://localhost:6443/api"
  ```

- [ ] 5.1.3.7 Verify audit log is being written:
  ```bash
  ssh wawashi@10.10.30.11 "sudo ls -la /var/log/kubernetes/audit/"
  ssh wawashi@10.10.30.11 "sudo tail -5 /var/log/kubernetes/audit/audit.log | head -1 | python3 -m json.tool"
  ```

- [ ] 5.1.3.8 Apply same changes to CP2, verify

- [ ] 5.1.3.9 Apply same changes to CP3, verify

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

- [ ] 5.1.4.4 Verify from WSL (pods restarting, cluster healthy)

- [ ] 5.1.4.5 Apply to CP2, verify

- [ ] 5.1.4.6 Apply to CP3, verify

**Rollback:** Restore from backup, static pods auto-restart.

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

  # Log authentication failures
  - level: Metadata
    stages:
      - ResponseComplete
    omitStages:
      - RequestReceived

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

- [ ] 5.1.6.1 Update Alloy DaemonSet config to scrape audit log files
  ```yaml
  # Add to Alloy config (helm/prometheus/values.yaml or Alloy ConfigMap)
  # Alloy runs on every node as a DaemonSet — it can read host paths
  local.file_match "audit_logs" {
    path_targets = [{"__path__" = "/var/log/kubernetes/audit/audit.log"}]
    sync_period  = "5s"
  }

  loki.source.file "audit_logs" {
    targets    = local.file_match.audit_logs.targets
    forward_to = [loki.write.default.receiver]
    tail_from_end = true
  }
  ```

  > Alloy already has hostPath access for `/var/log` — verify the mount covers `/var/log/kubernetes/audit/`.

- [ ] 5.1.6.2 Add Alloy hostPath volume mount for audit log directory (if not already covered)

- [ ] 5.1.6.3 Verify audit logs appear in Grafana → Explore → Loki
  ```
  {filename="/var/log/kubernetes/audit/audit.log"} | json | verb != "watch"
  ```

- [ ] 5.1.6.4 Create audit alerting rules
  ```yaml
  # Optional: Alert on suspicious audit events
  # e.g., secrets accessed by unexpected users, exec into pods, RBAC changes
  # This is a Loki alert rule, not a Prometheus rule
  ```

---

## 5.1.7 Certificate Expiry Monitoring

kubeadm certificates expire in 1 year. No existing alert for this.

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
                image: registry.k8s.io/kubeadm:v1.35.0
                command: ["/bin/sh", "-c"]
                args:
                  - |
                    OUTPUT=$(kubeadm certs check-expiration 2>&1)
                    echo "$OUTPUT"
                    # Check if any cert expires within 30 days
                    DAYS_LEFT=$(echo "$OUTPUT" | grep -oP '\d+(?=d)' | sort -n | head -1)
                    if [ -n "$DAYS_LEFT" ] && [ "$DAYS_LEFT" -lt 30 ]; then
                      echo "WARNING: Certificate expiring in ${DAYS_LEFT} days"
                      # Send Discord notification
                      if [ -n "$DISCORD_WEBHOOK_URL" ]; then
                        curl -H "Content-Type: application/json" \
                          -d "{\"content\":\"kubeadm certificate expiring in ${DAYS_LEFT} days. Run: kubeadm certs renew all\"}" \
                          "$DISCORD_WEBHOOK_URL"
                      fi
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

  > **Note:** Verify that `registry.k8s.io/kubeadm:v1.35.0` exists. If not, use an image that
  > includes `kubeadm` binary, or use `alpine` with kubeadm installed.

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

- [ ] 5.1.8.3 Run manually once and verify backup on NFS

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

- [ ] 5.1.10.3 Update Ansible playbooks to include hardening flags (so rebuilds from scratch include these settings)

---

## Verification Checklist

- [ ] kube-bench baseline scan completed and documented
- [ ] Kubelet `anonymous-auth: false` on all 3 nodes
- [ ] Kubelet `authorization.mode: Webhook` on all 3 nodes
- [ ] Kubelet `readOnlyPort: 0` on all 3 nodes
- [ ] Kubelet `rotateCertificates: true` on all 3 nodes
- [ ] API server `--anonymous-auth=false` on all 3 nodes
- [ ] API server `--profiling=false` on all 3 nodes
- [ ] Controller-manager `--profiling=false` on all 3 nodes
- [ ] Scheduler `--profiling=false` on all 3 nodes
- [ ] Audit policy file deployed to all 3 nodes
- [ ] Audit logs being written to `/var/log/kubernetes/audit/`
- [ ] Audit logs shipped to Loki via Alloy
- [ ] Certificate expiry CronJob deployed and tested
- [ ] kubeadm PKI backup to NFS deployed and tested
- [ ] kube-bench post-hardening scan shows improvement
- [ ] All 3 nodes Ready, all pods Running after all changes
- [ ] Anonymous kubelet API access blocked (verified from another node)
- [ ] Anonymous API server access blocked (verified)
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
