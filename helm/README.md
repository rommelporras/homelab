# Helm Values

This directory contains Helm values files for applications deployed to the homelab cluster.

## Why Values Files?

Instead of using `--set` flags:
```bash
# Hard to read, easy to make mistakes
helm-homelab install longhorn longhorn/longhorn \
  --set defaultSettings.defaultReplicaCount=2 \
  --set defaultSettings.defaultDataPath=/var/lib/longhorn \
  --set persistence.defaultClass=true
```

We use values files:
```bash
# Clean, version-controlled, documented
helm-homelab install longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --version 1.10.1 \
  --values helm/longhorn/values.yaml
```

## Directory Structure

```
helm/
├── README.md              # This file
├── longhorn/
│   └── values.yaml        # Longhorn distributed storage
├── prometheus/            # (v0.4.0)
│   └── values.yaml        # kube-prometheus-stack
└── loki/                  # (v0.4.0)
    └── values.yaml        # Loki log aggregation
```

## Installation Commands

### Prerequisites
```bash
# Add Helm repos (one-time setup)
helm-homelab repo add longhorn https://charts.longhorn.io
helm-homelab repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm-homelab repo add grafana https://grafana.github.io/helm-charts
helm-homelab repo update
```

### Longhorn (v0.3.0)
```bash
# 1. Create namespace with privileged security (Longhorn needs disk access)
kubectl-homelab create namespace longhorn-system
kubectl-homelab label namespace longhorn-system \
  pod-security.kubernetes.io/enforce=privileged

# 2. Install Longhorn
helm-homelab install longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --version 1.10.1 \
  --values helm/longhorn/values.yaml

# 3. Verify
kubectl-homelab -n longhorn-system get pods
kubectl-homelab get storageclass
```

### Prometheus + Grafana (v0.4.0)
```bash
# See helm/prometheus/values.yaml when created
```

### Loki (v0.4.0)
```bash
# See helm/loki/values.yaml when created
```

## Upgrading Charts

```bash
# Check current version
helm-homelab list -n longhorn-system

# Check available versions
helm-homelab search repo longhorn/longhorn --versions

# Upgrade (always specify version!)
helm-homelab upgrade longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --version 1.10.2 \
  --values helm/longhorn/values.yaml
```

## Viewing Default Values

To see all available options for a chart:
```bash
helm-homelab show values longhorn/longhorn > longhorn-defaults.yaml
```

Compare with our values to understand what we're customizing.

## CKA Relevance

Understanding Helm is useful for CKA because:
- Many exam questions involve deploying applications
- Helm is listed as an allowed tool during the exam
- Understanding what Helm creates helps debug issues

After installing with Helm, always explore what was created:
```bash
kubectl-homelab -n longhorn-system get all
kubectl-homelab -n longhorn-system get pv,pvc
kubectl-homelab -n longhorn-system get storageclass
```
