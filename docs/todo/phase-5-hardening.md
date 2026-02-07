# Phase 5: Production Hardening

> **Status:** ⬜ Planned
> **Target:** v0.24.0
> **Prerequisite:** Phase 4.9 complete, all applications migrated
> **DevOps Topics:** Security posture, backup/restore, defense in depth
> **CKA Topics:** RBAC, NetworkPolicy, Pod Security Standards, Resource Quotas

> **Purpose:** Harden the cluster for production-like reliability and security
>
> **Learning Goal:** Understand Kubernetes security model and best practices

---

## Why Hardening Matters

| Risk | Without Hardening | With Hardening |
|------|-------------------|----------------|
| Pod compromise | Attacker can reach any pod | NetworkPolicy limits blast radius |
| Privilege escalation | Container → Node access | PSS prevents dangerous capabilities |
| Resource exhaustion | One pod starves others | ResourceQuotas enforce limits |
| Data loss | No backups | Velero restores cluster state |
| Credential theft | Secrets readable by all | RBAC limits access |

---

## 5.1 Network Policies

> **WARNING:** Incorrect NetworkPolicies can break cluster. Test in warn mode first.
>
> **CKA Topic:** NetworkPolicy is a frequent exam topic

### Concept: Default Deny

```
Without NetworkPolicy:          With Default Deny:
┌─────────────────────┐        ┌─────────────────────┐
│     namespace       │        │     namespace       │
│  ┌───┐ ←──→ ┌───┐  │        │  ┌───┐     ┌───┐   │
│  │ A │      │ B │  │        │  │ A │ ✗   │ B │   │
│  └───┘ ←──→ └───┘  │        │  └───┘     └───┘   │
│    ↑↓        ↑↓    │        │    ✗         ✗     │
│  ┌───┐      ┌───┐  │        │  ┌───┐     ┌───┐   │
│  │ C │      │ D │  │        │  │ C │     │ D │   │
│  └───┘      └───┘  │        │  └───┘     └───┘   │
└─────────────────────┘        └─────────────────────┘
  All pods can talk              Must explicitly allow
```

- [ ] 5.1.1 Audit current network connectivity
  ```bash
  # List all pods and their namespaces
  kubectl-homelab get pods -A -o wide

  # Test connectivity between pods (example)
  kubectl-homelab run test --rm -it --image=curlimages/curl -n home -- \
    curl -s --max-time 5 http://prometheus-grafana.monitoring.svc:80 && echo "OPEN"
  ```

- [ ] 5.1.2 Create default-deny for invoicetron namespace
  ```bash
  kubectl-homelab apply -f manifests/network-policies/invoicetron-default-deny.yaml
  ```
  ```yaml
  # manifests/network-policies/invoicetron-default-deny.yaml
  apiVersion: networking.k8s.io/v1
  kind: NetworkPolicy
  metadata:
    name: default-deny-ingress
    namespace: invoicetron
  spec:
    podSelector: {}  # Applies to ALL pods in namespace
    policyTypes:
      - Ingress      # Block all incoming traffic by default
  ```

- [ ] 5.1.3 Allow traffic to PostgreSQL from Invoicetron app only
  ```yaml
  # manifests/network-policies/invoicetron-postgres-allow.yaml
  apiVersion: networking.k8s.io/v1
  kind: NetworkPolicy
  metadata:
    name: allow-postgres-from-app
    namespace: invoicetron
  spec:
    podSelector:
      matchLabels:
        app: postgresql
    policyTypes:
      - Ingress
    ingress:
      - from:
          - podSelector:
              matchLabels:
                app: invoicetron
        ports:
          - protocol: TCP
            port: 5432
  ```

- [ ] 5.1.4 Test that authorized traffic works
  ```bash
  # From invoicetron pod, should succeed
  kubectl-homelab exec -n invoicetron deployment/invoicetron -- \
    nc -zv postgresql 5432
  ```

