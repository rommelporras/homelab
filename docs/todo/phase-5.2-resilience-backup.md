# Phase 5.2: Resilience & Backup

> **Status:** ⬜ Planned
> **Target:** v0.32.0
> **Prerequisite:** Phase 5.1 (v0.31.0 — network policies in place)
> **DevOps Topics:** Resource management, disaster recovery, operational resilience
> **CKA Topics:** ResourceQuota, LimitRange, PodDisruptionBudget, Velero, tolerations

> **Purpose:** Survive node failures, recover from disasters, prevent resource exhaustion
>
> **Learning Goal:** Kubernetes resource management and backup/restore strategies

---

## 5.2.1 Resource Limits on All Workloads

> **Why:** Without limits, one misbehaving pod can starve an entire node.
> Pods without limits also can't be evicted by priority — kubelet kills them randomly under pressure.

- [ ] 5.2.1.1 Audit current resource usage
  ```bash
  kubectl-homelab top nodes
  kubectl-homelab top pods -A --sort-by=memory

  # Find pods without limits
  kubectl-homelab get pods -A -o json | jq -r '
    .items[] | select(.status.phase=="Running") |
    select(.spec.containers[] | .resources.limits == null) |
    .metadata.namespace + "/" + .metadata.name
  '
  ```

- [ ] 5.2.1.2 Set resource requests/limits on all manifest workloads
  - Review actual usage from `kubectl top` and set limits at ~2x observed usage
  - Every Deployment/StatefulSet in `manifests/` should have `resources` block
  - Include: adguard, homepage, myspeed, ghost (dev+prod), invoicetron (dev+prod),
    portfolio, browser, uptime-kuma, karakeep, cloudflared, arr-stack apps, atuin

- [ ] 5.2.1.3 Set resource limits in Helm values for Helm-managed workloads
  - Review `helm/*/values.yaml` for any components missing limits
  - ESO limits already set in Phase 5.0

- [ ] 5.2.1.4 Verify no pods are OOMKilled or throttled after applying limits
  ```bash
  # Check for OOMKilled
  kubectl-homelab get pods -A -o json | jq -r '
    .items[] |
    select(.status.containerStatuses[]?.lastState.terminated.reason == "OOMKilled") |
    .metadata.namespace + "/" + .metadata.name
  '

  # Check for CPU throttling
  # (CPUThrottlingHigh alert should not fire for non-excluded namespaces)
  ```

---

## 5.2.2 Resource Quotas

> **CKA Topic:** ResourceQuota prevents namespace-level resource exhaustion

- [ ] 5.2.2.1 Create ResourceQuota for invoicetron namespaces (template)
  ```yaml
  apiVersion: v1
  kind: ResourceQuota
  metadata:
    name: resource-quota
    namespace: invoicetron-prod
  spec:
    hard:
      requests.cpu: "2"
      requests.memory: 4Gi
      limits.cpu: "4"
      limits.memory: 8Gi
      pods: "10"
      persistentvolumeclaims: "5"
  ```

- [ ] 5.2.2.2 Apply quotas to other application namespaces
  - Adapt limits based on actual usage per namespace
  - Start with app namespaces (ghost, invoicetron, portfolio)
  - Don't quota system namespaces (monitoring, kube-system)

- [ ] 5.2.2.3 Verify quotas are enforced
  ```bash
  kubectl-homelab describe resourcequota -A
  ```

---

## 5.2.3 LimitRange Defaults

> **CKA Topic:** LimitRange sets default requests/limits for pods that don't specify them — safety net for missed workloads

- [ ] 5.2.3.1 Create LimitRange for application namespaces
  ```yaml
  apiVersion: v1
  kind: LimitRange
  metadata:
    name: default-limits
    namespace: invoicetron-prod
  spec:
    limits:
      - default:
          cpu: 500m
          memory: 512Mi
        defaultRequest:
          cpu: 100m
          memory: 128Mi
        type: Container
  ```

- [ ] 5.2.3.2 Apply LimitRange to all application namespaces
  - Same namespaces as ResourceQuotas (ghost, invoicetron, portfolio, arr-stack, etc.)
  - Adjust defaults based on namespace workload profile
  - Don't apply to system namespaces (monitoring, kube-system)

- [ ] 5.2.3.3 Verify defaults are applied to new pods
  ```bash
  # Deploy a pod without resource specs and check it gets defaults
  kubectl-homelab run test --rm -it --image=busybox -n invoicetron-prod -- sh -c "exit 0"
  kubectl-homelab get pod test -n invoicetron-prod -o jsonpath='{.spec.containers[0].resources}'
  ```

---

## 5.2.4 Velero Backup & Restore

> **Purpose:** Recover from accidental deletion, corruption, or node failure

### What Velero Backs Up

| Resource | Included | Notes |
|----------|----------|-------|
| K8s manifests | Yes | Deployments, Services, ConfigMaps, Secrets |
| PVC data | Yes (with restic/kopia) | Requires annotation |
| etcd | No | Use kubeadm snapshot for etcd |

- [ ] 5.2.4.1 Add Velero Helm repo
  ```bash
  helm-homelab repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts --force-update
  helm-homelab repo update
  ```

