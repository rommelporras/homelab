# Phase 3.1-3.4: Storage Infrastructure — COMPLETE

> **Status:** ✅ Released in v0.3.0
> **Completed:** January 17, 2026
> **CKA Topics:** PV/PVC, StorageClass, Dynamic Provisioning

---

## Summary

Longhorn distributed storage + NFS integration with Dell 5090 NAS.

## Completed Tasks

### 3.1 Longhorn Prerequisites

- [x] 3.1.1 Create Longhorn data directory ✓ (via 06-storage-prereqs.yml)
- [x] 3.1.2 Verify disk space (~400GB free per node) ✓
- [x] 3.1.3 Verify iscsid is active ✓
- [x] 3.1.4 Install NFS client ✓

### 3.2 Install Longhorn

- [x] 3.2.1 Add Helm repo ✓
- [x] 3.2.2 Create namespace with privileged security ✓
- [x] 3.2.3 Remove control-plane taints (homelab only) ✓ (via 07-remove-taints.yml)
- [x] 3.2.4 Install Longhorn with version pinning ✓
- [x] 3.2.5 Wait for all pods to be Running ✓ (23 pods)
- [x] 3.2.6 Verify Longhorn nodes are schedulable ✓

### 3.3 Verify Longhorn Storage

- [x] 3.3.1 Verify StorageClass is default ✓
- [x] 3.3.2 Create test PVC ✓
- [x] 3.3.3 Verify PVC is Bound ✓
- [x] 3.3.4 Create test pod that uses PVC ✓
- [x] 3.3.5 Verify data written ✓
- [x] 3.3.6 Verify replication (check Longhorn UI) ✓
- [x] 3.3.7 Cleanup test resources ✓

### 3.4 Configure NFS for Media Storage

- [x] 3.4.1 Enable NFS service in OMV ✓
- [x] 3.4.2 Create Immich subfolder on NAS ✓
- [x] 3.4.3 Verify NFS export exists ✓
- [x] 3.4.4 Verify NFS exports are accessible from cluster ✓
- [x] 3.4.5 Review the NFS PersistentVolume manifest ✓
- [ ] 3.4.6 Create NFS PersistentVolume for media (deferred - needs immich namespace)
- [x] 3.4.7 Test NFS mount in a pod ✓

## Configuration Files

- `helm/longhorn/values.yaml` — Longhorn Helm values
- `manifests/storage/nfs-immich.yaml` — NFS PV for Immich

## Install Commands

```bash
# Longhorn
helm-homelab install longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --version 1.10.1 \
  --values helm/longhorn/values.yaml

# Verify
kubectl-homelab -n longhorn-system get pods
kubectl-homelab get storageclass
```

## Related Documents

- [STORAGE_SETUP.md](../../STORAGE_SETUP.md) — Longhorn installation guide
- [EXISTING_INFRA.md](../../EXISTING_INFRA.md) — Dell 5090 NAS integration