- [ ] 5.1.5 Test that unauthorized traffic is blocked
  ```bash
  # From another namespace, should fail (timeout)
  kubectl-homelab run test --rm -it --image=curlimages/curl -n home -- \
    nc -zv postgresql.invoicetron.svc 5432 -w 5
  ```

- [ ] 5.1.6 Apply NetworkPolicies to other namespaces
  ```bash
  # Create policies for:
  # - monitoring (Prometheus can scrape, Grafana accessible)
  # - home (Homepage, AdGuard)
  # - gitlab (internal communication)
  ```

---

## 5.2 RBAC Policies

> **CKA Topic:** RBAC is heavily tested on the exam

### Concept: Least Privilege

```
Without RBAC:                    With RBAC:
┌─────────────────────┐         ┌─────────────────────┐
│  ServiceAccount     │         │  ServiceAccount     │
│  can do ANYTHING    │         │  ┌───────────────┐  │
│  in the cluster     │         │  │ Only what's   │  │
│                     │         │  │ explicitly    │  │
│                     │         │  │ allowed       │  │
└─────────────────────┘         │  └───────────────┘  │
                                └─────────────────────┘
```

- [ ] 5.2.1 Audit existing ServiceAccounts
  ```bash
  # List all ServiceAccounts
  kubectl-homelab get serviceaccounts -A

  # Check what default SA can do
  kubectl-homelab auth can-i --list --as=system:serviceaccount:default:default
  ```

- [ ] 5.2.2 Create read-only ServiceAccount for monitoring
  ```yaml
  # manifests/rbac/monitoring-readonly.yaml
  apiVersion: v1
  kind: ServiceAccount
  metadata:
    name: monitoring-readonly
    namespace: monitoring
  ---
  apiVersion: rbac.authorization.k8s.io/v1
  kind: ClusterRole
  metadata:
    name: monitoring-readonly
  rules:
    - apiGroups: [""]
      resources: ["pods", "nodes", "services", "endpoints"]
      verbs: ["get", "list", "watch"]
    - apiGroups: ["apps"]
      resources: ["deployments", "statefulsets", "daemonsets"]
      verbs: ["get", "list", "watch"]
  ---
  apiVersion: rbac.authorization.k8s.io/v1
  kind: ClusterRoleBinding
  metadata:
    name: monitoring-readonly
  subjects:
    - kind: ServiceAccount
      name: monitoring-readonly
      namespace: monitoring
  roleRef:
    kind: ClusterRole
    name: monitoring-readonly
    apiGroup: rbac.authorization.k8s.io
  ```

- [ ] 5.2.3 Test RBAC with kubectl auth can-i
  ```bash
  # Should succeed (read allowed)
  kubectl-homelab auth can-i get pods -n default \
    --as=system:serviceaccount:monitoring:monitoring-readonly

  # Should fail (delete not allowed)
  kubectl-homelab auth can-i delete pods -n default \
    --as=system:serviceaccount:monitoring:monitoring-readonly
  ```

- [ ] 5.2.4 Review and tighten GitLab deploy ServiceAccount
  ```bash
  # Check current permissions
  kubectl-homelab get rolebinding -n portfolio -o yaml

  # Ensure it only has: get, patch, update on deployments
  # Remove any unnecessary permissions
  ```

---

## 5.3 Pod Security Standards (PSS)

> **CKA Topic:** PSS replaces deprecated PodSecurityPolicy

### Three Levels

| Level | What It Allows | Use Case |
|-------|---------------|----------|
| **Privileged** | Everything | System components (node-exporter) |
| **Baseline** | Safe defaults, no privileged | Most applications |
| **Restricted** | Maximum security | Sensitive workloads |

- [ ] 5.3.1 Audit existing pods for security issues
  ```bash
  # Check what would happen with restricted profile
  kubectl-homelab label namespace portfolio \
    pod-security.kubernetes.io/warn=restricted \
    --dry-run=server -o yaml
  ```

