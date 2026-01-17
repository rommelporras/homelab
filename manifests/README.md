# Kubernetes Manifests

This directory contains raw Kubernetes YAML manifests for resources we manage directly (not via Helm).

## Why Manifests vs Helm?

| Use Case | Tool | Reason |
|----------|------|--------|
| Complex apps (Prometheus, Longhorn) | Helm | Many resources, configurable templates |
| Simple resources (PV, ConfigMap) | kubectl + YAML | Direct, educational, no abstraction |
| One-off resources | kubectl + YAML | Not worth a Helm chart |

## Directory Structure

```
manifests/
├── README.md                    # This file
└── storage/
    └── nfs-immich.yaml          # NFS PV for Immich media from NAS
```

## Applying Manifests

```bash
# Apply a single manifest
kubectl-homelab apply -f manifests/storage/nfs-immich.yaml

# Apply all manifests in a directory
kubectl-homelab apply -f manifests/storage/

# Dry-run to see what would be created
kubectl-homelab apply -f manifests/storage/ --dry-run=client
```

## CKA Practice

Writing and applying manifests is core CKA skill. Practice:

```bash
# Create manifest from scratch (imperative, then export)
kubectl-homelab run nginx --image=nginx --dry-run=client -o yaml > pod.yaml

# Explain any resource to see available fields
kubectl-homelab explain pv.spec.nfs
kubectl-homelab explain pvc.spec.selector

# Validate manifest syntax
kubectl-homelab apply -f manifest.yaml --dry-run=server
```

## Storage Manifests

### nfs-immich.yaml

Creates a PersistentVolume pointing to your Dell 5090 NAS for storing Immich media (photos, videos).

**Key concepts:**
- Static PV provisioning (admin creates PV manually)
- Access modes: ReadWriteMany (RWX) for multi-pod access
- Reclaim policy: Retain (never delete NAS data!)

**Before applying:**
1. Verify NFS export exists: `showmount -e 10.10.30.4`
2. Create immich namespace: `kubectl-homelab create namespace immich`
3. Verify nfs-common is installed on nodes

**Verify binding:**
```bash
kubectl-homelab get pv
kubectl-homelab get pvc -n immich
# PVC STATUS should be "Bound"
```
