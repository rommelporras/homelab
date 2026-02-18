---
tags: [homelab, kubernetes, upgrades, runbook]
updated: 2026-02-18
---

# Upgrade & Rollback Runbook

> Procedures for upgrading every component type in the homelab cluster.
> **Rule:** Always read upstream release notes before upgrading anything.

## Pre-Upgrade Checklist (EVERY upgrade)

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

## By Component Type

### Helm Charts

**Applies to:** Prometheus stack, Grafana, Loki, Alloy, cert-manager, Longhorn, Cilium, metrics-server, blackbox-exporter, Tailscale operator, GitLab, GitLab Runner, Intel GPU plugin

```bash
# Upgrade
helm-homelab upgrade <release> <chart> -n <namespace> -f helm/<chart>/values.yaml

# Verify
kubectl-homelab -n <namespace> rollout status deployment/<name>

# Rollback (to previous revision)
helm-homelab history <release> -n <namespace>  # find revision number
helm-homelab rollback <release> <revision> -n <namespace>
```

**Risk:** Low — Helm tracks revisions. PVC data persists across rollback.

### Raw Manifests

**Applies to:** Karakeep, Ghost, AdGuard, Homepage, MySpeed, Uptime Kuma, Firefox, Ollama, ARR stack apps, Cloudflare tunnel, portfolio, invoicetron

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

### Kubernetes (kubeadm)

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

### kube-vip (Static Pod)

```bash
# On EACH control plane node (one at a time):
# 1. Edit the static pod manifest
sudo vi /etc/kubernetes/manifests/kube-vip.yaml
# 2. Change image tag to new version
# 3. kubelet auto-restarts the pod

# Verify
kubectl-homelab -n kube-system get pods | grep kube-vip

# Rollback: edit manifest back to previous tag on each node
```

**Risk:** Medium — VIP may briefly drop during pod restart. Update one node at a time.

### Longhorn

```bash
# Upgrade via Helm
helm-homelab upgrade longhorn longhorn/longhorn -n longhorn-system -f helm/longhorn/values.yaml

# Verify
kubectl-homelab -n longhorn-system get pods
kubectl-homelab -n longhorn-system get volumes.longhorn.io
```

**Risk:** HIGHEST — **Longhorn CANNOT be downgraded.** Always read release notes. Backup all critical PVCs before upgrading.

### Cilium

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

## Risk Summary

| Component | Upgrade Method | Rollback | Risk | Notes |
|-----------|---------------|----------|------|-------|
| Helm charts | `helm upgrade` | `helm rollback` | Low | PVC data persists |
| Raw manifests | `kubectl apply` | `kubectl rollout undo` | Low | PVC data persists |
| Kubernetes | `kubeadm upgrade` | etcd restore (manual) | **High** | 1 minor at a time |
| kube-vip | Edit static pod | Edit manifest back | Medium | VIP brief drop |
| Longhorn | `helm upgrade` | **Cannot downgrade** | **Highest** | Read release notes! |
| Cilium | `helm upgrade` | `helm rollback` | Medium-High | Brief network disruption |

## Service-Specific Warnings

### Ghost (Blog)
- Major versions may include database migrations that run automatically on startup
- Back up the Ghost content database PVC before major upgrades
- Check the Ghost changelog for breaking theme/API changes

### GitLab CE
- GitLab has strict upgrade path requirements — use the [upgrade path tool](https://gitlab-com.gitlab.io/support/toolbox/upgrade-path/)
- Never skip required stop versions (e.g., 16.x → 17.x has mandatory stops)
- Database migrations run on startup and can take several minutes

### Jellyfin
- Database schema changes are one-way — cannot downgrade after migration
- Check plugin compatibility before major upgrades

### PostgreSQL (Invoicetron)
- Major version upgrades require `pg_dump`/`pg_restore` (data directory not compatible)
- Minor/patch upgrades are safe (just bump image tag)

### Meilisearch (Karakeep)
- Major version upgrades may require re-indexing all data
- Export data before upgrading, import after

### ARR Stack (Sonarr/Radarr/Prowlarr)
- LinuxServer.io images auto-migrate databases on startup
- Back up the config PVC before major version bumps
- Check TRaSH Guides for any custom format changes

## Emergency Rollback

If something goes catastrophically wrong:

```bash
# 1. For Helm releases
helm-homelab rollback <release> 0 -n <namespace>  # 0 = previous revision

# 2. For manifest deployments
kubectl-homelab -n <namespace> rollout undo deployment/<name>

# 3. For Kubernetes itself (nuclear option)
# Restore etcd from backup on cp1:
sudo etcdctl snapshot restore /tmp/etcd-pre-upgrade-<date>.db \
  --data-dir=/var/lib/etcd-restore
# Then swap data directories and restart etcd
# This is complex — see kubeadm docs for full procedure

# 4. For Longhorn — CANNOT rollback
# Only option: restore PVC data from Longhorn snapshots/backups
```

## Version Tracking

Automated version checking is handled by:
- **Renovate Bot** — Opens PRs for outdated container images in manifests
- **version-checker** — Prometheus metrics for all running images + K8s version
- **Weekly CronJob** — Nova checks Helm chart drift, sends Discord digest

See [[Monitoring]] for dashboard and alert details.