- [ ] 5.3.2 List current namespace security levels
  ```bash
  kubectl-homelab get namespaces -o custom-columns=\
  NAME:.metadata.name,\
  ENFORCE:.metadata.labels.pod-security\\.kubernetes\\.io/enforce
  ```

- [ ] 5.3.3 Fix pods that violate baseline profile
  ```bash
  # Common fixes:
  # - Add securityContext.runAsNonRoot: true
  # - Remove privileged: true (if not needed)
  # - Add readOnlyRootFilesystem: true
  # - Remove hostNetwork, hostPID, hostIPC
  ```

- [ ] 5.3.4 Enforce baseline on application namespaces
  ```bash
  # Apply baseline to all app namespaces
  for ns in portfolio invoicetron home; do
    kubectl-homelab label namespace $ns \
      pod-security.kubernetes.io/enforce=baseline \
      pod-security.kubernetes.io/warn=restricted \
      --overwrite
  done
  ```

---

## 5.4 Resource Quotas

> **Purpose:** Prevent one application from starving others

- [ ] 5.4.1 Analyze current resource usage
  ```bash
  # Per-node usage
  kubectl-homelab top nodes

  # Per-pod usage
  kubectl-homelab top pods -A --sort-by=memory

  # Check which pods don't have limits
  kubectl-homelab get pods -A -o json | jq -r '
    .items[] |
    select(.spec.containers[].resources.limits == null) |
    "\(.metadata.namespace)/\(.metadata.name)"
  '
  ```

- [ ] 5.4.2 Set resource requests/limits on all workloads
  ```bash
  # Review and update:
  # - manifests/home/adguard/deployment.yaml
  # - manifests/portfolio/deployment.yaml
  # - manifests/invoicetron/deployment.yaml

  # All Deployments should have:
  # resources:
  #   requests:
  #     memory: "Xmi"
  #     cpu: "Ym"
  #   limits:
  #     memory: "Xmi"
  #     cpu: "Ym"
  ```

- [ ] 5.4.3 Create ResourceQuota for invoicetron namespace
  ```yaml
  # manifests/resource-quotas/invoicetron-quota.yaml
  apiVersion: v1
  kind: ResourceQuota
  metadata:
    name: invoicetron-quota
    namespace: invoicetron
  spec:
    hard:
      requests.cpu: "2"
      requests.memory: 4Gi
      limits.cpu: "4"
      limits.memory: 8Gi
      pods: "10"
      persistentvolumeclaims: "5"
  ```

- [ ] 5.4.4 Verify quota is enforced
  ```bash
  kubectl-homelab describe resourcequota -n invoicetron
  ```

---

## 5.5 Backup Strategy (Velero)

> **Purpose:** Recover from disasters (accidental deletion, corruption, node failure)

### What Velero Backs Up

| Resource | Included | Notes |
|----------|----------|-------|
| K8s manifests | Yes | Deployments, Services, ConfigMaps, Secrets |
| PVC data | Yes (with restic) | Requires annotation |
| etcd | No | Use kubeadm snapshot for etcd |

- [ ] 5.5.1 Add Velero Helm repo
  ```bash
  helm-homelab repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts --force-update
  helm-homelab repo update
  ```

- [ ] 5.5.2 Create NFS backup location on NAS
  ```bash
  # On NAS, create:
  # /volume1/k8s-backups/velero

  # Test NFS mount from a node
  ssh k8s-cp1 "sudo mount -t nfs 10.10.30.4:/volume1/k8s-backups /mnt && ls /mnt && sudo umount /mnt"
  ```