- [ ] 5.2.4.2 Create NFS backup location on NAS
  ```bash
  # Create backup directory via NFS mount from a k8s node
  ssh wawashi@10.10.30.11 "sudo mount -t nfs4 10.10.30.4:/Kubernetes/Backups /tmp/nfs && \
    sudo mkdir -p /tmp/nfs/velero && sudo umount /tmp/nfs"
  ```

- [ ] 5.2.4.3 Create `helm/velero/values.yaml`
  ```yaml
  # Configure: NFS filesystem provider, node agent for PVC backup,
  # backup storage location pointing to NAS, snapshots disabled
  # (Longhorn handles volume snapshots separately)
  ```

- [ ] 5.2.4.4 Install Velero with NFS backend
  ```bash
  kubectl-homelab create namespace velero

  helm-homelab install velero vmware-tanzu/velero \
    --namespace velero \
    --values helm/velero/values.yaml
  ```

- [ ] 5.2.4.5 Create scheduled backup
  ```bash
  # Daily backup at 03:00 Manila time, retain 7 days
  velero schedule create daily-backup \
    --schedule="0 19 * * *" \
    --ttl 168h \
    --include-namespaces portfolio-prod,invoicetron-prod,ghost-prod,home,monitoring,arr-stack,atuin,karakeep
  ```

- [ ] 5.2.4.6 Test backup
  ```bash
  velero backup create test-backup --include-namespaces portfolio-prod
  velero backup describe test-backup
  velero backup logs test-backup
  ```

- [ ] 5.2.4.7 Test restore
  ```bash
  # Backup first, then delete and restore
  velero restore create --from-backup test-backup
  kubectl-homelab get deployment -n portfolio-prod
  ```

---

## 5.2.5 Pod Eviction Timing

> **Problem:** When a node goes down, pods take ~5-6 min to reschedule (300s default toleration).

- [ ] 5.2.5.1 Evaluate reducing tolerationSeconds for stateless services
  ```yaml
  # Add to stateless Deployments (Ghost, Portfolio, Homepage, etc.):
  spec:
    template:
      spec:
        tolerations:
          - key: "node.kubernetes.io/not-ready"
            operator: "Exists"
            effect: "NoExecute"
            tolerationSeconds: 30
          - key: "node.kubernetes.io/unreachable"
            operator: "Exists"
            effect: "NoExecute"
            tolerationSeconds: 30
  ```
  - Trade-off: faster failover vs. more pod migrations on transient blips
  - Only for stateless services — databases should keep 300s (data consistency)

- [ ] 5.2.5.2 Document expected recovery times
  | Phase | Duration |
  |-------|----------|
  | M80q BIOS POST | ~5-7 min |
  | Kubernetes node NotReady detection | ~40s |
  | Pod eviction (default) | 300s |
  | Pod eviction (tuned) | 30s |
  | Total worst-case (default) | ~11 min |
  | Total worst-case (tuned) | ~6.5 min |

---

## 5.2.6 OPNsense Stale Firewall States

> **Problem:** After node reboot, OPNsense keeps stale TCP states. Cross-VLAN SSH times out
> until states are manually cleared. Happened on every node reboot.

- [ ] 5.2.6.1 Investigate OPNsense state timeout tuning for K8s VLAN
  - Current behavior: stale states persist for minutes after node comes back
  - Options: reduce state timeout for VLAN 30, or use adaptive timeouts

- [ ] 5.2.6.2 Evaluate OPNsense API for automated state clearing
  - Ansible pre/post-reboot task to clear states via OPNsense REST API
  - Would eliminate manual intervention during rolling reboots

---

## 5.2.7 GitLab HA Evaluation

> **Problem:** GitLab webservice is single-replica. Node reboot takes down container registry,
> causing ImagePullBackOff cascade for invoicetron and portfolio.

- [ ] 5.2.7.1 Assess memory budget for 2 replicas
  ```bash
  kubectl-homelab top pods -n gitlab --sort-by=memory
  # Each webservice replica uses ~2-3GB RAM
  # Total cluster RAM: 3 x 16GB = 48GB
  # Current usage: check if headroom exists
  ```

- [ ] 5.2.7.2 If feasible: scale webservice + registry to 2 replicas
  ```yaml
  # helm/gitlab/values.yaml
  gitlab:
    webservice:
      replicas: 2
    registry:
      replicas: 2
  ```
  - Add podAntiAffinity to spread replicas across nodes

---

## 5.2.8 Longhorn Remaining Items

- [x] 5.2.8.1 ~~`node-down-pod-deletion-policy`~~ — **Done in v0.28.2**
- [x] 5.2.8.2 ~~`orphan-resource-auto-deletion`~~ — **Done in v0.28.2**

