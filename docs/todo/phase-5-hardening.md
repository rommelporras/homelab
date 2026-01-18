# Phase 5: Production Hardening

> **Status:** ⬜ Planned
> **Target:** v0.10.0
> **CKA Topics:** RBAC, NetworkPolicy, Pod Security Standards, Resource Quotas

---

## 5.1 Network Policies

> **WARNING:** Incorrect NetworkPolicies can break cluster. Test in warn mode first.

- [ ] 5.1.1 Create default-deny for databases namespace
  ```yaml
  apiVersion: networking.k8s.io/v1
  kind: NetworkPolicy
  metadata:
    name: default-deny-ingress
    namespace: databases
  spec:
    podSelector: {}
    policyTypes: [Ingress]
  ```

- [ ] 5.1.2 Allow specific traffic to PostgreSQL (from media namespace)

- [ ] 5.1.3 Test that Immich can still connect

- [ ] 5.1.4 Test that unauthorized pods CANNOT connect

- [ ] 5.1.5 Document all NetworkPolicies in /manifests

---

## 5.2 RBAC Policies

- [ ] 5.2.1 Create read-only ServiceAccount for monitoring

- [ ] 5.2.2 Create namespace-scoped admin Roles

- [ ] 5.2.3 Test with `kubectl auth can-i`

---

## 5.3 Pod Security Standards

- [ ] 5.3.1 Audit existing pods for security issues
  ```bash
  kubectl-homelab label namespace media pod-security.kubernetes.io/warn=restricted --dry-run=server
  ```

- [ ] 5.3.2 Fix pods that violate restricted profile

- [ ] 5.3.3 Enforce baseline on all namespaces

---

## 5.4 Resource Quotas

- [ ] 5.4.1 Analyze current resource usage
  ```bash
  kubectl-homelab top pods -A
  ```

- [ ] 5.4.2 Set resource requests/limits on all workloads

- [ ] 5.4.3 Create ResourceQuotas per namespace

---

## 5.5 Backup Strategy (Velero)

- [ ] 5.5.1 Install Velero

- [ ] 5.5.2 Configure backup to NFS

- [ ] 5.5.3 Create scheduled backups

- [ ] 5.5.4 Test restore procedure

---

## Final: Documentation Updates

- [ ] Update VERSIONS.md
  - Add Velero and security components
  - Add version history entry

- [ ] Update docs/reference/CHANGELOG.md
  - Add Phase 5 section with milestone, decisions, lessons learned

- [ ] Move this file to completed folder
  ```bash
  mv docs/todo/phase-5-hardening.md docs/todo/completed/
  ```