- [ ] 5.5.3 Install Velero with NFS plugin
  ```bash
  # Create velero namespace
  kubectl-homelab create namespace velero

  # Install Velero (using NFS provider)
  helm-homelab install velero vmware-tanzu/velero \
    --namespace velero \
    --set configuration.backupStorageLocation.bucket=velero \
    --set configuration.backupStorageLocation.config.path=/volume1/k8s-backups \
    --set configuration.backupStorageLocation.provider=filesystem \
    --set snapshotsEnabled=false \
    --set deployNodeAgent=true \
    --set nodeAgent.podVolumePath=/var/lib/kubelet/pods
  ```

- [ ] 5.5.4 Create scheduled backup
  ```bash
  # Daily backup, retain 7 days
  velero schedule create daily-backup \
    --schedule="0 2 * * *" \
    --ttl 168h \
    --include-namespaces portfolio,invoicetron,home,monitoring
  ```

- [ ] 5.5.5 Test backup
  ```bash
  # Create manual backup
  velero backup create test-backup --include-namespaces portfolio

  # Check backup status
  velero backup describe test-backup
  velero backup logs test-backup
  ```

- [ ] 5.5.6 Test restore procedure
  ```bash
  # Delete a deployment (test)
  kubectl-homelab delete deployment portfolio -n portfolio

  # Restore from backup
  velero restore create --from-backup test-backup

  # Verify deployment is back
  kubectl-homelab get deployment -n portfolio
  ```

---

## 5.6 Documentation Updates

- [ ] 5.6.1 Update VERSIONS.md
  ```
  # Add to Infrastructure section:
  | Velero | 1.x.x | Backup and restore |

  # Add to Version History:
  | YYYY-MM-DD | Phase 5: Production hardening |
  ```

- [ ] 5.6.2 Create docs/context/Security.md
  ```
  Document:
  - NetworkPolicy strategy
  - RBAC roles and bindings
  - PSS levels per namespace
  - Backup schedule and retention
  ```

- [ ] 5.6.3 Update docs/reference/CHANGELOG.md
  - Add Phase 5 section with security decisions

---

## Verification Checklist

- [ ] NetworkPolicies in place for sensitive namespaces
- [ ] Default deny verified (unauthorized traffic blocked)
- [ ] RBAC ServiceAccounts have minimal permissions
- [ ] PSS baseline enforced on application namespaces
- [ ] All pods have resource requests and limits
- [ ] ResourceQuotas prevent runaway resource usage
- [ ] Velero installed and backup location accessible
- [ ] Test backup created successfully
- [ ] Test restore verified working
- [ ] Documentation updated

---

## Rollback

If NetworkPolicies break connectivity:

```bash
# 1. Identify breaking policy
kubectl-homelab get networkpolicy -A

# 2. Delete the problematic policy
kubectl-homelab delete networkpolicy <name> -n <namespace>

# 3. Connectivity should restore immediately
```

If PSS blocks pods:

```bash
# 1. Change to warn mode
kubectl-homelab label namespace <ns> \
  pod-security.kubernetes.io/enforce=privileged \
  --overwrite

# 2. Fix pod security context
# 3. Re-apply enforcement
```

---

## Troubleshooting

### NetworkPolicy blocking legitimate traffic

```bash
# Check if policy exists
kubectl-homelab get networkpolicy -n <namespace>

# Describe policy to see rules
kubectl-homelab describe networkpolicy <name> -n <namespace>

# Test connectivity with debug pod
kubectl-homelab run test --rm -it --image=curlimages/curl -n <namespace> -- \
  curl -v <target-service>
```

### Velero backup fails

```bash
# Check Velero logs
kubectl-homelab logs -n velero -l app.kubernetes.io/name=velero

# Check backup status
velero backup describe <backup-name> --details

# Common issues:
# - NFS mount permissions
# - PVC not annotated for backup
# - Node agent not running on all nodes
```

---

## Final: Commit and Release

- [ ] Commit changes
  ```bash
  /commit
  ```

- [ ] Release v0.10.0
  ```bash
  /release v0.10.0
  ```

- [ ] Move this file to completed folder
  ```bash
  mv docs/todo/phase-5-hardening.md docs/todo/completed/
  ```