- [ ] 5.2.8.3 Document manual recovery procedure for stuck stopped replicas
  ```bash
  # 1. Identify stopped replicas
  kubectl-homelab -n longhorn-system get replicas.longhorn.io \
    -o custom-columns=NAME:.metadata.name,VOLUME:.spec.volumeName,NODE:.spec.nodeID,STATE:.status.currentState \
    | grep stopped

  # 2. Verify volume has at least 1 healthy replica
  kubectl-homelab -n longhorn-system get replicas.longhorn.io \
    -o custom-columns=VOLUME:.spec.volumeName,STATE:.status.currentState \
    | sort | uniq -c

  # 3. Delete stopped replicas (Longhorn auto-rebuilds)
  kubectl-homelab -n longhorn-system delete replicas.longhorn.io <name>

  # 4. Monitor rebuild
  kubectl-homelab -n longhorn-system get volumes.longhorn.io -w
  ```

- [ ] 5.2.8.4 Verify `replica-soft-anti-affinity` is `false`
  ```bash
  kubectl-homelab -n longhorn-system get settings replica-soft-anti-affinity -o jsonpath='{.value}'
  # Must be: false
  ```

---

## 5.2.9 PodDisruptionBudgets

> **CKA Topic:** PDBs prevent voluntary disruptions (drain, upgrade) from killing too many pods at once

Without PDBs, `kubectl drain` or a rolling upgrade can terminate all replicas of a service simultaneously. PDBs enforce a minimum availability guarantee during voluntary disruptions.

- [ ] 5.2.9.1 Add PDBs for services with 2+ replicas
  ```yaml
  apiVersion: policy/v1
  kind: PodDisruptionBudget
  metadata:
    name: ghost-pdb
    namespace: ghost-prod
  spec:
    minAvailable: 1
    selector:
      matchLabels:
        app: ghost
  ```
  - Apply to: any Deployment/StatefulSet with replicas >= 2
  - If GitLab HA is enabled (5.2.7), add PDBs for webservice and registry

- [ ] 5.2.9.2 Add PDBs for critical single-replica services
  ```yaml
  # For single-replica services, use maxUnavailable: 0 during maintenance
  # This prevents accidental eviction — drain will block until you scale up or remove PDB
  apiVersion: policy/v1
  kind: PodDisruptionBudget
  metadata:
    name: vault-pdb
    namespace: vault
  spec:
    maxUnavailable: 0
    selector:
      matchLabels:
        app.kubernetes.io/name: vault
  ```
  - Evaluate for: Vault, Prometheus, Grafana (services where downtime causes cascading alerts)
  - Trade-off: `maxUnavailable: 0` blocks `kubectl drain` — must remove PDB before maintenance

- [ ] 5.2.9.3 Verify PDBs are respected during drain
  ```bash
  kubectl-homelab get pdb -A
  # Test: cordon a node and attempt drain — PDB should block if it would violate budget
  kubectl-homelab cordon <node>
  kubectl-homelab drain <node> --ignore-daemonsets --delete-emptydir-data --dry-run=client
  kubectl-homelab uncordon <node>
  ```

---

## 5.2.10 Documentation

- [ ] 5.2.10.1 Update VERSIONS.md
  ```
  | Velero | X.X.X | Backup and restore |
  ```

- [ ] 5.2.10.2 Update `docs/context/Security.md` with:
  - Resource quota strategy
  - Backup schedule and retention policy
  - Recovery time documentation

- [ ] 5.2.10.3 Update `docs/reference/CHANGELOG.md`

---

## Verification Checklist

- [ ] All workload pods have resource requests and limits
- [ ] ResourceQuotas on application namespaces
- [ ] LimitRange defaults on application namespaces
- [ ] Velero installed, NFS backup location accessible
- [ ] Scheduled backup running daily (includes arr-stack, atuin, karakeep)
- [ ] Test backup created and restore verified
- [ ] Pod eviction timing documented and tuned for stateless services
- [ ] PodDisruptionBudgets on multi-replica and critical services
- [ ] OPNsense state issue investigated (automated or timeout tuned)
- [ ] GitLab HA evaluated (scaled if memory permits)
- [ ] Longhorn `replica-soft-anti-affinity` confirmed `false`
- [ ] Stopped replica recovery procedure documented

---

## Rollback

**Resource limits cause OOMKilled:**
```bash
# Increase the limit in the manifest
# Or temporarily remove limits to stabilize
kubectl-homelab patch deployment <name> -n <ns> \
  --type=json -p='[{"op": "remove", "path": "/spec/template/spec/containers/0/resources/limits"}]'
```

**Velero backup fails:**
```bash
kubectl-homelab logs -n velero -l app.kubernetes.io/name=velero
velero backup describe <name> --details
# Common: NFS mount permissions, node agent not running
```

---

## Deferred to Phase 6 (ArgoCD)

These items are explicitly NOT in Phase 5:

| Item | Why Deferred |
|------|-------------|
| Manifest directory reorganization | ArgoCD ApplicationSets use directory structure — reorganize right before ArgoCD setup |
| Automated version management | ArgoCD + Renovate Bot solves this permanently |
| App version updates (Ghost, etc.) | One-off bumps are maintenance, not a phase. Automated pipeline comes with ArgoCD |

---

## Final: Commit and Release

- [ ] `/audit-security` then `/commit`
- [ ] `/release v0.32.0 "Resilience & Backup"`
- [ ] `mv docs/todo/phase-5.2-resilience-backup.md docs/todo/completed/`
